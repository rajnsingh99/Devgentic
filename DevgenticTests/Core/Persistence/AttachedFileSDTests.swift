// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttachedFileSDTests.swift
//  DevgenticTests
//
//  Created on 03/04/26.
//
//  Tests AttachedTextFileSD and AttachedImageFileSD — round-trip mapping,
//  persistence, and edge cases.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class AttachedFileSDTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ConversationSD.self, ChatMessageSD.self,
            AttachedTextFileSD.self, AttachedImageFileSD.self,
            configurations: config
        )
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
    }

    // MARK: - AttachedTextFileSD

    func testTextFileRoundTrip() {
        let original = AttachedTextFile(
            name: "example.swift",
            url: URL(string: "file:///Users/test/example.swift")!,
            fileExtension: "swift",
            content: "import Foundation\nprint(\"Hello\")",
            size: 31
        )

        let sd = AttachedTextFileSD.from(original)
        let restored = sd.toStruct()

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.name, "example.swift")
        XCTAssertEqual(restored.url, URL(string: "file:///Users/test/example.swift")!)
        XCTAssertEqual(restored.fileExtension, "swift")
        XCTAssertEqual(restored.content, "import Foundation\nprint(\"Hello\")")
        XCTAssertEqual(restored.size, 31)
    }

    func testTextFilePersistence() throws {
        let sd = AttachedTextFileSD(
            id: UUID(), name: "test.py", url: "file:///tmp/test.py",
            fileExtension: "py", content: "print('hi')", size: 11
        )
        context.insert(sd)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AttachedTextFileSD>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "test.py")
        XCTAssertEqual(fetched.first?.content, "print('hi')")
    }

    func testTextFileEmptyContent() {
        let original = AttachedTextFile(
            name: "empty.txt",
            url: URL(string: "file:///tmp/empty.txt")!,
            fileExtension: "txt",
            content: "",
            size: 0
        )

        let sd = AttachedTextFileSD.from(original)
        let restored = sd.toStruct()

        XCTAssertEqual(restored.content, "")
        XCTAssertEqual(restored.size, 0)
    }

    func testTextFileUnicodeContent() {
        let unicodeContent = "// 日本語コメント\nlet x = \"こんにちは\""
        let original = AttachedTextFile(
            name: "unicode.swift",
            url: URL(string: "file:///tmp/unicode.swift")!,
            fileExtension: "swift",
            content: unicodeContent,
            size: Int64(unicodeContent.utf8.count)
        )

        let sd = AttachedTextFileSD.from(original)
        let restored = sd.toStruct()

        XCTAssertEqual(restored.content, unicodeContent)
    }

    // MARK: - AttachedImageFileSD

    func testImageFileRoundTrip() {
        let imageData = Data(repeating: 0xAB, count: 256)
        let original = AttachedImageFile(
            name: "photo.png",
            url: URL(string: "file:///Users/test/photo.png")!,
            fileExtension: "png",
            binaryData: imageData,
            size: 256
        )

        let sd = AttachedImageFileSD.from(original)
        let restored = sd.toStruct()

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.name, "photo.png")
        XCTAssertEqual(restored.url, URL(string: "file:///Users/test/photo.png")!)
        XCTAssertEqual(restored.fileExtension, "png")
        XCTAssertEqual(restored.binaryData, imageData)
        XCTAssertEqual(restored.size, 256)
    }

    func testImageFilePersistence() throws {
        let data = Data(repeating: 0xFF, count: 128)
        let sd = AttachedImageFileSD(
            id: UUID(), name: "img.jpg", url: "file:///tmp/img.jpg",
            fileExtension: "jpg", binaryData: data, size: 128
        )
        context.insert(sd)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AttachedImageFileSD>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.binaryData, data)
    }

    func testImageFileEmptyData() {
        let original = AttachedImageFile(
            name: "empty.png",
            url: URL(string: "file:///tmp/empty.png")!,
            fileExtension: "png",
            binaryData: Data(),
            size: 0
        )

        let sd = AttachedImageFileSD.from(original)
        let restored = sd.toStruct()

        XCTAssertTrue(restored.binaryData.isEmpty)
    }

    func testLargeImageFilePersistence() throws {
        // Simulate a 1MB image
        let largeData = Data(repeating: 0xCD, count: 1_000_000)
        let sd = AttachedImageFileSD(
            id: UUID(), name: "large.png", url: "file:///tmp/large.png",
            fileExtension: "png", binaryData: largeData, size: 1_000_000
        )
        context.insert(sd)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AttachedImageFileSD>())
        XCTAssertEqual(fetched.first?.binaryData.count, 1_000_000)
    }
}
