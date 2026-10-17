// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProjectMemoryTests.swift
//  devgenticTests
//
//  Project memory after `.devgentic/context.md` (2026-10-06): one fact per file under
//  `.devgentic/memory/`, written only through `remember` / `forget`, which check what they are
//  told. On the device run the old whole-file tool wrote `python build -m math_utils` and a
//  `cargo build` for a project with no Rust into every later conversation.
//

import XCTest
@testable import devgentic

// MARK: - The store

final class ProjectMemoryStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectMemory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func entry(_ name: String, _ type: ProjectMemoryType = .gotcha, summary: String = "A fact",
                       details: String = "") -> ProjectMemoryEntry {
        ProjectMemoryEntry(name: name, type: type, summary: summary, details: details, files: [],
                           command: nil, evidence: "stated in conversation 1234", updated: "2026-10-06")
    }

    /// A hand-written decoder drops what it does not know; every field must survive a round trip,
    /// including front-matter keys a person added by hand.
    func testAnEntrySurvivesARoundTripWithEveryField() {
        var original = ProjectMemoryEntry(
            name: "test-command", type: .command, summary: "Tests run with pytest -q",
            details: "Run from the root.\nNot from tests/.", files: ["tests", "src/app.py"],
            command: "pytest -q", evidence: "run_command exited 0 in conversation ABCD1234 (fg_1)",
            updated: "2026-10-06")
        original.extraFields = [("owner", "raj"), ("note", "keep: this")]
        XCTAssertEqual(ProjectMemoryEntry.parse(original.rendered(), fileStem: "test-command"), original)
    }

    func testMalformedFilesAreSkippedNotGuessed() throws {
        let store = ProjectMemoryStore(projectRoot: root)
        try store.save(entry("good"))
        try "no front matter here".write(to: store.fileURL(for: "bad"), atomically: true, encoding: .utf8)
        try "---\ntype: architecture\nsummary: s\n---\n".write(to: store.fileURL(for: "unknown-type"), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.entries().map(\.name), ["good"])
    }

    func testSaveRemoveAndTheIndexFollowTheEntries() throws {
        let store = ProjectMemoryStore(projectRoot: root)
        try store.save(entry("b-trap", .gotcha, summary: "B"))
        try store.save(entry("a-cmd", .command, summary: "A"))
        let index = try String(contentsOf: store.directory.appendingPathComponent("INDEX.md"), encoding: .utf8)
        XCTAssertTrue(index.contains("- [command] a-cmd — A") && index.contains("- [gotcha] b-trap — B"), index)
        XCTAssertEqual(store.entries().map(\.name), ["a-cmd", "b-trap"], "ordered by type, then name")

        XCTAssertTrue(try store.remove(named: "A-CMD"))
        XCTAssertFalse(try store.remove(named: "a-cmd"))
        let after = try String(contentsOf: store.directory.appendingPathComponent("INDEX.md"), encoding: .utf8)
        XCTAssertFalse(after.contains("a-cmd"))
    }

    func testNamesAreNormalised() {
        XCTAssertEqual(ProjectMemoryStore.normalizedName("  Test Command!! "), "test-command")
        XCTAssertEqual(ProjectMemoryStore.normalizedName("run_tests/fast"), "run-tests-fast")
        XCTAssertNil(ProjectMemoryStore.normalizedName("—!—"))
    }

    func testThePromptListingCarriesDetailsOnlyWhileTheyAreSmall() throws {
        let store = ProjectMemoryStore(projectRoot: root)
        XCTAssertNil(store.promptListing(), "no entries, no section")
        try store.save(entry("small", details: "ZZ_DETAIL_ZZ"))
        XCTAssertTrue(store.promptListing()?.contains("ZZ_DETAIL_ZZ") == true)

        let big = String(repeating: "x", count: ProjectMemoryStore.Limits.detailsChars)
        for index in 0..<4 { try store.save(entry("big-\(index)", details: big)) }
        let listing = try XCTUnwrap(store.promptListing())
        XCTAssertFalse(listing.contains("ZZ_DETAIL_ZZ"), "past the inline budget only the index lines remain")
        XCTAssertTrue(listing.contains("- [gotcha] small — A fact"))
    }

    func testAgentsMDIsReadAndABlankOneIsAbsent() throws {
        XCTAssertNil(ProjectInstructionsFile.read(inProject: root.path))
        try "   \n".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(ProjectInstructionsFile.read(inProject: root.path))
        try "Run swift test before finishing.".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectInstructionsFile.read(inProject: root.path), "Run swift test before finishing.")
    }
}

// MARK: - remember / forget / recall

final class ProjectMemoryToolTests: XCTestCase {

    private var root: URL!
    private var logs: URL!
    private var registry: BackgroundProcessRegistry!
    private let conversation = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectMemoryTools-\(UUID().uuidString)")
        logs = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectMemoryLogs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "print(1)".write(to: root.appendingPathComponent("src/app.py"), atomically: true, encoding: .utf8)
        registry = BackgroundProcessRegistry(rootDirectory: logs)
    }

    override func tearDownWithError() throws {
        registry.terminateAll()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: logs)
    }

    private func tool(conversation: UUID? = nil) -> RememberTool {
        RememberTool(projectPath: root.path, conversationID: conversation ?? self.conversation, registry: registry)
    }

    private func args(_ fields: [String: Any]) throws -> RememberTool.Arguments {
        try JSONDecoder().decode(RememberTool.Arguments.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func run(_ command: String, in conversation: UUID? = nil) async throws {
        let started = try registry.launch(command: command, workingDirectory: root.path, timeout: 30,
                                          conversationID: conversation ?? self.conversation, foreground: true)
        _ = await registry.waitUntilEnded(conversationID: conversation ?? self.conversation, taskID: started.id)
    }

    private func refusal(_ verdict: RememberTool.Verdict) -> String? {
        if case .refused(let reason) = verdict { return reason }
        return nil
    }

    // MARK: Commands are remembered only once they have worked here

    /// The device case: a build command the model never ran — while a DIFFERENT command did succeed,
    /// so only matching the command itself can refuse it.
    func testACommandThatWasNeverRunIsRefused() async throws {
        try await run("true")
        let verdict = tool().validate(try args(["type": "command", "name": "build", "summary": "Build",
                                                "command": "python build -m math_utils"]))
        XCTAssertTrue(refusal(verdict)?.contains("has not run successfully") == true, "\(verdict)")
    }

    func testACommandThatFailedIsRefused() async throws {
        try await run("false")
        let verdict = tool().validate(try args(["type": "command", "name": "c", "summary": "s", "command": "false"]))
        XCTAssertNotNil(refusal(verdict), "a command that exited non-zero was remembered")
    }

    func testACommandThatRanInAnotherConversationIsRefused() async throws {
        try await run("true", in: UUID())
        XCTAssertNotNil(refusal(tool().validate(try args(["type": "command", "name": "c", "summary": "s", "command": "true"]))))
    }

    func testACommandThatExitedZeroHereIsSavedWithItsEvidence() async throws {
        try await run("echo  ok")
        let verdict = tool().validate(try args(["type": "command", "name": "Echo Check", "summary": "Echo works",
                                                "command": "echo ok"]))
        guard case .accepted(let entry, let replaced) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertFalse(replaced)
        XCTAssertEqual(entry.name, "echo-check")
        XCTAssertEqual(entry.command, "echo ok")
        XCTAssertTrue(entry.evidence.contains("exited 0"), entry.evidence)
    }

    func testACommandEntryNeedsTheCommand() throws {
        XCTAssertNotNil(refusal(tool().validate(try args(["type": "command", "name": "c", "summary": "s"]))))
    }

    // MARK: Shape and content

    func testAnUnknownTypeIsRefused() throws {
        let verdict = tool().validate(try args(["type": "architecture", "name": "arch", "summary": "Modules"]))
        XCTAssertTrue(refusal(verdict)?.contains("type must be one of") == true, "\(verdict)")
    }

    func testOversizeTextIsRefused() throws {
        let long = String(repeating: "a", count: ProjectMemoryStore.Limits.summaryChars + 1)
        XCTAssertNotNil(refusal(tool().validate(try args(["type": "gotcha", "name": "g", "summary": long]))))
        let huge = String(repeating: "a", count: ProjectMemoryStore.Limits.detailsChars + 1)
        XCTAssertNotNil(refusal(tool().validate(try args(["type": "gotcha", "name": "g", "summary": "s", "details": huge]))))
    }

    func testFilesMustExistInsideTheProjectAndAreStoredRelative() throws {
        let missing = tool().validate(try args(["type": "gotcha", "name": "g", "summary": "s", "files": ["src/nope.py"]]))
        XCTAssertNotNil(refusal(missing))
        let outside = tool().validate(try args(["type": "gotcha", "name": "g", "summary": "s", "files": ["/etc/hosts"]]))
        XCTAssertNotNil(refusal(outside), "a file outside the project was accepted")

        let absolute = root.appendingPathComponent("src/app.py").path
        guard case .accepted(let entry, _) = tool().validate(
            try args(["type": "gotcha", "name": "g", "summary": "s", "files": "src, \(absolute)"])) else {
            return XCTFail("existing project files were refused")
        }
        XCTAssertEqual(entry.files, ["src", "src/app.py"])
    }

    func testASecretIsRefused() throws {
        let verdict = tool().validate(try args(["type": "gotcha", "name": "token", "summary": "Use API_TOKEN=sk-abc123def456ghi789"]))
        XCTAssertTrue(refusal(verdict)?.contains("secret") == true, "\(verdict)")
    }

    func testAFullStoreRefusesNewEntriesButStillUpdates() throws {
        let store = ProjectMemoryStore(projectRoot: root)
        for index in 0..<ProjectMemoryStore.Limits.entries {
            try store.save(ProjectMemoryEntry(name: "e\(index)", type: .gotcha, summary: "s", details: "", files: [],
                                              command: nil, evidence: "", updated: "2026-10-06"))
        }
        XCTAssertNotNil(refusal(tool().validate(try args(["type": "gotcha", "name": "new-one", "summary": "s"]))))
        guard case .accepted(_, let replaced) = tool().validate(try args(["type": "gotcha", "name": "e3", "summary": "updated"])) else {
            return XCTFail("updating an existing entry was refused")
        }
        XCTAssertTrue(replaced)
    }

    // MARK: Writing, reading, removing

    func testRememberRecallForgetEndToEnd() async throws {
        let saved = try await tool().call(arguments: args(["type": "preference", "name": "style",
                                                            "summary": "Keep answers short", "details": "ZZ_DETAILS_ZZ"]))
        XCTAssertTrue(saved.hasPrefix("Saved memory 'style'"), saved)

        let recalled = try await RecallTool(projectPath: root.path).call(arguments: .init(name: "style"))
        XCTAssertTrue(recalled.contains("ZZ_DETAILS_ZZ"), recalled)

        let unknown = try await RecallTool(projectPath: root.path).call(arguments: .init(name: "nope"))
        XCTAssertTrue(unknown.hasPrefix("Error:") && unknown.contains("style"), unknown)

        let removed = try await ForgetTool(projectPath: root.path).call(arguments: .init(name: "style"))
        XCTAssertTrue(removed.hasPrefix("Removed"), removed)
        XCTAssertTrue(ProjectMemoryStore(projectRoot: root).entries().isEmpty)
    }

    func testARefusalIsAnErrorTheExecutorRecordsAsAFailure() async throws {
        let output = try await tool().call(arguments: args(["type": "command", "name": "c", "summary": "s", "command": "make"]))
        XCTAssertTrue(output.hasPrefix("Error:"), output)
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure(output), "a refusal must count as a failed call")
        XCTAssertTrue(ProjectMemoryStore(projectRoot: root).entries().isEmpty, "a refused entry was written")
    }
}

// MARK: - Wiring

final class ProjectMemoryWiringTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectMemoryWiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func codeConfig() -> AgentConfig {
        var config = AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "m"),
                                 tools: CodeToolPreset.defaultTools, historyStrategy: .pointer)
        config.projectPath = root.path
        config.instructions = "STORED PROMPT"
        return config
    }

    func testOnlyACodeProfileWithAFolderGetsTheMemoryTools() {
        let code = AgentConnect.codeMemoryTools(for: .code(codeConfig()), conversationID: UUID(), messageID: UUID())
        XCTAssertEqual(code.map(\.name), ["remember", "forget", "recall"])
        XCTAssertFalse(code.contains { $0.requiresConfirmation }, "the memory tools park on no banner by default")

        var noFolder = codeConfig()
        noFolder.projectPath = nil
        XCTAssertTrue(AgentConnect.codeMemoryTools(for: .code(noFolder), conversationID: UUID(), messageID: nil).isEmpty)
        XCTAssertTrue(AgentConnect.codeMemoryTools(for: .agent(codeConfig()), conversationID: UUID(), messageID: nil).isEmpty)
    }

    /// The whole point: what one conversation remembers is in the next run's prompt, and
    /// `AGENTS.md` is read fresh, without the stored prompt being rewritten.
    func testWhatOneRunRemembersIsInTheNextRunsPrompt() async throws {
        XCTAssertNil(AgentConnect.codeProjectKnowledge(codeConfig(), traceTag: "test"), "an empty project must add nothing")

        try "ZZ_AGENTS_RULE_ZZ".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let remember = RememberTool(projectPath: root.path, conversationID: UUID())
        let args = try JSONDecoder().decode(RememberTool.Arguments.self, from: Data(
            #"{"type": "convention", "name": "naming", "summary": "ZZ_REMEMBERED_ZZ"}"#.utf8))
        _ = try await remember.call(arguments: args)

        let after = try XCTUnwrap(AgentConnect.codeProjectKnowledge(codeConfig(), traceTag: "test"))
        XCTAssertFalse(after.contains("STORED PROMPT"), "the knowledge is its own layer, never glued onto the stored prompt")
        XCTAssertTrue(after.contains("ZZ_AGENTS_RULE_ZZ"), "AGENTS.md did not reach the run's prompt")
        XCTAssertTrue(after.contains("ZZ_REMEMBERED_ZZ"), "the remembered fact did not reach the next run's prompt")
    }

    /// The factories above are only worth anything if the run paths call them. A source check,
    /// because a real Code run needs a model.
    func testEveryCodeRunPathAppendsTheKnowledgeAndTheTools() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Code
            .deletingLastPathComponent()   // Interfaces
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
        guard let source = try? String(contentsOf: root.appendingPathComponent("Devgentic/Core/Backends/TextGen/AgentConnect.swift"), encoding: .utf8) else {
            throw XCTSkip("AgentConnect.swift not reachable — running outside a checkout")
        }
        XCTAssertEqual(source.components(separatedBy: "projectKnowledge = Self.codeProjectKnowledge(config").count - 1, 2,
                       "streamAgentResponse and streamWorkflowNodeResponse must both read the project's knowledge")
        XCTAssertEqual(source.components(separatedBy: "input.projectKnowledge = projectKnowledge").count - 1, 2,
                       "both paths must hand the knowledge to the run, or it is read and dropped")
        XCTAssertTrue(source.contains("let memoryTools = Self.codeMemoryTools(for: profile.details, conversationID: conversationID,\n                                                           messageID: traceContext.messageID)"),
                      "the memory tools must be built with the run's answer ID, or no answer can show or undo its changes")
        XCTAssertTrue(source.contains("activeTools.append(contentsOf: memoryTools)"))
    }
}

// MARK: - Phase 2: undo ledger, stale marks, the card's text

final class ProjectMemoryLedgerTests: XCTestCase {

    private var root: URL!
    private var ledgerRoot: URL!
    private var ledger: ProjectMemoryLedger!
    private let conversation = UUID()
    private let answer = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryLedger-\(UUID().uuidString)")
        ledgerRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryLedgerRecords-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "x = 1".write(to: root.appendingPathComponent("src/app.py"), atomically: true, encoding: .utf8)
        ledger = ProjectMemoryLedger(rootDirectory: ledgerRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: ledgerRoot)
    }

    private var store: ProjectMemoryStore { ProjectMemoryStore(projectRoot: root) }

    private func remember(_ name: String, _ summary: String, answer: UUID? = nil) async throws {
        let tool = RememberTool(projectPath: root.path, conversationID: conversation,
                                messageID: answer ?? self.answer, ledger: ledger)
        let args = try JSONDecoder().decode(RememberTool.Arguments.self, from: JSONSerialization.data(
            withJSONObject: ["type": "convention", "name": name, "summary": summary]))
        let output = try await tool.call(arguments: args)
        XCTAssertTrue(output.hasPrefix("Saved"), output)
    }

    private func forget(_ name: String) async throws {
        let tool = ForgetTool(projectPath: root.path, conversationID: conversation, messageID: answer, ledger: ledger)
        _ = try await tool.call(arguments: .init(name: name))
    }

    private var changes: [ProjectMemoryChange] { ledger.changes(conversationID: conversation, messageID: answer) }

    func testChangesAreRecordedAgainstTheAnswerThatMadeThem() async throws {
        try await remember("naming", "camelCase")
        try await remember("other", "Belongs to another answer", answer: UUID())
        XCTAssertEqual(changes.map(\.name), ["naming"], "only this answer's changes")
        XCTAssertEqual(changes.first?.kind, .saved)
        XCTAssertNil(changes.first?.before)
    }

    func testUndoingANewEntryRemovesIt() async throws {
        try await remember("naming", "camelCase")
        XCTAssertEqual(ledger.undo(try XCTUnwrap(changes.first)), .undone)
        XCTAssertNil(store.entry(named: "naming"))
        let index = try String(contentsOf: store.directory.appendingPathComponent("INDEX.md"), encoding: .utf8)
        XCTAssertFalse(index.contains("naming"), "the index still lists the undone entry")
        XCTAssertEqual(ledger.undo(try XCTUnwrap(changes.first)), .alreadyUndone)
    }

    func testUndoingAReplacementRestoresTheEarlierEntry() async throws {
        try await remember("naming", "First version", answer: UUID())
        try await remember("naming", "Second version")
        let change = try XCTUnwrap(changes.first)
        XCTAssertEqual(change.kind, .replaced)
        XCTAssertEqual(ledger.undo(change), .undone)
        XCTAssertEqual(store.entry(named: "naming")?.summary, "First version")
    }

    func testUndoingAForgetBringsTheEntryBack() async throws {
        try await remember("naming", "camelCase", answer: UUID())
        try await forget("naming")
        let change = try XCTUnwrap(changes.first)
        XCTAssertEqual(change.kind, .removed)
        XCTAssertEqual(change.summary, "camelCase")
        XCTAssertEqual(ledger.undo(change), .undone)
        XCTAssertEqual(store.entry(named: "naming")?.summary, "camelCase")
    }

    /// The one rule: an entry changed after the run wrote it is never overwritten by Undo.
    func testAnEntryChangedSinceIsNotUndone() async throws {
        try await remember("naming", "camelCase")
        let edited = ProjectMemoryEntryEditor.edited(try XCTUnwrap(store.entry(named: "naming")),
                                                     summary: "snake_case", details: "", on: Date())
        try store.save(edited)
        XCTAssertEqual(ledger.undo(try XCTUnwrap(changes.first)), .changedSince)
        XCTAssertEqual(store.entry(named: "naming")?.summary, "snake_case", "Undo overwrote the user's edit")
        XCTAssertTrue(store.entry(named: "naming")?.evidence.contains("edited by the user") == true)
    }

    func testARefusedRememberRecordsNothing() async throws {
        let tool = RememberTool(projectPath: root.path, conversationID: conversation, messageID: answer, ledger: ledger)
        let args = try JSONDecoder().decode(RememberTool.Arguments.self, from: JSONSerialization.data(
            withJSONObject: ["type": "command", "name": "build", "summary": "s", "command": "make"]))
        _ = try await tool.call(arguments: args)
        XCTAssertTrue(changes.isEmpty)
    }

    // MARK: Stale marks

    func testAnEntryIsStaleOnlyWhenAFileItNamesChangedAfterIt() throws {
        let entry = ProjectMemoryEntry(name: "app", type: .gotcha, summary: "app.py sets x", details: "",
                                       files: ["src/app.py"], command: nil, evidence: "", updated: "2026-10-06")
        try store.save(entry)
        let entryFile = store.fileURL(for: "app")
        let source = root.appendingPathComponent("src/app.py")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: source.path)
        XCTAssertTrue(store.staleFiles(of: entry).isEmpty)
        XCTAssertFalse(store.promptListing()?.contains("may be stale") ?? true)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: entryFile.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: source.path)
        XCTAssertEqual(store.staleFiles(of: entry), ["src/app.py"])
        XCTAssertTrue(store.promptListing()?.contains("may be stale: src/app.py") == true,
                      "the next run is not warned that the fact may be out of date")
    }

    // MARK: The card's text

    func testTheCardTitleCountsWhatIsStillStanding() {
        func change(_ kind: ProjectMemoryChange.Kind) -> ProjectMemoryChange {
            ProjectMemoryChange(id: UUID(), conversationID: conversation, messageID: answer, projectPath: root.path,
                                name: "n", kind: kind, summary: "", before: nil, after: nil, at: Date())
        }
        XCTAssertEqual(TurnMemoryChanges.title(for: [change(.saved)]), "Saved 1 memory")
        XCTAssertEqual(TurnMemoryChanges.title(for: [change(.saved), change(.replaced), change(.removed)]),
                       "Saved 2 memories, removed 1 memory")
        XCTAssertEqual(TurnMemoryChanges.title(for: [change(.removed)]), "Removed 1 memory")
        XCTAssertEqual(TurnMemoryChanges.note(for: [("a", .changedSince), ("b", .undone)]),
                       "Not undone — changed since: a. Edit it in Project Context.")
        XCTAssertNil(TurnMemoryChanges.note(for: [("b", .undone)]))
    }
}

// MARK: - Phase 3: the end-of-run memory pass

final class ProjectMemorySuggestionTests: XCTestCase {

    private var root: URL!
    private var scratch: URL!
    private var registry: BackgroundProcessRegistry!
    private var suggestionStore: ProjectMemorySuggestionStore!
    private let conversation = UUID()
    private let answer = UUID()

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MemorySuggest-\(UUID().uuidString)")
        root = scratch.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        registry = BackgroundProcessRegistry(rootDirectory: scratch.appendingPathComponent("logs"))
        suggestionStore = ProjectMemorySuggestionStore(rootDirectory: scratch.appendingPathComponent("suggestions"))
    }

    override func tearDownWithError() throws {
        registry.terminateAll()
        try? FileManager.default.removeItem(at: scratch)
    }

    private var memory: ProjectMemoryStore { ProjectMemoryStore(projectRoot: root) }

    private func run(_ command: String) async throws {
        let started = try registry.launch(command: command, workingDirectory: root.path, timeout: 30,
                                          conversationID: conversation, foreground: true)
        _ = await registry.waitUntilEnded(conversationID: conversation, taskID: started.id)
    }

    private func evidence(tools: Int = 1) -> ProjectMemoryRunEvidence {
        let evidence = ProjectMemoryRunEvidence(startedAt: Date(timeIntervalSinceNow: -60))
        for index in 0..<tools {
            evidence.observe(.toolSucceeded(ToolOutput(toolName: "read_file", params: "{\"path\":\"f\(index)\"}", output: "ok", isSuccess: true)))
        }
        return evidence
    }

    func testProposalsAreReadFromAnArrayInProseOrAFence() {
        let fenced = "Here you go:\n```json\n[{\"type\": \"preference\", \"name\": \"short\", \"summary\": \"Keep it short\"}]\n```"
        XCTAssertEqual(ProjectMemorySuggester.proposals(from: fenced).map(\.name), ["short"])
        XCTAssertTrue(ProjectMemorySuggester.proposals(from: "[]").isEmpty)
        XCTAssertTrue(ProjectMemorySuggester.proposals(from: "Nothing worth saving.").isEmpty)
        XCTAssertTrue(ProjectMemorySuggester.proposals(from: "[{\"type\": \"gotcha\"").isEmpty, "a cut-off reply is dropped, not guessed")
    }

    /// The pass gets NO trust of its own: every proposal faces `remember`'s checks.
    func testOnlyProposalsThatPassRemembersChecksBecomeSuggestionsCappedAtThree() async throws {
        try await run("true")
        try memory.save(ProjectMemoryEntry(name: "naming", type: .convention, summary: "snake_case", details: "",
                                           files: [], command: nil, evidence: "", updated: "2026-10-06"))
        let reply = """
        [
          {"type": "convention", "name": "style-a", "summary": "Tabs, not spaces"},
          {"type": "command", "name": "true-cmd", "summary": "true works", "command": "true"},
          {"type": "command", "name": "build", "summary": "Build", "command": "python build -m math_utils"},
          {"type": "architecture", "name": "arch", "summary": "Modules and sub-modules"},
          {"type": "convention", "name": "naming", "summary": "snake_case"},
          {"type": "preference", "name": "p1", "summary": "Short answers"},
          {"type": "gotcha", "name": "g1", "summary": "Fourth valid one"}
        ]
        """
        let kept = ProjectMemorySuggester.suggestions(
            from: reply, projectPath: root.path, conversationID: conversation, messageID: answer,
            registry: registry, existing: memory.entries())
        XCTAssertEqual(kept.compactMap(\.entry?.name), ["style-a", "true-cmd", "p1"])
        XCTAssertTrue(kept.first { $0.entry?.name == "true-cmd" }?.entry?.evidence.contains("exited 0") == true)
    }

    func testThePassSuggestsButNeverWritesMemory() async throws {
        let reply = #"[{"type": "preference", "name": "short", "summary": "Keep answers short"}]"#
        let task = await ProjectMemorySuggester().schedule(
            evidence: evidence(), userRequest: "fix it", answer: "Fixed.", projectPath: root.path,
            conversationID: conversation, messageID: answer, registry: registry, suggestions: suggestionStore
        ) { _ in reply }
        await task?.value
        XCTAssertEqual(suggestionStore.suggestions(conversationID: conversation, messageID: answer).count, 1)
        XCTAssertTrue(memory.entries().isEmpty, "a suggestion was written to project memory without the user")
    }

    func testAcceptWritesTheEntryAndDismissWritesNothing() throws {
        let entry = ProjectMemoryEntry(name: "short", type: .preference, summary: "Keep answers short", details: "",
                                       files: [], command: nil, evidence: "stated in conversation 1234", updated: "2026-10-06")
        let first = ProjectMemorySuggestion(id: UUID(), conversationID: conversation, messageID: answer,
                                            projectPath: root.path, entryText: entry.rendered(), createdAt: Date())
        suggestionStore.add(first)
        let saved = try suggestionStore.accept(first)
        XCTAssertEqual(memory.entry(named: "short")?.summary, "Keep answers short")
        XCTAssertTrue(saved.evidence.contains("accepted by the user"), saved.evidence)
        XCTAssertTrue(suggestionStore.suggestions(projectPath: root.path).isEmpty)

        let second = ProjectMemorySuggestion(id: UUID(), conversationID: conversation, messageID: answer,
                                             projectPath: root.path, entryText: entry.rendered().replacingOccurrences(of: "name: short", with: "name: other"),
                                             createdAt: Date())
        suggestionStore.add(second)
        XCTAssertEqual(suggestionStore.suggestions(projectPath: root.path).count, 1)
        suggestionStore.dismiss(second)
        XCTAssertTrue(suggestionStore.suggestions(projectPath: root.path).isEmpty)
        XCTAssertNil(memory.entry(named: "other"))
    }

    func testARunThatUsedNoToolsGetsNoPass() async {
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        let task = await ProjectMemorySuggester().schedule(
            evidence: evidence(tools: 0), userRequest: "explain closures", answer: "A closure…",
            projectPath: root.path, conversationID: conversation, messageID: answer,
            registry: registry, suggestions: suggestionStore
        ) { _ in calls.count += 1; return "[]" }
        await task?.value
        XCTAssertNil(task)
        XCTAssertEqual(calls.count, 0, "a model call was spent on a run that learned nothing about the project")
    }

    func testANewRunCancelsThePendingPass() async throws {
        let suggester = ProjectMemorySuggester()
        let reply = #"[{"type": "preference", "name": "short", "summary": "Keep answers short"}]"#
        let task = await suggester.schedule(
            evidence: evidence(), userRequest: "fix it", answer: "Fixed.", projectPath: root.path,
            conversationID: conversation, messageID: answer, registry: registry, suggestions: suggestionStore
        ) { _ in
            // A model that finishes regardless of cancellation, as a local generation can: only
            // the pass's own cancellation check may keep the reply from being stored.
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { resume.resume() }
            }
            return reply
        }
        await suggester.cancel(conversationID: conversation)
        await task?.value
        XCTAssertTrue(suggestionStore.suggestions(conversationID: conversation, messageID: answer).isEmpty,
                      "a cancelled pass still stored its suggestions")
    }

    func testEvidenceKeepsEachToolsOutcomeAndOnlyItsFirstLine() {
        let evidence = ProjectMemoryRunEvidence()
        evidence.observe(.content("text"))
        evidence.observe(.toolSucceeded(ToolOutput(toolName: "read_file", output: "line 1\nline 2", isSuccess: true)))
        evidence.observe(.toolFailed(ToolOutput(toolName: "run_command", params: "{\"command\":\"make\"}",
                                                output: "Error: make: not found\nmore", isSuccess: false), category: .executionThrew))
        XCTAssertEqual(evidence.toolOutcomes.map(\.name), ["read_file", "run_command"])
        XCTAssertEqual(evidence.toolOutcomes.last?.firstLine, "Error: make: not found")
        XCTAssertEqual(evidence.toolOutcomes.map(\.succeeded), [true, false])
    }

    func testThePromptCarriesCommandsFailuresAndWhatIsAlreadyKnown() async throws {
        let started = Date(timeIntervalSinceNow: -1)
        try await run("echo hi")
        let commands = registry.snapshots(conversationID: conversation).filter { $0.startedAt >= started }
        let existing = [ProjectMemoryEntry(name: "naming", type: .convention, summary: "snake_case", details: "",
                                           files: [], command: nil, evidence: "", updated: "")]
        let outcomes = [ProjectMemoryRunEvidence.ToolOutcome(name: "run_command", params: "{}", succeeded: false, firstLine: "Error: boom")]
        let messages = ProjectMemorySuggester.messages(userRequest: "ZZ_REQUEST_ZZ", answer: "ZZ_ANSWER_ZZ",
                                                       outcomes: outcomes, commands: commands, existing: existing)
        let user = try XCTUnwrap(messages.last?["content"])
        for needle in ["ZZ_REQUEST_ZZ", "ZZ_ANSWER_ZZ", "`echo hi` → finished (exit 0)", "Error: boom", "- [convention] naming — snake_case"] {
            XCTAssertTrue(user.contains(needle), "the pass is not told: \(needle)")
        }
        XCTAssertTrue(messages.first?["content"]?.contains("Never propose a description of the code") == true)
    }

    func testTheSettingIsOffByDefaultAndPerProject() throws {
        let suite = "MemorySuggestSetting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "m"), tools: [], historyStrategy: .pointer)
        config.projectPath = root.path
        XCTAssertFalse(ProjectMemorySuggester.isEnabled(for: .code(config), defaults: defaults))

        var settings = CodeQuickSettings.default
        settings.suggestMemories = true
        XCTAssertFalse(settings.isDefault)
        CodeQuickSettingsStore.save(settings, for: root.path, defaults: defaults, now: Date())
        XCTAssertTrue(ProjectMemorySuggester.isEnabled(for: .code(config), defaults: defaults))
        XCTAssertFalse(ProjectMemorySuggester.isEnabled(for: .agent(config), defaults: defaults))

        var other = config
        other.projectPath = scratch.appendingPathComponent("elsewhere").path
        XCTAssertFalse(ProjectMemorySuggester.isEnabled(for: .code(other), defaults: defaults), "the setting leaked to another project")
    }

    /// A real run needs a model, so the run path's three hooks are pinned in the source.
    func testTheRunPathCancelsCollectsAndSchedules() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: repo.appendingPathComponent("Devgentic/Core/Backends/TextGen/AgentConnect.swift"), encoding: .utf8) else {
            throw XCTSkip("AgentConnect.swift not reachable — running outside a checkout")
        }
        XCTAssertTrue(source.contains("await ProjectMemorySuggester.shared.cancel(conversationID: conversationID)"))
        XCTAssertEqual(source.components(separatedBy: "memoryEvidence.observe(event)").count - 1, 2,
                       "both stream loops (with and without a timeout) must record the tools' outcomes")
        XCTAssertTrue(source.contains("if ProjectMemorySuggester.isEnabled(for: profile.details)"))
        XCTAssertTrue(source.contains("await ProjectMemorySuggester.shared.schedule("))
    }
}
