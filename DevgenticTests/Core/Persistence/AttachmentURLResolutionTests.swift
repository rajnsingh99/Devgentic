// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttachmentURLResolutionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

final class AttachmentURLResolutionTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([AttachedTextFileSD.self, AttachedImageFileSD.self,
                         ChatMessageSD.self, ConversationSD.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    // MARK: - The crash

    /// The exact shapes that made `URL(string:)` return nil and therefore trapped.
    func testMalformedURLsNoLongerCrashTextAttachments() throws {
        for raw in ["", " ", "   ", "\u{0000}bad", "not a url at all with spaces"] {  // "" is the one that trapped
            let row = AttachedTextFileSD(
                id: UUID(), name: "notes.txt", url: raw,
                fileExtension: "txt", content: "the content survives", size: 20
            )
            // Before the fix, this line trapped.
            let value = row.toStruct()
            XCTAssertEqual(value.content, "the content survives",
                           "The attachment's payload must be unaffected by a bad url (raw: \(raw.debugDescription))")
            XCTAssertEqual(value.name, "notes.txt")
        }
    }

    func testMalformedURLsNoLongerCrashImageAttachments() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        for raw in ["", " ", "\u{0000}bad"] {
            let row = AttachedImageFileSD(
                id: UUID(), name: "shot.png", url: raw,
                fileExtension: "png", binaryData: bytes, size: Int64(bytes.count)
            )
            let value = row.toStruct()
            XCTAssertEqual(value.binaryData, bytes,
                           "Image bytes must survive a bad url (raw: \(raw.debugDescription))")
        }
    }

    // MARK: - Identity

    /// ⚠️ Two broken attachments must NOT collapse into one list identity.
    /// Only the empty-string case reaches the placeholder — see `testOnlyTheEmptyStringFailsToParse`.
    func testPlaceholderURLsAreUniquePerRow() {
        let a = AttachedTextFileSD(id: UUID(), name: "a.txt", url: "", fileExtension: "txt",
                                   content: "a", size: 1).toStruct()
        let b = AttachedTextFileSD(id: UUID(), name: "b.txt", url: "", fileExtension: "txt",
                                   content: "b", size: 1).toStruct()
        XCTAssertNotEqual(a.url, b.url,
                          "A shared sentinel URL would collide these two attachments in any list keyed by url.")
    }

    /// Stable across loads, so SwiftUI does not churn the row on every fetch.
    func testPlaceholderURLIsStableForTheSameRow() {
        let row = AttachedTextFileSD(id: UUID(), name: "a.txt", url: "", fileExtension: "txt",
                                     content: "a", size: 1)
        XCTAssertEqual(row.toStruct().url, row.toStruct().url)
    }

    /// The placeholder must be recognisable as not-a-real-file, so nothing tries to read from it.
    func testPlaceholderURLIsObviouslyNotAFilePath() {
        let value = AttachedTextFileSD(id: UUID(), name: "a.txt", url: "", fileExtension: "txt",
                                       content: "a", size: 1).toStruct()
        XCTAssertEqual(value.url.scheme, "devgentic-unresolved")
        XCTAssertFalse(value.url.isFileURL)
    }

    // MARK: - The normal and recoverable paths

    /// A well-formed `absoluteString` — what `from(_:)` always writes — must be untouched.
    func testWellFormedURLsRoundTripUnchanged() {
        let original = URL(fileURLWithPath: "/tmp/some file.txt")
        let row = AttachedTextFileSD.from(
            AttachedTextFile(name: "some file.txt", url: original,
                             fileExtension: "txt", content: "c", size: 1)
        )
        XCTAssertEqual(row.toStruct().url, original)
    }

    func testRemoteURLsRoundTripUnchanged() {
        let original = URL(string: "https://example.com/a%20b.png")!
        let row = AttachedImageFileSD.from(
            AttachedImageFile(name: "a b.png", url: original,
                              fileExtension: "png", binaryData: Data([1]), size: 1)
        )
        XCTAssertEqual(row.toStruct().url, original)
    }

    /// ⚠️ MEASURED, not assumed: on macOS 26 `URL(string:)` returns nil ONLY for the empty string —
    /// spaces, NUL bytes, newlines and control characters all parse, percent-encoded. This pins that
    /// premise, because the ladder's shape depends on it and a Foundation change would invalidate it.
    func testOnlyTheEmptyStringFailsToParse() {
        XCTAssertNil(URL(string: ""), "The empty string is the one value that trapped.")
        for raw in [" ", "\u{0000}bad", "not a url at all", "/tmp/my file.txt", "a\nb"] {
            XCTAssertNotNil(URL(string: raw),
                            "Premise changed: \(raw.debugDescription) no longer parses, so the ladder needs revisiting.")
        }
    }

    /// A bare path that EXISTS is recovered as a proper file URL rather than left schemeless —
    /// the lenient parse would otherwise yield something no file operation can use.
    func testExistingBarePathIsRecoveredAsAFileURL() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AttachmentURL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("my file.txt").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertNil(URL(string: path)?.scheme, "Test premise: a bare path parses without a scheme.")

        let value = AttachedTextFileSD(id: UUID(), name: "my file.txt", url: path,
                                       fileExtension: "txt", content: "x", size: 1).toStruct()
        XCTAssertTrue(value.url.isFileURL, "An existing bare path should become a file URL, got \(value.url)")
        XCTAssertEqual(value.url.standardizedFileURL.path,
                       URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    /// A bare path that does NOT exist is kept as parsed — discarding it would lose real information.
    func testNonExistentBarePathIsKeptRatherThanReplaced() {
        let value = AttachedTextFileSD(id: UUID(), name: "gone.txt", url: "/nope/gone.txt",
                                       fileExtension: "txt", content: "c", size: 1).toStruct()
        XCTAssertEqual(value.url.absoluteString, "/nope/gone.txt")
        XCTAssertNotEqual(value.url.scheme, "devgentic-unresolved",
                          "A parseable value must not be thrown away for a placeholder.")
    }

    // MARK: - End to end

    /// The real failure mode: loading a conversation whose attachment row has a bad url.
    func testConversationWithABadAttachmentURLStillLoads() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let sd = ChatMessageSD(
            id: UUID(), conversationId: UUID(), timestamp: Date(), senderType: "user",
            traceID: nil,
            contentData: try JSONEncoder().encode(MessageContent.plainText("see attached")),
            agentResponseData: nil, timelineEventsData: nil
        )
        sd.attachedTextFiles = [
            AttachedTextFileSD(id: UUID(), name: "ok.txt", url: "file:///tmp/ok.txt",
                               fileExtension: "txt", content: "fine", size: 4),
            AttachedTextFileSD(id: UUID(), name: "broken.txt", url: "",
                               fileExtension: "txt", content: "also fine", size: 9),
        ]
        context.insert(sd)
        try context.save()

        // Before the fix this trapped and took the app down mid-load.
        let message = sd.toChatMessage()

        let files = try XCTUnwrap(message.attachedTextFiles)
        XCTAssertEqual(files.count, 2, "The bad row must not be dropped — its content is intact.")
        XCTAssertEqual(Set(files.map(\.content)), ["fine", "also fine"])
        XCTAssertEqual(Set(files.map(\.url)).count, 2, "Both attachments need distinct identities.")
    }
}

private extension AttachedTextFile {
    /// `URL(fileURLWithPath:)` may standardize the path, so compare resolved locations.
    func isFileURLPointingAt(_ path: String) -> Bool {
        url.isFileURL && url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
