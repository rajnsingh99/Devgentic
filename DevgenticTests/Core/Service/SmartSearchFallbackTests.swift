// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SmartSearchFallbackTests.swift
//  DevgenticTests
//
//  Tests for HybridSearchService.filesystemScan — the bounded disk-walk fallback
//  that runs when a SCOPED Spotlight query returns zero rows. Spotlight excludes
//  volatile locations (/private/tmp, /var/folders) from its index, so index-empty
//  ≠ disk-empty there; the fallback is what makes an spotlight_search "success"
//  mean "the answer reflects the disk".
//
//  The temp directories these tests create live under /var/folders — genuinely
//  unindexed territory, i.e. exactly the terrain the fallback exists for.
//

import XCTest
@testable import devgentic

final class SmartSearchFallbackTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-search-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    // MARK: - Matching

    func testScan_FindsFileInSubdirectory() throws {
        try touch("archive/target_log.txt")
        try touch("unrelated.md")

        let results = HybridSearchService.filesystemScan(term: "target", scopeURL: root)
        XCTAssertEqual(results?.count, 1)
        XCTAssertTrue(results?.first?.hasSuffix("archive/target_log.txt") == true)
    }

    func testScan_MultiToken_AllTokensMustMatchFilename() throws {
        try touch("alpha_notes.md")
        try touch("alpha_summary.md")
        try touch("beta_notes.md")

        // Mirrors the ANDed kMDItemFSName token query: both tokens, case-insensitive.
        let results = HybridSearchService.filesystemScan(term: "Alpha Notes", scopeURL: root)
        XCTAssertEqual(results?.count, 1)
        XCTAssertTrue(results?.first?.hasSuffix("alpha_notes.md") == true)
    }

    func testScan_MatchesDirectoriesToo() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("target_dir"), withIntermediateDirectories: true)

        let results = HybridSearchService.filesystemScan(term: "target", scopeURL: root)
        XCTAssertEqual(results?.count, 1, "Directories must match — kMDItemFSName queries match folders")
    }

    func testScan_SkipsHiddenFiles() throws {
        try touch(".hidden_target.txt")
        try touch("visible_target.txt")

        let results = HybridSearchService.filesystemScan(term: "target", scopeURL: root)
        XCTAssertEqual(results?.count, 1)
        XCTAssertTrue(results?.first?.hasSuffix("visible_target.txt") == true)
    }

    // MARK: - Honest empties vs unverifiable scopes

    func testScan_NoMatches_ReturnsEmptyNotNil() throws {
        try touch("something.txt")

        let results = HybridSearchService.filesystemScan(term: "zzz_absent", scopeURL: root)
        XCTAssertNotNil(results, "Scanned-and-found-nothing is a verified empty, not a failure")
        XCTAssertTrue(results?.isEmpty == true)
    }

    func testScan_NonexistentScope_ReturnsNil() {
        let bogus = root.appendingPathComponent("does-not-exist")
        let results = HybridSearchService.filesystemScan(term: "anything", scopeURL: bogus)
        XCTAssertNil(results, "Unenumerable scope = absence NOT verified — must be distinguishable")
    }

    func testScan_FileScope_ReturnsNil() throws {
        try touch("a_file.txt")
        let fileURL = root.appendingPathComponent("a_file.txt")
        let results = HybridSearchService.filesystemScan(term: "a_file", scopeURL: fileURL)
        XCTAssertNil(results, "Scope must be a directory")
    }

    // MARK: - Bounds

    func testScan_CapsResults() throws {
        for i in 0..<15 { try touch("cap_\(i).txt") }

        let results = HybridSearchService.filesystemScan(term: "cap", scopeURL: root, maxResults: 10)
        XCTAssertEqual(results?.count, 10)
    }

    func testScan_RespectsMaxDepth() throws {
        try touch("l1/l2/l3/deep_target.txt")

        let shallow = HybridSearchService.filesystemScan(term: "deep_target", scopeURL: root, maxDepth: 2)
        XCTAssertTrue(shallow?.isEmpty == true, "Beyond maxDepth must not be scanned")

        let deep = HybridSearchService.filesystemScan(term: "deep_target", scopeURL: root, maxDepth: 6)
        XCTAssertEqual(deep?.count, 1)
    }
}
