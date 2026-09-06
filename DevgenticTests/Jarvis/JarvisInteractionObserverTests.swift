//
//  JarvisInteractionObserverTests.swift
//  DevgenticTests
//
//  The HITL observer's re-arm contract.
//
//  ⚠️ WHY A SOURCE-READING TEST. The observer re-arms itself inside its own `onChange`, so it used
//  to outlive the conversation it was armed for: "new conversation" and a profile switch both clear
//  `jarvisConversationID` while leaving the loop running, and every HITL raised anywhere in the app
//  then woke a handler with nothing to do — emitting an ERROR claiming a parked run would hang the
//  orb, on a session that had no run at all.
//
//  The fix stops re-arming while nothing is bound, which is only safe because `execute()` arms it
//  again on every dispatch. That makes a call site in a DIFFERENT method load-bearing: delete it and
//  the observer never comes back after a "new conversation", so an agent that parks for approval
//  hangs the orb on THINKING with no way to answer — the exact deadlock the observer exists to
//  prevent. Nothing else would notice. Driving the real path needs a MainApplicationViewModel, an
//  InteractionCenter and live observation tracking, so the coupling is pinned structurally, the way
//  `ShellInterpolationGuardTests` pins its own.
//

import XCTest
@testable import devgentic

final class JarvisInteractionObserverContractTests: XCTestCase {

    private func controllerSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)   // …/DevgenticTests/Jarvis/<this>
            .deletingLastPathComponent()                 // …/DevgenticTests/Jarvis
            .deletingLastPathComponent()                 // …/DevgenticTests
            .deletingLastPathComponent()                 // repo root
        let source = repoRoot.appendingPathComponent("Devgentic/Jarvis/JarvisSessionController.swift")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("controller source not reachable from \(repoRoot.path) — running outside a checkout")
        }
        return try String(contentsOf: source, encoding: .utf8)
    }

    /// The body of `execute(_:)`, from its signature to the next method at the same indent.
    private func executeBody(in source: String) -> String? {
        guard let start = source.range(of: "private func execute(_ command: String) async {") else { return nil }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    func ") else {
            return String(rest)
        }
        return String(rest[..<end.lowerBound])
    }

    /// ⚠️⚠️ THE LOAD-BEARING COUPLING. `observeInteractions()` stops re-arming itself once the
    /// conversation is unbound, so this call is what brings the observer back for the next turn.
    /// Without it, the first "new conversation" silently disables HITL surfacing for the rest of
    /// the panel session.
    func testDispatchReArmsTheInteractionObserver() throws {
        let source = try controllerSource()
        guard let body = executeBody(in: source) else {
            return XCTFail("could not locate execute(_:) — if it was renamed, re-point this test rather than deleting it")
        }
        XCTAssertTrue(body.contains("observeInteractions()"),
                      "execute() must arm the HITL observer: it is the ONLY thing that restores it after a 'new conversation' or a profile switch.")
    }

    /// It must arm AFTER the conversation exists, or it arms against nothing and immediately
    /// unwinds itself under the new guard.
    func testTheObserverIsArmedAfterTheConversationIsBound() throws {
        let source = try controllerSource()
        guard let body = executeBody(in: source) else {
            return XCTFail("could not locate execute(_:)")
        }
        guard let ensure = body.range(of: "ensureConversation("),
              let observe = body.range(of: "observeInteractions()") else {
            return XCTFail("execute() must both bind a conversation and arm the observer")
        }
        XCTAssertLessThan(ensure.lowerBound, observe.lowerBound,
                          "ensureConversation must run BEFORE observeInteractions, or the observer arms with jarvisConversationID still nil and stops on its first change.")
    }

    /// ⚠️ The observer must not re-arm while unbound — that is the defect. Pinned on the source
    /// because the alternative is a live view model and an interaction centre.
    func testTheObserverStopsWhileNoConversationIsBound() throws {
        let source = try controllerSource()
        guard let start = source.range(of: "private func observeInteractions() {"),
              let end = source.range(of: "private func handleInteractionChange() {") else {
            return XCTFail("could not locate the observer")
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("guard self.jarvisConversationID != nil else"),
                      "The onChange closure must stop observing while nothing is bound; without it every app-wide HITL wakes a handler with no run to surface.")
    }

    /// ⚠️ A nil conversation is the ordinary state between turns, not a fault. Logging it at error
    /// level asserted a deadlock that was not happening — the project's own rule is that a log
    /// which lies is worse than no log, because it sends the reader somewhere else entirely.
    func testAnUnboundConversationIsNotReportedAsAnError() throws {
        let source = try controllerSource()
        guard let start = source.range(of: "private func handleInteractionChange() {"),
              let end = source.range(of: "var isVoiceApprovalArmed") else {
            return XCTFail("could not locate handleInteractionChange")
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        guard let unbound = body.range(of: "no conversation is bound") else {
            return XCTFail("the unbound case should still be reported, just not as a failure")
        }
        // Walk back to the start of that logging statement and check its level.
        let statement = String(body[..<unbound.lowerBound])
        let level = statement.range(of: "logger.", options: .backwards)
        guard let level else { return XCTFail("no logger call precedes the unbound message") }
        let call = String(statement[level.lowerBound...])
        XCTAssertFalse(call.hasPrefix("logger.error"),
                       "An unbound conversation is the state after 'new conversation' — reporting it as an error sends a reader hunting a deadlock that is not happening.")
    }
}
