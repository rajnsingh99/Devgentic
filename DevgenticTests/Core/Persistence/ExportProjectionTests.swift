// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ExportProjectionTests.swift
//  DevgenticTests
//
//  Register model/mm-4 — Export fetched and decoded the whole conversation, every attached
//  image's external-storage blob included, on the MainActor BEFORE the save panel appeared.
//  Two halves, both pinned here:
//    1. the store's export projection carries every message field the exporter reads but no
//       image bytes, and decides truncation by COUNT rather than by decoding a probe message;
//    2. the exporter presents the save panel FIRST and loads only after a destination is
//       chosen — a Cancel costs nothing.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class ExportProjectionTests: XCTestCase {

    private var container: ModelContainer!
    private var store: ChatPersistenceStore!
    private let conversationID = UUID()
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ConversationSD.self, ChatMessageSD.self,
            AttachedTextFileSD.self, AttachedImageFileSD.self,
            configurations: config
        )
        store = ChatPersistenceStore.shared
        store.configureContainer(container)
    }

    override func tearDown() async throws {
        container = nil
        store = nil
    }

    // MARK: - Fixtures

    private func image(named name: String, bytes: Int) -> AttachedImageFile {
        AttachedImageFile(name: name, url: URL(fileURLWithPath: "/tmp/\(name)"), fileExtension: "png",
                          binaryData: Data(repeating: 0xAB, count: bytes), size: Int64(bytes))
    }

    private func textFile(named name: String, content: String) -> AttachedTextFile {
        AttachedTextFile(name: name, url: URL(fileURLWithPath: "/tmp/\(name)"), fileExtension: "txt",
                         content: content, size: Int64(content.utf8.count))
    }

    /// Three messages, oldest first: a user turn carrying an image AND a text file, an agent
    /// reply, a plain user turn.
    private func seedConversation() async -> [ChatMessage] {
        let messages = [
            ChatMessage(conversationId: conversationID, timestamp: epoch, sender: .user,
                        content: .markdownText("Here is the screenshot"),
                        attachedTextFiles: [textFile(named: "notes.txt", content: "keep me")],
                        attachedImageFiles: [image(named: "shot.png", bytes: 4096)]),
            ChatMessage(conversationId: conversationID, timestamp: epoch.addingTimeInterval(1), sender: .agent,
                        content: .markdownText("I see a **chart**.")),
            ChatMessage(conversationId: conversationID, timestamp: epoch.addingTimeInterval(2), sender: .user,
                        content: .markdownText("Thanks"))
        ]
        store.addConversation(from: Conversation(id: conversationID, messages: [], timestamp: epoch,
                                                  userDefinedTitle: "Export me", isPinned: false,
                                                  backendEntityId: nil))
        await store.addMessages(messages, toConversation: conversationID)
        return messages
    }

    // MARK: - 1. The projection

    /// THE pin: same messages as `fetchMessages`, image bytes EMPTY, everything else intact.
    func testProjectionOmitsImageBytesAndKeepsEverythingElse() async {
        _ = await seedConversation()

        let full = await store.fetchMessages(for: conversationID, offset: 0, limit: 100)
        let export = await store.fetchMessagesForExport(for: conversationID, limit: 100)

        XCTAssertEqual(export.messages.map(\.id), full.map(\.id), "same rows, same (newest-first) order")
        XCTAssertFalse(export.isTruncated)

        let fullImage = full.last?.attachedImageFiles?.first
        let exportImage = export.messages.last?.attachedImageFiles?.first
        XCTAssertEqual(fullImage?.binaryData.count, 4096, "sanity: the full fetch carries the bytes")
        // Pins the STRUCT's shape only — this container is in-memory, so there is no sidecar to
        // fault. That the projection skips the sidecar read on disk was measured separately
        // (see `toStructOmittingBytes`' doc: ~1 ms vs ~9 ms over 40 × 2 MB rows).
        XCTAssertEqual(exportImage?.binaryData.count, 0, "the export projection carries no image bytes")
        XCTAssertEqual(exportImage?.name, "shot.png")
        XCTAssertEqual(exportImage?.size, 4096, "the size the exporter falls back to")
        XCTAssertEqual(exportImage?.fileExtension, "png")
        XCTAssertEqual(exportImage?.id, fullImage?.id)

        XCTAssertEqual(export.messages.last?.attachedTextFiles?.first?.content, "keep me",
                       "text attachments are inline columns and the export may embed them — untouched")
        XCTAssertEqual(export.messages.map { $0.content.textContent }, full.map { $0.content.textContent })
        XCTAssertEqual(export.messages.map(\.sender), full.map(\.sender))
    }

    /// Truncation is decided by COUNT: more rows than the cap → true; exactly the cap → false.
    func testTruncationIsDecidedByCount() async {
        _ = await seedConversation()

        let capped = await store.fetchMessagesForExport(for: conversationID, limit: 2)
        XCTAssertEqual(capped.messages.count, 2)
        XCTAssertTrue(capped.isTruncated, "three rows, cap of two")

        let exact = await store.fetchMessagesForExport(for: conversationID, limit: 3)
        XCTAssertEqual(exact.messages.count, 3)
        XCTAssertFalse(exact.isTruncated, "exactly at the cap is not truncated")
    }

    /// The document is byte-identical either way — the exporter never needed the bytes.
    func testExportedMarkdownIsIdenticalWithAndWithoutImageBytes() async {
        _ = await seedConversation()
        let full = await store.fetchMessages(for: conversationID, offset: 0, limit: 100)
        let export = await store.fetchMessagesForExport(for: conversationID, limit: 100)

        let fromFull = await ConversationExporter.toMarkdown(title: "T", messages: full)
        let fromProjection = await ConversationExporter.toMarkdown(title: "T", messages: export.messages)

        XCTAssertEqual(fromProjection, fromFull)
        XCTAssertTrue(fromProjection.contains("keep me"),
                      "[mm-5] the attached file's text is embedded — and it comes from the struct, which the projection keeps")
        XCTAssertTrue(fromProjection.contains("shot.png"), "sanity: the image is listed by name")
        XCTAssertTrue(fromProjection.contains("4 KB"), "sanity: and by size, from `size` not `binaryData`")
    }

    // MARK: - 2. Panel first

    @MainActor
    private final class Recorder {
        var events: [String] = []
    }

    /// Cancel at the panel → the loader is NEVER called. Before the fix the whole fetch had
    /// already run by the time the panel appeared.
    func testCancellingAtThePanelLoadsNothing() async {
        let recorder = Recorder()
        let presenter: ConversationExporter.SavePanelPresenter = { _, completion in
            recorder.events.append("panel")
            completion(nil)
        }

        ConversationExporter.exportToFile(title: "T", presentPanel: presenter) {
            recorder.events.append("load")
            return ([], false)
        }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(recorder.events, ["panel"])
    }

    /// Choosing a file → panel, THEN load, then the file holds the exporter's document.
    func testChoosingAFileLoadsAfterThePanelAndWrites() async throws {
        let recorder = Recorder()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-projection-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let message = ChatMessage(conversationId: conversationID, timestamp: epoch, sender: .user,
                                  content: .markdownText("Hello export"))
        let presenter: ConversationExporter.SavePanelPresenter = { panel, completion in
            recorder.events.append("panel")
            XCTAssertEqual(panel.nameFieldStringValue, "T.md")
            completion(url)
        }

        ConversationExporter.exportToFile(title: "T", presentPanel: presenter) {
            recorder.events.append("load")
            return ([message], true)
        }
        // The write happens in a Task after the panel answers; give it a bounded moment.
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(recorder.events, ["panel", "load"], "the panel must be up before any fetch starts")
        let written = try String(contentsOf: url, encoding: .utf8)
        let expected = await ConversationExporter.toMarkdown(title: "T", messages: [message], isTruncated: true)
        XCTAssertEqual(written, expected)
        XCTAssertTrue(written.contains("only the most recent 1 messages"), "sanity: the truncation flag reached the document")
    }

    /// The panel is modeless. A conversation deleted while it is up must be REPORTED, not
    /// written as a header-only file logged as a success.
    func testAVanishedConversationIsReportedAndNothingIsWritten() async throws {
        let recorder = Recorder()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-vanished-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let presenter: ConversationExporter.SavePanelPresenter = { _, completion in
            recorder.events.append("panel")
            completion(url)
        }
        let reporter: ConversationExporter.FailureReporter = { message in
            recorder.events.append("failure: \(message)")
        }

        ConversationExporter.exportToFile(title: "T", presentPanel: presenter, reportFailure: reporter) {
            recorder.events.append("load")
            return nil
        }
        for _ in 0..<50 where recorder.events.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(recorder.events.count, 3, "\(recorder.events)")
        XCTAssertEqual(recorder.events.prefix(2), ["panel", "load"])
        XCTAssertTrue(recorder.events.last?.hasPrefix("failure: ") == true, "\(recorder.events)")
        XCTAssertTrue(recorder.events.last?.contains("no longer exists") == true, "\(recorder.events)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing must be written")
    }
}
