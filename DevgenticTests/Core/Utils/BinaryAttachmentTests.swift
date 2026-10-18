// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BinaryAttachmentTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class BinaryAttachmentTests: XCTestCase {

    private let classFileBytes: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x41, 0x00, 0x1F]

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - SuggestableFileFilter

    func testCompiledArtifactsAreNotSuggested() {
        XCTAssertFalse(SuggestableFileFilter.admits(fileURL: URL(fileURLWithPath: "/p/January2026.class")))
        XCTAssertFalse(SuggestableFileFilter.admits(fileURL: URL(fileURLWithPath: "/p/lib.jar")))
        XCTAssertFalse(SuggestableFileFilter.admits(fileURL: URL(fileURLWithPath: "/p/main.o")))
        XCTAssertFalse(SuggestableFileFilter.admits(fileURL: URL(fileURLWithPath: "/p/clip.mp4")))
        XCTAssertFalse(SuggestableFileFilter.admits(fileURL: URL(fileURLWithPath: "/p/bundle.zip")))
    }

    func testSourceAndDocumentsAreSuggested() {
        for name in ["January2026.java", "README.md", "Makefile", "spec.pdf", "shot.png", "build.gradle"] {
            XCTAssertTrue(SuggestableFileFilter.admits(fileURL: URL(fileURLWithPath: "/p/\(name)")), name)
        }
    }

    func testBuildOutputBelowTheRootIsExcluded() {
        let root = URL(fileURLWithPath: "/w/java")
        XCTAssertTrue(SuggestableFileFilter.isInsideExcludedDirectory(
            URL(fileURLWithPath: "/w/java/out/production/cp-dsa/dsa/jan26"), root: root))
        XCTAssertTrue(SuggestableFileFilter.isInsideExcludedDirectory(
            URL(fileURLWithPath: "/w/java/out"), root: root))
        XCTAssertFalse(SuggestableFileFilter.isInsideExcludedDirectory(
            URL(fileURLWithPath: "/w/java/src/dsa/jan26"), root: root))
    }

    /// A project that itself lives under a folder named `build` must still be indexed.
    func testExcludedNamesAboveTheRootDoNotCount() {
        let root = URL(fileURLWithPath: "/home/build/app")
        XCTAssertFalse(SuggestableFileFilter.isInsideExcludedDirectory(
            URL(fileURLWithPath: "/home/build/app/src"), root: root))
        XCTAssertFalse(SuggestableFileFilter.isInsideExcludedDirectory(
            URL(fileURLWithPath: "/elsewhere/out"), root: root), "a path outside the root is not judged")
    }

    // MARK: - BinaryFileProbe

    func testLooksBinaryClassifier() {
        XCTAssertTrue(BinaryFileProbe.looksBinary(Data(classFileBytes), isTruncated: false))
        XCTAssertFalse(BinaryFileProbe.looksBinary(Data("héllo wörld".utf8), isTruncated: false))
        XCTAssertTrue(BinaryFileProbe.looksBinary(Data([0xFF, 0xFE, 0x41]), isTruncated: false), "invalid UTF-8")
    }

    /// The probe reads a prefix, which can split a multi-byte character — that is not binary.
    func testTruncatedMultiByteTailIsForgiven() {
        var bytes = Array(String(repeating: "a", count: 10).utf8)
        bytes += Array("€".utf8).prefix(2)   // 3-byte sequence cut after 2
        XCTAssertFalse(BinaryFileProbe.looksBinary(Data(bytes), isTruncated: true))
        XCTAssertTrue(BinaryFileProbe.looksBinary(Data(bytes), isTruncated: false))
    }

    func testProbeJudgesOnlyOnPositiveEvidence() throws {
        let dir = try tempDir()
        let binary = dir.appendingPathComponent("January2026.class")
        try Data(classFileBytes).write(to: binary)
        let source = dir.appendingPathComponent("January2026.java")
        try Data("class January2026 {}".utf8).write(to: source)

        XCTAssertTrue(BinaryFileProbe.contentLooksBinary(binary))
        XCTAssertFalse(BinaryFileProbe.contentLooksBinary(source))
        XCTAssertFalse(BinaryFileProbe.contentLooksBinary(dir.appendingPathComponent("ghost.bin")),
                       "a missing file is the send path's error to report, not a binary")
    }

    // MARK: - Send-time error

    func testBinaryReadThrowsNotTextWithANonRetryRemedy() async throws {
        let binary = try tempDir().appendingPathComponent("January2026.class")
        try Data(classFileBytes).write(to: binary)

        do {
            _ = try await FileProcessorService().readFileContentOrThrow(for: binary)
            XCTFail("a binary must not read as text")
        } catch let error as FileRetrievalError {
            guard case .notText = error else { return XCTFail("expected .notText, got \(error)") }
            XCTAssertFalse(error.suggestion?.contains("re-attach") ?? false,
                           "re-attaching a binary can never succeed")
        }
    }
}
