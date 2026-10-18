// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CapabilityCardRouter.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "CapabilityCardRouter")

// Why: attribution is ordering-based and assumes sequential subtasks and trials; parallel subtasks would need a subtask id on events.
/// Maintains the Plan & Execute and Reflexion cards inside a streaming message's timeline, routing forwarded events
/// into the active step's or attempt's nested sub-timeline.
@MainActor
final class CapabilityCardRouter {

    private let message: ChatMessage

    // Plan card state
    private var planCardID: UUID?
    /// Non-nil when the plan card is nested inside this reflection attempt (stacked capabilities).
    private var planCardTrial: Int?
    private var activeStepID: String?

    // Reflection card state
    private var reflectionCardID: UUID?
    private var activeTrial: Int?
    private var trialStartedAt: [Int: Date] = [:]

    init(message: ChatMessage) {
        self.message = message
    }

    // MARK: - Plan lifecycle

    func handlePlanGenerated(_ subtasks: [SubTask]) {
        let card = PlanRunData(phase: .executing, steps: subtasks.map(Self.step(from:)))
        planCardID = card.id
        activeStepID = nil
        if let trial = activeTrial, reflectionCardID != nil {
            planCardTrial = trial
            mutateReflection { data in
                guard let a = data.attempts.firstIndex(where: { $0.trial == trial }) else { return }
                data.attempts[a].events.append(.planExecution(card))
            }
        } else {
            planCardTrial = nil
            message.appendTimelineEvent(.planExecution(card))
        }
    }

    func handlePlanReviewRequested() {
        mutatePlan { $0.phase = .awaitingApproval }
    }

    func handlePlanApproved(_ subtasks: [SubTask]) {
        mutatePlan { data in
            data.phase = .executing
            // Review edits can add/remove/reword steps — replace wholesale. Nothing has
            // executed yet at this point, so no live statuses are lost.
            data.steps = subtasks.map(Self.step(from:))
        }
    }

    func handleSubtaskStarted(id: String, description: String) {
        if planCardID == nil {
            // Defensive: a started event with no plan card (shouldn't happen — planGenerated
            // always precedes) still gets a card so the step has somewhere to live.
            handlePlanGenerated([])
        }
        activeStepID = id
        mutatePlan { data in
            data.phase = .executing
            if let s = data.steps.firstIndex(where: { $0.id == id }) {
                data.steps[s].status = .running
            } else {
                data.steps.append(PlanStepData(id: id, title: description, status: .running))
            }
        }
    }

    func handleSubtaskCompleted(id: String, summary: String, outcome: ExecutionOutcome?, durationMs: Int?) {
        mutatePlan { data in
            guard let s = data.steps.firstIndex(where: { $0.id == id }) else { return }
            data.steps[s].status = Self.stepStatus(for: outcome)
            data.steps[s].summary = summary
            data.steps[s].durationMs = durationMs
        }
        if activeStepID == id { activeStepID = nil }
    }

    // MARK: - Reflection lifecycle

    func handleTrialStarted(trial: Int, maxTrials: Int) {
        // A prior trial's nested plan card (stacked capabilities) never sees its own
        // executionFinished — the reflection wrapper captures it. Close it here.
        closeNestedPlanCard(reason: "a new trial starting (superseded)")

        if reflectionCardID == nil {
            let card = ReflectionRunData(maxTrials: maxTrials)
            reflectionCardID = card.id
            message.appendTimelineEvent(.reflectionRun(card))
        }
        activeTrial = trial
        trialStartedAt[trial] = Date()
        mutateReflection { data in
            data.maxTrials = maxTrials
            if !data.attempts.contains(where: { $0.trial == trial }) {
                data.attempts.append(ReflectionAttemptData(trial: trial))
            }
        }
    }

    func handleTrialEvaluating(trial: Int) {
        mutateReflection { data in
            guard let a = data.attempts.firstIndex(where: { $0.trial == trial }) else { return }
            data.attempts[a].status = .evaluating
            if data.attempts[a].durationMs == nil, let start = self.trialStartedAt[trial] {
                data.attempts[a].durationMs = Int(Date().timeIntervalSince(start) * 1000)
            }
        }
    }

    func handleTrialRejected(trial: Int, critique: String) {
        mutateReflection { data in
            guard let a = data.attempts.firstIndex(where: { $0.trial == trial }) else { return }
            data.attempts[a].status = .rejected
            data.attempts[a].critique = critique
            if data.attempts[a].durationMs == nil, let start = self.trialStartedAt[trial] {
                data.attempts[a].durationMs = Int(Date().timeIntervalSince(start) * 1000)
            }
        }
        closeNestedPlanCard(reason: "the trial being REJECTED (its work was discarded)")
        activeTrial = nil
    }

    func handleTrialAccepted(trial: Int) {
        mutateReflection { data in
            data.acceptedTrial = trial
            guard let a = data.attempts.firstIndex(where: { $0.trial == trial }) else { return }
            data.attempts[a].status = .accepted
            if data.attempts[a].durationMs == nil, let start = self.trialStartedAt[trial] {
                data.attempts[a].durationMs = Int(Date().timeIntervalSince(start) * 1000)
            }
        }
        closeNestedPlanCard(reason: "the trial being accepted")
        activeTrial = nil
    }

    // MARK: - Terminal

    /// Finishes any open cards. Safe to call unconditionally — no-op without cards.
    /// Also invoked from the stream's cancel/error catches so an interrupted run
    /// doesn't persist a card that claims to still be executing.
    func handleExecutionFinished(outcome: ExecutionOutcome) {
        if planCardID != nil {
            mutatePlan { data in
                guard data.phase != .finished else { return }
                data.phase = .finished
                data.outcome = outcome
                data.finishedAt = Date()
                for i in data.steps.indices where data.steps[i].status == .running {
                    data.steps[i].status = (outcome == .cancelled) ? .cancelled : .failed
                }
                // A plan rejected in review finishes with every step still .pending —
                // that is the honest record (nothing ran).
            }
        }
        if reflectionCardID != nil {
            mutateReflection { data in
                data.outcome = outcome
                data.finishedAt = Date()
                for i in data.attempts.indices {
                    switch data.attempts[i].status {
                    case .running, .evaluating:
                        // The final trial is never evaluated — a clean finish marks it
                        // `.completed` (ran, no evaluator verdict), not `.accepted`.
                        switch outcome {
                        case .cancelled: data.attempts[i].status = .cancelled
                        case .failed:    data.attempts[i].status = .failed
                        default:         data.attempts[i].status = .completed
                        }
                        if data.attempts[i].durationMs == nil,
                           let start = trialStartedAt[data.attempts[i].trial] {
                            data.attempts[i].durationMs = Int(Date().timeIntervalSince(start) * 1000)
                        }
                    default:
                        break
                    }
                }
            }
        }
        activeStepID = nil
        activeTrial = nil
    }

    // MARK: - Event routing

    /// Appends the event into the active step's or attempt's nested sub-timeline.
    /// Returns `false` when no capability segment is active; the caller then appends to the top-level timeline.
    /// Nested arrays follow the same eviction rule (`maxTimelineEvents`) as the top-level timeline.
    func route(_ event: TimelineEvent) -> Bool {
        withActiveEvents { events in
            events.append(event)
            ChatMessage.evictOverflow(&events, context: "capability-card nested")
        }
    }

    /// Completes an executing `.toolExecution` row nested in the active segment.
    /// Returns `false` when no nested target matched (caller falls back to the
    /// top-level completion path).
    func completeTool(output: ToolOutput, failureCategory: ToolFailureCategory?, durationMs: Int?) -> Bool {
        var completed = false
        let handled = withActiveEvents { events in
            // Matched by name and params; see `ToolRowMatcher`.
            guard let idx = ToolRowMatcher.index(in: events, for: output) else { return }
            if case .toolExecution(var d) = events[idx] {
                d.params = output.params
                // Cap, snapshots and effect must match `completeToolTimelineEvent` exactly;
                // this is the second place a tool row is finalised.
                let capped = ToolExecutionData.cappedOutput(output.output)
                if capped.count != output.output.count {
                    logger.warning("[TOOL_OUTPUT] '\(output.toolName)' returned \(output.output.count) chars — truncated to \(ToolExecutionData.maxPersistedOutputLength) for the timeline (card-nested row).")
                }
                d.output = capped
                d.isSuccess = output.isSuccess
                d.failureCategory = failureCategory
                d.durationMs = durationMs
                d.isExecuting = false
                d.preWriteContent = output.preWriteContent
                d.postWriteContent = output.postWriteContent
                d.effect = ActionEffect.from(toolExecution: d)
                events[idx] = .toolExecution(d)
                EditPatchStore.recordIfCode(d, in: message)
                completed = true
            }
        }
        return handled && completed
    }

    // MARK: - Targeting

    /// Runs `body` against the events array of the innermost active segment:
    /// plan step nested in a reflection attempt (stacked) → reflection attempt →
    /// top-level plan step. Returns whether a segment was found.
    @discardableResult
    private func withActiveEvents(_ body: (inout [TimelineEvent]) -> Void) -> Bool {
        if let trial = activeTrial, reflectionCardID != nil {
            if let stepID = activeStepID, let cardID = planCardID, planCardTrial == trial {
                var handled = false
                mutateReflection { data in
                    guard let a = data.attempts.firstIndex(where: { $0.trial == trial }),
                          let p = data.attempts[a].events.firstIndex(where: { Self.isPlanCard($0, id: cardID) }),
                          case .planExecution(var plan) = data.attempts[a].events[p],
                          let s = plan.steps.firstIndex(where: { $0.id == stepID })
                    else { return }
                    body(&plan.steps[s].events)
                    data.attempts[a].events[p] = .planExecution(plan)
                    handled = true
                }
                return handled
            }
            var handled = false
            mutateReflection { data in
                guard let a = data.attempts.firstIndex(where: { $0.trial == trial }) else { return }
                body(&data.attempts[a].events)
                handled = true
            }
            return handled
        }
        if let stepID = activeStepID, planCardID != nil, planCardTrial == nil {
            var handled = false
            mutatePlan { data in
                guard let s = data.steps.firstIndex(where: { $0.id == stepID }) else { return }
                body(&data.steps[s].events)
                handled = true
            }
            return handled
        }
        return false
    }

    // MARK: - Card mutation

    private func mutatePlan(_ body: (inout PlanRunData) -> Void) {
        guard let cardID = planCardID else { return }
        if let trial = planCardTrial {
            mutateReflection { data in
                guard let a = data.attempts.firstIndex(where: { $0.trial == trial }),
                      let p = data.attempts[a].events.firstIndex(where: { Self.isPlanCard($0, id: cardID) }),
                      case .planExecution(var plan) = data.attempts[a].events[p]
                else { return }
                body(&plan)
                data.attempts[a].events[p] = .planExecution(plan)
            }
            return
        }
        guard let idx = message.timelineEvents.firstIndex(where: { Self.isPlanCard($0, id: cardID) }),
              case .planExecution(var plan) = message.timelineEvents[idx]
        else { return }
        body(&plan)
        message.timelineEvents[idx] = .planExecution(plan)
    }

    private func mutateReflection(_ body: (inout ReflectionRunData) -> Void) {
        guard let cardID = reflectionCardID,
              let idx = message.timelineEvents.firstIndex(where: {
                  if case .reflectionRun(let d) = $0 { return d.id == cardID }
                  return false
              }),
              case .reflectionRun(var data) = message.timelineEvents[idx]
        else { return }
        body(&data)
        message.timelineEvents[idx] = .reflectionRun(data)
    }

    /// Finishes a plan card nested in a reflection attempt and forgets it so the next trial gets a fresh card.
    /// A step still `.running` never reported completion (the plan aborted early) and is force-closed `.cancelled`.
    /// - Parameter reason: the trial transition that closed the card, for the log only.
    private func closeNestedPlanCard(reason: String) {
        guard planCardTrial != nil, planCardID != nil else { return }
        let trial = planCardTrial
        var forceClosed = 0
        mutatePlan { data in
            guard data.phase != .finished else { return }
            data.phase = .finished
            data.finishedAt = Date()
            for i in data.steps.indices where data.steps[i].status == .running {
                data.steps[i].status = .cancelled
                forceClosed += 1
            }
            // Was left nil, so the card carried no verdict at all. A plan that had to
            // force-close a step did not run to completion, whatever the trial's verdict.
            data.outcome = forceClosed > 0 ? .cancelled : .completed
        }
        if forceClosed > 0 {
            logger.warning("[CAPABILITY] Nested plan card for trial \(trial.map(String.init) ?? "?") closed on \(reason) with \(forceClosed) step(s) still running — recorded as cancelled, not completed; those steps never reported completion and their work is not in the result.")
        }
        planCardID = nil
        planCardTrial = nil
        activeStepID = nil
    }

    // MARK: - Helpers

    private static func isPlanCard(_ event: TimelineEvent, id: UUID) -> Bool {
        if case .planExecution(let d) = event { return d.id == id }
        return false
    }

    private static func step(from subtask: SubTask) -> PlanStepData {
        PlanStepData(id: subtask.id, title: subtask.description, toolHints: subtask.toolHints)
    }

    private static func stepStatus(for outcome: ExecutionOutcome?) -> PlanStepStatus {
        switch outcome {
        case .completedWithWarnings: return .warning
        case .failed, .timedOut:     return .failed
        case .cancelled:             return .cancelled
        case .completed, nil:        return .completed
        }
    }
}
