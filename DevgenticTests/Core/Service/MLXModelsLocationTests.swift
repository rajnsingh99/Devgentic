// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXModelsLocationTests.swift
//  DevgenticTests
//
//  G14 — custom models directory, import, and Reveal in Finder.
//
//  ⚠️ These do NOT write to `UserDefaults` for the bookmark, so a test run can never leave the
//  developer's real models directory repointed at a temp folder that later gets deleted.
//  Coverage is the pure logic: usability checks, repo-id suggestion, and import validation.
//

import XCTest
@testable import devgentic

@MainActor
final class MLXModelsLocationTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-location-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    /// ⚠️ The picker can hand back a URL the app cannot actually use — a folder under
    /// Desktop/Documents/Downloads is subject to TCC. Checking explicitly beats a
    /// mysteriously empty model list.
    func testUsabilityRequiresAnExistingReadableWritableDirectory() throws {
        XCTAssertTrue(MLXModelsLocation.isUsable(root))
        XCTAssertFalse(MLXModelsLocation.isUsable(root.appendingPathComponent("does-not-exist")))

        // A file is not a directory.
        let file = root.appendingPathComponent("a-file.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertFalse(MLXModelsLocation.isUsable(file))
    }

    /// The default must resolve on a normal machine — it is the fallback everything else
    /// depends on, and it replaced a `!` force-unwrap.
    func testDefaultDirectoryResolves() throws {
        let fallback = try XCTUnwrap(MLXModelsLocation.defaultDirectory)
        XCTAssertTrue(fallback.path.contains("huggingface/models"))
    }

    /// ⚠️ Rewritten 2026-08-03. This called `effectiveDirectory()` unconditionally and asserted
    /// only that the result was non-nil. On a machine with a custom directory configured, that
    /// path resolves the stored bookmark and — if macOS reports it stale — calls
    /// `setCustomDirectory`, a `UserDefaults` WRITE, which the header above promises these
    /// tests never do. It now takes only the read-only branch, and asserts the actual rule.
    func testEffectiveDirectoryFallsBackToTheDefault() throws {
        try XCTSkipIf(
            MLXModelsLocation.hasCustomDirectory,
            "A custom models directory is configured on this machine. Resolving it can refresh a stale bookmark, which writes UserDefaults — these tests must not touch the developer's real configuration."
        )
        XCTAssertEqual(
            MLXModelsLocation.effectiveDirectory(),
            MLXModelsLocation.defaultDirectory,
            "with no bookmark stored, the effective directory must be the default"
        )
    }
}

@MainActor
final class MLXModelImportTests: XCTestCase {

    private var root: URL!
    private var source: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-import-\(UUID().uuidString)")
        source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func service() -> MLXModelService {
        MLXModelService(modelsRootOverride: root.appendingPathComponent("store"))
    }

    private func writeModel(config: Bool = true, weights: Bool = true) throws {
        if config { try Data("{}".utf8).write(to: source.appendingPathComponent("config.json")) }
        if weights { try Data("w".utf8).write(to: source.appendingPathComponent("model.safetensors")) }
    }

    func testImportsAValidFolder() async throws {
        try writeModel()
        let service = service()

        let result = await service.importModel(from: source, as: "local/MyModel")
        guard case .success = result else { return XCTFail("valid folder was rejected: \(result)") }

        XCTAssertTrue(service.isInstalled(repoId: "local/MyModel"))
        // Copied, not moved — the user's own folder must be left alone.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("config.json").path))
    }

    func testRejectsAFolderWithNoConfig() async throws {
        try writeModel(config: false)
        let result = await service().importModel(from: source, as: "local/NoConfig")
        guard case .failure(.missingConfig) = result else { return XCTFail("expected missingConfig, got \(result)") }
    }

    func testRejectsAFolderWithNoWeights() async throws {
        try writeModel(weights: false)
        let result = await service().importModel(from: source, as: "local/NoWeights")
        guard case .failure(.missingWeights) = result else { return XCTFail("expected missingWeights, got \(result)") }
    }

    /// ⚠️ Applies the same completeness rule as the scan (A2). Importing a truncated repo
    /// would reproduce the exact "shows as Installed, fails at load" bug that fix removed.
    func testRejectsATruncatedShardedFolder() async throws {
        try writeModel(weights: false)
        let names = (1...4).map { String(format: "model-%05d-of-00004.safetensors", $0) }
        let map = Dictionary(uniqueKeysWithValues: names.enumerated().map { ("l.\($0.offset)", $0.element) })
        try JSONSerialization.data(withJSONObject: ["weight_map": map])
            .write(to: source.appendingPathComponent("model.safetensors.index.json"))
        // Only two of the four shards present.
        for name in names.prefix(2) {
            try Data("w".utf8).write(to: source.appendingPathComponent(name))
        }

        let result = await service().importModel(from: source, as: "local/Truncated")
        guard case .failure(.incompleteShards(let present, let expected)) = result else {
            return XCTFail("expected incompleteShards, got \(result)")
        }
        XCTAssertEqual(present, 2)
        XCTAssertEqual(expected, 4)
    }

    func testRejectsANonDirectory() async throws {
        let file = root.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: file)
        let result = await service().importModel(from: file, as: "local/File")
        guard case .failure(.notADirectory) = result else { return XCTFail("expected notADirectory, got \(result)") }
    }

    func testRejectsADuplicate() async throws {
        try writeModel()
        let service = service()
        _ = await service.importModel(from: source, as: "local/Twice")

        let second = await service.importModel(from: source, as: "local/Twice")
        guard case .failure(.alreadyInstalled) = second else { return XCTFail("expected alreadyInstalled, got \(second)") }
    }

    /// Every failure must say something the user can act on — an import that fails with a
    /// generic message leaves them with no idea what to fix.
    func testEveryImportErrorExplainsItself() {
        let errors: [MLXModelService.ImportError] = [
            .notADirectory, .missingConfig, .missingWeights,
            .incompleteShards(present: 1, expected: 3),
            .copyFailed("disk full"), .alreadyInstalled("a/b")
        ]
        let messages = errors.compactMap(\.errorDescription)
        XCTAssertEqual(messages.count, errors.count)
        XCTAssertEqual(Set(messages).count, errors.count, "two import failures share a message")
    }
}

final class SuggestedRepoIdTests: XCTestCase {

    /// A python `huggingface_hub` cache folder already encodes the full id.
    func testDecodesThePythonCacheLayout() {
        XCTAssertEqual(
            MLXModelService.suggestedRepoId(for: URL(fileURLWithPath: "/x/models--mlx-community--Phi-4")),
            "mlx-community/Phi-4"
        )
    }

    /// A plausible author directory above the model becomes the org.
    func testUsesTheParentDirectoryAsTheAuthor() {
        XCTAssertEqual(
            MLXModelService.suggestedRepoId(for: URL(fileURLWithPath: "/x/mlx-community/Qwen2.5-3B-Instruct-4bit")),
            "mlx-community/Qwen2.5-3B-Instruct-4bit"
        )
    }

    /// ⚠️ A folder sitting directly in Downloads must not be attributed to an author called
    /// "Downloads".
    func testGenericParentsDoNotBecomeAnAuthor() {
        for parent in ["Downloads", "Desktop", "Documents", "models"] {
            let suggestion = MLXService_suggestion(parent: parent)
            XCTAssertEqual(suggestion, "local/MyModel", "\(parent) was treated as a publisher")
        }
    }

    private func MLXService_suggestion(parent: String) -> String {
        MLXModelService.suggestedRepoId(for: URL(fileURLWithPath: "/x/\(parent)/MyModel"))
    }
}
