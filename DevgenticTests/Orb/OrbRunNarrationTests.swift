// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbRunNarrationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class OrbRunNarrationTests: XCTestCase {

    // MARK: - Unavailability

    /// ⚠️ THE REGRESSION THAT MATTERS. An unavailable projection carries an EMPTY verdict
    /// sentence, so speaking it verbatim ends the turn in silence with no reason given.
    func testEveryUnavailabilityCauseProducesItsOwnSentence() {
        var sentences: Set<String> = []
        for cause in [RunReportUnavailability.neverRecorded, .purged, .storeUnavailable] {
            let sentence = OrbRunNarration.unavailabilitySentence(cause)
            XCTAssertNotNil(sentence, "\(cause) must be explained, not swallowed.")
            XCTAssertFalse(sentence!.isEmpty)
            sentences.insert(sentence!)
        }
        XCTAssertEqual(sentences.count, 3, "Three different situations must not share one sentence — that teaches the user the feature is broken.")
        XCTAssertNil(OrbRunNarration.unavailabilitySentence(.none))
    }

    // MARK: - Changes

    func testNoChangesIsStatedPlainly() {
        let spoken = OrbRunNarration.changeSentence(effects: [], writeToolNames: [])
        XCTAssertTrue(spoken.lowercased().contains("didn't change"))
    }

    func testASingleFileChangeNamesTheFileAndTheLineCounts() {
        let effect = ActionEffect(path: "/Users/alice/src/Config.swift", linesAdded: 12, linesRemoved: 3, diff: nil, isTruncated: false)
        let spoken = OrbRunNarration.changeSentence(effects: [effect], writeToolNames: [])
        XCTAssertTrue(spoken.contains("Config.swift"), "The file must be named: \(spoken)")
        XCTAssertFalse(spoken.contains("/Users/"), "An absolute path read aloud is eleven words of noise: \(spoken)")
        XCTAssertTrue(spoken.contains("12"))
        XCTAssertTrue(spoken.contains("3"))
    }

    /// A spoken list has to be receivable in order, with no chance to skim back.
    func testALongChangeListIsCappedAndSaysHowManyItOmitted() {
        let effects = (1...9).map {
            ActionEffect(path: "/tmp/File\($0).swift", linesAdded: $0, linesRemoved: 0, diff: nil, isTruncated: false)
        }
        let spoken = OrbRunNarration.changeSentence(effects: effects, writeToolNames: [])
        XCTAssertTrue(spoken.contains("9 files"), "The total must still be stated: \(spoken)")
        XCTAssertTrue(spoken.contains("File1.swift"))
        XCTAssertFalse(spoken.contains("File9.swift"), "Past the cap the listener has lost the first item anyway.")
        XCTAssertTrue(spoken.contains("\(9 - OrbRunNarration.spokenListCap) more"),
                      "Omission must be admitted, not silent: \(spoken)")
    }

    /// ⚠️ The honest-gap case. A write-class tool ran but left no reconstructable effect —
    /// reporting "nothing changed" there would be a lie the user acts on.
    func testAWriteToolWithNoRecoverableEffectAdmitsTheGap() {
        let spoken = OrbRunNarration.changeSentence(effects: [], writeToolNames: ["write_file", "write_file"])
        XCTAssertFalse(spoken.lowercased().contains("didn't change"),
                       "A write tool ran — claiming nothing changed is worse than admitting ignorance: \(spoken)")
        XCTAssertTrue(spoken.contains("write file"), "Underscores are unintelligible aloud: \(spoken)")
        XCTAssertTrue(spoken.lowercased().contains("can't tell"))
    }

    func testEffectsWinOverTheToolNameFallback() {
        let effect = ActionEffect(path: "/tmp/Real.swift", linesAdded: 1, linesRemoved: 1, diff: nil, isTruncated: false)
        let spoken = OrbRunNarration.changeSentence(effects: [effect], writeToolNames: ["write_file"])
        XCTAssertTrue(spoken.contains("Real.swift"))
        XCTAssertFalse(spoken.lowercased().contains("can't tell"))
    }

    func testLineCountPhrasingHasNoZeroNoise() {
        let addOnly = OrbRunNarration.spokenEffect(
            ActionEffect(path: "/tmp/A.swift", linesAdded: 4, linesRemoved: 0, diff: nil, isTruncated: false))
        XCTAssertFalse(addOnly.contains("0"), "\"0 removed\" is noise in a spoken sentence: \(addOnly)")

        let removeOnly = OrbRunNarration.spokenEffect(
            ActionEffect(path: "/tmp/A.swift", linesAdded: 0, linesRemoved: 4, diff: nil, isTruncated: false))
        XCTAssertFalse(removeOnly.contains("0 added"), "\(removeOnly)")
    }

    // MARK: - Speech shaping

    func testLongErrorTextIsClippedAtAWordBoundary() {
        let long = String(repeating: "diagnostic ", count: 60)
        let clipped = OrbRunNarration.clipForSpeech(long)
        XCTAssertLessThan(clipped.count, long.count)
        XCTAssertTrue(clipped.hasSuffix("…"))
        XCTAssertFalse(clipped.contains("diagnosti…"), "Slicing mid-word sounds like a fault: \(clipped)")
    }

    func testNewlinesAreFlattenedSoASentenceDoesNotStutter() {
        let clipped = OrbRunNarration.clipForSpeech("first line\nsecond line")
        XCTAssertFalse(clipped.contains("\n"))
        XCTAssertTrue(clipped.contains("first line second line"))
    }

    func testShortTextIsLeftAlone() {
        XCTAssertEqual(OrbRunNarration.clipForSpeech("A timeout."), "A timeout.")
    }

    // MARK: - Command vocabulary

    func testTheNewRunQuestionsAreRecognised() {
        XCTAssertEqual(OrbSessionController.voiceCommand(in: "what went wrong"), .whatWentWrong)
        XCTAssertEqual(OrbSessionController.voiceCommand(in: "What did you change?"), .whatDidYouChange)
    }

    /// "read me the answer" reuses the existing repeat path rather than reading the report's
    /// 160-character preview back at the user.
    func testReadMeTheAnswerRepeatsTheRealAnswer() {
        XCTAssertEqual(OrbSessionController.voiceCommand(in: "read me the answer"), .repeatAnswer)
    }

    /// ⚠️ The standing rule for this vocabulary: a real request that merely CONTAINS a control
    /// word must reach the model, not be swallowed as a command.
    func testARequestContainingAControlPhraseStillReachesTheModel() {
        XCTAssertNil(OrbSessionController.voiceCommand(in: "explain what went wrong with the deployment last week"))
        XCTAssertNil(OrbSessionController.voiceCommand(in: "tell me what did you change in the spec"))
    }
}

/// [Audit Batch 6] What Orb says about a run must not assert more than the run did.
@MainActor
final class OrbRunNarrationAccuracyTests: XCTestCase {

    /// ⚠️ #53 — effects arrive one per file-mutating EXECUTION, not one per file. Three edits to
    /// one file used to be announced as "I changed 3 files. Config.swift … Config.swift …".
    func testRepeatedEditsToOneFileAreOneFile() {
        let effects = [
            ActionEffect(path: "/tmp/Config.swift", linesAdded: 4, linesRemoved: 0, diff: nil, isTruncated: false),
            ActionEffect(path: "/tmp/Config.swift", linesAdded: 2, linesRemoved: 1, diff: nil, isTruncated: false),
            ActionEffect(path: "/tmp/Config.swift", linesAdded: 1, linesRemoved: 0, diff: nil, isTruncated: false),
        ]
        let spoken = OrbRunNarration.changeSentence(effects: effects, writeToolNames: [])
        XCTAssertTrue(spoken.contains("one file"), "Three edits to one file is one file: \(spoken)")
        XCTAssertEqual(spoken.components(separatedBy: "Config.swift").count - 1, 1, "The file should be named once: \(spoken)")
        // Line counts are summed, not taken from the last edit.
        XCTAssertTrue(spoken.contains("7"), "Added lines should total 4+2+1: \(spoken)")
    }

    func testDistinctFilesAreStillCountedSeparately() {
        let effects = [
            ActionEffect(path: "/tmp/A.swift", linesAdded: 1, linesRemoved: 0, diff: nil, isTruncated: false),
            ActionEffect(path: "/tmp/B.swift", linesAdded: 1, linesRemoved: 0, diff: nil, isTruncated: false),
        ]
        let spoken = OrbRunNarration.changeSentence(effects: effects, writeToolNames: [])
        XCTAssertTrue(spoken.contains("2 files"), spoken)
    }

    func testMergePreservesTheOrderTheAgentWorkedIn() {
        let effects = [
            ActionEffect(path: "/tmp/B.swift", linesAdded: 1, linesRemoved: 0, diff: nil, isTruncated: false),
            ActionEffect(path: "/tmp/A.swift", linesAdded: 1, linesRemoved: 0, diff: nil, isTruncated: false),
            ActionEffect(path: "/tmp/B.swift", linesAdded: 1, linesRemoved: 0, diff: nil, isTruncated: false),
        ]
        XCTAssertEqual(OrbRunNarration.mergedByPath(effects).map(\.fileName), ["B.swift", "A.swift"])
    }

    /// ⚠️ #29 — a failed tool row's title is "name · <80 chars of raw JSON>". Speaking it verbatim
    /// read absolute paths and punctuation aloud, breaking this file's own rule about paths.
    func testAFailedToolIsNamedWithoutItsArguments() {
        let row = RunReportRow(
            id: "t1", kind: .tool, timestamp: Date(),
            title: #"write_file · {"file_path": "/Users/alice/Documents/secret/keys.txt", "content": "..."}"#,
            meta: "failed", duration: "12ms", isProblem: true, isNotable: true, isIndented: false,
            detail: .empty
        )
        let spoken = OrbRunNarration.spokenProblem(row)
        XCTAssertTrue(spoken.contains("write file"), "The tool is the meaningful half: \(spoken)")
        XCTAssertFalse(spoken.contains("/Users/"), "A path must never be read aloud here: \(spoken)")
        XCTAssertFalse(spoken.contains("{"), "Raw JSON must not be spoken: \(spoken)")
    }

    /// Non-tool problem rows keep their prose title — it is already written for a reader.
    func testANonToolProblemKeepsItsTitle() {
        let row = RunReportRow(
            id: "e1", kind: .issue, timestamp: Date(),
            title: "The model timed out", meta: "timeout", duration: "",
            isProblem: true, isNotable: true, isIndented: false, detail: .empty
        )
        XCTAssertTrue(OrbRunNarration.spokenProblem(row).contains("The model timed out"))
    }
}
