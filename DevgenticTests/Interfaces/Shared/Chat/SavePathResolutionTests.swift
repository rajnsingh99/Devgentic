//
//  SavePathResolutionTests.swift
//  DevgenticTests
//
//  Regression cover for the Code Viewer path/read-failure fixes of 2026-08-10
//  (Chat_Production_Readiness.md rows CH4, CH5, CH6).
//

import XCTest
@testable import devgentic

final class SavePathResolutionTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devgentic-savepath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - CH4 (symlinks)

    /// Writing to a symlink path REPLACES the link with a regular file and leaves the real
    /// file untouched — while the drift check reads THROUGH the link, so it compares the right
    /// bytes and then the write lands on a different inode. `writeTarget` resolves first.
    func testWriteTargetResolvesSymlinkToItsTarget() throws {
        let real = dir.appendingPathComponent("real.txt")
        let link = dir.appendingPathComponent("link.txt")
        try "ORIGINAL\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let target = ChatHistoryViewModel.writeTarget(forPath: link.path)

        XCTAssertEqual(target.resolvingSymlinksInPath().path, real.resolvingSymlinksInPath().path,
                       "the save must be aimed at the real file, not the link")

        // And writing there preserves the link while updating the real file.
        try "EDITED\n".write(to: target, atomically: true, encoding: .utf8)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                        "the symlink must survive the save")
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "EDITED\n",
                       "the real file must receive the edit")
    }

    /// Control: an ordinary path is returned unchanged in substance, so the resolution cannot
    /// retarget a normal save.
    func testWriteTargetLeavesOrdinaryPathAtSameFile() throws {
        let plain = dir.appendingPathComponent("plain.txt")
        try "HI\n".write(to: plain, atomically: true, encoding: .utf8)

        let target = ChatHistoryViewModel.writeTarget(forPath: plain.path)

        try "BYE\n".write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: plain, encoding: .utf8), "BYE\n")
    }

    // MARK: - CH6 (unreadable is not absent)

    /// Only "no such file" may be treated as a create. An undecodable or unreadable file
    /// EXISTS, and skipping the drift guard for it overwrites content never inspected.
    func testOnlyMissingFileCountsAsAbsent() {
        XCTAssertTrue(ChatHistoryViewModel.meansFileAbsent(CocoaError(.fileReadNoSuchFile)))
        XCTAssertTrue(ChatHistoryViewModel.meansFileAbsent(CocoaError(.fileNoSuchFile)))

        XCTAssertFalse(ChatHistoryViewModel.meansFileAbsent(CocoaError(.fileReadInapplicableStringEncoding)),
                       "a non-UTF-8 file exists — it must not be treated as a create")
        XCTAssertFalse(ChatHistoryViewModel.meansFileAbsent(CocoaError(.fileReadNoPermission)),
                       "an unreadable file exists — it must not be treated as a create")
        XCTAssertFalse(ChatHistoryViewModel.meansFileAbsent(CocoaError(.fileReadCorruptFile)))
    }

    /// The real read that CH6 is about: a Latin-1 byte makes `String(contentsOf:.utf8)` throw
    /// an error that is NOT "no such file", proving the two cases are genuinely distinguishable
    /// at this seam rather than only in theory.
    func testUndecodableFileThrowsSomethingOtherThanNoSuchFile() throws {
        let file = dir.appendingPathComponent("latin1.txt")
        // 0xFF is not valid UTF-8.
        try Data([0x68, 0x69, 0xFF, 0x0A]).write(to: file)

        do {
            _ = try String(contentsOf: file, encoding: .utf8)
            XCTFail("expected the UTF-8 read to fail")
        } catch let error as CocoaError {
            XCTAssertFalse(ChatHistoryViewModel.meansFileAbsent(error),
                           "an existing, undecodable file must not be classified as absent")
        }
    }

    // MARK: - CH5 (path resolution parity with the executor)

    /// The viewer used `expandingTildeInPath`, which leaves a RELATIVE path untouched;
    /// `URL(fileURLWithPath:)` then anchors it to the process CWD (`/` for a GUI-launched
    /// app). The write tools resolve through `FilePathResolver`, which anchors to HOME — so a
    /// model emitting a bare filename gave the tab a different file than the agent wrote.
    func testLiveWriteEventAnchorsRelativePathToHomeLikeTheExecutor() throws {
        let params = #"{"path":"Notes.java","content":"class Notes {}"}"#
        let began = try XCTUnwrap(AgentLiveWriteEvent.began(
            toolName: "write_file", params: params, conversationID: UUID()
        ))

        XCTAssertEqual(began.path, FilePathResolver.resolve("Notes.java"),
                       "the tab's path must match how the executor resolved it")
        XCTAssertTrue(began.path.hasPrefix(NSHomeDirectory()),
                      "a relative path must anchor to HOME, not the process working directory")
        XCTAssertNotEqual(began.path, "Notes.java")
    }

    /// Control: absolute and tilde paths keep their existing behaviour.
    func testLiveWriteEventLeavesAbsolutePathAloneAndExpandsTilde() throws {
        let absolute = try XCTUnwrap(AgentLiveWriteEvent.began(
            toolName: "write_file",
            params: #"{"path":"/tmp/devgentic_ch5.java","content":"x"}"#,
            conversationID: UUID()
        ))
        XCTAssertEqual(absolute.path, "/tmp/devgentic_ch5.java")

        let tilde = try XCTUnwrap(AgentLiveWriteEvent.began(
            toolName: "write_file",
            params: #"{"path":"~/devgentic_ch5.java","content":"x"}"#,
            conversationID: UUID()
        ))
        XCTAssertEqual(tilde.path, NSHomeDirectory() + "/devgentic_ch5.java")
    }
}
