// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SpeechTransportTeardownTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class SpeechTransportTeardownTests: XCTestCase {

    private let service = SpeechService.shared

    override func setUp() async throws {
        service.stop()
        service.resetTransportHostsForTesting()
    }

    override func tearDown() async throws {
        service.stop()
        service.resetTransportHostsForTesting()
    }

    private func startPlayback() {
        service.speak("Alpha segment.", messageID: UUID(), canPresentCodeViewer: false)
        XCTAssertTrue(service.isActive, "sanity: a session is live")
    }

    /// Lets the deferred check behind `transportHostDidDisappear` run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: - The rule

    /// THE pin: the last host goes away → the session stops and the synthesizer is released.
    func testLastHostGoneStopsALiveSession() async {
        let host = UUID()
        service.transportHostDidAppear(host)
        startPlayback()

        service.transportHostDidDisappear(host)
        await settle()

        XCTAssertFalse(service.isActive, "no transport anywhere means no way to stop it — so stop it")
        XCTAssertFalse(service.isSynthesizerLoaded, "the [V5] lifetime: released at session end")
    }

    /// The cross-surface case the per-surface fix would have broken: the main window is still
    /// showing an island when the panel closes.
    func testASurvivingHostKeepsTheSessionAlive() async {
        let main = UUID(), panel = UUID()
        service.transportHostDidAppear(main)    // main window
        service.transportHostDidAppear(panel)   // QuickAccess transcript
        startPlayback()

        service.transportHostDidDisappear(panel)   // panel closed
        await settle()

        XCTAssertTrue(service.isActive, "the main window still shows the transport")
        XCTAssertEqual(service.mountedTransportHosts, 1)
    }

    /// A mode switch tears one host down and mounts another in the same transaction, in an
    /// unspecified order. The deferred check must see the SETTLED count, not the momentary 0.
    func testHostReplacedWithinTheSameTurnDoesNotStop() async {
        let chatMode = UUID(), codeMode = UUID()
        service.transportHostDidAppear(chatMode)
        startPlayback()

        service.transportHostDidDisappear(chatMode)   // Chat-mode ChatHistoryView gone …
        service.transportHostDidAppear(codeMode)      // … Code-mode ChatHistoryView mounted, same turn
        await settle()

        XCTAssertTrue(service.isActive, "a replaced host is not a lost host")
        XCTAssertEqual(service.mountedTransportHosts, 1)
    }

    /// The synchronous rule, without the deferral, for the two negatives.
    func testStopIfNoTransportRemainsIsANoOpWhenIdleOrHosted() {
        service.stopIfNoTransportRemains()          // idle, zero hosts
        XCTAssertFalse(service.isActive)

        service.transportHostDidAppear(UUID())
        startPlayback()
        service.stopIfNoTransportRemains()          // live, one host
        XCTAssertTrue(service.isActive, "a hosted session must not be stopped")
    }

    /// Registration is idempotent per identity: a duplicate `onAppear` is still ONE host (a
    /// counter would have leaked +1 and disarmed the rule for the rest of the process), and a
    /// teardown for an id that is not registered is ignored (a counter would have stolen a
    /// host that is still on screen).
    func testRegistrationIsIdempotentPerIdentity() async {
        let main = UUID(), panel = UUID()
        service.transportHostDidAppear(main)
        service.transportHostDidAppear(main)          // duplicate appear
        XCTAssertEqual(service.mountedTransportHosts, 1)

        service.transportHostDidAppear(panel)
        startPlayback()
        service.transportHostDidDisappear(panel)      // SwiftUI onDisappear …
        service.transportHostDidDisappear(panel)      // … AND the panel's windowWillClose
        service.transportHostDidDisappear(UUID())     // a never-registered id
        await settle()

        XCTAssertTrue(service.isActive, "the main window still hosts the transport")
        XCTAssertEqual(service.mountedTransportHosts, 1)

        service.transportHostDidDisappear(main)       // the real last host
        await settle()
        XCTAssertFalse(service.isActive)
    }

    /// A session started AFTER every host is gone (nothing does this today) is left alone
    /// until a host actually disappears — the rule fires on teardown, not on speak.
    func testHostlessStartIsNotStoppedBySpeakItself() {
        startPlayback()
        XCTAssertTrue(service.isActive)
    }
}
