// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillAllowedToolsWiringTests.swift
//  devgenticTests
//
//  That the `allowed-tools` declaration actually reaches the places that show it — and reaches
//  NOWHERE ELSE.
//
//  ⚠️ Policy-only tests go green over features that cannot run. `SkillToolDeclaration` being
//  correct and unused looks identical to `SkillToolDeclaration` being correct and wired, and this
//  codebase has shipped that exact shape before. Everything here goes through the real scanner, the
//  real loader, or the real tool resolver.
//

import XCTest
@testable import devgentic

final class SkillAllowedToolsWiringTests: XCTestCase {

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

    @discardableResult
    private func createSkill(name: String, allowedToolsLine: String?) throws -> URL {
        let skillDir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let declaration = allowedToolsLine.map { "\n\($0)" } ?? ""
        let content = """
        ---
        name: \(name)
        description: A skill named \(name).\(declaration)
        ---

        # \(name)
        Do the thing.
        """
        try content.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return skillDir
    }

    // MARK: - It reaches the manifest

    func testAScannedSkillCarriesItsDeclaration() throws {
        try createSkill(name: "declaring", allowedToolsLine: "allowed-tools: [Read, Grep]")
        let manifest = try XCTUnwrap(try SkillFolderScanner.scan(rootFolder: tempDir).first)
        XCTAssertEqual(manifest.allowedTools, ["Read", "Grep"])
    }

    func testASkillWithoutTheFieldCarriesNil() throws {
        try createSkill(name: "silent", allowedToolsLine: nil)
        let manifest = try XCTUnwrap(try SkillFolderScanner.scan(rootFolder: tempDir).first)
        XCTAssertNil(manifest.allowedTools)
    }

    // MARK: - The shell OFFER (the one place a declaration influences anything, and it ends at a click)

    /// ⚠️ MOVED to `SkillCapabilityHints` when the profile's skills card was deleted (V6). It lived
    /// in a SwiftUI view before, which is why the demotion from automatic grant to offer originally
    /// shipped with no test at all. It also moved from the IMPORT site to the LINK site: importing
    /// is global now, and the shell tool is per-profile, so linking is the only moment both facts
    /// are in hand.
    func testADeclaredShellToolOffersTheShellTool() throws {
        try createSkill(name: "shell-declaring", allowedToolsLine: "allowed-tools: [Bash]")
        let manifest = try XCTUnwrap(try SkillFolderScanner.scan(rootFolder: tempDir).first)
        XCTAssertTrue(SkillCapabilityHints.shouldOfferShellTool(
            declaredTools: manifest.allowedTools, hasScripts: false, profileTools: []),
            "a skill declaring Bash with no scripts/ directory used to produce no offer at all")
    }

    func testAScopedShellDeclarationAlsoOffers() throws {
        try createSkill(name: "scoped-shell", allowedToolsLine: "allowed-tools: [Bash(git status:*)]")
        let manifest = try XCTUnwrap(try SkillFolderScanner.scan(rootFolder: tempDir).first)
        XCTAssertTrue(SkillCapabilityHints.shouldOfferShellTool(
            declaredTools: manifest.allowedTools, hasScripts: false, profileTools: []))
    }

    func testADeclarationOfReadOnlyToolsOffersNothing() throws {
        try createSkill(name: "read-only", allowedToolsLine: "allowed-tools: [Read, Grep]")
        let manifest = try XCTUnwrap(try SkillFolderScanner.scan(rootFolder: tempDir).first)
        XCTAssertFalse(SkillCapabilityHints.shouldOfferShellTool(
            declaredTools: manifest.allowedTools, hasScripts: false, profileTools: []),
            "the offer must follow the declaration, not merely the presence of one")
    }

    /// A bundled `scripts/` directory is the other, independent trigger.
    func testBundledScriptsAlsoOffer() {
        XCTAssertTrue(SkillCapabilityHints.shouldOfferShellTool(
            declaredTools: nil, hasScripts: true, profileTools: []))
    }

    /// ⚠️ The offer is an OFFER. It returns a Bool for a sentence and a button; it never appends a
    /// tool. The auto-grant was removed because unreviewed content was deciding a capability, and a
    /// frontmatter declaration is weaker evidence than a directory listing, not stronger.
    func testTheOfferIsSuppressedOnceTheProfileHasTheTool() {
        XCTAssertFalse(SkillCapabilityHints.shouldOfferShellTool(
            declaredTools: ["Bash"], hasScripts: true,
            profileTools: [SkillCapabilityHints.shellTool()]))
    }

    /// ⚠️ The tool a user gets on accepting must stay confirmation-gated and built-in-sourced. A
    /// minted `sourceId` once made the tool render as OFF while live, and ticking it appended a
    /// second, unreachable copy.
    func testTheOfferedToolIsConfirmationGatedAndBuiltInSourced() {
        let tool = SkillCapabilityHints.shellTool()
        XCTAssertEqual(tool.name, "run_command", "execute_shell was removed 2026-09-24; run_command is the shell")
        XCTAssertTrue(tool.requiresConfirmation,
                      "the grant is a person's answer to a question — a pre-approved shell makes the question cosmetic")
        XCTAssertEqual(tool.sourceId, ToolSource.builtInSourceID)
    }
}

// MARK: - Non-enforcement

/// ⚠️⚠️ THE INVARIANT THIS WHOLE FEATURE IS BUILT AROUND.
///
/// A SKILL.md is imported content. It may have arrived in a .zip the user did not author. Letting a
/// string in its frontmatter decide which tools an agent may call would be an unreviewed file
/// overriding a preference the user set deliberately — invariant 14, and the same reasoning that
/// removed the `hasScripts` auto-grant.
///
/// Honouring it as a subtract-only narrowing is a coherent position, and the machinery exists (the
/// G6 per-iteration gate in `ReActAgentExecutor` already filters the schema and refuses dispatch).
/// It is the USER's call, not a default to pick. Until they make it, this test is what says so.
///
/// **Mutation check:** make the declaration gate tool resolution and confirm this goes red.
final class SkillAllowedToolsNonEnforcementTests: XCTestCase {

    private func manifest(name: String, allowedTools: [String]?) -> SkillManifest {
        SkillManifest(
            id: UUID(), name: name, description: "A skill.",
            folderPath: "/tmp/skills/\(name)", resourceCount: 0, hasScripts: false,
            compatibility: nil, isEnabled: true, allowedTools: allowedTools
        )
    }

    private func tool(named name: String) -> Tool {
        Tool(name: name, description: "", isEnabled: true, requiresConfirmation: false,
             sourceId: ToolSource.builtInSourceID,
             parameters: SchemaBuilder.object(properties: [], required: []))
    }

    /// Differential: the SAME profile tools under a restrictive declaration and under none must
    /// resolve to the same set. An absolute assertion would pass if nothing resolved at all.
    func testARestrictiveDeclarationDoesNotRemoveASingleTool() async {
        let memory = StaticGroundingMemory(ragContext: "")
        let profileTools = [tool(named: "read_file"), tool(named: "run_command")]

        let underDeclaration = await AgentConnect().resolveExecutableTools(
            profileTools: profileTools,
            conversationID: UUID(),
            longTermMemory: memory,
            skillManifests: [manifest(name: "read-only", allowedTools: ["Read"])]
        )
        let underNoDeclaration = await AgentConnect().resolveExecutableTools(
            profileTools: profileTools,
            conversationID: UUID(),
            longTermMemory: memory,
            skillManifests: [manifest(name: "read-only", allowedTools: nil)]
        )

        XCTAssertEqual(Set(underDeclaration.map(\.name)), Set(underNoDeclaration.map(\.name)),
                       "a skill's allowed-tools must not change which tools a run gets — it describes, it does not gate")
        XCTAssertTrue(underDeclaration.contains { $0.name == "run_command" },
                      "run_command survives a declaration that does not mention it; the control that makes the equality above meaningful")
    }

    /// `allowed-tools: []` is the strongest form of the declaration — "this skill needs no tools".
    /// It is still not a gate.
    func testAnEmptyDeclarationDoesNotStripTheToolSet() async {
        let resolved = await AgentConnect().resolveExecutableTools(
            profileTools: [tool(named: "read_file")],
            conversationID: UUID(),
            longTermMemory: StaticGroundingMemory(ragContext: ""),
            skillManifests: [manifest(name: "needs-nothing", allowedTools: [])]
        )
        XCTAssertTrue(resolved.contains { $0.name == "read_file" })
    }

    /// ⚠️ The declaration must not reach the model. Foreign names in context invite `Bash` calls
    /// that land in the hallucinated-tool path and burn iterations against the circuit breaker; and
    /// an element is the least-validated string the skill format produces, so putting it in a
    /// sentence spoken in the APP's voice would hand an imported file a way to assert things about
    /// the user's configuration. This is information for the USER.
    func testTheDeclarationIsNotRenderedIntoTheDiscoveryPrompt() {
        let body = SkillDiscoveryRendering.discoveryBody(
            for: [manifest(name: "declaring", allowedTools: ["Bash", "Read"])],
            wrapping: .xml)
        XCTAssertNotNil(body)
        XCTAssertFalse(body?.contains("Bash") ?? true,
                       "a declared tool name must not reach the system prompt")
        XCTAssertFalse(body?.contains("allowed-tools") ?? true)
    }
}
