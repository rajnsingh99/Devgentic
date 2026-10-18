// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsTestHostGuardTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class ChatOpsTestHostGuardTests: XCTestCase {

    /// ⚠️ THE ONE ASSERTION THAT PROVES THE GUARD WORKS: it is evaluated in a real XCTest process,
    /// so it answers the same question production asks, in the situation that matters.
    func testThisProcessMayNotOpenRealChatConnections() {
        let mayOpen = ChatOpsCoordinator.mayOpenRealConnections
        XCTAssertFalse(mayOpen, """
            An XCTest host believes it may open real chat listeners. Every test run would then race \
            the developer's running app for the same bot token — Telegram serves one poller and 409s \
            the other, so their commands are swallowed at random and executed in the test host.
            """)
    }

    /// `bootstrap()` must actually consult it. A correct predicate nothing calls is the same
    /// comment-only protection this replaced.
    func testBootstrapConsultsTheGuardBeforeStartingAnything() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSourceStrippingComments("Devgentic/ChatOps/Services/ChatOpsCoordinator.swift")
        guard let bootstrap = source.range(of: "func bootstrap() {"),
              let guardCall = source.range(of: "mayOpenRealConnections", range: bootstrap.upperBound..<source.endIndex),
              let firstStart = source.range(of: "startTelegram()", range: bootstrap.upperBound..<source.endIndex) else {
            return XCTFail("could not find the guard and the first bridge start inside bootstrap()")
        }
        XCTAssertTrue(guardCall.lowerBound < firstStart.lowerBound,
                      "the refusal must come before any bridge is started")
    }

    /// ⚠️ DELIBERATELY NOT `#if DEBUG`, unlike `TraceStore`'s twin. That one is compiled out of
    /// release because it GRANTS something — an environment-supplied path a shipped app must not
    /// honour. This one only ever REFUSES, and `XCTestCase` cannot load in a shipped app anyway, so
    /// leaving it in costs nothing and also covers a release-configuration test run.
    func testTheGuardIsNotCompiledOutOfReleaseBuilds() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Services/ChatOpsCoordinator.swift")
        guard let start = source.range(of: "static var mayOpenRealConnections: Bool {"),
              let end = source.range(of: "\n    }", range: start.upperBound..<source.endIndex) else {
            return XCTFail("could not locate the guard")
        }
        XCTAssertFalse(source[start.lowerBound..<end.upperBound].contains("#if DEBUG"),
                       "the refusal is now compiled out of release builds; it grants nothing, so it need not be")
    }

    /// Previews are the other host that must not open real connections.
    func testPreviewsAreRefusedToo() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSourceStrippingComments("Devgentic/ChatOps/Services/ChatOpsCoordinator.swift")
        XCTAssertTrue(source.contains("XCODE_RUNNING_FOR_PREVIEWS"),
                      "a SwiftUI preview would open the developer's real chat listeners")
    }

    /// ⚠️ The seam that lets a test construct the view model DELIBERATELY rather than being
    /// forbidden by comment. It is not the safety mechanism — the guard above is — but without it
    /// the only way to express "no ChatOps" is to not construct the object at all.
    func testTheViewModelExposesAnExplicitChatOpsOptOut() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSourceStrippingComments("Devgentic/Interfaces/Main/MainApplicationViewModel.swift")
        XCTAssertTrue(source.contains("bootstrapChatOps: Bool = true"), """
            The view model no longer offers an explicit ChatOps opt-out, so the only way to avoid \
            starting bridges is the comment-only convention that never worked.
            """)
        XCTAssertTrue(source.contains("if bootstrapChatOps {"), "the parameter is declared but not honoured")
    }
}
