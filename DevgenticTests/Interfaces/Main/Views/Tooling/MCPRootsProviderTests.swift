//
//  MCPRootsProviderTests.swift
//  DevgenticTests
//
//  Roots wiring, 2026-08-02. Roots are a PERMISSION BOUNDARY handed to third-party servers,
//  so the rules that matter most here are the negative ones: no fallback, no invented default,
//  no slot clobbering another.
//

import XCTest
@testable import devgentic

@MainActor
final class MCPRootsProviderTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MCPRootsProvider.setCodeProjectRoot(nil)
        await MCPRootsProvider.setExplorerRoot(nil)
    }

    override func tearDown() async throws {
        await MCPRootsProvider.setCodeProjectRoot(nil)
        await MCPRootsProvider.setExplorerRoot(nil)
        try await super.tearDown()
    }

    // MARK: - No fallback

    /// The single most important rule. Roots grant a third party access, and this app is not
    /// sandboxed — defaulting to the home directory or a last-used folder to make servers
    /// "just work" would be a silent, real over-grant.
    func testNoSourcesSet_PublishesNothing() {
        XCTAssertTrue(MCPRootsProvider.roots.isEmpty, "An empty boundary is the honest answer, never a default")
        XCTAssertTrue(MCPRootsProvider.currentRoots().isEmpty)
    }

    func testClearingBothSources_ReturnsToEmpty() async {
        await MCPRootsProvider.setCodeProjectRoot(URL(fileURLWithPath: "/tmp"))
        XCTAssertFalse(MCPRootsProvider.roots.isEmpty)

        await MCPRootsProvider.setCodeProjectRoot(nil)
        XCTAssertTrue(MCPRootsProvider.roots.isEmpty, "Clearing must not leave a stale grant in place")
    }

    // MARK: - Both sources contribute

    /// Roots are not a Code-mode feature: the Explorer's folder is the only boundary chat and
    /// workflow can offer, so it must count on its own.
    func testExplorerAlone_IsPublished() async {
        await MCPRootsProvider.setExplorerRoot(URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(MCPRootsProvider.roots.count, 1)
    }

    func testCodeAlone_IsPublished() async {
        await MCPRootsProvider.setCodeProjectRoot(URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(MCPRootsProvider.roots.count, 1)
    }

    /// Independent slots: the two sources are unrelated parts of the app, and a single shared
    /// setter would let whichever fired last erase the other's contribution.
    func testBothSources_Union_NeitherClobbersTheOther() async {
        await MCPRootsProvider.setCodeProjectRoot(URL(fileURLWithPath: "/tmp"))
        await MCPRootsProvider.setExplorerRoot(URL(fileURLWithPath: "/usr"))

        let paths = Set(MCPRootsProvider.roots.map(\.path))
        XCTAssertEqual(paths, ["/tmp", "/usr"])
    }

    func testSameFolderInBothSlots_IsDeduplicated() async {
        let shared = URL(fileURLWithPath: "/tmp")
        await MCPRootsProvider.setCodeProjectRoot(shared)
        await MCPRootsProvider.setExplorerRoot(shared)

        XCTAssertEqual(MCPRootsProvider.roots.count, 1, "One folder open twice is still one boundary")
    }

    /// Switching project must move the boundary, not add to it.
    func testReplacingASlot_DoesNotAccumulate() async {
        await MCPRootsProvider.setCodeProjectRoot(URL(fileURLWithPath: "/tmp"))
        await MCPRootsProvider.setCodeProjectRoot(URL(fileURLWithPath: "/usr"))

        XCTAssertEqual(MCPRootsProvider.roots.map(\.path), ["/usr"])
    }

    // MARK: - roots/list answering

    /// Advertising a path a server cannot stat produces per-server errors that look like the
    /// server is broken.
    func testCurrentRoots_OmitsPathsThatNoLongerExist() async {
        await MCPRootsProvider.setCodeProjectRoot(URL(fileURLWithPath: "/tmp"))
        await MCPRootsProvider.setExplorerRoot(URL(fileURLWithPath: "/definitely/not/here/\(UUID().uuidString)"))

        let answered = MCPRootsProvider.currentRoots()
        XCTAssertEqual(answered.count, 1, "Only the existing directory is advertised")
        XCTAssertTrue(answered[0].uri.contains("tmp"))
    }

    func testCurrentRoots_ProducesFileURIsWithNames() async {
        await MCPRootsProvider.setCodeProjectRoot(URL(fileURLWithPath: "/tmp"))

        let root = try? XCTUnwrap(MCPRootsProvider.currentRoots().first)
        XCTAssertTrue(root?.uri.hasPrefix("file://") ?? false, "MCP roots are file URIs, not bare paths")
        XCTAssertEqual(root?.name, "tmp")
    }

    /// A file is not a workspace; only directories are valid roots.
    func testCurrentRoots_OmitsRegularFiles() async {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("root-probe-\(UUID().uuidString).txt")
        try? "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        await MCPRootsProvider.setCodeProjectRoot(file)
        XCTAssertTrue(MCPRootsProvider.currentRoots().isEmpty)
    }
}
