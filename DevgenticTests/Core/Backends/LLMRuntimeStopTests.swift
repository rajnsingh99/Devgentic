// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LLMRuntimeStopTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class LLMRuntimeStopTests: XCTestCase {

    // MARK: - A stopped generation is a cancellation, not an answer

    /// Mutation that must turn this red: make `throwIfCancelled` return without throwing.
    func testACancelledGenerationThrowsInsteadOfReturningItsPartialText() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try MLXLLMProvider.throwIfCancelled(discarding: "half an ans", path: "test")
        }
        do {
            try await task.value
            XCTFail("a cancelled generation returned normally — its partial text would be used as the answer")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }

    /// Mutation that must turn this red: drop the `Task.isCancelled` guard so it always throws.
    func testAGenerationThatFinishedNormallyIsReturned() async throws {
        try await Task {
            try MLXLLMProvider.throwIfCancelled(discarding: "a whole answer", path: "test")
        }.value
    }

    /// Both non-streaming MLX paths must check AFTER their loop. Mutation that must turn this red:
    /// delete either call.
    func testBothNonStreamingMLXPathsCheckForAStopAfterTheirLoop() throws {
        let source = try Self.source("Devgentic/Core/Backends/MLXLLMProvider.swift")
        XCTAssertEqual(source.components(separatedBy: "try Self.throwIfCancelled(discarding: fullText").count - 1, 2,
                       "generateWithUsage and generate(payload:) must both refuse to return partial text on a stop")

        guard let body = Self.body(of: "func generateWithUsage(", in: source, length: 1600),
              let loop = body.range(of: "for try await token in stream"),
              let check = body.range(of: "try Self.throwIfCancelled"),
              let ret = body.range(of: "return (fullText, sink.value)") else {
            return XCTFail("generateWithUsage no longer has the loop → check → return shape")
        }
        XCTAssertLessThan(loop.lowerBound, check.lowerBound)
        XCTAssertLessThan(check.lowerBound, ret.lowerBound, "the check must run BEFORE the partial text is returned")
    }

    /// Mutation that must turn this red: remove the IC's `if Task.isCancelled { … throw }`.
    func testTheIntelligenceCoreRefusesToReturnPartialTextOnAStop() throws {
        let source = try Self.source("Devgentic/Core/Service/IntelligenceCoreService.swift")
        guard let body = Self.body(of: "func generate(messages:", in: source, length: 4000),
              let perform = body.range(of: "container.perform"),
              let check = body.range(of: "if Task.isCancelled {"),
              let complete = body.range(of: "COMPLETE —") else {
            return XCTFail("IntelligenceCoreService.generate no longer checks for a stop after generating")
        }
        let afterCheck = body[check.upperBound...].prefix(400)
        XCTAssertTrue(afterCheck.contains("throw CancellationError()"))
        XCTAssertLessThan(perform.lowerBound, check.lowerBound)
        XCTAssertLessThan(check.lowerBound, complete.lowerBound, "the check must run before the result is reported as complete")
    }

    // MARK: - Image generation: Stop is cancelled, not failed

    /// Mutation that must turn this red: drop the `URLError.cancelled` arm.
    func testACloudStopIsRecognisedAsAStop() async {
        let verdict = await Task { ImageGenExecutor.isStop(URLError(.cancelled)) }.value
        XCTAssertTrue(verdict, "a cloud provider's Stop was recorded as a failure")
        let swiftStop = await Task { ImageGenExecutor.isStop(CancellationError()) }.value
        XCTAssertTrue(swiftStop)
    }

    /// A provider may wrap the cancellation in its own error; the task's flag still says Stop.
    /// Mutation that must turn this red: drop the `Task.isCancelled` arm.
    func testAWrappedStopIsStillAStopWhenTheTaskWasCancelled() async {
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return ImageGenExecutor.isStop(ImageGenError.providerError(underlying: "cancelled"))
        }
        let verdict = await task.value
        XCTAssertTrue(verdict, "a stop wrapped by the provider drew an error card")
    }

    /// The other direction: real failures stay failures.
    func testRealFailuresAreNotMistakenForAStop() async {
        let timedOut = await Task { ImageGenExecutor.isStop(URLError(.timedOut)) }.value
        let provider = await Task { ImageGenExecutor.isStop(ImageGenError.contentPolicyViolation(detail: "x")) }.value
        XCTAssertFalse(timedOut)
        XCTAssertFalse(provider)
    }

    /// Mutation that must turn this red: put `catch is CancellationError` back, or move the stop
    /// arm below the `ImageGenError` one.
    func testTheExecutorChecksForAStopBeforeAnyFailureArm() throws {
        let source = try Self.source("Devgentic/Core/Backends/ImageGen/ImageGenExecutor.swift")
        guard let stop = source.range(of: "} catch where Self.isStop(error) {"),
              let imageGenArm = source.range(of: "} catch let error as ImageGenError {") else {
            return XCTFail("the executor no longer classifies a Stop through isStop")
        }
        XCTAssertLessThan(stop.lowerBound, imageGenArm.lowerBound,
                          "a wrapped stop would hit the ImageGenError arm first and be recorded as failed")
    }

    // MARK: - Ollama pulls are bounded by silence, not by total length

    /// Mutation that must turn this red: put the resource timeout back to 1800.
    func testALongOllamaPullIsNotCutOffAtThirtyMinutes() {
        let config = OllamaConnect.pullSessionConfiguration()
        XCTAssertGreaterThanOrEqual(config.timeoutIntervalForResource, 24 * 60 * 60,
                                    "a pull that keeps progressing must be allowed to take hours")
        XCTAssertEqual(config.timeoutIntervalForRequest, 300,
                       "a pull that goes silent must still fail within five minutes")
    }

    /// Mutation that must turn this red: build the pull's session from an inline configuration.
    func testThePullUsesThatConfiguration() throws {
        let source = try Self.source("Devgentic/Core/Service/OllamaConnect.swift")
        guard let body = Self.body(of: "static func pullOllamaModel(", in: source, length: 1200) else {
            return XCTFail("pullOllamaModel is gone")
        }
        XCTAssertTrue(body.contains("URLSession(configuration: pullSessionConfiguration())"))
        XCTAssertFalse(body.contains("timeoutIntervalForResource"), "the pull set its own total cap again")
    }

    // MARK: - Helpers

    private static func body(of signature: String, in source: String, length: Int) -> String? {
        guard let start = source.range(of: signature) else { return nil }
        return String(source[start.lowerBound...].prefix(length))
    }

    private static func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Backends
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(relativePath) not reachable from \(repoRoot.path) — running outside a checkout")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
