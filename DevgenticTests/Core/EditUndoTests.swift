// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EditUndoTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class EditPatchTests: XCTestCase {

    private func patch(_ before: String, _ after: String, created: Bool = false) throws -> EditPatch {
        try XCTUnwrap(EditPatch.make(before: before, after: after, path: "/p/F.swift", conversationID: UUID(),
                                     messageID: UUID(), toolEventID: UUID(), createdFile: created))
    }

    private func numbered(_ n: Int, prefix: String = "line") -> String {
        (1...n).map { "\(prefix) \($0)\n" }.joined()
    }

    func testLinesKeepTheirTerminators() {
        XCTAssertEqual(EditPatch.lines(of: "a\r\nb\nc"), ["a\r\n", "b\n", "c"])
        XCTAssertEqual(EditPatch.lines(of: ""), [])
        let text = "x\r\n\ny\n"
        XCTAssertEqual(EditPatch.lines(of: text).joined(), text)
    }

    /// ⚠️ THE CORE PROMISE: on a file the agent left untouched since, Undo gives back the original
    /// byte for byte — line endings and the final newline included.
    func testUndoOnAnUnchangedFileRestoresItExactly() throws {
        let base = numbered(40)
        let cases: [(String, String)] = [
            (base, base.replacingOccurrences(of: "line 20\n", with: "line 20 changed\n")),
            (base, base.replacingOccurrences(of: "line 5\n", with: "")),
            (base, base + "appended\n"),
            (base, String(base.dropLast())),                          // final newline removed
            ("a\r\nb\r\nc\r\n", "a\r\nB\r\nc\r\n"),                   // CRLF kept
            (base, "rewritten\n"),
        ]
        for (before, after) in cases {
            XCTAssertEqual(try patch(before, after).revert(current: after), .content(before),
                           "not restored exactly for after=\(after.prefix(30).debugDescription)")
        }
    }

    /// `git revert`: the user added a header after the agent's edit; Undo reverses only the
    /// agent's lines and keeps the header.
    func testLaterEditsElsewhereSurviveTheUndo() throws {
        let before = numbered(30)
        let after = before.replacingOccurrences(of: "line 20\n", with: "line 20 changed\n")
        let p = try patch(before, after)
        let edited = "// header\n// more\n" + after
        XCTAssertEqual(p.revert(current: edited), .content("// header\n// more\n" + before))
    }

    /// The user edited the agent's own lines: nothing is guessed.
    func testEditsToTheAgentsLinesAreAConflict() throws {
        let before = numbered(30)
        let after = before.replacingOccurrences(of: "line 20\n", with: "line 20 changed\n")
        let edited = after.replacingOccurrences(of: "line 20 changed\n", with: "line 20 changed by me\n")
        guard case .conflict = try patch(before, after).revert(current: edited) else {
            return XCTFail("a conflicting undo was applied anyway")
        }
    }

    /// Repeated lines (`}` everywhere): with context and the nearest-position rule, the right copy
    /// is reversed even after the file shifted.
    func testTheRightCopyOfARepeatedBlockIsReversed() throws {
        let block = "func a() {\n    x()\n}\n\n"
        let before = String(repeating: block, count: 8)
        var lines = EditPatch.lines(of: before)
        lines[17] = "    y()\n"               // the 5th function's body
        let after = lines.joined()
        let shifted = "import Foo\n" + after
        XCTAssertEqual(try patch(before, after).revert(current: shifted), .content("import Foo\n" + before))
    }

    /// ⚠️ The hard case: the agent DELETED a line in one of eight identical functions, so its hunk
    /// is nothing but repeated context — it matches every copy. Only the nearest-position rule
    /// picks the right one after the file shifted.
    func testAnAmbiguousHunkIsPlacedNearestItsOriginalPosition() throws {
        // Eight identical functions, except the 5th has its call twice; the agent removes the
        // duplicate. Afterwards all eight are identical, so the hunk's after-side matches EVERY
        // function — only its original position says which one to put the line back into.
        let block = "func a() {\n    x()\n}\n\n"
        let fifth = "func a() {\n    x()\n    x()\n}\n\n"
        let before = String(repeating: block, count: 4) + fifth + String(repeating: block, count: 3)
        let after = String(repeating: block, count: 8)
        let shifted = "import Foo\n" + after
        let p = try patch(before, after)
        XCTAssertGreaterThan(Self.occurrences(of: p.hunks[0].newLines, in: EditPatch.lines(of: after)), 1,
                             "the fixture is not ambiguous, so it does not test placement")
        XCTAssertEqual(p.revert(current: shifted), .content("import Foo\n" + before),
                       "the line went back into the wrong function")
    }

    static func occurrences(of block: [String], in lines: [String]) -> Int {
        guard block.count <= lines.count else { return 0 }
        return (0...(lines.count - block.count)).filter { Array(lines[$0..<($0 + block.count)]) == block }.count
    }

    func testACreatedFileIsDeletedOnlyIfUntouched() throws {
        let p = try patch("", "new file\n", created: true)
        XCTAssertEqual(p.revert(current: "new file\n"), .deleteFile)
        guard case .conflict = p.revert(current: "new file\nedited\n") else { return XCTFail("an edited file would be deleted") }
    }

    func testAMissingFileIsAConflict() throws {
        guard case .conflict = try patch("a\n", "b\n").revert(current: nil) else { return XCTFail() }
    }

    /// A rewrite past the line-diff budget becomes one hunk — still reversible exactly.
    func testAHugeRewriteIsStillReversible() throws {
        let before = numbered(2_500)
        let after = numbered(2_500, prefix: "other")
        let p = try patch(before, after)
        XCTAssertEqual(p.hunks.count, 1)
        XCTAssertEqual(p.revert(current: after), .content(before))
    }

    func testThePatchSurvivesTheDisk() throws {
        let p = try patch(numbered(10), numbered(12))
        XCTAssertEqual(try JSONDecoder().decode(EditPatch.self, from: JSONEncoder().encode(p)), p)
    }
}

final class EditPatchStoreTests: XCTestCase {

    private var root: URL!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("editpatch-\(UUID())")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func patch(conversation: UUID = UUID()) -> EditPatch {
        EditPatch.make(before: "a\n", after: "b\n", path: "/p/F", conversationID: conversation,
                       messageID: UUID(), toolEventID: UUID(), createdFile: false)!
    }

    func testSaveLoadAndMarkReverted() {
        let store = EditPatchStore(rootDirectory: root, sweeps: false)
        let p = patch()
        store.save(p)
        XCTAssertEqual(store.load(conversationID: p.conversationID, toolEventID: p.toolEventID), p)
        store.markReverted(p)
        XCTAssertNotNil(store.load(conversationID: p.conversationID, toolEventID: p.toolEventID)?.revertedAt)
    }

    func testTheSweepEnforcesSevenDaysAndTheCap() throws {
        let store = EditPatchStore(rootDirectory: root, maxTotalBytes: 1, sweeps: false)
        let old = patch(), recent = patch()
        store.save(old); store.save(recent)
        let oldURL = store.url(conversationID: old.conversationID, toolEventID: old.toolEventID)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86_400)], ofItemAtPath: oldURL.path)
        let roomy = EditPatchStore(rootDirectory: root, sweeps: false)
        roomy.sweep()
        XCTAssertNil(roomy.load(conversationID: old.conversationID, toolEventID: old.toolEventID), "kept past 7 days")
        XCTAssertNotNil(roomy.load(conversationID: recent.conversationID, toolEventID: recent.toolEventID))
        store.sweep()
        XCTAssertNil(store.load(conversationID: recent.conversationID, toolEventID: recent.toolEventID), "the size cap was not enforced")
    }

    /// ⚠️ THE WIRING: a finished write in a CODE conversation leaves an undo record; elsewhere none.
    @MainActor
    func testACodeWriteIsRecordedAndAChatWriteIsNot() async throws {
        let store = EditPatchStore(rootDirectory: root, sweeps: false)
        func write() -> ToolExecutionData {
            var data = ToolExecutionData(id: UUID(), name: "write_file", params: "{}", output: "ok", isSuccess: true, isExecuting: false)
            data.params = String(data: try! JSONSerialization.data(withJSONObject: ["path": "/p/F.swift", "content": "b\n"]), encoding: .utf8)!
            data.preWriteContent = "a\n"
            data.effect = ActionEffect.from(toolExecution: data)
            return data
        }
        let code = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""))
        code.profileType = .code
        let chat = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""))
        chat.profileType = .agent
        let codeWrite = write(), chatWrite = write()
        EditPatchStore.recordIfCode(codeWrite, in: code, store: store)
        EditPatchStore.recordIfCode(chatWrite, in: chat, store: store)

        let deadline = Date().addingTimeInterval(5)
        while store.load(conversationID: code.conversationId, toolEventID: codeWrite.id) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(store.load(conversationID: code.conversationId, toolEventID: codeWrite.id), "a Code write left no undo record")
        XCTAssertNil(store.load(conversationID: chat.conversationId, toolEventID: chatWrite.id), "a chat write was copied to disk")
    }

    func testBothCompletionPathsRecord() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Devgentic/Core/Utils/ActiveStreamManager.swift", "Devgentic/Core/Utils/CapabilityCardRouter.swift"] {
            guard let code = try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8) else {
                throw XCTSkip("\(path) not reachable — running outside a checkout")
            }
            XCTAssertTrue(code.contains("EditPatchStore.recordIfCode("), "\(path) finishes writes without an undo record")
        }
    }
}

final class EditUndoPlanTests: XCTestCase {

    private var root: URL!
    private var store: EditPatchStore!
    private let conversation = UUID()

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("editundo-\(UUID())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = EditPatchStore(rootDirectory: root.appendingPathComponent("patches"), sweeps: false)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// Simulates an agent write: the file changes on disk and a patch is stored.
    @discardableResult
    private func agentWrite(_ path: String, from before: String, to after: String) throws -> EditUndo.Write {
        try after.write(toFile: path, atomically: true, encoding: .utf8)
        let id = UUID()
        store.save(EditPatch.make(before: before, after: after, path: path, conversationID: conversation,
                                  messageID: UUID(), toolEventID: id, createdFile: before.isEmpty)!)
        return EditUndo.Write(toolEventID: id, path: path)
    }

    private func file(_ name: String) -> String { root.appendingPathComponent(name).path }
    private func plan(_ writes: [EditUndo.Write]) -> EditUndo.Plan {
        EditUndo.plan(writes: writes, conversationID: conversation, store: store, read: EditUndo.readFile)
    }

    func testAnUnchangedFileIsRestoredExactlyAndMarked() throws {
        let path = file("A.swift")
        let w = try agentWrite(path, from: "a\nb\n", to: "a\nB\n")
        let p = plan([w])
        XCTAssertEqual(p.files.first?.outcome, .restore(content: "a\nb\n", exact: true))
        let applied = EditUndo.apply(p, store: store, read: EditUndo.readFile)
        XCTAssertEqual(applied.changed, [path])
        XCTAssertEqual(EditUndo.readFile(path), "a\nb\n")
        XCTAssertEqual(plan([w]).files.first?.outcome, .alreadyUndone, "the same edit could be undone twice")
    }

    /// Two writes to one file in a turn: undone newest first, back to the original.
    func testAChainOfWritesIsUndoneNewestFirst() throws {
        let path = file("A.swift")
        let first = try agentWrite(path, from: "1\n2\n3\n", to: "1\nTWO\n3\n")
        let second = try agentWrite(path, from: "1\nTWO\n3\n", to: "1\nTWO\n3\n4\n")
        let p = plan([second, first])
        XCTAssertEqual(p.files.first?.outcome, .restore(content: "1\n2\n3\n", exact: true))
    }

    func testAFileChangedSinceIsRevertedAroundTheChange() throws {
        let path = file("A.swift")
        let before = (1...20).map { "l\($0)\n" }.joined()
        let after = before.replacingOccurrences(of: "l10\n", with: "L10\n")
        let w = try agentWrite(path, from: before, to: after)
        try ("// mine\n" + after).write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(plan([w]).files.first?.outcome, .restore(content: "// mine\n" + before, exact: false))
    }

    /// One write in the chain has no record (expired): the file is left alone entirely.
    func testAMissingRecordBlocksTheWholeFile() throws {
        let path = file("A.swift")
        let w = try agentWrite(path, from: "a\n", to: "b\n")
        let lost = EditUndo.Write(toolEventID: UUID(), path: path)
        guard case .cannotUndo = plan([lost, w]).files.first?.outcome else { return XCTFail("a partial chain was undone") }
    }

    /// A save made after the confirmation sheet opened wins: the file is skipped, not clobbered.
    func testAFileChangedAfterPlanningIsSkipped() throws {
        let path = file("A.swift")
        let w = try agentWrite(path, from: "a\n", to: "b\n")
        let p = plan([w])
        try "b\nsaved meanwhile\n".write(toFile: path, atomically: true, encoding: .utf8)
        let applied = EditUndo.apply(p, store: store, read: EditUndo.readFile)
        XCTAssertTrue(applied.changed.isEmpty)
        XCTAssertEqual(EditUndo.readFile(path), "b\nsaved meanwhile\n")
        XCTAssertNil(store.load(conversationID: conversation, toolEventID: w.toolEventID)?.revertedAt, "a skipped undo was recorded as done")
    }

    func testACreatedFileGoesToTheTrash() throws {
        let path = file("New.swift")
        let w = try agentWrite(path, from: "", to: "fresh\n")
        let p = plan([w])
        XCTAssertEqual(p.files.first?.outcome, .moveToTrash)
        _ = EditUndo.apply(p, store: store, read: EditUndo.readFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testPermissionsSurviveTheRestore() throws {
        let path = file("run.sh")
        let w = try agentWrite(path, from: "echo a\n", to: "echo b\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        _ = EditUndo.apply(plan([w]), store: store, read: EditUndo.readFile)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755, "undoing an edit made the script non-executable")
    }

    /// Rewind = this turn and every later one; Undo = this turn only. Newest first either way.
    @MainActor
    func testRewindReachesLaterTurnsAndUndoDoesNot() {
        func turn(_ path: String) -> ChatMessage {
            let m = ChatMessage(conversationId: conversation, sender: .agent, content: .markdownText(""))
            var d = ToolExecutionData(id: UUID(), name: "write_file", params: "{}", output: "ok", isSuccess: true, isExecuting: false)
            d.effect = ActionEffect(path: path, linesAdded: 1, linesRemoved: 0, diff: "+x", isTruncated: false)
            m.timelineEvents = [.toolExecution(d)]
            return m
        }
        let older = turn("/p/A"), newer = turn("/p/B")
        let newestFirst = [newer, older]
        XCTAssertEqual(EditUndo.writes(from: older, newestFirst: newestFirst, throughLatest: false).map(\.path), ["/p/A"])
        XCTAssertEqual(EditUndo.writes(from: older, newestFirst: newestFirst, throughLatest: true).map(\.path), ["/p/B", "/p/A"])
    }

    func testTheCardOffersUndoAndRewind() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = "Devgentic/Interfaces/Shared/Chat/TurnFileChangesCard.swift"
        guard let code = try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        XCTAssertTrue(code.contains("startUndo(rewind: false)") && code.contains("startUndo(rewind: true)"))
        XCTAssertTrue(code.contains("EditUndo.apply(plan, store: .shared"), "confirming does not apply the plan")
    }
}
