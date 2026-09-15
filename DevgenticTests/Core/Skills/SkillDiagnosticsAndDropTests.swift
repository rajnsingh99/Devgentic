// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillDiagnosticsAndDropTests.swift
//  devgenticTests
//
//  Three places where the app KNEW something and did not say so.
//

import XCTest
import UniformTypeIdentifiers
@testable import devgentic

// MARK: - Code mode's inert-skills warning

/// ⚠️⚠️ THE WARNING WENT SILENT AT THE MIGRATION AND NOTHING NOTICED. It read only the pre-V6
/// `skillConfig` blob, so once skills moved into `skillSelections` it could never fire — for exactly
/// the profiles that reach it. The state it exists to expose (a Code profile carrying skills the
/// runtime discards) became invisible.
final class CodeModeSkillDiagnosticsTests: XCTestCase {

    private func config(selections: [SkillSelection]? = nil,
                        legacy: SkillFolderConfig? = nil) -> AgentConfig {
        var c = AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                            tools: [], skillSelections: selections)
        c.skillConfig = legacy
        return c
    }

    /// **Mutation check:** drop the `skillSelections` arm and this goes red — which is the exact
    /// state the code shipped in.
    func testAV6ShapedProfileIsReported() {
        let names = CodeModeSkillDiagnostics.inertSkillNames(
            in: config(selections: [.link(skillID: "skill_1", name: "code-review")]))
        XCTAssertEqual(names, ["code-review"])
    }

    /// The legacy arm still matters for a profile that has not been through the sweep.
    func testAPreV6ProfileIsStillReported() {
        let manifest = SkillManifest(id: UUID(), name: "legacy-skill", description: "d",
                                     folderPath: "/tmp/x", resourceCount: 0, hasScripts: false,
                                     compatibility: nil, isEnabled: true, allowedTools: nil)
        let names = CodeModeSkillDiagnostics.inertSkillNames(
            in: config(legacy: SkillFolderConfig(folderURL: URL(fileURLWithPath: "/tmp"),
                                                 manifests: [manifest], lastScannedAt: Date())))
        XCTAssertEqual(names, ["legacy-skill"])
    }

    /// A half-migrated profile holding the same skill in both shapes must be reported once.
    func testASkillPresentInBothShapesIsReportedOnce() {
        let manifest = SkillManifest(id: UUID(), name: "code-review", description: "d",
                                     folderPath: "/tmp/x", resourceCount: 0, hasScripts: false,
                                     compatibility: nil, isEnabled: true, allowedTools: nil)
        let names = CodeModeSkillDiagnostics.inertSkillNames(
            in: config(selections: [.link(skillID: "skill_1", name: "code-review")],
                       legacy: SkillFolderConfig(folderURL: URL(fileURLWithPath: "/tmp"),
                                                 manifests: [manifest], lastScannedAt: Date())))
        XCTAssertEqual(names, ["code-review"])
    }

    func testADisabledSkillIsNotReported() {
        let names = CodeModeSkillDiagnostics.inertSkillNames(
            in: config(selections: [.link(skillID: "skill_1", name: "off", isEnabled: false)]))
        XCTAssertTrue(names.isEmpty)
    }

    func testAProfileWithNoSkillsReportsNothing() {
        XCTAssertTrue(CodeModeSkillDiagnostics.inertSkillNames(in: config()).isEmpty)
    }
}

// MARK: - Resolving a dropped item to a file URL

/// ⚠️⚠️ THE DOC COMMENT DESCRIBED A FIX THAT WAS NEVER MADE. It said "`loadItem` rather than
/// `loadObject(ofClass: URL.self)` … the failure is silent" — and then called the very API it warned
/// against. A drop that could not be resolved was discarded with no row, no error and no spinner.
final class SkillImportDropResolutionTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// ⚠️⚠️ THE REAL FIX, AND THE ONE WORTH PINNING. A drop resolving to nothing used to be
    /// `continue`d past in silence — the user let go over the target and the sheet did not react.
    ///
    /// **Mutation check:** return nil unconditionally from `message` and the first case goes red.
    func testADropThatResolvesToNothingProducesAMessage() throws {
        let message = try XCTUnwrap(SkillDropReport.message(resolved: 0, unreadable: 1))
        XCTAssertTrue(message.contains("could not be read"), message)
    }

    func testAPartialDropNamesHowManyWereSkipped() {
        let message = SkillDropReport.message(resolved: 2, unreadable: 1)
        XCTAssertEqual(message, "1 of 3 dropped items could not be read and were skipped. Try dragging those from Finder, or use Browse.")
    }

    /// ⚠️ Nil when everything resolved — the caller assigns this to `commitError`, so a non-nil
    /// "everything is fine" string would render as an error on a successful drop.
    func testACleanDropSaysNothing() {
        XCTAssertNil(SkillDropReport.message(resolved: 3, unreadable: 0))
    }

    /// ⚠️ REFRAMED, NOT A REGRESSION TEST. The audit claimed `loadObject(ofClass:)` returns nil for
    /// these shapes and `loadItem` does not; measured, BOTH resolve BOTH shapes, so no mutation of
    /// the API choice can fail a test. This pins the resolver's contract, nothing more — a genuine
    /// file promise arrives under a promise type identifier the drop zone does not even accept.
    func testAPlainFileURLResolves() async throws {
        let file = tempDir.appendingPathComponent("SKILL.md")
        try "---\nname: x\ndescription: d\n---\n\nbody".write(to: file, atomically: true, encoding: .utf8)

        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier,
                                            visibility: .all) { completion in
            completion(file.dataRepresentation, nil)
            return nil
        }

        let resolved = await provider.loadFileURL()
        XCTAssertEqual(resolved?.standardizedFileURL.path, file.standardizedFileURL.path,
                       "a file-URL promise delivered as bytes must still resolve — this is the arm that was missing")
    }

    /// The control: a provider carrying no file URL at all still resolves to nil, and the sheet's
    /// caller is what turns that into a message rather than silence.
    func testAProviderWithNoFileURLResolvesToNil() async {
        let provider = NSItemProvider(object: "just text" as NSString)
        let resolved = await provider.loadFileURL()
        XCTAssertNil(resolved)
    }
}
