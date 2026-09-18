// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteChunkedSendTests.swift
//  devgenticTests
//
//  Delivering a reply that does not fit one message.
//
//  ⚠️⚠️ THE THREE DEFECTS THIS PINS, ALL IN ONE LINE. Every API client spelled a chunked send as
//  `for chunk in chunks { try await send(chunk) }`, which meant:
//    (1) `Retry-After` was PARSED by all three clients and honoured by none — the only readers of
//        `rateLimited(retryAfter:)` anywhere in the tree were `errorDescription` switches;
//    (2) a throw on chunk k abandoned k+1…n, so the answer stopped mid-sentence with no signal;
//    (3) the caller's retry restarted from chunk ONE, because nothing recorded how far it got, so
//        the mirror re-posted every chunk that had already arrived.
//
//  ⚠️ AND THE CHUNKER MEASURED IN THE WRONG UNIT. `text.count` counts Characters; the platforms
//  count UTF-16. One family emoji is 1 Character and 11 UTF-16 units, so an emoji-dense reply built
//  "within budget" chunks an order of magnitude over the real limit — and the platform rejects the
//  whole message rather than truncating, so the answer did not arrive at all.
//

import XCTest
@testable import devgentic

final class RemoteChunkedSendTests: XCTestCase {

    // MARK: - Chunking: the unit

    /// ⚠️ THE REGRESSION. A family emoji is one Character and eleven UTF-16 units.
    func testChunksAreMeasuredInUTF16NotCharacters() {
        let emoji = "👨‍👩‍👧‍👦"
        XCTAssertEqual(emoji.count, 1, "precondition: one Character")
        XCTAssertGreaterThan(emoji.utf16.count, 8, "precondition: many UTF-16 units")

        let text = String(repeating: emoji, count: 50)
        let chunks = RemoteTextBudget.chunk(text, limit: 100)

        for chunk in chunks {
            // ⚠️ `chunk.utf16.count` DIRECTLY, never `RemoteTextBudget.measure`. Asserting through
            //   the same function under test is self-consistent: change `measure` to count
            //   Characters and both the code and the assertion move together, so the test passes
            //   over the exact bug it exists to catch. (Confirmed by mutation — it did.)
            XCTAssertLessThanOrEqual(chunk.utf16.count, 100, """
                A chunk is over the platform's real budget. Counting Characters instead of UTF-16 is \
                what made an emoji-dense reply exceed the limit by an order of magnitude — and the \
                platform rejects the whole message rather than truncating it, so nothing arrives.
                """)
        }
        XCTAssertEqual(chunks.joined(), text, "chunking must be lossless")
    }

    /// ⚠️ Cutting on a UTF-16 index rather than a Character index splits a grapheme and produces a
    /// replacement character — corruption that looks like the model emitted it.
    func testChunkingNeverSplitsAGrapheme() {
        let text = String(repeating: "é👍🏽", count: 200)
        let chunks = RemoteTextBudget.chunk(text, limit: 40)

        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks {
            XCTAssertFalse(chunk.unicodeScalars.contains("\u{FFFD}"), "a grapheme was split: \(chunk)")
        }
    }

    /// ⚠️ PROGRESS GUARANTEE. A single grapheme costing more than the whole budget leaves room for
    /// no Characters at all, and the obvious loop then appends an empty chunk forever.
    func testASingleGraphemeLargerThanTheBudgetDoesNotHang() {
        let huge = "👨‍👩‍👧‍👦"
        let chunks = RemoteTextBudget.chunk(huge + "abc", limit: 2)

        XCTAssertEqual(chunks.joined(), huge + "abc", "content must survive even when it cannot fit")
        XCTAssertFalse(chunks.contains(""), "an empty chunk means the loop failed to advance")
        XCTAssertLessThan(chunks.count, 20, "suspiciously many chunks — the loop is barely advancing")
    }

    func testShortTextIsNotChunked() {
        XCTAssertEqual(RemoteTextBudget.chunk("hello", limit: 100), ["hello"])
    }

    func testChunkingPrefersParagraphThenLineBoundaries() {
        let text = "para one\n\npara two\n\npara three"
        let chunks = RemoteTextBudget.chunk(text, limit: 20)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks[0].hasSuffix("\n\n"), "should cut on the paragraph break: \(chunks[0])")
    }

    // MARK: - Sending: pacing and resume

    func testEveryChunkIsSentInOrder() async throws {
        let recorder = SendRecorder()
        try await RemoteChunkedSend.send(["a", "b", "c"], sleep: { _ in }) { await recorder.record($0) }
        let sent = await recorder.sent
        XCTAssertEqual(sent, ["a", "b", "c"])
    }

    /// ⚠️ THE HEADER THE PLATFORM SENDS IS AN INSTRUCTION, NOT A DIAGNOSTIC. All three clients
    /// parsed it and then discarded it.
    func testARateLimitIsWaitedOutAndTheChunkRetried() async throws {
        let recorder = SendRecorder()
        await recorder.failNext(1, with: SlackAPIError.rateLimited(retryAfter: 2))
        let waits = WaitRecorder()

        try await RemoteChunkedSend.send(["a", "b"], sleep: { await waits.record($0) }) {
            try await recorder.recordThrowing($0)
        }

        let sent = await recorder.sent
        XCTAssertEqual(sent, ["a", "a", "b"], "the throttled chunk must be retried, not skipped")
        let observed = await waits.waits
        XCTAssertEqual(observed, [2], "the platform's own retry_after must be honoured")
    }

    /// ⚠️ A header-supplied hour inside a send is indistinguishable from a hang.
    func testAnAbsurdRetryAfterIsClamped() async throws {
        let recorder = SendRecorder()
        await recorder.failNext(1, with: SlackAPIError.rateLimited(retryAfter: 86_400))
        let waits = WaitRecorder()

        try await RemoteChunkedSend.send(["a"], sleep: { await waits.record($0) }) {
            try await recorder.recordThrowing($0)
        }

        let observed = await waits.waits
        XCTAssertEqual(observed, [RemoteChunkedSend.maxRetryAfter])
    }

    /// ⚠️ THE RESUME POINT — the fix for the duplicate-post half. A boolean "it failed" cannot
    /// express the difference between "nothing arrived" and "the first four paragraphs arrived".
    func testAPartialFailureReportsHowFarItGot() async {
        let recorder = SendRecorder()
        // Calls 1 and 2 land ("a", "b"); the third throws.
        await recorder.failFrom(3, with: SlackAPIError.apiError(method: "chat.postMessage", error: "boom"))

        do {
            try await RemoteChunkedSend.send(["a", "b", "c"], sleep: { _ in }) {
                try await recorder.recordThrowing($0)
            }
            XCTFail("expected a PartialDelivery")
        } catch let partial as RemoteChunkedSend.PartialDelivery {
            XCTAssertEqual(partial.delivered, 2, "two chunks landed before the failure")
            XCTAssertEqual(partial.total, 3)
        } catch {
            XCTFail("expected PartialDelivery, got \(error)")
        }
    }

    /// When the FIRST chunk fails nothing arrived, so there is no partial state to describe and the
    /// underlying error is the honest one to raise.
    func testAFailureOnTheFirstChunkThrowsTheUnderlyingError() async {
        let recorder = SendRecorder()
        await recorder.failFrom(1, with: SlackAPIError.invalidToken)
        do {
            try await RemoteChunkedSend.send(["a", "b"], sleep: { _ in }) {
                try await recorder.recordThrowing($0)
            }
            XCTFail("expected a throw")
        } catch is RemoteChunkedSend.PartialDelivery {
            XCTFail("nothing was delivered — this must not report a partial delivery")
        } catch {
            // correct
        }
    }

    /// ⚠️ THE DUPLICATE-POST FIX, END TO END. A caller resuming from `delivered` must not re-post
    /// what already arrived — which is exactly what the mirror's retry used to do.
    func testResumingSkipsAlreadyDeliveredChunks() async throws {
        let recorder = SendRecorder()
        try await RemoteChunkedSend.send(["a", "b", "c"], startingAt: 2, sleep: { _ in }) {
            await recorder.record($0)
        }
        let sent = await recorder.sent
        XCTAssertEqual(sent, ["c"], "chunks 1 and 2 had already arrived and must not be posted twice")
    }

    /// ⚠️ Only a rate limit is retried. A 400 has been refused on its merits and cannot start
    /// working; retrying it just posts the same rejected message again.
    func testANonRateLimitErrorIsNotRetried() async {
        let recorder = SendRecorder()
        await recorder.failFrom(1, with: SlackAPIError.apiError(method: "chat.postMessage", error: "invalid_blocks"))
        _ = try? await RemoteChunkedSend.send(["a"], sleep: { _ in }) {
            try await recorder.recordThrowing($0)
        }
        let sent = await recorder.sent
        XCTAssertEqual(sent.count, 1, "a non-rate-limit failure must be attempted exactly once")
    }

    // MARK: - The clients agree with the shared helper

    /// Each client keeps a named `chunkText` so its own tests exercise the call production takes.
    /// This pins that the forwarders really do forward.
    func testEveryClientForwardsToTheSharedChunker() {
        let text = String(repeating: "x", count: 9_000)
        XCTAssertEqual(TelegramAPIClient.chunkText(text, maxLength: 4000),
                       RemoteTextBudget.chunk(text, limit: 4000))
        XCTAssertEqual(DiscordAPIClient.chunkText(text, maxLength: 1950),
                       RemoteTextBudget.chunk(text, limit: 1950))
        XCTAssertEqual(SlackAPIClient.chunkText(text, maxLength: 3000),
                       RemoteTextBudget.chunk(text, limit: 3000))
    }

    /// All three error types must answer the rate-limit question, or the driver silently stops
    /// retrying on that platform.
    func testAllThreeErrorsReportTheirRetryAfter() {
        XCTAssertEqual((SlackAPIError.rateLimited(retryAfter: 5) as RemoteRateLimitedError).retryAfterSeconds, 5)
        XCTAssertEqual((DiscordAPIError.rateLimited(retryAfter: 7) as RemoteRateLimitedError).retryAfterSeconds, 7)
        XCTAssertEqual((TelegramAPIError.rateLimited(retryAfter: 9) as RemoteRateLimitedError).retryAfterSeconds, 9)

        // ⚠️ A 429 Telegram did not quantify is still a rate limit, so it must answer with a value.
        XCTAssertNotNil((TelegramAPIError.rateLimited(retryAfter: nil) as RemoteRateLimitedError).retryAfterSeconds)

        // ⚠️ A non-rate-limit error must answer nil, or the driver retries something unretryable.
        XCTAssertNil((SlackAPIError.invalidToken as RemoteRateLimitedError).retryAfterSeconds)
        XCTAssertNil((TelegramAPIError.invalidToken as RemoteRateLimitedError).retryAfterSeconds)
    }

    // MARK: - Doubles

    private actor SendRecorder {
        private(set) var sent: [String] = []
        private var failuresRemaining = 0
        private var failFromIndex: Int?
        private var error: Error = SlackAPIError.invalidToken
        private var calls = 0

        func record(_ chunk: String) { sent.append(chunk) }

        func failNext(_ count: Int, with error: Error) {
            failuresRemaining = count
            self.error = error
        }

        /// Fail every attempt from the 1-based `index` onward.
        func failFrom(_ index: Int, with error: Error) {
            failFromIndex = index
            self.error = error
        }

        func recordThrowing(_ chunk: String) throws {
            calls += 1
            sent.append(chunk)
            if let failFromIndex, calls >= failFromIndex { throw error }
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw error
            }
        }
    }

    private actor WaitRecorder {
        private(set) var waits: [TimeInterval] = []
        func record(_ seconds: TimeInterval) { waits.append(seconds) }
    }
}
