//
//  SpeechCodeViewerCapabilityTests.swift
//  DevgenticTests
//
//  [CF-21] Read Aloud announced "Here is the code in the panel view" and posted
//  `.speechOpenCodeViewer` unconditionally. That notification's only observer calls
//  `showCodeInViewer` on whatever `ChatHistoryViewModel` is in its environment, and QuickAccess
//  builds its view model WITHOUT `ownsCodeViewer` — so in that window the promise is empty, and
//  with pause-on-code enabled playback then stopped waiting for a Resume the user has no
//  transport to press (QuickAccess mounts no `SpeechControlIsland`).
//
//  SpeechService now takes the capability as a session input. These tests pin the two halves it
//  owns: what the reader SAYS, and the session default.
//
//  The call site is now wired too: `ChatBubbleView.toggleReadAloud` passes
//  `chatHistoryViewModel.canPresentCodeViewer`, so QuickAccess's view model (built WITHOUT
//  `ownsCodeViewer`) correctly gets `false` and the wrong-announcement / stuck-waiting symptom
//  is gone — not testable from this file since `toggleReadAloud` is a private SwiftUI method,
//  verified by reading `ChatBubbleView.swift` directly. The transport half is closed too:
//  `QuickAccessContentView` now mounts `SpeechControlIsland` over its transcript on the same
//  `speechService.isActive` gate the main window uses — see `SpeechTransportMountSignalTests`
//  at the bottom of this file for what is and is not testable about that.
//

import XCTest
@testable import devgentic

@MainActor
final class SpeechCodeViewerCapabilityTests: XCTestCase {

    // MARK: - What the reader says

    /// The main window owns a Code Viewer, so the announcement is the promise it has always
    /// been — pinned verbatim, because this is the string the row is contrasted against.
    func testAnnouncementIsUnchangedWhereAViewerExists() {
        XCTAssertEqual(
            SpeechService.codeBlockAnnouncement(canPresentCodeViewer: true, language: "swift"),
            "Here is the code in the panel view."
        )
        XCTAssertEqual(
            SpeechService.codeBlockAnnouncement(canPresentCodeViewer: true, language: nil),
            "Here is the code in the panel view."
        )
    }

    /// Where there is no viewer the reader must not promise a panel. It says the block is being
    /// skipped, and names the language so the listener still knows what was there.
    func testAnnouncementSaysSkippedWhereThereIsNoViewer() {
        let spoken = SpeechService.codeBlockAnnouncement(canPresentCodeViewer: false, language: "swift")

        XCTAssertFalse(spoken.contains("Here is the code"),
                       "The panel promise must not survive into a window with no panel: '\(spoken)'")
        XCTAssertTrue(spoken.localizedCaseInsensitiveContains("skipping"), "Got '\(spoken)'")
        XCTAssertTrue(spoken.contains("swift"), "The language is what tells the listener what was skipped: '\(spoken)'")
    }

    /// An unlabelled fence has no language to name; the sentence must still read as English
    /// rather than interpolating an empty word into it.
    func testSkipAnnouncementDropsAnEmptyLanguage() {
        let noLanguage = SpeechService.codeBlockAnnouncement(canPresentCodeViewer: false, language: nil)
        let blankLanguage = SpeechService.codeBlockAnnouncement(canPresentCodeViewer: false, language: "   ")

        XCTAssertEqual(noLanguage, blankLanguage, "A whitespace-only tag is no tag")
        XCTAssertTrue(noLanguage.localizedCaseInsensitiveContains("skipping"), "Got '\(noLanguage)'")
        XCTAssertFalse(noLanguage.contains("  "), "No double space where the language would have been: '\(noLanguage)'")
    }

    /// The two branches must actually differ. A refactor that collapses them (or forgets to
    /// pass the flag through) shows up here rather than in a user's ear.
    func testTheTwoAnnouncementsAreDifferentSentences() {
        XCTAssertNotEqual(
            SpeechService.codeBlockAnnouncement(canPresentCodeViewer: true, language: "swift"),
            SpeechService.codeBlockAnnouncement(canPresentCodeViewer: false, language: "swift")
        )
    }

    // MARK: - Session default

    /// The capability defaults to true so the main window — which does own a viewer, and is
    /// every existing call site — keeps its behaviour. An idle service must report that
    /// default, not a `false` left behind by a previous QuickAccess session.
    func testCapabilityDefaultsToTrueWhenIdle() {
        let service = SpeechService.shared
        service.stop()

        XCTAssertTrue(service.sessionCanPresentCodeViewerForTesting,
                      "A session that ended must not leave the next one thinking it has no viewer")
    }
}


// MARK: - CF-21 · the transport's mount condition

/// `SpeechControlIsland` is now mounted by BOTH surfaces that can start Read Aloud — the main
/// window's `ChatHistoryView` and `QuickAccessContentView` — each gated on `speechService.isActive`.
/// QuickAccess renders the app's real `ChatBubbleView`, whose Read Aloud button is not among the
/// actions `chatActionsSuppressed` hides, so playback could be started there while no Play, Pause,
/// Stop or speed control existed anywhere on screen.
///
/// ⚠️ The mount itself is an `if` inside a SwiftUI body and is NOT unit-testable here; it was
/// verified by reading both call sites. Extracting it into a "pure function" would only produce
/// one that returns its own argument, and a test of that would assert nothing. What IS worth
/// pinning — and what a regression would actually break — is the SIGNAL both surfaces gate on:
/// `isActive` must be true for exactly the session's lifetime, or one surface shows a transport
/// for a finished reader while the other shows none for a live one.
@MainActor
final class SpeechTransportMountSignalTests: XCTestCase {

    override func tearDown() async throws {
        SpeechService.shared.stop()
    }

    func testIsActiveIsTrueForExactlyTheSessionLifetime() {
        let service = SpeechService.shared
        service.stop()
        XCTAssertFalse(service.isActive, "idle: neither surface mounts a transport")

        service.speak("Alpha segment.", messageID: UUID(), canPresentCodeViewer: false)
        XCTAssertTrue(service.isActive, "speaking: both surfaces mount their transport")

        service.stop()
        XCTAssertFalse(service.isActive, "stopped: the transport must disappear on both")
    }
}
