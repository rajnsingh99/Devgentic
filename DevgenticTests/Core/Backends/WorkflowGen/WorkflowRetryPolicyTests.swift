//
//  WorkflowRetryPolicyTests.swift
//  DevgenticTests
//
//  The retry rules had NO test surface before this file: they lived inline in two loops that
//  disagreed with each other, and the Action loop disagreed with its own comment (it claimed to
//  "retry transient failures (timeout, network, MCP)" while retrying everything).
//
//  THE RULE (owner decision, 2026-08-19): retry on a compute timeout, or on a failure of a profile
//  node (bot / agent / sub-workflow). Never on cancellation. Action nodes are deterministic, so a
//  tool failure only retries when transient.
//

import XCTest
@testable import devgentic

final class WorkflowRetryPolicyTests: XCTestCase {

    // MARK: - structuralAttempts — which node kinds get the OUTER loop

    /// The N4 fix: sub-workflow nodes were rendered a Retries stepper that did nothing.
    func testSubWorkflowGetsTheConfiguredAttempts() {
        XCTAssertEqual(
            WorkflowRetryPolicy.structuralAttempts(isSubWorkflow: true, maxNodeRetries: 3, fallbackRetries: 0),
            4, "3 retries means 4 attempts"
        )
    }

    /// ⚠️ The multiplication guard. Action nodes retry in their OWN per-tool loop; if the outer loop
    /// also ran on their retry count, a setting of 3 would produce 9 tool invocations.
    func testNonSubWorkflowStructuralNodesGetExactlyOneOuterAttempt() {
        XCTAssertEqual(
            WorkflowRetryPolicy.structuralAttempts(isSubWorkflow: false, maxNodeRetries: 3, fallbackRetries: 2),
            1, "Action / condition / code / gate / trigger must not be looped by the outer retry"
        )
    }

    func testZeroRetriesMeansOneAttempt() {
        XCTAssertEqual(
            WorkflowRetryPolicy.structuralAttempts(isSubWorkflow: true, maxNodeRetries: 0, fallbackRetries: 0), 1
        )
    }

    /// The legacy workflow-level stepper (retired 2026-08-13) still applies when a node sets nothing.
    func testFallsBackToTheWorkflowLevelRetryCount() {
        XCTAssertEqual(
            WorkflowRetryPolicy.structuralAttempts(isSubWorkflow: true, maxNodeRetries: nil, fallbackRetries: 2), 3
        )
    }

    func testAttemptsAreNeverBelowOne() {
        XCTAssertEqual(
            WorkflowRetryPolicy.structuralAttempts(isSubWorkflow: true, maxNodeRetries: -5, fallbackRetries: 0), 1,
            "a corrupt stored value must not produce a zero-attempt node that never runs"
        )
    }

    // MARK: - stopsRetrying — which results END the attempt loop

    func testCompletedStopsTheLoop() {
        XCTAssertTrue(WorkflowRetryPolicy.stopsRetrying(after: .completed))
    }

    func testRetryableFailureContinuesAndNonRetryableStops() {
        XCTAssertFalse(WorkflowRetryPolicy.stopsRetrying(after: .failed(.executionTimeout(elapsed: 10, limit: 5))),
                       "a retryable failure is the whole reason the loop exists")
        XCTAssertTrue(WorkflowRetryPolicy.stopsRetrying(after: .failed(.cancelled)),
                      "cancellation is never retryable — Stop must not be answered by restarting")
    }

    func testCancellationStopsTheLoop() {
        XCTAssertTrue(WorkflowRetryPolicy.stopsRetrying(after: .canceled))
    }

    /// ⚠️ THE PHASE B GUARD, and the reason this function was extracted. The decision used to be
    /// four inline `if case` lines inside `executeProfileNodeWithRetry` with NO `.skipped` arm, so
    /// a skipped envelope fell through the attempt loop and RE-DISPATCHED the node the user had
    /// just skipped — at full token cost, and on existing workflows too, because `maxRetries` still
    /// honours the retired workflow-level fallback.
    ///
    /// ⚠️ This arm is UNREACHABLE through the executor today: both `.skipped` envelopes are built
    /// in the dispatch pre-flight, which never enters the loop. An end-to-end test therefore CANNOT
    /// verify it — one was written and a mutation removing the guard survived it. Testing the pure
    /// policy is what makes the guard verifiable before Phase B can regress it.
    func testEverySkipReasonStopsTheLoop() {
        for reason in NodeSkipReason.allCases {
            XCTAssertTrue(WorkflowRetryPolicy.stopsRetrying(after: .skipped(reason: reason)),
                          "a skip is an instruction, not a failure — retrying it re-runs work the user stopped: \(reason)")
        }
    }

    // MARK: - shouldRetrySubWorkflow — coarse on purpose, except cancellation

    /// Deliberately coarse: profile nodes are LLM-driven and non-deterministic, so a second attempt
    /// is a fresh sample rather than a replay. A parse failure or an action loop may not recur.
    func testProfileFailuresRetryRegardlessOfReason() {
        let reasons: [AgentFailureReason] = [
            .executionTimeout(elapsed: 10, limit: 5),
            .modelError(provider: "test", error: "boom"),
            .consecutiveParseFailures(count: 3, lastError: "bad json"),
            .repetitiveActionLoop(action: "read_file", count: 4),
            .consecutiveToolFailures(count: 3, lastTool: "t", lastError: "e"),
            .iterationBudgetExhausted(iterations: 15)
        ]
        for reason in reasons {
            XCTAssertTrue(WorkflowRetryPolicy.shouldRetrySubWorkflow(after: reason),
                          "a non-deterministic node's failure is worth a fresh attempt: \(reason)")
        }
    }

    /// ⚠️ THE ONE EXCLUSION, and the most important assertion in this file. A cancel is the user
    /// pressing Stop — not a failure. Retrying it restarts the run they just stopped, up to five
    /// times, defeating the conversation-scoped Stop.
    func testCancellationIsNeverRetried() {
        XCTAssertFalse(WorkflowRetryPolicy.shouldRetrySubWorkflow(after: .cancelled),
                       "Stop must not be answered by restarting the run")
    }

    // MARK: - Iteration exhaustion reaches the node as a REAL reason

    /// ⚠️ TWO PHRASINGS, TWO PATHS. `.failHard` says "allowed steps"; the DEFAULT
    /// `.synthesizeBestEffort` says "iterations". Matching only the first would have covered only
    /// the non-default policy — and it is the default one that reaches a workflow node whenever the
    /// agent produced no text.
    func testBothExhaustionPhrasingsClassifyAsIterationBudget() {
        let failHard = "Reached maximum allowed steps (15) without completion."
        let synthesize = "Reached maximum iterations (15) without explicit completion"

        XCTAssertEqual(AgentFailureReason.classify(agentReasonText: failHard),
                       .iterationBudgetExhausted(iterations: 15))
        XCTAssertEqual(AgentFailureReason.classify(agentReasonText: synthesize),
                       .iterationBudgetExhausted(iterations: 15))
    }

    /// THE USER-FACING FIX. Before this, exhaustion fell through to `.modelError`, so the node's
    /// remediation told the user to check connectivity, credentials and the selected model — for a
    /// run that had simply run out of steps.
    func testExhaustionNoLongerAdvisesCheckingCredentials() {
        let reason = AgentFailureReason.classify(agentReasonText: "Reached maximum iterations (20) without explicit completion")
        let advice = reason.remediation ?? ""
        XCTAssertTrue(advice.contains("20"), "the advice must name the actual limit — got: \(advice)")
        XCTAssertTrue(advice.lowercased().contains("iteration") || advice.lowercased().contains("step"))
        XCTAssertFalse(advice.lowercased().contains("credential"),
                       "running out of steps is not a provider problem")
    }

    /// The parser is total: an unreadable count degrades to the generic reason rather than
    /// inventing a number for a remediation string.
    func testUnparseableExhaustionTextFallsBackRatherThanGuessing() {
        // No parentheses at all — bails at the delimiter guard.
        XCTAssertNil(AgentFailureReason.exhaustedIterationCount(in: "Reached maximum steps somehow"))
        if case .iterationBudgetExhausted = AgentFailureReason.classify(agentReasonText: "Reached maximum steps somehow") {
            XCTFail("must not construct the case without a real count")
        }

        // ⚠️ PARENTHESES PRESENT, CONTENTS NOT A NUMBER. This case was MISSING and a mutation
        // exposed it: changing `Int(digits)` to `Int(digits) ?? 0` survived the whole suite,
        // because the only unparseable input tested had no parens and bailed one guard EARLIER —
        // the mutated line was never reached. A `?? 0` here would tell the user "you used all 0 of
        // your steps", which is exactly the invented number the nil-return exists to prevent.
        for garbage in ["Reached maximum iterations (many) without explicit completion",
                        "Reached maximum allowed steps () without completion.",
                        "Reached maximum iterations (fifteen) without explicit completion"] {
            XCTAssertNil(AgentFailureReason.exhaustedIterationCount(in: garbage),
                         "a non-numeric count must yield nil, never a guessed number: \(garbage)")
            if case .iterationBudgetExhausted = AgentFailureReason.classify(agentReasonText: garbage) {
                XCTFail("must fall back to the generic reason rather than invent a count: \(garbage)")
            }
        }
    }

    func testUnrelatedFailureTextIsUntouched() {
        XCTAssertNil(AgentFailureReason.exhaustedIterationCount(in: "HTTP 500 from provider (retry later)"))
        XCTAssertEqual(AgentFailureReason.classify(agentReasonText: "Breaking stale loop: tool 'read_file' called 3 times"),
                       .repetitiveActionLoop(action: "read_file", count: 3))
    }

    // MARK: - isTransientToolError — the Action path's honesty fix

    func testComputeTimeoutIsTransient() {
        let timeout = AgentExecutionError(reason: .executionTimeout(elapsed: 30, limit: 30))
        XCTAssertTrue(WorkflowRetryPolicy.isTransientToolError(timeout))
    }

    func testNetworkErrorIsTransient() {
        XCTAssertTrue(WorkflowRetryPolicy.isTransientToolError(URLError(.timedOut)))
        XCTAssertTrue(WorkflowRetryPolicy.isTransientToolError(URLError(.networkConnectionLost)))
    }

    /// MCP over HTTP surfaces as a wrapped URLError rather than a bare one.
    func testWrappedNetworkErrorIsTransient() {
        let wrapped = NSError(domain: "MCP", code: 1,
                              userInfo: [NSUnderlyingErrorKey: URLError(.cannotConnectToHost)])
        XCTAssertTrue(WorkflowRetryPolicy.isTransientToolError(wrapped))
    }

    /// THE FIX: these all used to retry, burning the node's budget to reach the identical error.
    func testDeterministicToolFailuresAreNotTransient() {
        struct ToolArgumentError: Error {}
        let permanent: [Error] = [
            ToolArgumentError(),
            NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError),
            NSError(domain: NSPOSIXErrorDomain, code: 13)   // permission denied
        ]
        for error in permanent {
            XCTAssertFalse(WorkflowRetryPolicy.isTransientToolError(error),
                           "a deterministic tool error must not be retried: \(error)")
        }
    }

    /// An unrecognised error is treated as PERMANENT, so a newly-introduced tool error cannot
    /// silently acquire retry behaviour nobody chose.
    func testUnknownErrorsDefaultToPermanent() {
        struct BrandNewError: Error {}
        XCTAssertFalse(WorkflowRetryPolicy.isTransientToolError(BrandNewError()))
    }

    func testDeclineReasonIsAlwaysStated() {
        struct Whatever: Error {}
        XCTAssertFalse(WorkflowRetryPolicy.declineReason(for: Whatever()).isEmpty)
        XCTAssertTrue(WorkflowRetryPolicy.declineReason(for: CancellationError()).contains("cancelled"))
    }

    /// WF-CC4: a cancellation-shaped `URLError` must not be classified as an ordinary transient
    /// network blip — a Stop-triggered cancellation can surface as `URLError(.cancelled)` rather
    /// than `CancellationError`, and this predicate must not contradict the file's own rule that
    /// cancellation is never retried just because of which shape it happened to arrive in.
    func testCancelledURLErrorIsNotTransient() {
        XCTAssertFalse(WorkflowRetryPolicy.isTransientToolError(URLError(.cancelled)))
    }

    /// The wrapped-error path (MCP over HTTP) must apply the same exclusion as the bare one.
    func testWrappedCancelledURLErrorIsNotTransient() {
        let wrapped = NSError(domain: "MCP", code: 1,
                              userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)])
        XCTAssertFalse(WorkflowRetryPolicy.isTransientToolError(wrapped))
    }

    // MARK: - shouldRetryToolFailure — cancellation is checked first, unconditionally (WF-CC4)

    /// The single most important property: cancelled beats everything else, including an error
    /// that would otherwise clearly qualify as transient and retries remaining.
    func testCancellationIsNeverRetriedEvenForATransientError() {
        XCTAssertFalse(WorkflowRetryPolicy.shouldRetryToolFailure(
            URLError(.networkConnectionLost), attempt: 0, maxRetries: 3, isCancelled: true
        ))
    }

    func testNonCancelledTransientErrorWithRetriesRemainingIsRetried() {
        XCTAssertTrue(WorkflowRetryPolicy.shouldRetryToolFailure(
            URLError(.networkConnectionLost), attempt: 0, maxRetries: 3, isCancelled: false
        ))
    }

    func testNonCancelledTransientErrorWithNoRetriesRemainingIsNotRetried() {
        XCTAssertFalse(WorkflowRetryPolicy.shouldRetryToolFailure(
            URLError(.networkConnectionLost), attempt: 3, maxRetries: 3, isCancelled: false
        ))
    }

    func testNonCancelledPermanentErrorIsNotRetried() {
        struct ToolArgumentError: Error {}
        XCTAssertFalse(WorkflowRetryPolicy.shouldRetryToolFailure(
            ToolArgumentError(), attempt: 0, maxRetries: 3, isCancelled: false
        ))
    }
}
