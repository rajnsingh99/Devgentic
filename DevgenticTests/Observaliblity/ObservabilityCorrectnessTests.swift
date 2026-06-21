//
//  ObservabilityCorrectnessTests.swift
//  DevgenticTests
//
//  Pure-function regression coverage for the Phase A correctness fixes:
//  the trace-status derivation (Gap #1) and the SHA-256 config hash (Gap #16).
//  Both were extracted/made testable specifically so this file can pin them down
//  without standing up the full ActiveStreamManager / config-capture machinery.
//

import XCTest
@testable import devgentic

final class ObservabilityCorrectnessTests: XCTestCase {

    // MARK: - TraceStatus.resolve (Gap #1)

    func testResolve_thrownError_alwaysError_regardlessOfOutcome() {
        // A thrown exception reaching the stream boundary is the most severe signal and
        // must win over whatever terminal outcome the executor reported.
        for outcome: ExecutionOutcome? in [nil, .completed, .failed, .cancelled] {
            XCTAssertEqual(
                TraceStatus.resolve(thrownError: true, terminalOutcome: outcome),
                .error,
                "thrownError must map to .error even when terminalOutcome is \(String(describing: outcome))"
            )
        }
    }

    func testResolve_noThrow_mapsOutcomeToStatus() {
        // This is the core of Gap #1: a non-throwing failure/cancel must NOT be recorded
        // as `.completed` (the old behavior derived status purely from `error != nil`).
        XCTAssertEqual(TraceStatus.resolve(thrownError: false, terminalOutcome: .completed), .completed)
        XCTAssertEqual(TraceStatus.resolve(thrownError: false, terminalOutcome: .failed), .failed)
        XCTAssertEqual(TraceStatus.resolve(thrownError: false, terminalOutcome: .cancelled), .cancelled)
    }

    func testResolve_noThrow_nilOutcome_defaultsToCompleted() {
        // After ASM's safety net `terminalOutcome` is never nil, but defend the boundary:
        // a non-throwing run with no reported outcome is treated as a clean completion.
        XCTAssertEqual(TraceStatus.resolve(thrownError: false, terminalOutcome: nil), .completed)
    }

    // MARK: - TraceConfigSnapshot.shortHash (Gap #16)

    func testShortHash_isStableAcrossCalls() {
        // The whole point of the SHA-256 fix: identical input → identical hash across calls
        // (and processes). Swift's per-process-seeded `hashValue` could not promise this.
        XCTAssertEqual(TraceConfigSnapshot.shortHash("the quick brown fox"),
                       TraceConfigSnapshot.shortHash("the quick brown fox"))
    }

    func testShortHash_matchesKnownSHA256Prefix() {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223...; first 8 bytes = ba7816bf8f01cfea.
        // Pinning the exact value proves we hash with SHA-256, not `hashValue`.
        XCTAssertEqual(TraceConfigSnapshot.shortHash("abc"), "ba7816bf8f01cfea")
    }

    func testShortHash_is16LowercaseHexChars() {
        let hash = TraceConfigSnapshot.shortHash("anything")
        XCTAssertEqual(hash.count, 16, "8 bytes → 16 hex chars (format-compatible with the old %016x)")
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testShortHash_differsForDifferentInput() {
        XCTAssertNotEqual(TraceConfigSnapshot.shortHash("a"), TraceConfigSnapshot.shortHash("b"))
    }
}
