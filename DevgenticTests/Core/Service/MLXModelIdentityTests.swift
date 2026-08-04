//
//  MLXModelIdentityTests.swift
//  DevgenticTests
//
//  Batch 1 "Identity" group of the MLX Model Manager readiness plan.
//
//    A3   `displayName` re-attached the author only for `mlx-community`, so every other
//         publisher produced a bare name — and that string is the identity key everywhere.
//         12 of 18 models on the dev machine failed every exact-match lookup.
//    A17  `isInstalled` compensated with a substring `contains`, which matched a DIFFERENT
//         model whose name merely contained the candidate — showing "Installed" for a model
//         that was never downloaded, and hiding its only Download affordance.
//    B14  Duplicate ids were dropped with no log.
//
//  The two bugs are opposite errors in the same comparison, which is why derivation and
//  comparison now live together in `MLXModelIdentity` and are pinned together here.
//

import XCTest
@testable import devgentic

@MainActor
final class MLXModelIdentityTests: XCTestCase {

    private let base = URL(fileURLWithPath: "/Users/x/Library/Application Support/huggingface/models")

    private func repoId(_ path: String) -> String {
        MLXModelIdentity.canonicalRepoId(forModelAt: URL(fileURLWithPath: path), downloadBase: base)
    }

    // MARK: - A3: derivation

    /// The regression itself. Before the fix these all collapsed to the bare folder name
    /// because the author was only re-attached for a literal `mlx-community` parent.
    func testAuthorIsPreservedForEveryPublisher() async {
        XCTAssertEqual(
            repoId("\(base.path)/models/lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit"),
            "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit"
        )
        XCTAssertEqual(repoId("\(base.path)/models/NexVeridian/Qwen3-Coder-Next-8bit"),
                       "NexVeridian/Qwen3-Coder-Next-8bit")
        XCTAssertEqual(repoId("\(base.path)/models/badmadrad/Devstral-Small-2-24B-Instruct-2512-MLX-3bit"),
                       "badmadrad/Devstral-Small-2-24B-Instruct-2512-MLX-3bit")
    }

    /// The one case that always worked must keep working.
    func testMlxCommunityStillResolves() async {
        XCTAssertEqual(repoId("\(base.path)/models/mlx-community/Phi-4-mini-instruct-4bit"),
                       "mlx-community/Phi-4-mini-instruct-4bit")
    }

    /// In the python `huggingface_hub` cache `config.json` lives at
    /// `models--Org--Name/snapshots/<sha>/`, so the leaf is a commit SHA — which is why the
    /// old `modelDir.lastPathComponent.starts(with: "models--")` branch could never fire.
    func testPythonHubCacheLayoutIsDecodedFromTheAncestor() async {
        XCTAssertEqual(
            repoId("\(base.path)/models--mlx-community--Mistral-7B/snapshots/a1b2c3d4"),
            "mlx-community/Mistral-7B"
        )
    }

    func testLegacyFlatLayoutAndUnknownPathsDegradeToTheFolderName() async {
        XCTAssertEqual(repoId("\(base.path)/SomeLooseModel"), "SomeLooseModel")
        XCTAssertEqual(repoId("/somewhere/else/entirely/Foo"), "Foo")
    }

    // MARK: - A17: comparison must never use substrings

    /// THE A17 case. `Qwen2.5-7B-Instruct-4bit-DWQ` contains `Qwen2.5-7B-Instruct-4bit`, so
    /// the old `contains` reported the distinct 4bit model as installed and the store then
    /// rendered no Download button for it at all.
    func testAVariantSuffixIsNotTheSameModel() async {
        XCTAssertEqual(
            MLXModelIdentity.match(
                installed: "mlx-community/Qwen2.5-7B-Instruct-4bit-DWQ",
                candidate: "mlx-community/Qwen2.5-7B-Instruct-4bit"
            ),
            .none
        )
        XCTAssertEqual(
            MLXModelIdentity.match(
                installed: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                candidate: "mlx-community/Llama-3.2-3B-Instruct"
            ),
            .none
        )
    }

    /// Same model name, different publisher — a common mirror-upload shape on HF.
    func testSameNameFromDifferentOrgsAreDistinct() async {
        XCTAssertEqual(
            MLXModelIdentity.match(
                installed: "orgA/Llama-3.2-3B-Instruct-4bit",
                candidate: "orgB/Llama-3.2-3B-Instruct-4bit"
            ),
            .none
        )
    }

    func testExactMatchIsCaseInsensitive() async {
        XCTAssertEqual(
            MLXModelIdentity.match(installed: "MLX-Community/Phi-4", candidate: "mlx-community/phi-4"),
            .exact
        )
    }

    /// Migration path: profiles saved before the canonical-id fix stored a bare, author-less
    /// name. Those must still resolve, but the match is ambiguous so it is reported as such.
    func testBareNameFromAnOlderProfileStillResolvesButIsFlaggedLegacy() async {
        XCTAssertEqual(
            MLXModelIdentity.match(installed: "NexVeridian/Qwen3-Coder-Next-8bit",
                                   candidate: "Qwen3-Coder-Next-8bit"),
            .legacyBareName
        )
    }

    /// The legacy tolerance applies only when exactly one side carries an author — otherwise
    /// it would resurrect the cross-org false positive above.
    func testLegacyToleranceDoesNotApplyWhenBothAreQualified() async {
        XCTAssertEqual(
            MLXModelIdentity.match(installed: "orgA/Foo", candidate: "orgB/Foo"),
            .none
        )
    }

    func testEmptyIdentifiersNeverMatch() async {
        XCTAssertEqual(MLXModelIdentity.match(installed: "", candidate: ""), .none)
        XCTAssertEqual(MLXModelIdentity.match(installed: "mlx-community/Foo", candidate: "  "), .none)
    }
}

// MARK: - Service-level identity behaviour

@MainActor
final class MLXModelServiceIdentityTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-identity-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    @discardableResult
    private func installModel(_ repoId: String) throws -> URL {
        let parts = repoId.components(separatedBy: "/")
        var folder = root.appendingPathComponent("models")
        for part in parts { folder = folder.appendingPathComponent(part) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("w".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        return folder
    }

    /// End-to-end A3: the scan must record the full repo id, not the bare folder name.
    func testScanRecordsFullRepoIdsForNonMlxCommunityPublishers() async throws {
        try installModel("lmstudio-community/Qwen3.5-9B-MLX-8bit")
        try installModel("mlx-community/Phi-4-mini-instruct-4bit")

        let service = MLXModelService(modelsRootOverride: root)
        await service.forceRefreshInstalledModelsAsync()

        XCTAssertEqual(
            Set(service.installedModels.map(\.displayName)),
            ["lmstudio-community/Qwen3.5-9B-MLX-8bit", "mlx-community/Phi-4-mini-instruct-4bit"]
        )
    }

    /// The downstream consequence of A3: the coordinator's install check, the bridge's
    /// terminal-state decision and every profile lookup all use this.
    func testIsInstalledResolvesAPublisherQualifiedModel() async throws {
        try installModel("NexVeridian/Qwen3-Coder-Next-8bit")
        let service = MLXModelService(modelsRootOverride: root)
        await service.forceRefreshInstalledModelsAsync()

        XCTAssertTrue(service.isInstalled(repoId: "NexVeridian/Qwen3-Coder-Next-8bit"))
        // Migration: a profile saved before the fix stored the bare name.
        XCTAssertTrue(service.isInstalled(repoId: "Qwen3-Coder-Next-8bit"))
    }

    /// A17 at the service level: a distinct variant must still offer a Download button.
    func testIsInstalledIsFalseForADistinctVariant() async throws {
        try installModel("mlx-community/Qwen2.5-7B-Instruct-4bit-DWQ")
        let service = MLXModelService(modelsRootOverride: root)
        await service.forceRefreshInstalledModelsAsync()

        XCTAssertFalse(
            service.isInstalled(repoId: "mlx-community/Qwen2.5-7B-Instruct-4bit"),
            "a suffixed variant was treated as the base model — the A17 substring bug is back"
        )
    }

    /// B14: two publishers shipping the same folder name are now distinct entries rather
    /// than one silently swallowing the other.
    func testSameModelNameFromTwoPublishersBothSurvive() async throws {
        try installModel("orgA/Llama-3.2-3B-Instruct-4bit")
        try installModel("orgB/Llama-3.2-3B-Instruct-4bit")

        let service = MLXModelService(modelsRootOverride: root)
        await service.forceRefreshInstalledModelsAsync()

        XCTAssertEqual(service.installedModels.count, 2)
        XCTAssertTrue(service.isInstalled(repoId: "orgA/Llama-3.2-3B-Instruct-4bit"))
        XCTAssertTrue(service.isInstalled(repoId: "orgB/Llama-3.2-3B-Instruct-4bit"))
    }
}

// MARK: - A2: shard completeness

@MainActor
final class MLXShardCompletenessTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-shard-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    /// Writes a sharded repo declaring `expected` shards but only materialising `present`.
    @discardableResult
    private func makeShardedModel(_ repoId: String, expected: Int, present: Int) throws -> URL {
        let parts = repoId.components(separatedBy: "/")
        var folder = root.appendingPathComponent("models")
        for part in parts { folder = folder.appendingPathComponent(part) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))

        let names = (1...expected).map { String(format: "model-%05d-of-%05d.safetensors", $0, expected) }
        let weightMap = Dictionary(uniqueKeysWithValues: names.enumerated().map { ("layer.\($0.offset)", $0.element) })
        let index = try JSONSerialization.data(withJSONObject: ["weight_map": weightMap])
        try index.write(to: folder.appendingPathComponent("model.safetensors.index.json"))

        for name in names.prefix(present) {
            try Data("w".utf8).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    /// THE A2 case. HubApi moves each finished shard into place, so a pull killed partway
    /// leaves valid `.safetensors` beside `config.json` — enough for the old one-file check.
    func testTruncatedShardedRepoIsIncomplete() async throws {
        let folder = try makeShardedModel("mlx-community/Big-MoE", expected: 4, present: 2)

        XCTAssertTrue(MLXModelService.containsWeights(at: folder),
                      "precondition: the old check passes, which is exactly the bug")
        let result = MLXModelService.shardCompleteness(at: folder)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.expected, 4)
        XCTAssertEqual(result.present, 2)
    }

    func testCompleteShardedRepoIsComplete() async throws {
        let folder = try makeShardedModel("mlx-community/Big-MoE", expected: 4, present: 4)
        XCTAssertTrue(MLXModelService.shardCompleteness(at: folder).isComplete)
    }

    /// Unsharded repos ship no index; they must not be reported incomplete.
    func testUnshardedRepoIsTreatedAsComplete() async throws {
        var folder = root.appendingPathComponent("models/mlx-community/Small")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("w".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        folder = folder.standardizedFileURL

        XCTAssertTrue(MLXModelService.shardCompleteness(at: folder).isComplete)
    }

    /// End-to-end: a truncated model must not appear in the installed list at all, since
    /// selecting it fails at load time with a raw framework error.
    func testTruncatedModelIsExcludedFromTheInstalledScan() async throws {
        try makeShardedModel("mlx-community/Truncated", expected: 4, present: 2)
        try makeShardedModel("mlx-community/Whole", expected: 2, present: 2)

        let service = MLXModelService(modelsRootOverride: root)
        await service.forceRefreshInstalledModelsAsync()

        XCTAssertEqual(service.installedModels.map(\.displayName), ["mlx-community/Whole"])
        XCTAssertFalse(service.isInstalled(repoId: "mlx-community/Truncated"))
    }
}
