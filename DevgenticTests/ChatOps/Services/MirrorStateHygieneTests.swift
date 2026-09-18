// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MirrorStateHygieneTests.swift
//  devgenticTests
//
//  B7 — MIR-4, MIR-5, MIR-6 and OBS-6.
//
//  ⚠️ MIR-5 AND OBS-6 ARE ONE ROOT CAUSE: operation-keyed prompt state (`hitlMessageIDs`,
//  `mirroredOperations`) with session-keyed release paths that never touched it. Landing OBS-6 alone
//  would make every ordinary bridge stop emit one warning per abandoned prompt instead of one teardown
//  line with a count; landing MIR-5 alone leaves the resolution path unable to say what happened.
//

import XCTest
@testable import devgentic

final class MirrorStateHygieneTests: XCTestCase {

    private func mirrorSource() throws -> String {
        try ChatOpsSecurityTierMatrixTests
            .readSourceStrippingComments("Devgentic/ChatOps/Services/RemoteMirrorService.swift")
    }

    // MARK: - MIR-4

    /// ⚠️ `observeMessage` RE-ARMS ITS OBSERVATION ON EVERY FLUSH — roughly 5-20 times a second at the
    /// adaptive interval. An `.info` line there wrote one entry per re-arm into the same ring buffer a
    /// diagnostic bundle exports, burying the mirror's real drop lines under its own noise.
    func testTheObservationLogIsNotOnTheReEntrantPath() throws {
        let source = try mirrorSource()
        guard let fn = source.range(of: "func observeMessage(") else {
            return XCTFail("observeMessage has moved — this test is blind")
        }
        let body = String(source[fn.upperBound...].prefix(2000))
        XCTAssertFalse(body.contains("logger.info("),
                       "an .info line inside the re-armed observer emits once per streamed flush")
    }

    /// It must still be logged — once, where a run is admitted, with the provider it lacked.
    func testARunIsStillReportedWhenItIsAdmittedForMirroring() throws {
        let source = try mirrorSource()
        XCTAssertTrue(source.contains("Mirroring the run in conversation"),
                      "moving the line must not delete it: a conversation absent from the log would "
                      + "be indistinguishable from one that produced no remote output")
    }

    // MARK: - MIR-5

    /// ⚠️⚠️ SESSION-KEYED RELEASE FOR OPERATION-KEYED STATE. `teardown` cleared the sessions and left
    /// `hitlMessageIDs` populated, so every posted prompt was abandoned with its message id still
    /// recorded — and the observers that would rewrite it then found no session and bailed silently.
    func testTeardownReleasesTheOperationKeyedStateToo() throws {
        let source = try mirrorSource()
        guard let fn = source.range(of: "func teardown()") else { return XCTFail("teardown has moved") }
        let body = String(source[fn.upperBound...].prefix(1200))

        for field in ["hitlMessageIDs.removeAll()", "mirroredOperations.removeAll()", "observedMessageIDs.removeAll()"] {
            XCTAssertTrue(body.contains(field),
                          "teardown leaves \(field.replacingOccurrences(of: ".removeAll()", with: "")) "
                          + "populated, so its prompts keep live buttons nothing will ever rewrite")
        }
    }

    /// ⚠️ THE COUNT IS THE POINT. "Torn down" is unfalsifiable; a number of abandoned prompts is the
    /// fact that tells a field debugger whether a user is staring at buttons that will never resolve.
    func testTeardownReportsWhatItAbandoned() throws {
        let source = try mirrorSource()
        guard let fn = source.range(of: "func teardown()") else { return XCTFail("teardown has moved") }
        let body = String(source[fn.upperBound...].prefix(1200))
        XCTAssertTrue(body.contains("abandonedPrompts"), "teardown reports no counts")
        XCTAssertTrue(body.contains("logger.warning"),
                      "abandoning live prompts is a failure and must clear the persist floor; .info "
                      + "never reaches an exported diagnostic bundle")
    }

    // MARK: - OBS-6

    /// ⚠️⚠️ TWO OPPOSITE SITUATIONS SHARED ONE BARE `return`. "Not ours" (a Mac-only run — the common
    /// case) and "ours, but the session is gone" were indistinguishable, and the second leaves
    /// approve/deny buttons live on a decision already made, with nothing written anywhere.
    func testAStrandedPromptIsDistinguishedFromOneThatIsNotOurs() throws {
        let source = try mirrorSource()
        XCTAssertTrue(source.contains("case stranded(messageID: String, reason: String)"),
                      "the two outcomes are still collapsed into one silent bail")
        XCTAssertTrue(source.contains("func reportStranded("),
                      "the stranded case must SAY so — that is the whole finding")

        // ⚠️⚠️ THAT THE FUNCTION EXISTS PROVES NOTHING, AND A MUTATION CAUGHT ME HERE: deleting only
        // the CALL left `reportStranded` declared and this test green over a silently-restored
        // defect. Assert the stranded ARM invokes it.
        guard let fn = source.range(of: "func rewritableTarget(") else {
            return XCTFail("rewritableTarget has moved")
        }
        let body = String(source[fn.upperBound...].prefix(700))
        // ⚠️⚠️ BOUNDED TO THE SWITCH, NOT A FIXED WINDOW — and a mutation caught this too. A
        // 220-character slice after `case .stranded` ran PAST the end of the function and matched
        // `reportStranded`'s own DECLARATION on the next line, so the test passed over a mutation
        // that had deleted the call. A window that can escape its scope reads whatever follows.
        guard let arm = body.range(of: "case .stranded") else { return XCTFail("no .stranded arm") }
        let afterArm = body[arm.upperBound...]
        let armBody = String(afterArm[..<(afterArm.range(of: "\n        }")?.lowerBound ?? afterArm.endIndex)])
        XCTAssertTrue(armBody.contains("reportStranded("),
                      "the stranded arm returns nil without reporting — indistinguishable from "
                      + "\"not ours\", which is exactly the defect OBS-6 filed")
    }

    /// ⚠️ THE ORDER IS LOAD-BEARING. `hitlMessageIDs` must be checked FIRST so `.notOurs` stays narrow;
    /// checking the session first would classify every Mac-only resolution as stranded and flood the
    /// log with exactly the non-event this distinction exists to keep out.
    func testNotOursIsCheckedBeforeTheSession() throws {
        let source = try mirrorSource()
        guard let fn = source.range(of: "func promptResolution(") else {
            return XCTFail("promptResolution has moved")
        }
        let body = String(source[fn.upperBound...].prefix(900))
        guard let ours = body.range(of: "hitlMessageIDs[operationID]"),
              let session = body.range(of: "remoteSessions[conversationID]") else {
            return XCTFail("could not locate both checks")
        }
        XCTAssertLessThan(ours.lowerBound, session.lowerBound,
                          "checking the session first makes every Mac-only resolution look stranded")
    }

    /// ⚠️ `.notOurs` STAYS SILENT — the `PairingAttemptPolicy.unrelated` precedent. A future reader
    /// "completing" the logging here should fail this test rather than succeed.
    func testTheNotOursCaseIsDeliberatelyUnlogged() throws {
        let source = try mirrorSource()
        guard let fn = source.range(of: "func rewritableTarget(") else {
            return XCTFail("rewritableTarget has moved")
        }
        let body = String(source[fn.upperBound...].prefix(700))
        guard let notOurs = body.range(of: "case .notOurs:") else { return XCTFail("no .notOurs arm") }
        let arm = String(body[notOurs.upperBound...].prefix(120))
        XCTAssertFalse(arm.contains("logger."),
                       "a line per Mac-only resolution buries the one that matters")
    }

    // MARK: - MIR-6

    /// ⚠️ The set had ONE reset hook and that hook had ZERO callers, so it grew for the life of the
    /// process and could SUPPRESS an injection the view genuinely needed after a conversation switch.
    /// Deleting it is more correct than resetting it: the view is asked directly and cannot go stale.
    func testTheSyncServiceNoLongerKeepsASecondCopyOfWhatTheViewHolds() throws {
        let source = try ChatOpsSecurityTierMatrixTests
            .readSourceStrippingComments("Devgentic/ChatOps/Services/ConversationSyncService.swift")
        XCTAssertFalse(source.contains("syncedMessageIDs"),
                       "the dead dedup set is back; its only reset hook has no callers, so it grows "
                       + "unbounded and can suppress a needed injection")
        XCTAssertFalse(source.contains("func resetForConversation"),
                       "an uncalled reset hook is what made the set's safety rest on an unwritten "
                       + "cross-file claim about what loadConversation merges")
        XCTAssertTrue(source.contains("currentChatMessages.contains(where:"),
                      "the observer must ask the view directly — that answer cannot go stale")
    }
}
