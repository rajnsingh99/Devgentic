// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatOpsLoggingHygieneTests.swift
//  devgenticTests
//
//  OBS-1. ChatOps wrote 119 CONSEQUENCE-bearing log lines through Apple's `os.Logger`, which does
//  two things the subsystem's own logging standard forbids: os_log redacts every interpolated
//  dynamic value as `<private>` in a release build (so the chat id, the close code and the command
//  name — the entire diagnostic payload — are unreadable in the field), and a raw `os.Logger` never
//  enters `LogRecorder`'s ring, so not one of those lines reaches an exported diagnostic bundle.
//
//  ⚠️ THE MIGRATION IS ONLY HALF THE FIX, AND THE OTHER HALF IS THE LOG LEVEL. `DGLogger` routes
//  `.warning` and above into the ring and drops everything below it (`shouldPersist`, floor set
//  deliberately in 2026-08-23 after measurement: info/notice was 95.1% of 1,060,962 rows and nothing
//  read it). So converting a dead-end drop from `Logger.info` to `DGLogger.info` makes it readable
//  on the developer's own Mac and changes NOTHING about the bug report — which is the only place a
//  remote-control failure can be observed, because the machine that reproduces it is the user's.
//

import XCTest
@testable import devgentic

final class ChatOpsLoggingHygieneTests: XCTestCase {

    // MARK: - The migration itself

    /// ⚠️ THE DRIFT GUARD. Converting 24 declarations is worthless if the 25th file retypes
    /// `Logger(subsystem:)` — which is how the original 119 lines accumulated in the first place.
    /// Scans the real ChatOps tree from this file's own compile-time path.
    ///
    /// ⚠️ COMMENT-BLIND, deliberately. A structural scan that counts commented-out code has given a
    /// false verdict three times in this subsystem's history; `//` is stripped before matching, so a
    /// prose mention of `Logger(subsystem:)` in a doc comment cannot fail the test and, more
    /// importantly, cannot PASS it either.
    func testNoChatOpsFileDeclaresARawOSLogger() throws {
        let offenders = try Self.chatOpsSources().compactMap { file -> String? in
            let stripped = Self.strippingComments(file.text)
            guard stripped.contains("Logger(subsystem:") else { return nil }
            return file.name
        }
        XCTAssertTrue(offenders.isEmpty,
                      "every ChatOps logger must be a DGLogger so its lines reach a diagnostic "
                      + "bundle and are not redacted to <private> — offenders: \(offenders)")
    }

    /// ⚠️ THE NON-VACUITY GUARD, without which the test above passes by finding no files at all —
    /// a relocated directory, a renamed folder or a broken `#filePath` walk all read as "clean".
    func testTheSweepActuallyReachesTheChatOpsTree() throws {
        let sources = try Self.chatOpsSources()
        XCTAssertGreaterThan(sources.count, 30, "the ChatOps sweep found almost nothing — it is not looking at the source tree")

        let declaring = sources.filter { Self.strippingComments($0.text).contains("DGLogger(category:") }
        XCTAssertGreaterThan(declaring.count, 20,
                             "only \(declaring.count) ChatOps files declare a DGLogger; the sweep is looking at the wrong tree")
    }

    // MARK: - The level, which decides whether the line is exportable

    /// The persist floor, asserted against the real policy function rather than restated. This is
    /// the fact that makes `strandsTheUser` load-bearing: below `.warning` a line is Console-only.
    func testOnlyWarningAndAboveSurviveIntoADiagnosticBundle() {
        XCTAssertFalse(DGLogger.shouldPersist(level: .debug, diagnosticsEnabled: true))
        XCTAssertFalse(DGLogger.shouldPersist(level: .info, diagnosticsEnabled: true))
        XCTAssertFalse(DGLogger.shouldPersist(level: .notice, diagnosticsEnabled: true))
        XCTAssertTrue(DGLogger.shouldPersist(level: .warning, diagnosticsEnabled: true))
        XCTAssertTrue(DGLogger.shouldPersist(level: .error, diagnosticsEnabled: true))

        // The consent switch still vetoes everything — a warning is not exempt from the opt-out.
        XCTAssertFalse(DGLogger.shouldPersist(level: .error, diagnosticsEnabled: false))
    }

    /// ⚠️ ONE OF THE THREE SILENCES IS A FAILURE AND TWO ARE NOT, and the levels must follow that
    /// split rather than the fact that all three are silent. Each case's own `consequence` string is
    /// the evidence: two of them say the silence is correct because another component replied.
    func testOnlyTheUnrecognizedSilenceStrandsTheUser() {
        XCTAssertTrue(RemoteSilence.unrecognized("/frobnicate").strandsTheUser,
                      "input that matched no command leaves the remote user with no reply at all")
        XCTAssertFalse(RemoteSilence.handledElsewhere("ChatOpsPairingService").strandsTheUser,
                       "another component answered — a reply here would duplicate it")
        XCTAssertFalse(RemoteSilence.resolvedInteraction(operationID: UUID()).strandsTheUser,
                       "the mirror edits the original prompt in place — posting would double-report")
    }

    /// Every case is classified: a new `RemoteSilence` cannot be added and silently inherit a level.
    func testEverySilenceCaseIsClassified() {
        let all: [RemoteSilence] = [
            .handledElsewhere("x"),
            .resolvedInteraction(operationID: UUID()),
            .unrecognized("x")
        ]
        XCTAssertEqual(all.filter(\.strandsTheUser).count, 1,
                       "exactly one silence is a dead end; if this changed, the level mapping needs revisiting")
        for silence in all {
            XCTAssertTrue(silence.consequence.count > 20, "every silence must state its consequence")
            XCTAssertEqual(silence.tag, "[CHATOPS/SILENT]")
        }
    }

    // MARK: - Wiring

    /// ⚠️ THE WIRING TEST. `strandsTheUser` being correct proves nothing if the shared logger still
    /// writes one fixed level — the property would be dead code and the dead-end drop would stay
    /// unexportable. Reads the real `RemoteRenderLog.silence` body and requires that the level is
    /// CHOSEN by it. (Read from source, not observed through `LogRecorder`, because asserting on the
    /// ring would mean writing the app's real diagnostics preference from a test.)
    func testTheSharedSilenceLoggerPicksItsLevelFromStrandsTheUser() throws {
        let body = try Self.functionBody(named: "silence", in: "RemoteRendering.swift")
        XCTAssertTrue(body.contains("strandsTheUser"),
                      "RemoteRenderLog.silence must branch on strandsTheUser, else the classification is dead code")
        XCTAssertTrue(body.contains("logger.warning"),
                      "the dead-end branch must log at .warning — .info never reaches a diagnostic bundle")
        XCTAssertTrue(body.contains("logger.info"),
                      "the two correct-by-design silences must stay at .info and not flood every bundle")
    }

    /// ⚠️ THE FOUR HAND-WRITTEN DEAD ENDS, which do not go through `RemoteRenderLog`. Each sits at
    /// the end of a bridge's `routeCommand` and says in its own words that the user got no reply;
    /// each was `.info`, so it existed only in live Console. A `[CHATOPS/SILENT]` line that reports
    /// no reply must be at a level a bug report can carry.
    func testHandWrittenDeadEndDropsAreLoggedAtAPersistedLevel() throws {
        var offenders: [String] = []
        for file in try Self.chatOpsSources() {
            for (i, line) in Self.strippingComments(file.text).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains("[CHATOPS/SILENT]") else { continue }
                guard line.lowercased().contains("no reply") else { continue }   // its own consequence
                guard line.contains("logger.info(") || line.contains("logger.debug(")
                        || line.contains("logger.notice(") else { continue }
                offenders.append("\(file.name):\(i + 1)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "a silent drop that leaves the remote user with no reply must log at .warning "
                      + "or above, or it never reaches the bug report that is the only place it can "
                      + "be seen — offenders: \(offenders)")
    }

    // MARK: - Source access

    private struct Source { let name: String; let text: String }

    /// Locates `Devgentic/ChatOps` by walking up from this file, matching the helper the rest of the
    /// ChatOps suite uses.
    private static func chatOpsSources() throws -> [Source] {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("Devgentic/ChatOps")
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            var sources: [Source] = []
            let files = FileManager.default.enumerator(at: candidate, includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                sources.append(Source(name: url.lastPathComponent, text: text))
            }
            return sources
        }
        throw XCTSkip("Could not locate Devgentic/ChatOps from \(#filePath) — repository layout changed.")
    }

    /// Everything between `func <name>(` and the matching close brace, comments removed.
    private static func functionBody(named name: String, in fileName: String) throws -> String {
        guard let file = try chatOpsSources().first(where: { $0.name == fileName }) else {
            throw XCTSkip("\(fileName) not found in the ChatOps tree")
        }
        let stripped = strippingComments(file.text)
        guard let start = stripped.range(of: "func \(name)(") else {
            XCTFail("\(fileName) no longer declares func \(name)( — the wiring test is blind")
            return ""
        }
        guard let open = stripped[start.upperBound...].firstIndex(of: "{") else { return "" }

        var depth = 0
        var index = open
        while index < stripped.endIndex {
            if stripped[index] == "{" { depth += 1 }
            if stripped[index] == "}" {
                depth -= 1
                if depth == 0 { return String(stripped[open...index]) }
            }
            index = stripped.index(after: index)
        }
        return String(stripped[open...])
    }

    /// ⚠️ Strips `//` to the end of line. A structural scan that counts commented-out code has
    /// produced a false verdict three times in this subsystem; every scan here goes through this.
    private static func strippingComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }
}
