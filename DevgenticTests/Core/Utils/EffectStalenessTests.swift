// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EffectStalenessTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class EffectStalenessTests: XCTestCase {

    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("effect-staleness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("January2026.java")
        try "original contents\n".write(to: file, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        file = nil
        try super.tearDownWithError()
    }

    private func effect(fingerprinted: Bool) -> ActionEffect {
        ActionEffect(
            path: file.path, linesAdded: 1, linesRemoved: 5,
            diff: "-import java.util.Map;\n+// cleaned", isTruncated: false,
            fingerprint: fingerprinted ? .of(try! String(contentsOf: file, encoding: .utf8)) : nil
        )
    }

    // MARK: - The fingerprint itself

    func testAnUntouchedFileIsNotStale() throws {
        let fingerprint = EffectFingerprint.of(try String(contentsOf: file, encoding: .utf8))
        XCTAssertFalse(fingerprint.differsFromDisk(at: file.path))
    }

    func testAChangedFileIsStale() throws {
        let fingerprint = EffectFingerprint.of(try String(contentsOf: file, encoding: .utf8))
        try "original contents plus more\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(fingerprint.differsFromDisk(at: file.path))
    }

    func testASameLengthEditIsStillDetected() throws {
        // ⚠️ The case size alone would miss, and the reason the hash exists. `differsFromDisk`
        // short-circuits on size for speed; a character swap keeps the length, so without the
        // content check this would read as unchanged.
        try "abcdef\n".write(to: file, atomically: true, encoding: .utf8)
        let fingerprint = EffectFingerprint.of(try String(contentsOf: file, encoding: .utf8))
        try "abcXef\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(fingerprint.differsFromDisk(at: file.path))
    }

    func testCaptureDoesNoFileIO() throws {
        // ⚠️⚠️ THE PERFORMANCE GUARD. Capture runs on the main actor for every file write, and a
        // `stat` here measurably slowed the live-write path. Fingerprinting a string that is
        // already in memory must not depend on the file existing at all.
        try FileManager.default.removeItem(at: file)
        let fingerprint = EffectFingerprint.of("content held in memory\n")
        XCTAssertEqual(fingerprint.byteCount, 23)
    }

    func testADeletedFileIsStaleRatherThanUnknown() throws {
        // ⚠️ "I could not check" must never render as "unchanged". A deleted file is exactly where
        // a stored diff misleads most, so the unreadable case resolves to CHANGED.
        let fingerprint = EffectFingerprint.of(try String(contentsOf: file, encoding: .utf8))
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(fingerprint.differsFromDisk(at: file.path))
    }

    // MARK: - What the model is told

    /// Builds the episodic XML the way a real request does: an effect captured at TOOL
    /// COMPLETION (fingerprint taken then), persisted on the timeline, and rendered later.
    ///
    /// ⚠️⚠️ Drives `EpisodicHistoryFormatter.build`, NOT `renderEffect` with a hand-computed
    /// availability. An earlier draft of this file did the latter — `renderEffect(effect,
    /// diff: isStale ? .stale : .onDemand)` — which re-implemented the very decision under test
    /// and would have stayed green through a revert of the wiring. `ActiveStreamManager` sets
    /// `data.effect` once at completion and the formatter only READS it, so this mirrors
    /// production: capture while the file is fresh, mutate it, then render.
    private func episodicXML(strategy: HistoryStrategy = .pointer,
                             mutateFileBeforeRendering mutate: Bool) throws -> String {
        var data = ToolExecutionData(
            id: UUID(), name: "edit_code_batch",
            params: #"{"file_path":"\#(file.path)"}"#,
            output: "ok", isSuccess: true, isExecuting: false
        )
        let params = try JSONSerialization.data(withJSONObject: ["file_path": file.path, "content": "after\n"])
        data.params = try XCTUnwrap(String(data: params, encoding: .utf8))
        data.preWriteContent = "original contents\n"
        // ⚠️ `edit_code_*` params carry find/replace strings, NOT the post-state, so the executor
        // does a read-back after success and stores it here. (`write_file` differs — its params
        // hold the exact bytes.) Without this the effect derivation returns nil and the fixture
        // silently tests nothing.
        data.postWriteContent = "after\n"
        try "after\n".write(to: file, atomically: true, encoding: .utf8)
        // Captured HERE, against the post-write file — exactly where production captures it.
        data.effect = ActionEffect.from(toolExecution: data)
        XCTAssertNotNil(data.effect?.fingerprint, "the fixture never captured a fingerprint")

        if mutate {
            // Someone else moves the file: a git checkout, the user's editor, another agent.
            try "restored by the user\n".write(to: file, atomically: true, encoding: .utf8)
        }

        let conversationID = UUID()
        let user = ChatMessage(id: UUID(), conversationId: conversationID, timestamp: Date(),
                               sender: .user, content: .plainText("remove the unused imports"))
        let agent = ChatMessage(id: UUID(), conversationId: conversationID,
                                timestamp: Date().addingTimeInterval(1),
                                sender: .agent, content: .plainText("done"))
        agent.timelineEvents = [.toolExecution(data)]

        return EpisodicHistoryFormatter.build(
            strategy: strategy, from: [user, agent], toolsAvailable: true, staleness: .live)
    }

    func testAnUnchangedFileStillPromisesTheRetrieval() throws {
        let xml = try episodicXML(mutateFileBeforeRendering: false)
        XCTAssertTrue(xml.contains(#"diff="on_demand""#), "the common case must be unchanged:\n\(xml)")
        XCTAssertFalse(xml.contains(#"diff="stale""#))
    }

    func testAChangedFileWithdrawsThePromise() throws {
        // ⚠️ THE REGRESSION GUARD, in the exact shape of the incident: the file is restored
        // underneath a conversation that has already recorded the edit.
        let xml = try episodicXML(mutateFileBeforeRendering: true)
        XCTAssertTrue(xml.contains(#"diff="stale""#), "the retrieval promise was not withdrawn:\n\(xml)")
        XCTAssertFalse(xml.contains("on_demand"),
                       "the record still tells the model get_conversation_history returns this change")
    }

    func testTheCountsAndPathSurviveStaleness() throws {
        // "What did you change?" must stay answerable — only "the stored body still matches the
        // file" is withdrawn. Dropping the element would read as "nothing happened", the amnesia
        // `<effect>` exists to fix.
        let xml = try episodicXML(mutateFileBeforeRendering: true)
        XCTAssertTrue(xml.contains("<effect"))
        XCTAssertTrue(xml.contains("January2026.java"))
    }

    func testTheInlineStrategiesWithdrawItToo() throws {
        // `.recentHistory` renders effect BODIES inline rather than promising a fetch. A stale
        // body is worse than a stale promise — it hands the model a revert instrument for a state
        // the file no longer has.
        let xml = try episodicXML(strategy: .recentHistory, mutateFileBeforeRendering: true)
        XCTAssertTrue(xml.contains(#"diff="stale""#), "the inline path kept its stale body:\n\(xml)")
    }

    // MARK: - The third state

    func testAnEffectWithoutAFingerprintIsNeverCalledStale() throws {
        // ⚠️ Every effect already in the store predates this field. Nil is UNKNOWN, and unknown
        // must render exactly as it did before — not stale (noise on every old turn) and not
        // verified-fresh (a claim nothing supports).
        let legacy = effect(fingerprinted: false)
        try "changed\n".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertFalse(EpisodicHistoryFormatter.EffectStalenessCheck.live.isStale(legacy),
                       "an effect with no fingerprint must never be called stale")
    }

    func testALegacyEffectBlobStillDecodes() throws {
        // The Codable migration, asserted rather than assumed: a non-optional property here would
        // throw `keyNotFound` on every conversation in the store.
        let legacy = Data(#"{"path":"/a/b.swift","linesAdded":1,"linesRemoved":5,"isTruncated":false}"#.utf8)
        let decoded = try JSONDecoder().decode(ActionEffect.self, from: legacy)

        XCTAssertEqual(decoded.path, "/a/b.swift")
        XCTAssertNil(decoded.fingerprint)
    }

    // MARK: - The check must not put the filesystem on the sizing path

    func testTheUnknownCheckTouchesNoFiles() throws {
        // ⚠️ `ContextWindowGauge` builds this same XML to SIZE the prompt, on every recompute.
        // `.unknown` is what keeps the composer off the disk; if it ever started stat'ing, the
        // symptom would be a laggy composer that nothing connects to episodic memory.
        let recorded = effect(fingerprinted: true)
        try FileManager.default.removeItem(at: file)

        XCTAssertFalse(EpisodicHistoryFormatter.EffectStalenessCheck.unknown.isStale(recorded),
                       ".unknown must answer without consulting the filesystem")
        XCTAssertTrue(EpisodicHistoryFormatter.EffectStalenessCheck.live.isStale(recorded),
                      "and .live must still answer truthfully, so the two are genuinely different")
    }

    // MARK: - Every strategy forwards it

    /// ⚠️⚠️ THE DRIFT GUARD. `toolsAvailable` was added to this exact seam and TWO of the four
    /// strategy branches silently failed to forward it — the builders defaulted it to `true`, so a
    /// tool-less profile got the agent rendering with nothing reporting a problem. That bug is
    /// recorded in `EpisodicHistoryFormatter.build`'s own comment: "EVERY branch forwards
    /// `toolsAvailable`. Two of them did not…".
    ///
    /// ⚠️ The invariant is NOT "wherever `toolsAvailable` goes, `staleness` goes". That was the
    /// first draft and it is false: `envelope(…)` and `logEpisodicBudget(…)` take tool availability
    /// (for the `<tool_availability>` preface and the log) and render no `<effect>` at all, so
    /// they have no business knowing about files. The real invariant is narrower — every call that
    /// can PRODUCE an effect element must forward the check.
    ///
    /// A behavioural test would have to build four realistic histories and would then be
    /// exercising the timeline→effect derivation rather than the forwarding, which is the thing
    /// that actually broke.
    func testEveryEffectRenderingCallForwardsTheStalenessCheck() throws {
        let source = try Self.formatterSource()
        // The functions that can emit an `<effect>`, directly or by delegation.
        let renderers = ["renderInlineTurn", "renderPointerTurn",
                         "buildRecentHistoryString", "buildPointerHistoryString", "buildHybridHistoryString"]

        var offenders: [String] = []
        var callsChecked = 0
        for renderer in renderers {
            for call in Self.callSites(of: renderer, in: source) {
                callsChecked += 1
                if !call.contains("staleness:") {
                    offenders.append("\(renderer): \(call.prefix(120))")
                }
            }
        }

        XCTAssertGreaterThan(callsChecked, 5, "the scan found almost no call sites — it is reading the wrong file")
        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) effect-rendering call(s) do not forward `staleness`:

              \(offenders.joined(separator: "\n  "))

            Such a call takes the `.unknown` default, so a file that has changed keeps promising \
            its diff — the exact shape of the `toolsAvailable` regression this test exists to prevent.
            """)
    }

    /// ⚠️⚠️ THE WIRING GUARD, and it exists because MUTATION FOUND THE HOLE. Changing
    /// `AgentConnect`'s call from `staleness: .live` to `.unknown` left all twelve tests in this
    /// file green while the feature was dead in production — the formatter would be perfect and
    /// nothing would ever ask it a real question. That is the shape of the F2 regression, which
    /// shipped non-functional behind 163 passing tests.
    ///
    /// A source scan is the honest instrument here: the call sits inside `streamAgentResponse`,
    /// which cannot be driven from a unit test. Same approach as `ToolRegistryDriftTests`.
    func testTheRequestPathOptsIntoTheLiveCheck() throws {
        let source = try Self.agentConnectSource()
        let live = source.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .filter { $0.contains("staleness: .live") }

        XCTAssertFalse(live.isEmpty, """
            AgentConnect never passes `staleness: .live` to EpisodicHistoryFormatter.build.

            The default is `.unknown`, which never reports a stale file — so every `<effect>` keeps \
            promising a retrievable diff no matter what happened to the file, and the whole check \
            is dead code that no other test can see.
            """)
    }

    private static func agentConnectSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Devgentic/Core/Backends/TextGen/AgentConnect.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("AgentConnect.swift not reachable — running outside a checkout")
        }
        XCTAssertTrue(text.contains("EpisodicHistoryFormatter.build"), "read the wrong file")
        return text
    }

    func testEveryStrategyBranchIsCovered() throws {
        // Non-vacuity for the scan above: the switch must still have all four arms, or "every
        // branch forwards it" is a claim about fewer branches than exist.
        let source = try Self.formatterSource()
        for arm in ["case .recentHistory:", "case .fullHistory:", "case .pointer:", "case .hybrid:"] {
            XCTAssertTrue(source.contains(arm), "\(arm) is missing from the strategy switch")
        }
    }

    /// Every CALL to `name` — its full argument list, across line breaks. Declarations are skipped
    /// (a `func name(` line is not a call site), as are comments.
    private static func callSites(of name: String, in source: String) -> [String] {
        var results: [String] = []
        var search = source.startIndex
        while let hit = source.range(of: name + "(", range: search..<source.endIndex) {
            search = hit.upperBound
            let lineStart = source[..<hit.lowerBound].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
            let line = source[lineStart..<hit.lowerBound].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("///") || line.contains("func ") { continue }

            var depth = 1
            var idx = hit.upperBound
            while idx < source.endIndex, depth > 0 {
                if source[idx] == "(" { depth += 1 }
                if source[idx] == ")" { depth -= 1 }
                idx = source.index(after: idx)
            }
            results.append(String(source[hit.upperBound..<idx]))
        }
        return results
    }

    private static func formatterSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Utils
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent("Devgentic/Core/Utils/EpisodicHistoryFormatter.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("EpisodicHistoryFormatter.swift not reachable — running outside a checkout")
        }
        XCTAssertTrue(text.contains("enum EffectDiff"), "read the wrong file")
        return text
    }
}
