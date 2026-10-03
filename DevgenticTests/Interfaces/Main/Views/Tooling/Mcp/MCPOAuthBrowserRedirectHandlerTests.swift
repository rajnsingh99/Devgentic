// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPOAuthBrowserRedirectHandlerTests.swift
//  devgenticTests
//
//  Register KC-45 — the redirect handler opened the user's browser BEFORE checking that the
//  flow's loopback listener still existed, and reported the registry miss as "couldn't open
//  the browser".
//
//  ⚠️⚠️ THE FAILURE THESE PIN. `awaitAuthorizationCode` ran `NSWorkspace.open` first and only
//  then looked the listener up in `LoopbackRegistry`. A flow whose listener had already been
//  torn down therefore still popped a browser tab, sent the user through their whole login,
//  and only then died — with the miss reported as `openBrowserFailed` ("Try copying the URL
//  manually"), naming a failure that never happened and advising a manual URL that has nothing
//  to land on.
//
//  ⚠️ WHY THE BEHAVIOURAL PROBE GUARDS ITSELF. Calling the handler with no listener registered
//  is safe ONLY while the listener lookup precedes the browser open. If the ordering ever
//  regresses, that call would open a REAL browser tab on the developer's machine — the exact
//  side effect this defect is about — so the probe checks the source order first and declines
//  to fire when it has regressed, leaving the failure to the ordering pins below.
//

import XCTest
@testable import devgentic

@MainActor
final class MCPOAuthBrowserRedirectHandlerTests: XCTestCase {

    private static let sourcePath =
        "Devgentic/Interfaces/Main/Views/Tooling/Mcp/OAuth/MCPOAuthBrowserRedirectHandler.swift"

    // MARK: - The ordering

    func testTheListenerIsResolvedBeforeTheBrowserIsOpened() throws {
        let source = try TestRepositorySource.read(Self.sourcePath)
        let lookup = try XCTUnwrap(
            source.range(of: "LoopbackRegistry.shared.listener(for: redirectURI)"),
            "the handler no longer resolves its listener from the registry")
        let open = try XCTUnwrap(
            source.range(of: "NSWorkspace.shared.open("),
            "the handler no longer opens the browser through NSWorkspace")
        XCTAssertLessThan(lookup.lowerBound, open.lowerBound, """
            The browser is opened before the loopback listener is known to exist. A flow whose \
            listener is already gone then still pops a browser tab — the user signs in, the \
            redirect lands on a socket nothing is listening on, and the flow dies anyway. Look \
            first; launch after.
            """)
    }

    /// The miss must carry its OWN error. Resolved on source because throwing the registry miss
    /// for real requires the browser open to have happened first — the very defect.
    func testARegistryMissIsNotReportedAsABrowserFailure() throws {
        let source = try TestRepositorySource.read(Self.sourcePath)
        let lookup = try XCTUnwrap(
            source.range(of: "LoopbackRegistry.shared.listener(for: redirectURI)"))
        let nextThrow = try XCTUnwrap(
            source.range(of: "throw MCPOAuthBrowserError.", range: lookup.upperBound..<source.endIndex))
        let lineEnd = source[nextThrow.upperBound...].firstIndex(of: "\n") ?? source.endIndex
        let thrownCase = String(source[nextThrow.lowerBound..<lineEnd])
        XCTAssertFalse(thrownCase.contains("openBrowserFailed"), """
            The registry miss is reported as '\(thrownCase)' — 'couldn't open the browser'. \
            Nothing was even attempted yet: the actual state is that nothing is listening for \
            this flow's redirect, and 'copy the URL manually' would send the user into a browser \
            with nothing to land on.
            """)
    }

    // MARK: - The messages

    func testTheTwoStartupFailuresHaveDistinctMessages() {
        XCTAssertNotEqual(MCPOAuthBrowserError.openBrowserFailed.errorDescription,
                          MCPOAuthBrowserError.noLoopbackListener.errorDescription,
                          "a browser-open failure and a missing listener are different states "
                          + "with different remedies; one message cannot serve both")
        XCTAssertTrue(
            MCPOAuthBrowserError.openBrowserFailed.errorDescription?.lowercased().contains("browser") == true,
            "the browser-failure message must keep naming the browser")
    }

    // MARK: - Behavioural probe

    private static func listenerIsResolvedFirst(in source: String) -> Bool {
        guard let lookup = source.range(of: "LoopbackRegistry.shared.listener(for: redirectURI)"),
              let open = source.range(of: "NSWorkspace.shared.open(") else { return false }
        return lookup.lowerBound < open.lowerBound
    }

    func testASignInWithNoListenerFailsWithItsOwnErrorWithoutOpeningTheBrowser() async throws {
        let source = try TestRepositorySource.read(Self.sourcePath)
        try XCTSkipUnless(
            Self.listenerIsResolvedFirst(in: source),
            "the ordering regressed; calling the handler now would open a real browser tab, so "
            + "this probe declines to fire and the ordering pins above carry the failure")

        // A redirect URI nothing listens on — a fresh port, and explicitly unregistered.
        let redirectURI = URL(string: "http://127.0.0.1:\(Int.random(in: 40_000...60_000))/callback")!
        LoopbackRegistry.shared.unregister(redirectURL: redirectURI)

        let handler = MCPOAuthBrowserRedirectHandler(timeout: 1)
        do {
            _ = try await handler.awaitAuthorizationCode(
                authorizeURL: URL(string: "https://as.example.com/authorize")!,
                redirectURI: redirectURI,
                expectedState: "state")
            XCTFail("a flow whose listener is gone cannot return a code")
        } catch let error as MCPOAuthBrowserError {
            guard case .noLoopbackListener = error else {
                return XCTFail("expected .noLoopbackListener, got \(error)")
            }
            XCTAssertNotEqual(error.errorDescription,
                              MCPOAuthBrowserError.openBrowserFailed.errorDescription,
                              "the registry miss must not borrow the browser-failure message")
        }
    }
}
