// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TimelinePayloadBoundsTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class TimelinePayloadBoundsTests: XCTestCase {

    // MARK: - 1. Snapshots are session-scoped (not persisted)

    private func writeRow(pre: String?, post: String?) -> ToolExecutionData {
        var data = ToolExecutionData(id: UUID(), name: "write_file", params: "{}", output: "ok",
                                     isSuccess: true, isExecuting: false)
        data.preWriteContent = pre
        data.postWriteContent = post
        return data
    }

    func testSnapshotsAreOmittedFromEncoding() throws {
        let data = writeRow(pre: String(repeating: "A", count: 100_000),
                            post: String(repeating: "B", count: 100_000))

        let encoded = try JSONEncoder().encode(data)
        let json = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(json.contains("preWriteContent"), "Snapshots must not reach the timeline blob")
        XCTAssertFalse(json.contains("postWriteContent"))
        XCTAssertLessThan(encoded.count, 2_000,
                          "A write event must stay metadata-sized, not carry 200KB of file content")
    }

    /// Everything else must still survive the custom encoder — an explicit encode() is easy
    /// to under-fill, and a dropped field would silently break resume/compaction.
    func testAllOtherFieldsStillRoundTrip() throws {
        var data = ToolExecutionData(id: UUID(), name: "write_file", params: #"{"path":"/tmp/a"}"#,
                                     output: "done", isSuccess: false, isExecuting: false)
        data.failureCategory = .userDenied
        data.durationMs = 1234
        data.stepId = 7

        let decoded = try JSONDecoder().decode(ToolExecutionData.self, from: JSONEncoder().encode(data))

        XCTAssertEqual(decoded.id, data.id)
        XCTAssertEqual(decoded.name, "write_file")
        XCTAssertEqual(decoded.params, #"{"path":"/tmp/a"}"#)
        XCTAssertEqual(decoded.output, "done")
        XCTAssertEqual(decoded.isSuccess, false)
        XCTAssertEqual(decoded.failureCategory, .userDenied)
        XCTAssertEqual(decoded.durationMs, 1234)
        XCTAssertEqual(decoded.isExecuting, false)
        XCTAssertEqual(decoded.stepId, 7)
    }

    /// Rows written by an EARLIER build still carry the fields — decode must keep reading them.
    func testLegacyRowsWithSnapshotsStillDecode() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"write_file","params":"{}","isExecuting":false,
         "preWriteContent":"old content","postWriteContent":"new content"}
        """
        let decoded = try JSONDecoder().decode(ToolExecutionData.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.preWriteContent, "old content",
                       "Backward compatibility: previously-persisted snapshots must still load")
        XCTAssertEqual(decoded.postWriteContent, "new content")
    }

    /// In-memory capture is unaffected — the viewer's diff works during the session.
    func testSnapshotsSurviveInMemory() {
        let data = writeRow(pre: "before", post: "after")
        XCTAssertEqual(data.preWriteContent, "before")
        XCTAssertEqual(data.postWriteContent, "after")
    }

    // MARK: - 2. Output cap is explicit

    func testShortOutputIsUntouched() {
        let text = "Build succeeded in 2.1s"
        XCTAssertEqual(ToolExecutionData.cappedOutput(text), text)
    }

    func testOutputAtExactLimitIsUntouched() {
        let text = String(repeating: "x", count: ToolExecutionData.maxPersistedOutputLength)
        XCTAssertEqual(ToolExecutionData.cappedOutput(text), text, "Boundary must not truncate")
    }

    func testOversizedOutputIsTruncatedWithAMarker() {
        let overflow = 50_000
        let text = String(repeating: "x", count: ToolExecutionData.maxPersistedOutputLength + overflow)

        let capped = ToolExecutionData.cappedOutput(text)

        XCTAssertLessThan(capped.count, text.count)
        XCTAssertTrue(capped.contains("truncated \(overflow) characters"),
                      "Truncation must be EXPLICIT — a resumed run's LLM history is rebuilt from this field")
        XCTAssertTrue(capped.hasPrefix(String(repeating: "x", count: 100)), "The head of the output is preserved")
    }

    /// A 20MB build log — the case the cap exists for.
    func testPathologicalOutputCollapsesToBounded() {
        let hugeLog = String(repeating: "compiling module...\n", count: 200_000)
        let capped = ToolExecutionData.cappedOutput(hugeLog)

        XCTAssertLessThan(capped.count, ToolExecutionData.maxPersistedOutputLength + 200,
                          "A pathological log must not be able to balloon the conversation blob")
    }
}
