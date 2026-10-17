// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ⚠️ WIRING. The policy and the coordinator are worth nothing if the send path stops calling them,
//  and a cut call fails no unit test of either. Source-scanned in the `ToolRegistryDriftTests` /
//  `GaugeHistorySourceTests` idiom, over JOINED bodies (a line filter misses multi-line calls).
//

import XCTest
@testable import devgentic

final class LocalInferenceWiringTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Devgentic").path) else {
            throw XCTSkip("sources not reachable — running outside a checkout")
        }
        return try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func offset(of needle: String, in haystack: String, file: StaticString = #filePath, line: UInt = #line) -> Int? {
        guard let range = haystack.range(of: needle) else {
            XCTFail("missing: \(needle)", file: file, line: line)
            return nil
        }
        return haystack.distance(from: haystack.startIndex, to: range.lowerBound)
    }

    private let manager = "Devgentic/Core/Utils/ActiveStreamManager.swift"

    /// The run takes (or waits for) the local lock AFTER conversation admission (layer 1 before
    /// layer 2) and after the cancelled-while-queued early return, but BEFORE it does any work.
    func testRunsRegisterAfterConversationAdmissionAndBeforeWork() throws {
        let code = try source(manager)
        guard let admit = offset(of: "await self.admission.awaitTurn(", in: code),
              let cancelledReturn = offset(of: "was cancelled while waiting for conversation", in: code),
              let register = code.range(of: #"await self\.inferenceCoordinator\.acquire\(\s*InferenceRunManifest\.build\("#,
                                        options: .regularExpression).map({ code.distance(from: code.startIndex, to: $0.lowerBound) }),
              let work = offset(of: "let capabilityRouter = CapabilityCardRouter(message: agentMessage)", in: code)
        else { return }
        XCTAssertLessThan(admit, register, "layer 2 must come after layer 1")
        XCTAssertLessThan(cancelledReturn, register, "a run cancelled while queued must never register")
        XCTAssertLessThan(register, work, "the run must be registered before it does anything")
    }

    /// A run withdrawn or refused while waiting ends through the SAME three steps as every other exit
    /// — finalize (which also releases), drop the task, call `onComplete`. Skipping `onComplete` is
    /// what left a scheduled task "already running" until relaunch once before (D-12).
    func testCancelledAndDeniedWaitsEndLikeEveryOtherExit() throws {
        let code = try source(manager)
        for (arm, error) in [("case .cancelled:", "nil"), ("case .denied(let reason):", "refusal")] {
            let pattern = NSRegularExpression.escapedPattern(for: arm)
                + #"[\s\S]{0,400}?await self\.finalizeMessage\(agentMessage, conversationID: conversationID,\s*error: "#
                + NSRegularExpression.escapedPattern(for: error)
                + #"\)\s*self\.removeTask\(for: agentMessage\.id\)\s*onComplete\(\)\s*return"#
            XCTAssertNotNil(code.range(of: pattern, options: .regularExpression), "\(arm) must finalize, remove the task and complete")
        }
    }

    /// A run withdrawn while it waited — behind its conversation or for the local model — ends
    /// CANCELLED, like a run stopped mid-work, never as a failure. Finalizing with a
    /// `CancellationError` recorded it as FAILED under a "Response Error … Swift.CancellationError"
    /// card, mirrored as such to ChatOps, and left a workflow run's record unsettled.
    func testRunsWithdrawnWhileWaitingEndCancelledNotFailed() throws {
        let code = try source(manager)
        for marker in ["was cancelled while waiting for conversation", "was cancelled while waiting for the local model"] {
            let pattern = NSRegularExpression.escapedPattern(for: marker)
                + #"[\s\S]{0,120}?Self\.markWithdrawnBeforeStart\(agentMessage, workflow: workflowExecutionState\)\s*await self\.finalizeMessage\(agentMessage, conversationID: conversationID, error: nil\)"#
            XCTAssertNotNil(code.range(of: pattern, options: .regularExpression), "'\(marker)' must stamp CANCELLED and finalize without an error")
        }
        XCTAssertFalse(code.contains("error: CancellationError()"), "a cancellation must never be finalized as a thrown error")
        XCTAssertNotNil(code.range(of: #"case \.denied\(let reason\):\s*let refusal = LocalInferenceRefusal\(reason: reason\)\s*workflowExecutionState\?\.handleError\(refusal\.localizedDescription\)"#,
                                   options: .regularExpression), "a refused workflow run must settle its run record")
    }

    /// Every wait of the run — the first and any re-acquire after a park — goes through ONE observer
    /// that says so on screen and to a remote chat, and clears its banner when the wait ends.
    func testAWaitingRunIsVisibleAndItsBannerIsCleared() throws {
        let code = try source(manager)
        XCTAssertNotNil(code.range(of: #"onHold: \{ \[weak self\] position, _ in\s*self\?\.localWaitBegan\(agentMessage,"#,
                                   options: .regularExpression), "acquire must pass the wait-began observer")
        XCTAssertNotNil(code.range(of: #"onWaitEnded: \{ \[weak self\] _ in\s*self\?\.localWaitEnded\(agentMessage,"#,
                                   options: .regularExpression), "acquire must pass the wait-ended observer")
        XCTAssertNotNil(code.range(of: #"private func localWaitBegan\([\s\S]{0,200}?agentMessage\.agentState = \.thinking\(\.awaitingLocalModel\)[\s\S]{0,900}?didQueueForLocalModel: agentMessage"#,
                                   options: .regularExpression), "a wait must set the queued state and tell the mirror delegates")
        XCTAssertNotNil(code.range(of: #"private func localWaitEnded\([\s\S]{0,600}?localQueueBanners\.removeValue\(forKey: agentMessage\.id\)\?\.cancel\(\)[\s\S]{0,300}?AdvisoryCenter\.shared\.clear\(category: \.localModelBusy, conversationID: conversationID\)\s*AdvisoryCenter\.shared\.clear\(category: \.runNeedsConfirmation, conversationID: conversationID\)"#,
                                   options: .regularExpression), "the banner must go when the wait ends")

        let mirror = try source("Devgentic/ChatOps/Services/RemoteMirrorService.swift")
        XCTAssertNotNil(mirror.range(of: #"didQueueForLocalModel message: ChatMessage,[\s\S]{0,200}?guard let session = remoteSessions\[conversationID\] else \{ return \}[^\n]*\n\s*guard startedBy == session\.source else \{"#,
                                     options: .regularExpression), "the ChatOps notice goes through the same consent gate as mirroring")
    }

    /// Phase 7: the send path hears the question, the answer and every move of the line — and the
    /// banners' buttons reach the run. A cut here leaves a run held with nothing on screen.
    func testTheAskingBannerAndItsButtonsAreWired() throws {
        let code = try source(manager)
        for pattern in [
            #"onConfirmationNeeded: \{ \[weak self\] concerns, deadline in\s*self\?\.localConfirmationNeeded\(agentMessage,"#,
            #"onConfirmed: \{ \[weak self\] in\s*self\?\.localConfirmed\(agentMessage,"#,
            #"onPositionChanged: \{ \[weak self\] position, _ in\s*self\?\.localPositionChanged\(agentMessage,"#,
            // The question: Proceed + Stop, a countdown, not dismissible, above ambient banners.
            #"category: \.runNeedsConfirmation, message: message,\s*actionLabel: "Proceed", action: \.proceedRun\(messageID: agentMessage\.id\),[\s\S]{0,200}?secondaryActionLabel: "Stop", secondaryAction: \.stopRun\(messageID: agentMessage\.id\),\s*tone: \.warning, deadline: deadline, deadlineLabel: "Auto-denied in",\s*dismissible: false, priority: Advisory\.runQuestionPriority"#,
            #"func proceedHeldRun\(messageID: UUID\) \{\s*let accepted = inferenceCoordinator\.proceed\(runID: messageID\)"#,
            // The same-conversation queue gets its banner too.
            #"onWait: \{\s*agentMessage\.agentState = \.thinking\(\.queued\)\s*self\.conversationQueueBegan\(agentMessage, conversationID: conversationID\)"#,
        ] {
            XCTAssertNotNil(code.range(of: pattern, options: .regularExpression), "not wired: \(pattern)")
        }
        let banner = try source("Devgentic/Interfaces/Shared/ChatInput/AdvisoryBannerView.swift")
        XCTAssertNotNil(banner.range(of: #"case \.proceedRun\(let messageID\):\s*vm\.activeStreamManager\.proceedHeldRun\(messageID: messageID\)\s*case \.stopRun\(let messageID\):\s*vm\.activeStreamManager\.cancelStream\(for: messageID\)"#,
                                     options: .regularExpression), "the main window's buttons must reach the run")
        let quickAccess = try source("Devgentic/Interfaces/QuickAccess/Views/QuickAccessContentView.swift")
        XCTAssertNotNil(quickAccess.range(of: #"onProceedRun: \{ messageID in mainAppViewModel\.activeStreamManager\.proceedHeldRun\(messageID: messageID\) \},\s*onStopRun: \{ messageID in mainAppViewModel\.activeStreamManager\.cancelStream\(for: messageID\) \}"#,
                                          options: .regularExpression), "QuickAccess's buttons must reach the run")
    }

    /// The wait behind the conversation's own run is credited to the run's time bounds, like the
    /// local-model wait — a scheduled run's deadline must not run out in line.
    func testTheConversationQueueWaitIsCredited() throws {
        let code = try source(manager)
        XCTAssertNotNil(code.range(of: #"let admissionCredit: UUID\? = ParkScope\.chain\.isEmpty \? nil : UUID\(\)\s*if let admissionCredit \{ await ExecutionSuspensionService\.shared\.beginQueueWait\(admissionCredit\) \}\s*let waited = await self\.admission\.awaitTurn\([\s\S]{0,700}?\}\)\s*if let admissionCredit \{ await ExecutionSuspensionService\.shared\.endQueueWait\(admissionCredit\) \}"#,
                                   options: .regularExpression))
    }

    /// Phase 4: every park reports its run to the coordinator on begin, and every park end reports
    /// back — from `endPark`, the one place all resolution paths meet.
    func testParksAreReportedToTheCoordinator() throws {
        let code = try source("Devgentic/Core/Utils/ExecutionSuspensionService.swift")
        XCTAssertNotNil(code.range(of: #"private func beginPark\([^{]*\{[\s\S]{0,400}?if let runID = LocalInferenceScope\.runID \{\s*operationToLocalRun\[operationID\] = runID\s*Task \{ @MainActor in LocalInferenceCoordinator\.shared\.parkBegan\(runID: runID, operationID: operationID\) \}"#,
                                   options: .regularExpression))
        XCTAssertNotNil(code.range(of: #"private func endPark\([^{]*\{[\s\S]{0,200}?if let runID = operationToLocalRun\.removeValue\(forKey: operationID\) \{\s*Task \{ @MainActor in LocalInferenceCoordinator\.shared\.parkEnded\(runID: runID, operationID: operationID\) \}"#,
                                   options: .regularExpression))
    }

    /// The production coordinator credits queue waits to the run's time bounds.
    func testTheQueueWaitIsCreditedByDefault() throws {
        let code = try source("Devgentic/Core/LocalInference/LocalInferenceCoordinator.swift")
        XCTAssertTrue(code.contains("beginQueueWait: @escaping @Sendable (UUID) async -> Void = { await ExecutionSuspensionService.shared.beginQueueWait($0) }"))
        XCTAssertTrue(code.contains("endQueueWait: @escaping @Sendable (UUID) async -> Void = { await ExecutionSuspensionService.shared.endQueueWait($0) }"))
    }

    /// Released on the one path every run end takes, beside the conversation queue's release.
    func testRunsUnregisterBesideAdmitNext() throws {
        let code = try source(manager)
        XCTAssertNotNil(code.range(of: #"admission\.admitNext\(inConversation: conversationID\)[\s\S]{0,400}?inferenceCoordinator\.unregister\(runID: message\.id\)"#,
                                   options: .regularExpression),
                        "finalizeMessage must unregister the run right after admitNext")
        XCTAssertEqual(code.components(separatedBy: "inferenceCoordinator.unregister(").count - 1, 1,
                       "exactly one release site — a second would hide a path that skips finalizeMessage")
    }

    /// The run id is bound around the run Task's CREATION, so every task beneath inherits it.
    func testTheRunScopeIsBoundAroundTheRunTask() throws {
        let code = try source(manager)
        XCTAssertNotNil(code.range(of: #"LocalInferenceScope\.\$runID\.withValue\(agentMessage\.id\)\s*\{\s*Task \{ \[weak self\] in"#,
                                   options: .regularExpression))
    }

    /// Each local provider passes the gate at every generation entry point — holding the lock (taking
    /// it back after a park) and counting the generation — before it touches the model.
    func testLocalProvidersGateEveryGenerationEntryPoint() throws {
        let begin = #"let generation = try await LocalInferenceScope\.beginGeneration\(engine: "#
        let end = #"\s*defer \{ generation\.end\(\) \}"#

        let mlx = try source("Devgentic/Core/Backends/MLXLLMProvider.swift")
        for (name, pattern) in [
            ("generateWithUsage", #"func generateWithUsage\([^{]*\{\s*"# + begin + #"\.mlx, modelID: modelName\)"# + end),
            ("streamWithUsage producer", #"let producer = Task \{\s*do \{\s*"# + begin + #"\.mlx, modelID: modelName\)"# + end + #"\s*let tokenStream = await MLXService\.shared\.streamChat\("#),
            ("vision", begin + #"\.mlx, modelID: modelName\)"# + end + #"\s*var fullText = \"\"\s*let stream = await MLXService\.shared\.streamVisionChat\("#),
        ] {
            XCTAssertNotNil(mlx.range(of: pattern, options: .regularExpression), "MLX \(name) is not gated")
        }

        let ollama = try source("Devgentic/Core/Backends/OllamaLLMProvider.swift")
        for (name, pattern) in [
            ("postChat", #"private func postChat\([^{]*\{\s*"# + begin + #"inferenceEngine, modelID: config\.modelName,\s*contextTokens: requestedContext\)"# + end),
            ("dispatchCognitiveRequest", #"private func dispatchCognitiveRequest\([^{]*\{\s*"# + begin + #"inferenceEngine, modelID: config\.modelName,\s*contextTokens: requestedContext\)"# + end),
            // The stream's gate runs in `beforeOpen`, where the stall watchdog is paused — inside
            // `openBytes` a wait over 60 s failed the stream as a stalled connection.
            // …and COUNTED: begun there, ended in `onClose` when the reader ends.
            ("stream open", #"beforeOpen: \{\s*generation\.hold\(try await LocalInferenceScope\.beginGeneration\(engine: engine, modelID: model,\s*contextTokens: context\)\)\s*\},\s*onClose: \{ generation\.end\(\) \},\s*openBytes: \{"#),
        ] {
            XCTAssertNotNil(ollama.range(of: pattern, options: .regularExpression), "Ollama \(name) is not gated")
        }
    }
}

/// What a run withdrawn before it started is recorded as.
@MainActor
final class WithdrawnBeforeStartTests: XCTestCase {

    private func message() -> ChatMessage {
        ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""))
    }

    func testItIsCancelledByTheUserNotFailed() {
        let m = message()
        ActiveStreamManager.markWithdrawnBeforeStart(m, workflow: nil)
        XCTAssertEqual(m.terminalOutcome, .cancelled)
        XCTAssertEqual(m.terminalReason, "Cancelled by user")
    }

    /// A deadline that stamped TIMED OUT before cancelling keeps its own outcome and reason.
    func testAnOutcomeAlreadyStampedIsKept() {
        let m = message()
        m.terminalOutcome = .timedOut
        m.terminalReason = "Run stopped: deadline."
        ActiveStreamManager.markWithdrawnBeforeStart(m, workflow: nil)
        XCTAssertEqual(m.terminalOutcome, .timedOut)
        XCTAssertEqual(m.terminalReason, "Run stopped: deadline.")
    }

    func testAWorkflowRunRecordIsSettledAsCancelled() {
        let state = WorkflowExecutionState()
        state.isRunning = true
        ActiveStreamManager.markWithdrawnBeforeStart(message(), workflow: state)
        XCTAssertFalse(state.isRunning)
        XCTAssertTrue(state.wasCancelled)
    }
}
