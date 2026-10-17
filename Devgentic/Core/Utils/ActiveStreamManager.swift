// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ActiveStreamManager.swift
//  Devgentic
//
//  Created by Raj Singh on 19/08/25.
//

import Foundation
import AppKit
import os


private let logger = DGLogger(category: "ActiveStreamManager")

/// Delegate protocol for RemoteMirrorService to observe stream lifecycle.
@MainActor
protocol ActiveStreamMirrorDelegate: AnyObject {
    /// - Parameter startedBy: which surface started this run.
    ///
    ///   ⚠️⚠️ PASSED EXPLICITLY BECAUSE IT CANNOT BE READ OFF `message`. The delegate is handed the
    ///   AGENT message, whose `messageSource` is still the `.localUI` default at this instant —
    ///   every attributing surface assigns it AFTER `startMessageStream` returns
    ///   (`MessagingCoordinator`, `SchedulerCoordinator`, `QuickAccessSessionViewModel`,
    ///   `OrbSessionController`). Two conformers already document having hit this. The USER
    ///   message carries the truth here and is stamped before the call, so it is read from there.
    ///
    ///   ⚠️ **Do NOT "fix" this by stamping `agentMessage.messageSource` earlier instead.**
    ///   `OrbAmbientRunWatcher` reads that field off the agent message at `didEndStream` and its
    ///   classification is calibrated to today's timing; moving the write changes what Orb
    ///   announces.
    ///
    ///   ⚠️ `.localUI` here means "not attributed", not "definitely typed by hand" — a new surface
    ///   that forgets to stamp lands here. A consumer deciding whether to send data OFF the machine
    ///   must therefore treat it as a refusal, never as permission.
    func activeStreamManager(_ manager: ActiveStreamManager, didStartStream message: ChatMessage, startedBy: MessageSource, for conversationID: UUID)
    func activeStreamManager(_ manager: ActiveStreamManager, didEndStream message: ChatMessage)
    /// A started run is WAITING for the local model, which another run holds (local inference
    /// coordinator). Called once, when it starts waiting; `notice` is the plain-language status.
    func activeStreamManager(_ manager: ActiveStreamManager, didQueueForLocalModel message: ChatMessage,
                             notice: String, startedBy: MessageSource, for conversationID: UUID)
}

extension ActiveStreamMirrorDelegate {
    /// Only the remote mirror has someone to tell; every other observer ignores it.
    func activeStreamManager(_ manager: ActiveStreamManager, didQueueForLocalModel message: ChatMessage,
                             notice: String, startedBy: MessageSource, for conversationID: UUID) {}
}

@Observable @MainActor
final class ActiveStreamManager {

    private(set) var activeStreams: [UUID: ChatMessage] = [:]

    /// Live assistant message id → the id of the user question it is answering. Written and
    /// cleared in lockstep with `activeStreams`; see `incompleteTurnIDs`.
    @ObservationIgnored private var liveRunQuestionIDs: [UUID: UUID] = [:]

    // MARK: - Dependencies
    @ObservationIgnored private var activeTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Conversation admission

    /// One run at a time, per conversation. See `ConversationAdmission` for the whole argument —
    /// briefly: two concurrent runs in one conversation were reachable and unguarded, because the
    /// only thing stopping them was the composer's send button greying out, and the scheduler, Orb
    /// and the ChatOps bridge never touch a button.
    ///
    /// ⚠️ The busy test is injected rather than owned by that type, so `activeStreams` stays the
    /// single source of "what is running" — the `streamingMessageID`/`streamingMessage` pair this
    /// dictionary already replaced is what a second copy of that state turns into.
    /// One LOCAL run at a time, across conversations — layer 2 beneath `admission`. Settable so tests
    /// can observe registration without the process-wide instance.
    @ObservationIgnored var inferenceCoordinator: LocalInferenceCoordinator = .shared

    @ObservationIgnored private lazy var admission = ConversationAdmission { [weak self] conversationID, messageID in
        guard let self else { return false }
        return Self.isConversationBusy(self.activeStreams, conversationID: conversationID, excluding: messageID)
    }

    /// Whether some OTHER run is live in `conversationID`.
    ///
    /// ⚠️ `excluding` IS THE WHOLE SUBJECT. A waiting run is already in `activeStreams` — it is
    /// registered before its task starts so Stop and the sidebar can see it — so without this every
    /// run would find ITSELF busy and park forever, and no conversation would ever run anything
    /// again.
    ///
    /// ⚠️ A pure static over the dictionary rather than a closure body, because the closure body
    /// was unreachable from tests: they inject their own `isBusy` to exercise the queue, so the
    /// REAL predicate had no coverage at all and mutation removing `excluding` survived.
    static func isConversationBusy(_ streams: [UUID: ChatMessage],
                                   conversationID: UUID,
                                   excluding messageID: UUID) -> Bool {
        streams.values.contains { $0.conversationId == conversationID && $0.id != messageID }
    }

    /// When each live run CLAIMED its stream. Written and removed in lockstep with
    /// `activeStreams` (the only two sites are the insert below and `finalizeMessage`), so it
    /// cannot outlive the run it describes.
    ///
    /// Needed because a run's start time is NOT `ChatMessage.timestamp`: Redo and Resume stream
    /// into a pre-existing message whose timestamp is hours old. `ForegroundRunResolver` uses this
    /// to break a tie deterministically when a conversation somehow holds two live runs.
    @ObservationIgnored private var streamStartedAt: [UUID: Date] = [:]
    @ObservationIgnored nonisolated(unsafe) private var permissionResolvedObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var clarificationResolvedObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var planReviewResolvedObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var gateResolvedObserver: Any?

    @ObservationIgnored private let persistenceService: ChatPersistenceProtocol

    /// [G1 Piece 1] Per-message timestamp of the last in-flight flush, used to rate-limit the
    /// token-path coalesced flush. Boundary flushes (tool start/finish, HITL park) pass
    /// `immediate: true` and bypass this. Cleared when the message finalizes to bound the map.
    @ObservationIgnored private var lastInFlightFlush: [UUID: Date] = [:]
    private static let inFlightFlushInterval: TimeInterval = 2.0
    @ObservationIgnored private let fileProcessorService: FileProcessorService
    @ObservationIgnored private let backendOrchestrationService: BackendOrchestrationService

    /// [D2] Multicast stream-lifecycle delegates. Each active ChatOps transport (Telegram/Discord/Slack)
    /// owns its own RemoteMirrorService and registers here. A single `weak var` let the last-started
    /// transport clobber the others, so only ONE actually mirrored. Weak refs so a torn-down service
    /// auto-clears.
    private struct WeakMirror { weak var delegate: ActiveStreamMirrorDelegate? }
    @ObservationIgnored private var mirrorDelegates: [WeakMirror] = []

    /// Registers a mirror delegate (idempotent; prunes any dead refs).
    func addMirrorDelegate(_ delegate: ActiveStreamMirrorDelegate) {
        mirrorDelegates.removeAll { $0.delegate == nil || $0.delegate === delegate }
        mirrorDelegates.append(WeakMirror(delegate: delegate))
    }

    /// Unregisters a mirror delegate (e.g. when a transport stops); also prunes dead refs.
    func removeMirrorDelegate(_ delegate: ActiveStreamMirrorDelegate) {
        mirrorDelegates.removeAll { $0.delegate == nil || $0.delegate === delegate }
    }

    /// The currently-live delegates (dead weak refs filtered out).
    private var liveMirrorDelegates: [ActiveStreamMirrorDelegate] {
        mirrorDelegates.compactMap { $0.delegate }
    }

    /// [HITL/P1] Unified pending-interaction queue, owned by MainApplicationViewModel and
    /// injected after init. P1 only holds the reference (no writers yet); P2 wires enqueue.
    @ObservationIgnored var interactionCenter: InteractionCenter?

    init(
        persistenceService: ChatPersistenceProtocol,
        fileProcessorService: FileProcessorService
    ) {
        self.persistenceService = persistenceService
        self.fileProcessorService = fileProcessorService
        self.backendOrchestrationService = BackendOrchestrationService(
            fileProcessorService: fileProcessorService
        )
        setupHITLResolvedObservers()
        logger.info("ActiveStreamManager initialized.")
    }

    deinit {
        if let observer = permissionResolvedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = clarificationResolvedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = planReviewResolvedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = gateResolvedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Cross-Surface HITL Sync

    /// Observes resolved notifications so the Mac UI clears stale banners
    /// when Telegram (or a timeout) handles the HITL interaction.
    private func setupHITLResolvedObservers() {
        permissionResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlPermissionResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                // [HITL/P5] InteractionCenter is the single source of truth — clear by operationID.
                if let operationID { self.interactionCenter?.resolve(operationID: operationID) }
                // [HITL/C1] Emit the resolution trace span (precise decision + wait duration).
                let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String ?? "resolved"
                self.emitHITLTraceSpan(operationID: operationID, outcome: outcome)
                // [HITL/C2] Stamp the durable audit row with the same outcome (covers chat/code/workflow incl. gates).
                if let operationID {
                    Task { await TraceRecorder.shared.recordHITLResolved(operationID: operationID.uuidString, outcome: outcome, resolvedAt: Date()) }
                }
                // Nudge the active stream's thinking island forward immediately (subsequent stream
                // events refine it) so the UI doesn't briefly look stuck on "waiting".
                guard let conversationID else { return }
                for (_, message) in self.activeStreams where message.conversationId == conversationID && message.isStreaming {
                    // Only nudge a message that was actually awaiting input — don't clobber a
                    // concurrent stream's accurate state in the same conversation.
                    if case .interaction = message.agentState {
                        message.agentState = .thinking(.reflecting)
                    }
                }
            }
        }

        clarificationResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlClarificationResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                if let operationID { self.interactionCenter?.resolve(operationID: operationID) }
                // [HITL/C1] Emit the resolution trace span (precise decision + wait duration).
                let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String ?? "resolved"
                self.emitHITLTraceSpan(operationID: operationID, outcome: outcome)
                // [HITL/C2] Stamp the durable audit row with the same outcome (covers chat/code/workflow incl. gates).
                if let operationID {
                    Task { await TraceRecorder.shared.recordHITLResolved(operationID: operationID.uuidString, outcome: outcome, resolvedAt: Date()) }
                }
                guard let conversationID else { return }
                for (_, message) in self.activeStreams where message.conversationId == conversationID && message.isStreaming {
                    // Only nudge a message that was actually awaiting input — don't clobber a
                    // concurrent stream's accurate state in the same conversation.
                    if case .interaction = message.agentState {
                        message.agentState = .thinking(.reflecting)
                    }
                }
            }
        }

        planReviewResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlPlanReviewResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                if let operationID { self.interactionCenter?.resolve(operationID: operationID) }
                // [HITL/C1] Emit the resolution trace span (precise decision + wait duration).
                let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String ?? "resolved"
                self.emitHITLTraceSpan(operationID: operationID, outcome: outcome)
                // [HITL/C2] Stamp the durable audit row with the same outcome (covers chat/code/workflow incl. gates).
                if let operationID {
                    Task { await TraceRecorder.shared.recordHITLResolved(operationID: operationID.uuidString, outcome: outcome, resolvedAt: Date()) }
                }
                guard let conversationID else { return }
                for (_, message) in self.activeStreams where message.conversationId == conversationID && message.isStreaming {
                    if case .interaction = message.agentState {
                        message.agentState = .thinking(.planning)
                    }
                }
            }
        }

        // [E1] Gate resolved (chosen option / cancelled) → clear banner + trace + audit, like the others.
        gateResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlGateResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                if let operationID { self.interactionCenter?.resolve(operationID: operationID) }
                // [HITL/C1] Emit the resolution trace span (chosen option / cancelled + wait duration).
                let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String ?? "resolved"
                self.emitHITLTraceSpan(operationID: operationID, outcome: outcome)
                // [HITL/C2] Stamp the durable audit row with the chosen option.
                if let operationID {
                    Task { await TraceRecorder.shared.recordHITLResolved(operationID: operationID.uuidString, outcome: outcome, resolvedAt: Date()) }
                }
                guard let conversationID else { return }
                for (_, message) in self.activeStreams where message.conversationId == conversationID && message.isStreaming {
                    if case .interaction = message.agentState {
                        message.agentState = .thinking(.reflecting)
                    }
                }
            }
        }
    }


    /// Ids belonging to a turn that is still being WRITTEN, and therefore must not appear in any
    /// run's history — every live assistant message plus the question it is answering — except
    /// `keeping`, the question the calling run is itself asking.
    ///
    /// ⚠️ WHY THE WHOLE TURN, not just the assistant row. Dropping a live reply while keeping its
    /// question makes that question the trailing unanswered message, and `pairTurns`' orphan
    /// handler then emits it as `wasCancelled: true` /
    /// "Agent never responded to this query" — a LOUDER falsehood than the one being fixed,
    /// because it also fires `renderTerminationElement`. An unfinished turn is simply not part of
    /// history yet; asserting nothing about it is the only honest option.
    ///
    /// ⚠️ WHY IT MUST BE APPLIED AFTER `resolve`, not by filtering `inMemory`. `flushInFlight`
    /// upserts the in-flight assistant row into the STORE at every tool boundary and on the first
    /// content flush, so the store returns it within ~100 ms regardless of what the caller passes
    /// in memory. Filtering only the in-memory side would not remove the row — it would swap the
    /// live copy for a staler disk copy, since `BackendHistoryResolver.merge` lets in-memory win.
    ///
    /// ⚠️ AND WHY NOT `lifecycleState`. Nothing resets a persisted `.streaming` row at launch, so
    /// a force-quit during a long agent run leaves one on disk indefinitely. Filtering the store
    /// on lifecycle would erase every crash-interrupted turn — including completed tool work —
    /// from all future context in that conversation, which is far more common than this race.
    /// Keying on ids of runs that are live IN THIS PROCESS cannot make that mistake.
    ///
    /// `nonisolated static` over plain values so the rule is testable with no manager.
    nonisolated static func incompleteTurnIDs(
        liveRuns: [UUID: UUID],
        keeping keepID: UUID?
    ) -> Set<UUID> {
        var ids: Set<UUID> = []
        for (assistantID, questionID) in liveRuns {
            ids.insert(assistantID)
            ids.insert(questionID)
        }
        if let keepID { ids.remove(keepID) }
        return ids
    }

    /// ⚠️ THE SINGLE SOURCE both consumers of history must use.
    ///
    /// `BackendHistoryResolver`'s header states the rule this upholds: "There are two consumers
    /// and they MUST agree: the request path, which sends it, and the context gauge, which sizes
    /// it." Sharing the resolver was necessary but not sufficient — once the request began OMITTING
    /// in-flight turns, a gauge that still counted them was measuring a payload that would never
    /// ship. Both now ask this.
    ///
    /// - Parameter keeping: the question the calling run is itself asking, which is never omitted.
    func incompleteTurnIDs(keeping keepID: UUID? = nil) -> Set<UUID> {
        Self.incompleteTurnIDs(liveRuns: liveRunQuestionIDs, keeping: keepID)
    }

    /// The live ASSISTANT rows, and nothing else — the context gauge's omission.
    ///
    /// ⚠️ NOT `incompleteTurnIDs()`. The two consumers must agree about what the next request
    /// CARRIES, not about which ids are in flight, and on that question they differ by one row.
    /// The request path omits a whole turn because a HALF-WRITTEN turn poisons `pairTurns` — the
    /// question would be reported as answered with nothing. The gauge is not building a
    /// transcript; it is pricing tokens, and the question it would drop is a settled, persisted
    /// row that the next request certainly carries.
    ///
    /// Using the request path's set here made the ring FALL at the moment of send — the just-sent
    /// question was subtracted from the size of a request that had just included it — and jump
    /// back when streaming ended. The reply is still omitted: `flushInFlight` upserts the partial
    /// assistant row into the store within ~100 ms, and pricing a half-written answer makes the
    /// ring climb through a run and then drop as the row is replaced.
    func liveReplyIDs() -> Set<UUID> {
        Set(liveRunQuestionIDs.keys)
    }

    /// The history a run will actually carry, OLDEST-FIRST — derived from the store and the
    /// message being sent, rather than accepted from the surface that started the run.
    ///
    /// ⚠️ THE ONLY in-memory input is `[userMessage]` — the message racing its own persist on the
    /// surfaces that do not await it. In-flight streams are NOT passed in: `flushInFlight` upserts
    /// the live assistant row into the STORE within ~100 ms, so they arrive from the resolver on
    /// their own, and `omitting` then REMOVES them. Live-run state reaches this method only as
    /// that subtraction — never as an added source. (An earlier version of this comment said the
    /// method "holds both the message being sent and any in-flight streams", and a still earlier
    /// one said in-flight rows are "never in the store while running". Both were false, and
    /// `DerivedHistoryContractTests` has a scan that fails the build if `inMemory:` grows again.)
    /// The UI's `currentChatMessages` was over-supply — passing it is what let QuickAccess ship
    /// its 20-message pagination window as model history.
    ///
    /// - Parameter omitting: ids of messages belonging to a turn still being written, from
    ///   `incompleteTurnIDs`. Applied AFTER the resolve, for the `flushInFlight` reason above —
    ///   filtering the in-memory side alone removes nothing. The current `userMessage` is never
    ///   omitted, whatever the set says.
    /// - Parameter before: the assistant message being rewritten (regenerate / resume). When set,
    ///   the run replays only what preceded it, via `MessagingCoordinator.historySlice` — reused
    ///   rather than reimplemented so both callers keep one definition of "before".
    ///
    ///   ⚠️ ON THIS PATH THE CUT IS ALWAYS BY TIMESTAMP, never by identity, and the slice's own
    ///   doc describes identity as the primary branch because its OTHER caller
    ///   (`resolveBackendHistory(before:)`) does reach it. Here the boundary is the live assistant
    ///   row, so its id is always in `omitting` and `settled` never contains it — `firstIndex`
    ///   cannot match. The two cuts differ only for a row whose timestamp exactly TIES the
    ///   boundary's, which nothing in this codebase is known to produce (timestamps are assigned
    ///   once at init, and compaction checkpoints are deliberately offset by +0.001s). Treat the
    ///   identity branch as unreachable from here rather than as the normal case.
    ///
    /// `static` over plain values so the derivation is testable with no manager and no view model.
    /// The text conversation memory is searched with: what the user actually SAID (the
    /// persisted row), not the model-facing query. `promptOverride` decorates the latter — Orb
    /// appends a ~300-char spoken-style hint, a background-task wake sends its own prompt — and
    /// that decoration swamped MiniLM's 128-token window and switched BM25 fusion on for the
    /// hint's own words (RAG-19). Falls back to the model query when the row has no text (an
    /// image-only turn), so retrieval never runs on an empty string it did not run on before.
    static func retrievalQuery(for userMessage: ChatMessage, modelQuery: String) -> String {
        guard let said = userMessage.content.textContent,
              !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return modelQuery }
        return said
    }

    static func deriveHistory(
        userMessage: ChatMessage,
        omitting: Set<UUID> = [],
        before boundary: ChatMessage?,
        persistence: ChatPersistenceProtocol
    ) async -> [ChatMessage] {
        let resolved = await BackendHistoryResolver.resolve(
            conversationID: userMessage.conversationId,
            inMemory: [userMessage],
            persistence: persistence
        )
        let settled = omitting.isEmpty
            ? resolved.history
            : resolved.history.filter { $0.id == userMessage.id || !omitting.contains($0.id) }
        let final = boundary.map { MessagingCoordinator.historySlice(before: $0, in: settled) } ?? settled

        // ⚠️ THE COMPOSITION LINE. `MessagingCoordinator.resolveBackendHistory` used to emit this on
        // every send; when the resolve moved in here the request path went SILENT — no surface
        // logged what the model was actually given. Restored at the one place every run passes
        // through, so a field log can answer "what history did this turn carry, and what was left
        // out?" without reproducing.
        let omittedCount = resolved.history.count - settled.count
        let cutCount = settled.count - final.count
        var notes: [String] = []
        if resolved.capHit {
            notes.append("CAP HIT (\(BackendHistoryResolver.messageLimit)) → older turns are omitted from direct context and rely on RAG retrieval")
        }
        if omittedCount > 0 {
            notes.append("\(omittedCount) row(s) omitted as an UNFINISHED TURN (a live run's reply and the question it is answering) → the model is told nothing about a turn still being written, deliberately")
        }
        if cutCount > 0 {
            notes.append("\(cutCount) row(s) cut at or after the message being rewritten → regenerate/resume replays only what preceded it. The cut is by TIMESTAMP (strictly-earlier survives), so a row that TIES the boundary is cut too")
        }
        logger.info("[HISTORY] Derived \(final.count) message(s) for the request — stored: \(resolved.storedCount), source: \(userMessage.messageSource.rawValue), conversationID: \(userMessage.conversationId.uuidString.prefix(8)), messageID: \(userMessage.id.uuidString.prefix(8))\(notes.isEmpty ? "" : " — " + notes.joined(separator: "; "))")
        return final
    }

    /// Index of the first message that is OLDER than the one before it, or nil if `history` is
    /// oldest-first. The check behind the `[HISTORY]` guard-rail in `startMessageStream`.
    ///
    /// Equal timestamps do NOT trip it: a tie is unordered, not descending, and
    /// `BackendHistoryResolver.merge` can legitimately produce one (it sorts by timestamp over a
    /// dictionary's values). Only a strict inversion is evidence a caller built history backwards.
    ///
    /// `nonisolated static` over plain values so the rule is unit-testable with no manager, no
    /// persistence and no view model — the `RunAdmissionPolicy` shape.
    nonisolated static func firstDescendingPair(in history: [ChatMessage]) -> Int? {
        guard history.count > 1 else { return nil }
        for index in 1..<history.count where history[index].timestamp < history[index - 1].timestamp {
            return index
        }
        return nil
    }

    @discardableResult
    func startMessageStream(
        withConfig config: BackendRequestConfig,
        userMessage: ChatMessage,
        promptOverride: String? = nil,
        files: [FileSystemItem],
        updating existingMessage: ChatMessage? = nil,
        workflowExecutionState: WorkflowExecutionState? = nil,
        resumeState: TimelineReconstruction? = nil,
        onComplete: @escaping () -> Void
    ) -> ChatMessage {

        // Both derived from the message rather than passed alongside it, so they cannot disagree
        // with it. `conversationID` used to be a separate argument that every caller had to keep
        // in sync with the message it was sending.
        let conversationID = userMessage.conversationId
        let userQuery = promptOverride ?? userMessage.content.textContent ?? ""

        // ⚠️ A Code run takes ITS CONVERSATION'S project, not whichever one is open. Every path in —
        // composer, background-task wake, scheduler, resume, Orb, QuickAccess — comes through here,
        // which is why this is the one place it is done. A no-op for composer sends, whose
        // conversation is always bound to the open folder. See `CodeSessionManager.profile(_:forConversationProject:)`.
        let config = config.profile.profileType == .code
            ? BackendRequestConfig(profile: CodeSessionManager.profile(
                config.profile,
                forConversationProject: persistenceService.getConversation(withId: conversationID)?.projectPath))
            : config
        
        // ⚠️ GUARD-RAIL: a workflow profile started without workflow bookkeeping.
        //
        // Six of the seven callers of this method used to do exactly that. The run still
        // EXECUTES, which is why it went unnoticed — but with no `WorkflowExecutionState` there is
        // no run record (no stub, no freeze, no per-node timelines — that detail lives only in
        // the state and is never captured), HITL attributes to `.chat` instead of `.workflow`
        // (`enqueueHITL` keys on `workflowState != nil`), and the capability-card router stays on
        // even though parallel nodes interleave segments it cannot separate.
        //
        // `WorkflowRunBootstrap.begin(...)` is the fix; this line exists because a helper can be
        // forgotten by the NEXT new call site and a loud log cannot.
        if config.profile.profileType == .workflow && workflowExecutionState == nil {
            logger.error("""
                [WF_RUN] ⚠️ Workflow '\(config.profile.displayName)' (\(config.profile.id)) started \
                with NO WorkflowExecutionState — conv \(conversationID). CONSEQUENCE: this run \
                leaves no run record (nothing in run history, the run picker or the badge; per-node \
                timelines are never captured), any HITL it raises is attributed to the CHAT \
                interface instead of the workflow view, and capability-card routing stays enabled. \
                The run itself will execute normally. FIX: call WorkflowRunBootstrap.begin(...) at \
                this call site and pass its `state` + call `finalize()` in onComplete.
                """)
        }

        let agentMessage: ChatMessage
        let isRegeneration = existingMessage != nil

        if let messageToUpdate = existingMessage {
            agentMessage = messageToUpdate
            if resumeState != nil {
                // [ASM-3] A resumed run RE-GENERATES the assistant turn from the
                // reconstructed history — it does not continue the interrupted text
                // mid-sentence. Streaming into the old variant appended the new answer
                // onto the stale partial ("…partial sentenceHere is the full answer…").
                // Clear the streamed text; the timeline (tool rows, cards) survives —
                // resumeRun already sanitized it.
                let staleChars = agentMessage.currentAgentContent?.textContent?.count
                    ?? agentMessage.content.textContent?.count ?? 0
                if let agentResponse = agentMessage.agentResponse,
                   agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                    agentMessage.agentResponse?.variants[agentResponse.selectedVariantIndex].content = .markdownText("")
                }
                agentMessage.content = .markdownText("")
                agentMessage.invalidateMarkdownCache()
                logger.notice("🚀 [STREAM_RESUME] Resuming message \(agentMessage.id.uuidString) — cleared \(staleChars) chars of interrupted partial prose before re-generation (ASM-3).")
            } else {
                logger.notice("🚀 [STREAM_REGENERATE] Updating message \(agentMessage.id.uuidString) in conversation \(conversationID.uuidString).")
            }
        } else {
            agentMessage = ChatMessage(
                conversationId: conversationID,
                sender: .agent,
                content: .markdownText(""),
                isStreaming: true,
                backendEntityId: config.profile.id
            )
            agentMessage.profileType = config.profile.profileType
            // ⚠️ Reads `messageSource` off the USER's message, which every surface must set BEFORE
            // calling this — `.orb`, `.quickAccess`, `.scheduled`, the ChatOps sources, else the
            // `.localUI` default for a typed send. The scheduler set it only on the AGENT message
            // until 2026-09-07, so scheduled runs reported `localUI` here; if a new surface appears
            // and forgets, this line under-reports rather than lying loudly, so treat `localUI` on a
            // run you did not type as a missing attribution rather than proof of a manual send.
            logger.notice("🚀 [STREAM_START] Created message \(agentMessage.id.uuidString) for conversation \(conversationID.uuidString) — started by \(userMessage.messageSource.rawValue), profile '\(config.profile.displayName)' (\(config.profile.profileType.rawValue))\(promptOverride != nil ? ", model-facing query DIFFERS from the displayed message (promptOverride)" : "").")
        }

        // [G1 Piece 1] Mark the run in-flight and stamp the model identity that's about to run.
        // The lifecycle marker makes an interrupted (force-quit / crash) run distinguishable from a
        // finished one after restart; the run-identity stamp records which model actually produced
        // this message — the resume-safety guard plus an honest "which model ran" UI label even
        // after the originating profile is later edited.
        agentMessage.lifecycleState = .streaming
        if let llm = config.profile.resolvedLLMConfig {
            agentMessage.apiProvider = llm.apiProvider.rawValue
            agentMessage.modelName = llm.modelName
            agentMessage.modelDialect = llm.modelDialect.rawValue
        }

        activeStreams[agentMessage.id] = agentMessage
        // The question this run is answering, recorded from the caller rather than inferred.
        // `ChatMessage` has no parent link, so without this the only way to find a live reply's
        // question would be POSITION or TIMESTAMP — the identity-by-inference class this whole
        // change set removes. See `incompleteTurnIDs`.
        liveRunQuestionIDs[agentMessage.id] = userMessage.id
        streamStartedAt[agentMessage.id] = Date()
        for delegate in liveMirrorDelegates {
            // ⚠️ `userMessage.messageSource`, not `agentMessage`'s — see the protocol's own note.
            delegate.activeStreamManager(self, didStartStream: agentMessage,
                                         startedBy: userMessage.messageSource, for: conversationID)
        }

        // Defer initial state mutations to the next run loop tick.
        // This prevents "Modifying state during view update" warnings when the returned
        // ChatMessage is immediately assigned to SwiftUI state within a view update cycle.
        Task { @MainActor in
            agentMessage.agentState = .thinking(.reasoning)
        }
        
        // ⚠️ THE RUN'S ORIGIN TRAVELS WITH THE RUN. Bound once, here, so no surface can forget it —
        // see `WorkflowRunAttendance.origin` for the grant that crossed a surface boundary without it.
        // ⚠️ Bound around the Task's CREATION, not inside its body: an unstructured `Task {}`
        // inherits the task-local values of the context that creates it, which is the same mechanism
        // `$hasRemoteResponder` and `$isAttended` already rely on at their binding site.
        //
        // ⚠️ A WOKEN RUN IS UNATTENDED BY CONSTRUCTION, and binding that HERE — rather than at
        // whatever eventually triggers one — is the same argument `$origin` makes just above: a
        // surface cannot forget what it never had to remember. `.backgroundTask` exists only for a
        // run that a FINISHED PROCESS started. Nobody typed it and nobody is watching.
        //
        // ⚠️⚠️ NOT COSMETIC. `SessionToolApprovals.isAllowed` reads `canReachAHuman` off this
        // before serving a standing "Allow for this chat" grant. Left at its `true` default, a build
        // finishing overnight would spend approvals the user granted while sitting at the keyboard —
        // and the per-tool grant is keyed on `(conversation, node)` with NO surface, so
        // `MessageSource.backgroundTask` alone does not close it. `ToolExecutionLoop`'s two arms
        // (WF-SE11) key on the same predicate: with nobody reachable, `ask_user` and a tool
        // confirmation are refused with an honest observation instead of parking until a deadline
        // cancels the run.
        //
        // ⚠️ ADDITIVE ON PURPOSE. Every other source re-binds whatever the CALLER already bound, so
        // this cannot contradict ChatOps (`isAttended = false` AND `hasRemoteResponder = true`) or
        // `SchedulerCoordinator`. Deriving attendance from the source for ALL sources was the
        // obvious version and is wrong: it would have flipped a ChatOps run back to attended and
        // deleted the Router's first-match behaviour (WF-EX5), which exists because an arbitration
        // park there has no deadline to end it.
        let attended = userMessage.messageSource == .backgroundTask
            ? false
            : WorkflowRunAttendance.isAttended
        // ⚠️ THE UNATTENDED CASE IS SAID OUT LOUD; the attended one is not, so this is a signal
        // rather than noise on every send. Three behaviours hang off this value and all three are
        // silent refusals — a standing grant not served, `ask_user` refused, a tool confirmation
        // refused — so without this line an unattended run's behaviour looks like a bug.
        if !attended {
            logger.notice("[ATTENDANCE] Run \(agentMessage.id.uuidString.prefix(8)) in conversation \(conversationID.uuidString.prefix(8)) is UNATTENDED (started by \(userMessage.messageSource.rawValue), remote responder: \(WorkflowRunAttendance.hasRemoteResponder)). CONSEQUENCE: standing 'allow for this chat' grants are NOT served to it, and ask_user plus any tool confirmation are refused with an honest observation instead of parking for an answer nobody will give.")
        }
        // ⚠️ The run's identity travels with it for the same reason its origin does: the local
        // providers report which run touched a model through `LocalInferenceScope.runID`, read deep
        // inside orchestration where nothing else names the run.
        let streamTask = WorkflowRunAttendance.$isAttended.withValue(attended) {
            WorkflowRunAttendance.$origin.withValue(userMessage.messageSource) {
            LocalInferenceScope.$runID.withValue(agentMessage.id) {
            Task { [weak self] in
            guard let self = self else { return }

            // ⚠️ ONE RUN PER CONVERSATION, enforced HERE because this is the send path's single
            // chokepoint — all seven call sites are covered by one line, including any future one.
            // The task is created (so Stop and `activeTasks` work immediately) but does no work
            // until the conversation is free. See `admissionQueue`.
            // The wait behind this conversation's own run is credited to the run's time bounds like a
            // wait for the local model — a scheduled run's deadline must not run out in line. Only
            // when a bound is open (a scheduled run's): otherwise there is nothing to credit.
            let admissionCredit: UUID? = ParkScope.chain.isEmpty ? nil : UUID()
            if let admissionCredit { await ExecutionSuspensionService.shared.beginQueueWait(admissionCredit) }
            let waited = await self.admission.awaitTurn(
                conversationID: conversationID, messageID: agentMessage.id,
                // ⚠️ Said on screen, not just in the log. A queued run otherwise shows the ordinary
                // thinking indicator, so a ChatOps message sent while the user is typing locally
                // looks like the app has stalled rather than like it is second in line.
                onWait: {
                    agentMessage.agentState = .thinking(.queued)
                    self.conversationQueueBegan(agentMessage, conversationID: conversationID)
                })
            if let admissionCredit { await ExecutionSuspensionService.shared.endQueueWait(admissionCredit) }
            if waited {
                agentMessage.agentState = .thinking(.reasoning)
                self.conversationQueueEnded(agentMessage, conversationID: conversationID)
            }
            if Task.isCancelled {
                logger.info("[ADMISSION] Run \(agentMessage.id.uuidString.prefix(8)) was cancelled while waiting for conversation \(conversationID.uuidString.prefix(8)).")
                Self.markWithdrawnBeforeStart(agentMessage, workflow: workflowExecutionState)
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)
                // ⚠️ The SAME two lines every other exit of this task ends with. This early return
                // used to skip them, so a run cancelled while QUEUED never called `onComplete` —
                // and `SchedulerCoordinator.sendScheduledMessage` waits on exactly that callback.
                // Its 600 s deadline cancels a queued scheduled run, the callback never came, the
                // task stayed pinned in `runningTaskIDs`, and every later fire was skipped as
                // "already running" until relaunch; the task also leaked in `activeTasks`
                // (Timeout inventory D-12, 2026-09-26).
                self.removeTask(for: agentMessage.id)
                onComplete()
                return
            }

            // ⚠️ LAYER 2, AFTER layer 1 — never before. The coordinator decides across
            // conversations; a run still queued behind its OWN conversation is not competing for
            // the machine yet, and registering it early would put it in the local queue twice over.
            // A local run WAITS here while another local run holds the lock (cloud-only runs never
            // do). Released in `finalizeMessage`, beside `admitNext`.
            // The observer covers EVERY wait of this run: this one, and any later one when the run
            // takes the lock back after a HITL answer (phase 4).
            let startedBy = userMessage.messageSource
            let localAcquire = await self.inferenceCoordinator.acquire(
                InferenceRunManifest.build(
                    runID: agentMessage.id,
                    conversationID: conversationID,
                    profile: config.profile,
                    source: userMessage.messageSource,
                    attended: attended,
                    isRegeneration: isRegeneration && resumeState == nil,
                    isResume: resumeState != nil),
                observer: LocalWaitObserver(
                    onHold: { [weak self] position, _ in
                        self?.localWaitBegan(agentMessage, conversationID: conversationID,
                                             startedBy: startedBy, position: position)
                    },
                    onWaitEnded: { [weak self] _ in
                        self?.localWaitEnded(agentMessage, conversationID: conversationID)
                    },
                    onConfirmationNeeded: { [weak self] concerns, deadline in
                        self?.localConfirmationNeeded(agentMessage, conversationID: conversationID,
                                                      concerns: concerns, deadline: deadline)
                    },
                    onConfirmed: { [weak self] in
                        self?.localConfirmed(agentMessage, conversationID: conversationID)
                    },
                    onPositionChanged: { [weak self] position, _ in
                        self?.localPositionChanged(agentMessage, conversationID: conversationID, position: position)
                    }))
            var localQueueWait: TimeInterval = 0
            switch localAcquire {
            case .admitted(let waited):
                localQueueWait = waited
            case .cancelled:
                logger.info("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) was cancelled while waiting for the local model.")
                Self.markWithdrawnBeforeStart(agentMessage, workflow: workflowExecutionState)
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)
                // The same two lines every other exit of this task ends with — see the
                // conversation-admission early return above for what skipping them cost.
                self.removeTask(for: agentMessage.id)
                onComplete()
                return
            case .denied(let reason):
                let refusal = LocalInferenceRefusal(reason: reason)
                workflowExecutionState?.handleError(refusal.localizedDescription)
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: refusal)
                self.removeTask(for: agentMessage.id)
                onComplete()
                return
            }

            // ⚠️ THE GLOBAL TIME CEILING (local inference coordinator, phase 5) — the outermost limit on
            // every run, opened HERE, at admission, so time spent in either queue never counts. COMPUTE
            // time: the ceiling's scope joins the run's owner chain, so HITL parks and local-model waits
            // anywhere in the run pause it (owner-chain credit). Its frame is the outermost
            // `ExecutionBudget`, so a turn, node or tool limit inside is shortened to fit and fires
            // first, with its own honest outcome.
            let ceilingScope = UUID()
            let ceiling = LocalInferenceCoordinator.globalCeiling
            let ceilingFrame: ExecutionBudget.Frame? = if let ceiling {
                await ExecutionBudget.frame(
                    owner: "the \(ToolExecutionMediator.describe(ceiling)) limit on any run",
                    limit: ceiling, scope: ceilingScope)
            } else { nil }
            if let ceiling {
                logger.debug("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) — global ceiling \(ToolExecutionMediator.describe(ceiling)) of compute time opened (scope \(ceilingScope.uuidString.prefix(8))).")
            } else {
                logger.info("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) has NO global ceiling (Settings → General → Maximum Run Time is Off). CONSEQUENCE: only its own profile, node and tool limits bound it.")
            }
            let ceilingTask: Task<Void, Never>? = ceiling.map { limit in
                Task { @MainActor [weak self] in
                    await self?.enforceGlobalCeiling(limit, scope: ceilingScope, on: agentMessage)
                }
            }
            await ParkScope.withScope(ceilingScope, conversationID: conversationID) {
            await ExecutionBudget.$frames.withValue(ExecutionBudget.frames + (ceilingFrame.map { [$0] } ?? [])) {

            // Structured Plan & Execute / Reflexion cards (chat + code agents only).
            // Workflow runs keep the legacy flat milestone chips: their capability
            // events carry no node attribution, and parallel workflow nodes would
            // interleave segments the ordering-based router can't separate.
            let capabilityRouter = CapabilityCardRouter(message: agentMessage)
            let capabilityCardsEnabled = (workflowExecutionState == nil)

            do {
                let traceContext = TraceContext(profile: config.profile, messageID: agentMessage.id)
                agentMessage.traceID = traceContext.traceID
                // The wait happened before this trace existed, so it is recorded as a metric on it.
                if localQueueWait > 0 {
                    let waitedMs = Int(localQueueWait * 1000)
                    Task { await TraceRecorder.shared.emitMetric(span: traceContext, key: "local_queue_wait", valueMs: waitedMs) }
                }
                // Run-Report Phase 5: the workflow run record carries the same join key,
                // so run history and the trace store stop being unlinkable (old Seam 4).
                workflowExecutionState?.traceID = traceContext.traceID

                let profileType = config.profile.profileType.rawValue
                // ⚠️ EVERY turn still being written is excluded — this run's own (its placeholder is
                // registered before this task starts, and is EMPTY here) and any CONCURRENT run's.
                // Concurrency in one conversation is reachable: the scheduler, Orb and the
                // ChatOps bridge carry no admission check. Including an unfinished turn makes
                // `pairTurns` report the question as answered with nothing —
                // "(Terminated by user before any tools ran)" — while the run is still going.
                let history = await Self.deriveHistory(
                    userMessage: userMessage,
                    omitting: self.incompleteTurnIDs(keeping: userMessage.id),
                    before: existingMessage,
                    persistence: self.persistenceService
                )

                logger.info("[TRACE_INIT] traceID: \(traceContext.traceID), spanID: \(traceContext.spanID), profileType: \(profileType), messageID: \(agentMessage.id.uuidString.prefix(8)), conversationID: \(conversationID.uuidString.prefix(8))")

                Task {
                    await TraceRecorder.shared.beginTrace(
                        context: traceContext,
                        conversationID: conversationID,
                        messageID: agentMessage.id,
                        // The resolved model for single-model profiles (bot/agent/code/imageGen);
                        // nil for workflows, which have no single model. A label for the trace:
                        // cost no longer prices against it — each call is priced at its own model
                        // when its usage is read (`ModelPriceList`), and `recordTokenUsage` stores
                        // their sum. (Passing nil here was once why `traces.estimatedCostUSD` had
                        // been NULL on every run; with per-call pricing, workflows get a cost too.)
                        modelName: config.profile.resolvedLLMConfig?.modelName
                    )

                    // Phase B: capture the complete request configuration so the
                    // Report Inspector can show exactly which profile/model/tools/
                    // capabilities/retry-policy/hardware were in effect. Writes one
                    // row to `trace_configs` cascading on `traces.traceID`.
                    //
                    // TODO: pass `codeMemoryContent` from MainApplicationViewModel
                    // (CodeSystemPrompt.projectKnowledge) for a
                    // complete Code-mode snapshot. Current capture records only
                    // the project path — memory length/hash stay nil.
                    // ⚠️ The LIVE-detected capability, not the stored copy, so a trace records the
                    // tool-calling mode the run actually used (`LiveModelDetection`).
                    let snapshot = TraceConfigSnapshot.capture(
                        traceID: traceContext.traceID,
                        config: BackendRequestConfig(profile: await LiveModelDetection.resolving(config.profile)),
                        historyTurnCount: history.count,
                        files: files,
                        codeMemoryContent: nil
                    )
                    await TraceRecorder.shared.captureConfigSnapshot(snapshot)
                }

                // [M6] Log the query LENGTH, not its text — the raw prompt is user content and this
                // line goes to the unified OS log (readable via Console / sysdiagnose). traceID +
                // history/file counts are enough to correlate the handoff.
                // ⚠️ DERIVED, never accepted. Callers no longer supply history, so a surface
                // CANNOT hand over a pagination window, a private transcript, or a descending
                // store dump — the three shapes that produced `architecture_readme.md` §7
                // invariant #8's only live violation. This is the same move
                // `LLM_Execution_Concurrency_Design.md:55-59` made for `streamingMessageID`:
                // delete the storage, derive the value, and the wrong call becomes
                // unrepresentable rather than guarded against.

                // Retained as a SELF-check, not a caller check. Nothing outside can get this
                // wrong any more, so a trip here means the resolver itself regressed.
                if let disorder = Self.firstDescendingPair(in: history) {
                    logger.error("[HISTORY] ⚠️ Derived history is not oldest-first — conv \(conversationID.uuidString.prefix(8)), \(history.count) message(s), first out-of-order pair at index \(disorder). CONSEQUENCE: `pairTurns` walks forward, so every reply is matched to the WRONG question, the newest agent turn is dropped, and the oldest user message is emitted as an orphan marked \"Agent never responded to this query\". Callers no longer supply history, so this is a regression in BackendHistoryResolver.merge, not a caller bug.")
                }

                logger.info("[STREAM_HANDOFF] Passing to BackendOrchestrationService — traceID: \(traceContext.traceID), query: \(userQuery.count) chars, history: \(history.count) msgs, files: \(files.count)")

                let stream = self.backendOrchestrationService.streamMessage(
                    withConfig: config,
                    conversationID: conversationID,
                    userQuery: userQuery,
                    currentUserMessageID: userMessage.id,
                    retrievalQuery: Self.retrievalQuery(for: userMessage, modelQuery: userQuery),
                    // A Redo/Resume regenerates `existingMessage`: memory from it onward is the
                    // rejected answer and the conversation's "future" (RAG-4).
                    regenerating: existingMessage.map { RegenerationBoundary(messageID: $0.id, timestamp: $0.timestamp) },
                    history: history,
                    files: files,
                    context: traceContext,
                    resumeState: resumeState,
                    onTraceUpdate: { _ in } // Trace logs are handled by events now
                )

                logger.info("[STREAM_LISTEN] Awaiting events — traceID: \(traceContext.traceID), messageID: \(agentMessage.id.uuidString.prefix(8))")
                
                var tokenBuffer = ""
                var lastUpdateTime = Date()
                var tokensReceivedInWindow = 0
                var adaptiveInterval: TimeInterval = 0.1 // Start with default
                // [WF-RU1] The last `.error` event's message — the richest failure text the
                // stream produced. Consulted ONLY at stream end, and only when the engine's
                // terminal outcome is `.failed` (see the workflow settle there).
                var lastErrorEventMessage: String?
                // The bubble's content from before a `.draftText` preview started, or nil when no
                // draft is showing. Restored when the draft is withdrawn, and before the first
                // `.content` appends — so a draft is REPLACED by the answer, never duplicated by it.
                var draftBaseline: MessageContent?

                for try await event in stream {
                    try Task.checkCancellation()

                    switch event {
                    case .thought(let thoughtText, let id, let sourceNodeID):
                        // 1. Handle Thoughts (Update Headline + Append to History using structured ID)
                        agentMessage.agentState = .thinking(.reasoning)
                        let thoughtEvent = TimelineEvent.thought(id: id, text: thoughtText)
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(thoughtEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] Thought → node timeline [\(nodeID)], count=\(wfState.nodeTimelines[nodeID]?.count ?? 0)")
                        } else if !(capabilityCardsEnabled && capabilityRouter.route(thoughtEvent)) {
                            agentMessage.appendTimelineEvent(thoughtEvent)
                        }

                    case .reasoning(let text, let id, let sourceNodeID):
                        // Model-authored monologue (step.reasoning). Same UI handling as
                        // .thought for now (shared ThinkingDynamicIsland + timeline rendering),
                        // but persisted as .reasoning so downstream consumers can distinguish.
                        agentMessage.agentState = .thinking(.reasoning)
                        let reasoningEvent = TimelineEvent.reasoning(id: id, text: text)
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(reasoningEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] Reasoning → node timeline [\(nodeID)], count=\(wfState.nodeTimelines[nodeID]?.count ?? 0)")
                        } else if !(capabilityCardsEnabled && capabilityRouter.route(reasoningEvent)) {
                            agentMessage.appendTimelineEvent(reasoningEvent)
                        }

                    case .toolCall(let name, let params, let sourceNodeID, let stepId):
                        agentMessage.agentState = .acting(.tool(name: name))
                        // Live agent tabs (badge-only): announce a STARTING file write so
                        // the Code Viewer can open/update a background tab.
                        if let payload = AgentLiveWriteEvent.began(toolName: name, params: params, conversationID: conversationID) {
                            NotificationCenter.default.post(name: AgentLiveWriteEvent.began, object: nil,
                                                            userInfo: [AgentLiveWriteEvent.payloadKey: payload])
                        }
                        let toolEvent = TimelineEvent.toolExecution(
                            ToolExecutionData(id: UUID(), name: name, params: params, output: nil, isSuccess: nil, isExecuting: true, stepId: stepId)
                        )
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(toolEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] ToolCall '\(name)' → node timeline [\(nodeID)], count=\(wfState.nodeTimelines[nodeID]?.count ?? 0)")
                        } else if !(capabilityCardsEnabled && capabilityRouter.route(toolEvent)) {
                            agentMessage.appendTimelineEvent(toolEvent)
                        }
                        // [G1 Piece 1] Boundary flush — a tool just started; persist so an interrupted
                        // run shows it ran (and, when this is the parked tool, that it was in flight).
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)

                    // [HITL] Permission request → unified InteractionCenter (single source of truth).
                    // Node attribution rides in the banner via the origin; the thinking-island
                    // headline stays generic (the banner carries which node/agent is asking).
                    case .requestConfirmation(let toolName, let params, let operationID, let sourceNodeID, let sourceNodeName):
                        agentMessage.agentState = .interaction(.permission(toolName: toolName))
                        // [G1 Piece 1] Park marker + the operationID join key, flushed immediately:
                        // a run parked on approval can sit indefinitely, so this is the prime
                        // restart case. Resume (Piece 2) re-raises the HITL from this persisted opID.
                        agentMessage.lifecycleState = .parkedHITL(operationID: operationID)
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        // [WF-SE3] Provenance-aware tier: native names use the native map, MCP
                        // tools use their server-declared annotations (labelled as such), and a
                        // name collision floors at .moderate — see ToolRiskResolver.
                        let riskResolution = ToolRiskResolver.resolve(toolName: toolName)
                        await self.enqueueHITL(
                            operationID: operationID,
                            kind: .toolConfirmation(PendingToolConfirmation(
                                id: operationID,
                                toolName: toolName,
                                params: params,
                                risk: riskResolution.risk,
                                arguments: JSONValue.parseStructured(params),
                                riskIsServerDeclared: riskResolution.serverDeclared
                            )),
                            conversationID: conversationID,
                            profileType: config.profile.profileType,
                            workflowState: workflowExecutionState,
                            sourceNodeID: sourceNodeID,
                            sourceNodeName: sourceNodeName,
                            profileID: config.profile.id,
                            traceContext: traceContext
                        )

                    // [ASK_USER] Clarification request → unified InteractionCenter.
                    case .requestClarification(let question, let operationID, let sourceNodeID, let options, let multiline, let sourceNodeName):
                        agentMessage.agentState = .interaction(.clarification)
                        agentMessage.lifecycleState = .parkedHITL(operationID: operationID)
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        await self.enqueueHITL(
                            operationID: operationID,
                            kind: .clarification(PendingClarification(id: operationID, question: question, options: options, multiline: multiline)),
                            conversationID: conversationID,
                            profileType: config.profile.profileType,
                            workflowState: workflowExecutionState,
                            sourceNodeID: sourceNodeID,
                            sourceNodeName: sourceNodeName,
                            profileID: config.profile.id,
                            traceContext: traceContext
                        )

                    // [E1] Workflow Gate request → unified InteractionCenter as a `.gate` interaction.
                    case .requestGate(let prompt, let options, let operationID, let deadline, let sourceNodeID, let inputText, let highlights, let sourceNodeName):
                        agentMessage.agentState = .interaction(.gate)
                        agentMessage.lifecycleState = .parkedHITL(operationID: operationID)
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        await self.enqueueHITL(
                            operationID: operationID,
                            kind: .gate(PendingGate(id: operationID, prompt: prompt, options: options, deadline: deadline, inputText: inputText, highlights: highlights)),
                            conversationID: conversationID,
                            profileType: config.profile.profileType,
                            workflowState: workflowExecutionState,
                            sourceNodeID: sourceNodeID,
                            sourceNodeName: sourceNodeName,
                            profileID: config.profile.id,
                            traceContext: traceContext
                        )

                    case .toolSucceeded(let output, let durationMs, let sourceNodeID):
                        agentMessage.agentState = .thinking(.reflecting)
                        // ANY successful tool may have changed files — see `WorkspaceActivity`.
                        WorkspaceActivity.post(reason: "tool \(output.toolName) succeeded")
                        if let payload = AgentLiveWriteEvent.completed(toolName: output.toolName, params: output.params, isSuccess: true, preWriteContent: output.preWriteContent, conversationID: conversationID) {
                            NotificationCenter.default.post(name: AgentLiveWriteEvent.completed, object: nil,
                                                            userInfo: [AgentLiveWriteEvent.payloadKey: payload])
                        }
                        // Card-nested rows first (plan step / reflection attempt); fall back
                        // to the top-level / workflow-node completion path.
                        if !(capabilityCardsEnabled && sourceNodeID == nil
                             && capabilityRouter.completeTool(output: output, failureCategory: nil, durationMs: durationMs)) {
                            Self.completeToolTimelineEvent(
                                output: output,
                                failureCategory: nil,
                                durationMs: durationMs,
                                sourceNodeID: sourceNodeID,
                                agentMessage: agentMessage,
                                workflowExecutionState: workflowExecutionState
                            )
                        }
                        // [G1 Piece 1] Boundary flush — capture the completed tool's output durably.
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)

                    case .toolFailed(let output, let category, let suggestion, let sourceNodeID):
                        agentMessage.agentState = .thinking(.reflecting)
                        if let payload = AgentLiveWriteEvent.completed(toolName: output.toolName, params: output.params, isSuccess: false, preWriteContent: output.preWriteContent, conversationID: conversationID) {
                            NotificationCenter.default.post(name: AgentLiveWriteEvent.completed, object: nil,
                                                            userInfo: [AgentLiveWriteEvent.payloadKey: payload])
                        }
                        if !(capabilityCardsEnabled && sourceNodeID == nil
                             && capabilityRouter.completeTool(output: output, failureCategory: category, durationMs: nil)) {
                            Self.completeToolTimelineEvent(
                                output: output,
                                failureCategory: category,
                                durationMs: nil,
                                sourceNodeID: sourceNodeID,
                                agentMessage: agentMessage,
                                workflowExecutionState: workflowExecutionState
                            )
                        }
                        // [G1 Piece 1] Boundary flush — capture the failed tool's outcome durably.
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        if let s = suggestion {
                            logger.debug("[TOOL_FAILED] \(output.toolName) [\(category.rawValue)] suggestion: \(s)")
                        }


                    case .draftText(let draft):
                        // Provisional step text (see `AgentStreamEvent.draftText`). Set directly —
                        // not merged, buffered or flushed to disk: it is cumulative, and it may yet
                        // be withdrawn.
                        if draft.isEmpty {
                            if let baseline = draftBaseline {
                                setMessageContent(agentMessage, baseline, isRegeneration: isRegeneration)
                                draftBaseline = nil
                            }
                        } else if let current = messageContent(agentMessage, isRegeneration: isRegeneration) {
                            let baseline = draftBaseline ?? current
                            draftBaseline = baseline
                            setMessageContent(agentMessage, ChatMessage.draftDisplayContent(baseline: baseline, draft: draft),
                                              isRegeneration: isRegeneration)
                        }

                    case .content(let textChunk):
                        // A showing draft is the preview of this very text: put the bubble back
                        // the way it was before the draft, then append as usual.
                        if let baseline = draftBaseline {
                            setMessageContent(agentMessage, baseline, isRegeneration: isRegeneration)
                            draftBaseline = nil
                            // Render this chunk NOW rather than on the next throttle tick — the bubble
                            // just lost the draft, and waiting up to `adaptiveInterval` would blink it
                            // empty between the preview and the answer.
                            lastUpdateTime = .distantPast
                        }
                        // 3. Handle Final Text (Buffered)
                        if agentMessage.agentState != .thinking(.finalizing) {
                            agentMessage.agentState = .thinking(.finalizing)
                        }
                        
                        tokenBuffer += textChunk
                        tokensReceivedInWindow += textChunk.count

                        // Flush on TIME only.
                        //
                        // There used to be an `|| tokenBuffer.count > 50` escape hatch, which
                        // inverted the whole throttle for fast producers: an in-process MLX
                        // model fills 50 chars far quicker than `adaptiveInterval`, so the
                        // buffer clause won every time and forced a re-render every ~50 chars
                        // (~54 for a 2.7k reply) no matter how far behind the UI already was.
                        // The producer would finish while the consumer was still draining
                        // buffered tokens one render at a time — the model completed in 15s
                        // and the bubble kept dripping for ~a minute.
                        //
                        // The time clause alone already bounds latency to <= adaptiveInterval
                        // (0.2s worst case), and it degrades the RIGHT way: the further behind
                        // we fall, the more tokens coalesce into a single render.
                        let elapsed = -lastUpdateTime.timeIntervalSinceNow
                        if elapsed >= adaptiveInterval {
                            self.updateMessageContent(agentMessage, with: tokenBuffer, isRegeneration: isRegeneration)
                            // [G1 Piece 1] Coalesced flush — persist streamed prose at most every
                            // `inFlightFlushInterval`, so a long final answer isn't lost if interrupted.
                            await self.flushInFlight(agentMessage, conversationID: conversationID)

                            // Adapt interval based on token throughput:
                            // High throughput (fast local models) → shorter interval (0.05s) for smooth streaming
                            // Low throughput (slow remote APIs)  → longer interval (0.2s) to reduce UI churn
                            if elapsed > 0 {
                                let charsPerSecond = Double(tokensReceivedInWindow) / elapsed
                                if charsPerSecond > 500 {
                                    adaptiveInterval = 0.05   // Fast: flush frequently for smooth UX
                                } else if charsPerSecond > 100 {
                                    adaptiveInterval = 0.1    // Normal: balanced default
                                } else {
                                    adaptiveInterval = 0.2    // Slow: batch more to reduce rerenders
                                }
                            }

                            tokenBuffer = ""
                            tokensReceivedInWindow = 0
                            lastUpdateTime = Date()
                        }
                        
                    case .error(let structuredError):
                        // [WF-RU1] Remember the richest failure text for the workflow settle at
                        // stream end. Only USED when the engine's terminal outcome is `.failed` —
                        // an inner-node error a recovery branch survives never reaches it.
                        lastErrorEventMessage = structuredError.message
                        // The error card below replaces whatever the bubble shows, draft included;
                        // forget the draft so a later withdrawal cannot restore over the card.
                        draftBaseline = nil
                        // Surface the failure as a distinct error card in the bubble
                        // instead of leaving it buried in streaming prose. Without this,
                        // capability/system failures render as plain text that mimics
                        // the agent's own output and misleads users into thinking the
                        // run is still in progress.
                        // (Phase 4: category-aware title + actionable suggestion +
                        // category icon, rendered by ErrorMessageView.)
                        logger.error("Stream Error Event [\(structuredError.category.rawValue)]: \(structuredError.message)")
                        agentMessage.content = MessageContent.error(
                            title: structuredError.title,
                            details: structuredError.message,
                            category: structuredError.category,
                            suggestion: structuredError.suggestion
                        )
                        agentMessage.invalidateMarkdownCache()
                        if let agentResponse = agentMessage.agentResponse,
                           agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                            agentMessage.agentResponse?.variants[agentResponse.selectedVariantIndex].content = agentMessage.content
                        }

                    case .warning(let category, let message, _, let sourceNodeID):
                        let warningEvent = TimelineEvent.warning(id: UUID(), category: category, text: message)
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(warningEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] Warning[\(category.rawValue)] → node timeline [\(nodeID)]")
                        } else if !(capabilityCardsEnabled && capabilityRouter.route(warningEvent)) {
                            agentMessage.appendTimelineEvent(warningEvent)
                        }
                        logger.warning("Stream Warning [\(category.rawValue)]: \(message)")

                    // MARK: Workflow Orchestration Events
                    case .workflowNodeStarted(let nodeID, let profileName, let idx, let total):
                        agentMessage.agentState = .acting(.subtask(current: idx, total: total))
                        logger.info("[WF_EVENT] NodeStarted: '\(profileName)' [\(nodeID)] (\(idx)/\(total))")
                        workflowExecutionState?.handleNodeStarted(nodeID: nodeID, profileName: profileName, index: idx, total: total)

                    case .workflowNodeCompleted(let nodeID, let profileName, let summary, let nodeHasWarnings):
                        let completedId = UUID()
                        // `summary` now carries the node's FULL output (for the per-node
                        // Output panel + persistence via handleNodeCompleted). Keep the
                        // orchestrator's aggregate thought log a brief milestone so it
                        // isn't bloated by full node outputs.
                        let summaryPreview = summary.count > 200 ? String(summary.prefix(200)) + "…" : summary
                        agentMessage.appendTimelineEvent(.thought(id: completedId, text: "✅ \(profileName): \(summaryPreview)"))
                        // [M6] Log the summary LENGTH, not the node's output text (model content) —
                        // this line reaches the unified OS log. The full output is in the per-node
                        // Output panel + persisted via handleNodeCompleted for real inspection.
                        logger.info("[WF_EVENT] NodeCompleted: '\(profileName)' [\(nodeID)] summary=\(summary.count) chars")
                        workflowExecutionState?.handleNodeCompleted(nodeID: nodeID, profileName: profileName, summary: summary, hasWarnings: nodeHasWarnings)

                    case .workflowNodeFailed(let nodeID, let profileName, let error, let suggestion):
                        let failedId = UUID()
                        agentMessage.appendTimelineEvent(.thought(id: failedId, text: "❌ \(profileName): \(error)"))
                        logger.info("[WF_EVENT] NodeFailed: '\(profileName)' [\(nodeID)] error=\(error)")
                        workflowExecutionState?.handleNodeFailed(nodeID: nodeID, profileName: profileName, error: error, suggestion: suggestion)

                    case .workflowNodeSkipped(let nodeID, let profileName, let reason, let ranBeforeSkip):
                        // [XUI-12] `.info` and `reason.rawValue`: this matches the five sibling arms,
                        // skips are high-volume (a wide DAG can skip a whole subtree, so this must not
                        // be a `.notice`), and the raw value is the stable machine token that already
                        // appears in the trace context as `skip_reason` — `displayText` is localized
                        // prose that would break log grepping across locales.
                        //
                        // ⚠️ BOTH consequence clauses are CONDITIONAL, and the first draft of this
                        // line stated both unconditionally — inverting the engine's own central skip
                        // invariant in the line a field debugger reads. `.byUser` is the ONE skip
                        // whose subtree stays live (`NodeSkipReason.keepsDownstreamAlive`); for the
                        // other six `edgeIsLive` kills every edge below. And a pre-dispatch skip —
                        // which is the high-volume case, both engine emitters pass
                        // `ranBeforeSkip: false` — is labelled "Not run" on screen, not "Skipped".
                        // The line already printed both discriminators right beside the false claims.
                        let skipRowWord = ranBeforeSkip ? "Skipped" : "Not run"
                        let skipDownstream = reason.keepsDownstreamAlive
                            ? "downstream receives this node's INPUT unchanged"
                            : "every edge below it is dead, so its whole subtree is skipped too"
                        logger.info("[WF_EVENT] NodeSkipped: '\(profileName)' [\(nodeID)] reason=\(reason.rawValue) ranBeforeSkip=\(ranBeforeSkip). CONSEQUENCE: the node's row settles as '\(skipRowWord)' and contributes no output of its own; \(skipDownstream).")
                        workflowExecutionState?.handleNodeSkipped(nodeID: nodeID, profileName: profileName, reason: reason, ranBeforeSkip: ranBeforeSkip)

                    case .workflowNodeCancelled(let nodeID, let profileName):
                        // [XUI-12] `.notice`, not `.info`: a cancel is rare and user-initiated, and it
                        // is the one path whose emitter side is also quiet — keeping both at `.notice`
                        // makes the Stop story readable at one level across the two files.
                        logger.notice("[WF_EVENT] NodeCancelled: '\(profileName)' [\(nodeID)]. CONSEQUENCE: the node's row settles as 'Cancelled' (not failed) with any partial output discarded; no output port is activated, so nothing downstream of it runs.")
                        workflowExecutionState?.handleNodeCancelled(nodeID: nodeID, profileName: profileName)

                    case .workflowNodeRetryScheduled(let nodeID, let profileName, let attemptsRemaining):
                        // [CF-30] The row deliberately keeps showing the failure of the attempt
                        // that just ended; this only records that the engine has not given up, so
                        // a Stop during the back-off settles it as cancelled instead of leaving a
                        // failure the user pre-empted.
                        logger.notice("[WF_EVENT] NodeRetryScheduled: '\(profileName)' [\(nodeID)], \(attemptsRemaining) attempt(s) left. CONSEQUENCE: the node's row stays 'Failed' for the back-off (it is not retrying yet, and may never), but a Stop pressed now settles it as Cancelled rather than as a genuine failure.")
                        workflowExecutionState?.handleNodeRetryScheduled(nodeID: nodeID, profileName: profileName, attemptsRemaining: attemptsRemaining)

                    case .workflowProgress(let completed, let total):
                        logger.info("[WF_EVENT] Progress: \(completed)/\(total)")
                        workflowExecutionState?.handleProgress(completed: completed, total: total)

                    case .workflowRunFinished(let hadGenuineFailure):
                        // [WF-RU4] See the case's own doc for why this is separate from
                        // `agentMessage.terminalOutcome` — that one drives the chat bubble and
                        // must not change here.
                        logger.info("[WF_EVENT] RunFinished: hadGenuineFailure=\(hadGenuineFailure)")
                        workflowExecutionState?.completedDespiteNodeFailure = hadGenuineFailure

                    // MARK: Capability Events (Planning, Self-Reflection, Delegation)

                    case .planGenerated(let subtasks):
                        let count = subtasks.count
                        agentMessage.agentState = .thinking(.planning)
                        if capabilityCardsEnabled {
                            capabilityRouter.handlePlanGenerated(subtasks)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .planGenerated, detail: "Planned \(count) subtask\(count == 1 ? "" : "s")"
                            ))
                        }

                    case .planApproved(let subtasks):
                        agentMessage.agentState = .thinking(.planning)
                        if capabilityCardsEnabled {
                            capabilityRouter.handlePlanApproved(subtasks)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .planGenerated, detail: "Plan approved (\(subtasks.count) subtask\(subtasks.count == 1 ? "" : "s"))"
                            ))
                        }

                    case .requestPlanReview(let subtasks, let operationID, let sourceNodeID, let sourceNodeName):
                        agentMessage.agentState = .interaction(.planReview)
                        // [ASM-5] Park + immediate boundary flush — every other HITL case
                        // (tool confirmation, clarification, gate) does exactly this. Without
                        // the marker a plan-review park reloaded as `.streaming` after a quit
                        // (resume couldn't re-raise the review), and the run never reached the
                        // parked state the local-model release keys off — the loaded MLX model
                        // stayed pinned in memory for as long as the banner sat unanswered.
                        agentMessage.lifecycleState = .parkedHITL(operationID: operationID)
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        if capabilityCardsEnabled {
                            capabilityRouter.handlePlanReviewRequested()
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .planReviewRequested,
                                detail: "Plan with \(subtasks.count) subtask\(subtasks.count == 1 ? "" : "s") awaiting approval"
                            ))
                        }
                        await self.enqueueHITL(
                            operationID: operationID,
                            kind: .planReview(PendingPlanReview(id: operationID, subtasks: subtasks)),
                            conversationID: conversationID,
                            profileType: config.profile.profileType,
                            workflowState: workflowExecutionState,
                            sourceNodeID: sourceNodeID,
                            sourceNodeName: sourceNodeName,
                            profileID: config.profile.id,
                            traceContext: traceContext
                        )

                    case .subtaskStarted(let id, let index, let total, let description):
                        agentMessage.agentState = .acting(.subtask(current: index, total: total))
                        if capabilityCardsEnabled {
                            capabilityRouter.handleSubtaskStarted(id: id, description: description)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .subtaskStarted, detail: "Subtask \(index)/\(total): \(description)"
                            ))
                        }
                        // [G1 Piece 1] Boundary flush — persist the step transition durably.
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)

                    case .subtaskCompleted(let id, let index, let total, let summary, let outcome, let durationMs):
                        if capabilityCardsEnabled {
                            capabilityRouter.handleSubtaskCompleted(id: id, summary: summary, outcome: outcome, durationMs: durationMs)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .subtaskCompleted, detail: "Subtask \(index)/\(total): \(summary)"
                            ))
                        }
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)

                    case .reflectionTrialStarted(let trial, let maxTrials):
                        agentMessage.agentState = .thinking(.reasoning)
                        if capabilityCardsEnabled {
                            capabilityRouter.handleTrialStarted(trial: trial, maxTrials: maxTrials)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .reflectionTrialStarted, detail: "Trial \(trial) of \(maxTrials)"
                            ))
                        }

                    case .reflectionEvaluating(let trial):
                        agentMessage.agentState = .thinking(.reflecting)
                        if capabilityCardsEnabled {
                            capabilityRouter.handleTrialEvaluating(trial: trial)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .reflectionEvaluating, detail: "Evaluating trial \(trial)"
                            ))
                        }

                    case .reflectionRetrying(let trial, let critique):
                        agentMessage.agentState = .thinking(.reflecting)
                        if capabilityCardsEnabled {
                            // Full critique — the card is the critique's home now; the old
                            // 80-char milestone truncation lost the evaluator's reasoning.
                            capabilityRouter.handleTrialRejected(trial: trial, critique: critique)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .reflectionRetrying, detail: "Retry: \(String(critique.prefix(80)))"
                            ))
                        }

                    case .reflectionAccepted(let trial):
                        if capabilityCardsEnabled {
                            capabilityRouter.handleTrialAccepted(trial: trial)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .reflectionAccepted, detail: "Accepted on trial \(trial)"
                            ))
                        }

                    case .delegationStarted(let task):
                        let shortTask = String(task.prefix(60))
                        agentMessage.agentState = .acting(.tool(name: "call_agent"))
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .delegationStarted, detail: shortTask
                        ))

                    case .delegationCompleted(let summary):
                        let shortSummary = String(summary.prefix(80))
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .delegationCompleted, detail: shortSummary
                        ))

                    // MARK: History Compaction Events
                    case .compactionCompleted(let turns, let preview, let checkpoint):
                        // Chip ONLY. Persistence + live-array splice moved to
                        // HistoryCompactionService's checkpoint sink (registered by
                        // MessagingCoordinator): compaction runs in the background now, so
                        // it can complete after this stream has finished — at which point
                        // this event is never delivered. Data must not depend on it.
                        let shortPreview = String(preview.prefix(100))
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .compactionCompleted,
                            detail: "History compacted \u{2014} \(turns) turns summarized: \(shortPreview)"
                        ))
                        logger.info("[COMPACTION] Completed chip shown \u{2014} checkpoint \(checkpoint.id.uuidString.prefix(8)), conversationID: \(conversationID.uuidString.prefix(8))")

                    case .compactionFailed(let reason):
                        // Best-effort chip from the background run. The run continues
                        // with uncompacted history, so this is a warning, not an error.
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .compactionFailed,
                            detail: "History compaction didn't finish (\(reason)) \u{2014} continuing with full history"
                        ))
                        logger.warning("[COMPACTION] Reported to user as failed \u{2014} \(reason), conversationID: \(conversationID.uuidString.prefix(8))")

                    // MARK: Multimodal Events
                    case .mediaProgress:
                        // Deliberately dropped. This only ever drove the dynamic island's headline
                        // ("imageGen: Step 12/30"), and the island is gone.
                        //
                        // Generation is still visible: its only emitter (ImageGenExecutor) yields
                        // `.thought("Generating image with <model>…")` immediately before the first
                        // progress event, and that reaches the timeline — followed by the artifact
                        // itself. What's lost is the live step counter, nothing else.
                        //
                        // Restoring it isn't a one-liner and would be a NEW feature rather than a
                        // repair: the timeline has no progress concept at all, `TimelineEvent`
                        // carries no percent, and `appendTimelineEvent` only appends — so ticking
                        // events would either flood the action group ("Produced 47 artifacts") or
                        // need an upsert plus a change to a persisted enum.
                        break

                    case .artifactProduced(let artifact):
                        let mediaEvent = TimelineEvent.mediaGeneration(
                            id: UUID(),
                            toolName: artifact.label ?? artifact.kind.rawValue,
                            artifact: artifact,
                            isComplete: true
                        )
                        if !(capabilityCardsEnabled && capabilityRouter.route(mediaEvent)) {
                            agentMessage.appendTimelineEvent(mediaEvent)
                        }

                    // MARK: Token Usage
                    case .tokenUsage(let usage):
                        // Accumulate (don't overwrite): a multi-node workflow emits one
                        // event per node, so we want the run total, not just the last (D1).
                        agentMessage.tokenUsage = (agentMessage.tokenUsage ?? TokenUsage()).accumulated(with: usage)

                    // MARK: Terminal Outcome
                    case .executionFinished(let outcome, let reason):
                        agentMessage.terminalOutcome = outcome
                        agentMessage.terminalReason = reason
                        if capabilityCardsEnabled {
                            capabilityRouter.handleExecutionFinished(outcome: outcome)
                        }
                        logger.info("[STREAM_TERMINAL] outcome=\(outcome.rawValue), reason=\(reason ?? "nil")")
                    }
                }
                
                // Flush remaining text tokens
                if !tokenBuffer.isEmpty {
                    self.updateMessageContent(agentMessage, with: tokenBuffer, isRegeneration: isRegeneration)
                }
                
                logger.info("[STREAM_LOOP_END] Finished — traceID: \(traceContext.traceID), messageID: \(agentMessage.id.uuidString.prefix(8)), profileType: \(profileType)")

                // Forward the stream's end to the workflow execution state.
                //
                // ⚠️ `Task.isCancelled` is load-bearing here, not decoration. A workflow Stop
                // tears this loop down WITHOUT throwing (see `handleStreamEnd`), so the
                // `catch is CancellationError` arm below never runs for one — this is the only
                // place the workflow state can learn the run was stopped. Passing the flag
                // through is what keeps the frozen record's status agreeing with the trace
                // status stamped a few lines down.
                if let wfState = workflowExecutionState {
                    let finalText = agentMessage.content.textContent ?? ""
                    let stopped = Task.isCancelled
                    logger.info("[WF_EVENT] StreamEnd: cancelled=\(stopped), \(finalText.count) chars, nodeTimelines=\(wfState.nodeTimelines.count) nodes tracked")
                    logger.debug("[WF_EVENT] FinalOutput preview: \(String(finalText.prefix(300)))")
                    // [WF-RU1] An engine-declared run FAILURE must reach the workflow state as an
                    // ERROR, not be laundered into `finalOutput` as the run's answer. The `.error`
                    // arm only rewrites the MESSAGE; nothing called `handleError`, so
                    // `record.error` froze as nil, the Final Outcome panel rendered the failure
                    // text as ordinary markdown with a Copy chip, VoiceOver spoke it as
                    // "Output: …", and — because `handleError` is what runs `settleInFlightWork`
                    // — dangling tool rows spun for the rest of the session. Keyed off the
                    // engine's own `.executionFinished(.failed)` (stamped on the message by its
                    // arm above), NOT off `.error` events, which inner nodes also emit on runs a
                    // recovery branch then completes.
                    if !stopped, agentMessage.terminalOutcome == .failed, wfState.workflowError == nil {
                        let reason = lastErrorEventMessage ?? agentMessage.terminalReason ?? String(localized: "The workflow failed.")
                        wfState.handleError(reason)
                        logger.info("[WF_EVENT] Run FAILED per the engine's terminal outcome — settled workflowError (\(reason.count) chars) before StreamEnd. CONSEQUENCE: the record freezes .failed with record.error set, the UI renders the failure as an error rather than as the run's answer, and in-flight node/tool rows are settled instead of spinning forever.")
                    }
                    wfState.handleStreamEnd(finalText: finalText, cancelled: stopped)
                    if stopped {
                        logger.info("[WF_EVENT] Run STOPPED by user — state latched wasCancelled. CONSEQUENCE: the frozen record persists .cancelled with its in-flight node settled .cancelled, instead of a red 'Failed' reporting the user's own action back as an error.")
                    }
                }

                // Stop-button race: cancelling the consumer tears the stream down before
                // the producer's `.executionFinished(.cancelled)` can be consumed, so the
                // outcome arrives as nil and the safety net would record `.completed`
                // (audit #2). Stamp the honest outcome here.
                if Task.isCancelled, agentMessage.terminalOutcome == nil {
                    agentMessage.terminalOutcome = .cancelled
                    agentMessage.terminalReason = agentMessage.terminalReason ?? "Cancelled by user"
                }
                // Close any open capability cards so a persisted card never claims to
                // still be executing (mirrors the terminalOutcome safety net above).
                if capabilityCardsEnabled {
                    capabilityRouter.handleExecutionFinished(outcome: agentMessage.terminalOutcome ?? .completed)
                }
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)

            } catch is CancellationError {
                logger.info("[STREAM_CANCELLED] traceID: \(agentMessage.traceID ?? "?"), messageID: \(agentMessage.id.uuidString.prefix(8))")
                workflowExecutionState?.handleError("Cancelled", cancelled: true)
                if agentMessage.terminalOutcome == nil {
                    agentMessage.terminalOutcome = .cancelled
                    agentMessage.terminalReason = agentMessage.terminalReason ?? "Cancelled by user"
                }
                if capabilityCardsEnabled {
                    capabilityRouter.handleExecutionFinished(outcome: .cancelled)
                }
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)
            } catch {
                logger.error("[STREAM_ERROR] traceID: \(agentMessage.traceID ?? "?"), messageID: \(agentMessage.id.uuidString.prefix(8)), error: \(error.localizedDescription)")
                workflowExecutionState?.handleError(error.localizedDescription)
                if capabilityCardsEnabled {
                    capabilityRouter.handleExecutionFinished(outcome: .failed)
                }
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: error)
            }
            
            }
            }
            // The run is over (finalized above): the ceiling has nothing left to stop.
            ceilingTask?.cancel()

            self.removeTask(for: agentMessage.id)
            onComplete()
        }
        }
        }
        }
        
        activeTasks[agentMessage.id] = streamTask
        
        return agentMessage
    }
    
    /// Mutates the matching executing `.toolExecution` timeline event into its completed state.
    /// Routes to the workflow node's per-node timeline when `sourceNodeID` is present,
    /// else falls back to the message's root timeline. `failureCategory == nil` means success.
    static func completeToolTimelineEvent(
        output: ToolOutput,
        failureCategory: ToolFailureCategory?,
        durationMs: Int?,
        sourceNodeID: UUID?,
        agentMessage: ChatMessage,
        workflowExecutionState: WorkflowExecutionState?
    ) {
        // Bound what enters the timeline. `output` is an UNCAPPED string that lands in the
        // message's timeline blob — re-encoded whole on every flush and decoded eagerly on
        // every conversation load — so one verbose command (a build log, a large file dump)
        // could balloon a conversation permanently. Truncation is explicit: the marker is
        // visible to the user AND to a resumed run's LLM history, which
        // `TimelineTurnReconstructor` rebuilds from this field.
        let cappedOutput = ToolExecutionData.cappedOutput(output.output)
        if cappedOutput.count != output.output.count {
            logger.warning("[TOOL_OUTPUT] '\(output.toolName)' returned \(output.output.count) chars — truncated to \(ToolExecutionData.maxPersistedOutputLength) for the timeline. The full text reached the model on THIS run; a resumed run sees the truncation marker instead.")
        }

        let updater: (inout ToolExecutionData) -> Void = { data in
            // Refresh params to what ACTUALLY executed — when the user edits args in the HITL banner
            // (A3), output.params carries the corrected values; the card was built from the originals.
            data.params = output.params
            data.output = cappedOutput
            data.isSuccess = output.isSuccess
            data.failureCategory = failureCategory
            data.durationMs = durationMs
            data.isExecuting = false
            data.preWriteContent = output.preWriteContent
            data.postWriteContent = output.postWriteContent
            // Derive the change ONCE, here, while the snapshots are in hand. The episodic
            // formatter runs per request; deriving it there re-diffed every historical
            // write on every prompt build.
            data.effect = ActionEffect.from(toolExecution: data)
            // Same reasoning, same seam: parsed once here rather than re-scanned on every
            // prompt build. Nil for every tool that doesn't annotate a status.
            data.exitCode = ShellExitStatus.parse(cappedOutput)
        }

        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
            if let idx = wfState.nodeTimelines[nodeID].flatMap({
                ToolRowMatcher.index(in: $0, for: output)
            }) {
                if case .toolExecution(var data) = wfState.nodeTimelines[nodeID]![idx] {
                    updater(&data)
                    wfState.nodeTimelines[nodeID]![idx] = .toolExecution(data)
                    logger.debug("[WF_ROUTE] Tool '\(output.toolName)' completed → node [\(nodeID)] success=\(output.isSuccess) category=\(failureCategory?.rawValue ?? "nil")")
                }
            } else {
                logger.warning("[TIMELINE] '\(output.toolName)' finished in node [\(nodeID)] but no executing row has its params. CONSEQUENCE: no row is completed — completing a guessed row would show another call's result on it.")
            }
            return
        }

        if let index = ToolRowMatcher.index(in: agentMessage.timelineEvents, for: output) {
            if case .toolExecution(var data) = agentMessage.timelineEvents[index] {
                updater(&data)
                agentMessage.timelineEvents[index] = .toolExecution(data)
                EditPatchStore.recordIfCode(data, in: agentMessage)
            }
        } else if agentMessage.timelineEvents.contains(where: {
            if case .toolExecution(let data) = $0 { return data.isExecuting && data.name == output.toolName }
            return false
        }) {
            logger.warning("[TIMELINE] '\(output.toolName)' finished but no executing row of that name has its params. CONSEQUENCE: no row is completed — completing a guessed row would show another call's result on it.")
        }
    }

    /// [HITL/P5] Enqueue a HITL request into the unified `InteractionCenter` — the single source
    /// of truth across chat / code / workflow / scheduled. Builds the source-attributed origin
    /// (interface + workflow node identity + banner title). Replaces the retired per-message
    /// `ChatMessage.pendingInteraction` and per-workflow `WorkflowExecutionState.pendingInteractions`.
    func enqueueHITL(
        operationID: UUID,
        kind: PendingInteraction,
        conversationID: UUID,
        profileType: ProfileType,
        workflowState: WorkflowExecutionState?,
        sourceNodeID: UUID?,
        /// Producer-supplied display name, defaulted so existing call sites are unaffected.
        /// See the resolution comment below for why the id alone is not enough.
        sourceNodeName: String? = nil,
        profileID: UUID?,
        traceContext: TraceContext
    ) async {
        // ⚠️ CR-40: every caller awaits a persistence flush before getting here, and the request
        // can be resolved during it. Showing its banner now would leave one nobody can answer.
        if await ExecutionSuspensionService.shared.wasResolved(operationID) {
            logger.notice("[HITL] op \(operationID.uuidString.prefix(8)) was resolved before its banner could be shown (conversation \(conversationID.uuidString.prefix(8))). CONSEQUENCE: no banner is raised and no trace record is opened; the run has already moved on.")
            return
        }
        guard let interactionCenter else {
            // A park with no center means the run waits on an interaction NOBODY can
            // ever answer — that must never be silent.
            logger.error("[HITL] enqueue DROPPED — no InteractionCenter wired (op: \(operationID.uuidString.prefix(8)), conversation: \(conversationID.uuidString.prefix(8))). The run will hang parked.")
            return
        }

        let isWorkflow = workflowState != nil && sourceNodeID != nil
        let interface: HITLOrigin.Interface = isWorkflow
            ? .workflow
            : (profileType == .code ? .code : .chat)

        // Prefer a name the PRODUCER supplied. The `nodeResults` lookup below only works for a
        // node of the CURRENT canvas; for a request forwarded out of a sub-workflow, `sourceNodeID`
        // names an inner node this state has never heard of (the child's node events are
        // suppressed), so it always missed and the banner rendered a bare kind label — with two
        // nodes parked at once the user could not tell which was asking.
        let nodeName: String? = sourceNodeName ?? sourceNodeID.flatMap { id in
            workflowState?.nodeResults.first(where: { $0.nodeID == id })?.profileName
        }

        let kindLabel: String = {
            switch kind {
            case .toolConfirmation: return "Permission required"
            case .clarification:    return "Question"
            case .planReview:       return "Plan review"
            case .gate:             return "Decision required"
            }
        }()
        let title = nodeName.map { "\($0) · \(kindLabel)" } ?? kindLabel

        // Logged HERE (not at function entry) so it can reuse `kindLabel` — the first
        // version stringified the enum and truncated it to 40 chars, emitting the
        // half-word "toolConfirmation(devgentic.PendingToolCo".
        logger.log("[HITL] Parked op \(operationID.uuidString.prefix(8)) — \(kindLabel), conversation: \(conversationID.uuidString.prefix(8)), interface: \(interface.rawValue), profile: \(profileType.rawValue), node: \(nodeName ?? "none"). Awaiting user.")

        let origin = HITLOrigin(
            interface: interface,
            conversationID: conversationID,
            nodeID: sourceNodeID,
            nodeName: nodeName,
            title: title,
            profileID: profileID,
            // ⚠️ WHICH RUN IS ASKING. `traceContext.messageID` is the agent message this run is
            // streaming into — the same object `RemoteMirrorService` observes — so this is the join
            // key that lets the mirror post only the items belonging to the run it is mirroring.
            // Stamped here rather than at the four call sites so a fifth cannot forget it.
            runMessageID: traceContext.messageID
        )
        interactionCenter.enqueue(PendingHITL(id: operationID, origin: origin, kind: kind))

        // [HITL/C1] Record the raise for the trace span emitted on resolve — chat, code, and ALL workflow
        // HITL including gates. Gates are now a first-class `.gate` interaction (WorkflowExecutor no longer
        // emits its own span), so they are traced uniformly here with no double-emit to guard against.
        let kindType: String
        let kindToolName: String?
        switch kind {
        case .toolConfirmation(let c): kindType = "permission";    kindToolName = c.toolName
        case .clarification:           kindType = "clarification"; kindToolName = nil
        case .planReview:              kindType = "plan_review";   kindToolName = nil
        case .gate:                    kindType = "gate";          kindToolName = nil
        }

        // Sample the raise instant ONCE, synchronously, so the C1 span and C2 audit share the exact
        // same timestamp and neither drifts to whenever its deferred Task happens to run.
        let raisedAt = Date()

        hitlTraceInfo[operationID] = HITLTraceRecord(
            context: traceContext, raisedAt: raisedAt, type: kindType, toolName: kindToolName
        )

        // [HITL/C2] Durable audit row, written at RAISE for EVERY HITL (incl. gates). A request still
        // pending at quit/crash survives as resolvedAt=nil, which the launch reconcile stamps `interrupted`.
        Task { await TraceRecorder.shared.recordHITLRaised(
            operationID: operationID.uuidString,
            conversationID: conversationID.uuidString,
            interface: interface.rawValue,
            type: kindType,
            toolName: kindToolName,
            nodeName: nodeName,
            title: title,
            raisedAt: raisedAt,
            // v8 join keys: the audit row now names its run exactly, so the Run
            // Report stops guessing approvals into runs by time window.
            traceID: traceContext.traceID,
            spanID: traceContext.spanID
        ) }
    }

    /// [HITL/C1] In-flight HITL requests awaiting resolution, for the userInteraction trace span.
    private struct HITLTraceRecord {
        let context: TraceContext
        let raisedAt: Date
        let type: String
        let toolName: String?
    }
    @ObservationIgnored private var hitlTraceInfo: [UUID: HITLTraceRecord] = [:]

    /// [HITL/C1] Emit a `userInteraction` trace span when a HITL resolves — captures decision +
    /// wait duration so chat HITL (previously span-less) is visible in the Report Inspector.
    private func emitHITLTraceSpan(operationID: UUID?, outcome: String) {
        guard let opID = operationID, let rec = hitlTraceInfo.removeValue(forKey: opID) else { return }
        let waitMs = Int(Date().timeIntervalSince(rec.raisedAt) * 1000)
        let context = rec.context
        let type = rec.type
        let tool = rec.toolName
        let detailed = "\(outcome) · \(waitMs)ms"
        Task { await TraceRecorder.shared.emitUserInteraction(span: context, type: type, toolName: tool, outcome: detailed) }
    }

    /// The content the bubble is showing — the selected variant's when regenerating.
    private func messageContent(_ agentMessage: ChatMessage, isRegeneration: Bool) -> MessageContent? {
        guard isRegeneration else { return agentMessage.content }
        guard let response = agentMessage.agentResponse,
              response.variants.indices.contains(response.selectedVariantIndex) else { return nil }
        return response.variants[response.selectedVariantIndex].content
    }

    /// Replaces (does not merge) what the bubble shows. Used only for `.draftText` previews.
    private func setMessageContent(_ agentMessage: ChatMessage, _ content: MessageContent, isRegeneration: Bool) {
        if isRegeneration {
            guard let response = agentMessage.agentResponse,
                  response.variants.indices.contains(response.selectedVariantIndex) else { return }
            agentMessage.agentResponse?.variants[response.selectedVariantIndex].content = content
        } else {
            agentMessage.content = content
            agentMessage.agentResponse?.variants[0].content = content
        }
        agentMessage.invalidateMarkdownCache()
    }

    private func updateMessageContent(_ agentMessage: ChatMessage, with newTextChunk: String, isRegeneration: Bool) {
        // Merge decision lives in `ChatMessage.resolveStreamedChunkMerge` (pure,
        // testable). ASM-1: when current content is an `.error` card and prose
        // streams afterwards (workflow node failure + surviving terminal nodes;
        // planning subtask failure), the merge starts the answer fresh and hands
        // back a demoted timeline event so the failure stays discoverable instead
        // of being laundered into the answer's opening words.
        if isRegeneration {
            guard let agentResponse = agentMessage.agentResponse,
                  agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) else {
                return
            }
            var targetVariant = agentResponse.variants[agentResponse.selectedVariantIndex]
            if let merged = ChatMessage.resolveStreamedChunkMerge(current: targetVariant.content, chunk: newTextChunk) {
                targetVariant.content = merged.content
                agentMessage.agentResponse?.variants[agentResponse.selectedVariantIndex] = targetVariant
                if let demoted = merged.demotedError {
                    agentMessage.appendTimelineEvent(demoted)
                }
            }
        } else {
            if let merged = ChatMessage.resolveStreamedChunkMerge(current: agentMessage.content, chunk: newTextChunk) {
                agentMessage.content = merged.content
                agentMessage.agentResponse?.variants[0].content = merged.content
                if let demoted = merged.demotedError {
                    agentMessage.appendTimelineEvent(demoted)
                }
            }
        }
        // Invalidate cached markdown blocks so the next body evaluation reparses
        // with the updated content. This works with getOrCreateMarkdownBlocks() to
        // provide O(1) no-ops when body re-evaluates without new content.
        agentMessage.invalidateMarkdownCache()
    }
    
    /// [P8] Whether any stream is live for `conversationID` RIGHT NOW. Drives the
    /// sidebar's `StreamingPulseIndicator` — which had never rendered once: it read a
    /// persisted `isStreaming` that has no column, so every decode said `false`.
    /// "Streaming" is a live-process property (after a crash, nothing is streaming),
    /// so the live dictionary is the honest source; reading it from a view body
    /// auto-updates rows on stream start/end (`activeStreams` is observable).
    func hasActiveStream(inConversation conversationID: UUID) -> Bool {
        activeStreams.values.contains { $0.conversationId == conversationID }
    }

    /// Every live run, reduced to the fields the foreground decision needs.
    ///
    /// This is the authoritative answer to "what is running?" — it replaced
    /// `MainApplicationViewModel.streamingMessageID` / `.streamingMessage`, two stored `var`s that
    /// five surfaces overwrote and five completions nil'd with no ownership guard. `activeStreams`
    /// was always correctly keyed and always observable; the slot was a lossy copy of it.
    /// See `ForegroundRunResolver` for the full history and `LLM_Execution_Concurrency_Design.md`.
    ///
    /// Reading this inside a SwiftUI view body or an `ObservationStream` registers on
    /// `activeStreams`, so the composer's Send/Stop state updates on every stream start and end
    /// exactly as the sidebar's pulse already does.
    func liveRunSnapshot() -> [ForegroundRunResolver.LiveRun] {
        activeStreams.values.map { message in
            let parked: Bool
            if case .parkedHITL = message.lifecycleState { parked = true } else { parked = false }
            return ForegroundRunResolver.LiveRun(
                messageID: message.id,
                conversationID: message.conversationId,
                // `.distantPast` only if the two maps ever diverge; it degrades the tie-break to
                // "loses to everything", never the candidacy itself.
                startedAt: streamStartedAt[message.id] ?? .distantPast,
                isParked: parked,
                // ⚠️ From admission, the one place that knows: a queued run's message looks exactly
                // like a working one (`.streaming`, registered, timestamped). See `LiveRun.isQueued`.
                isQueued: admission.isWaiting(message.id)
            )
        }
    }

    public func cancelStream(for messageId: UUID) {
        guard let taskToCancel = activeTasks[messageId] else {
            logger.warning("Attempted to cancel a stream for message ID \(messageId.uuidString), but no active task was found.")
            return
        }
        
        logger.info("Cancelling stream task for message ID: \(messageId.uuidString)")
        taskToCancel.cancel()
        // ⚠️ A QUEUED run's task is suspended in `ConversationAdmission`'s `withCheckedContinuation`,
        // which ignores cancellation — so cancelling the task alone did NOTHING until the run in
        // front finished (CR-4). Withdrawing the waiter resumes it, and it exits through its own
        // `Task.isCancelled` branch (withdrawn-before-start, finalize, `onComplete`). Harmless for a
        // run that is not waiting.
        if let conversationID = activeStreams[messageId]?.conversationId {
            admission.forget(messageID: messageId, inConversation: conversationID)
        }
    }

    /// [HITL/P5] Cancel any active stream(s) for a conversation. Used on conversation deletion so a
    /// run parked on a HITL (which no longer has a per-HITL watchdog) doesn't strand — cancellation
    /// cascades to the suspension's withTaskCancellationHandler (deny / nil) and then finalizes.
    public func cancelStreams(forConversation conversationID: UUID) {
        let messageIDs = activeStreams.filter { $0.value.conversationId == conversationID }.map(\.key)
        for messageID in messageIDs {
            cancelStream(for: messageID)
        }
        // A parked waiter holds a continuation that nothing else will resume — see the method.
        admission.releaseAll(inConversation: conversationID)
    }
    
    
    /// [G1 Piece 1] Durably persist the in-flight agent message mid-run so an interrupted run
    /// (force-quit / crash) survives with its partial timeline instead of vanishing on restart.
    /// `addMessage` is an upsert-by-id, so repeated calls update one row rather than duplicating.
    /// Boundary flushes (tool start/finish, HITL park) pass `immediate: true`; the token path
    /// coalesces behind `inFlightFlushInterval`. No-ops if the task was cancelled (e.g. a
    /// delete-conversation cascade is tearing the run down) so a late flush can't re-insert a row
    /// that is being deleted.
    private func flushInFlight(_ message: ChatMessage, conversationID: UUID, immediate: Bool = false) async {
        if Task.isCancelled { return }
        if !immediate, let last = lastInFlightFlush[message.id], -last.timeIntervalSinceNow < Self.inFlightFlushInterval {
            return
        }
        lastInFlightFlush[message.id] = Date()
        await persistenceService.addMessage(message, toConversation: conversationID)
    }

    /// The pending "waiting for the local model" banner per run, so the wait's end can cancel it.
    @ObservationIgnored private var localQueueBanners: [UUID: Task<Void, Never>] = [:]
    /// The newest wording of each waiting run's notice — the delayed banner shows THIS, and a position
    /// change rewrites it (phase 7).
    @ObservationIgnored private var localQueueNotices: [UUID: String] = [:]
    /// Runs whose queue banner is on screen, so a position change updates it in place.
    @ObservationIgnored private var localQueueBannerShown: Set<UUID> = []

    /// A run started waiting for the local model — at its start, or to take the lock back after a HITL
    /// answer. ⚠️ Said on screen and to a remote chat, not just in the log: a run waiting for ANOTHER
    /// conversation's run otherwise looks exactly like a hung one.
    private func localWaitBegan(_ agentMessage: ChatMessage, conversationID: UUID,
                                startedBy: MessageSource, position: Int) {
        agentMessage.agentState = .thinking(.awaitingLocalModel)
        let holder = inferenceCoordinator.holderManifest
        let notice = Self.localQueueNotice(
            holder: holder,
            holderTitle: holder?.conversationID.flatMap { persistenceService.getConversation(withId: $0)?.userDefinedTitle },
            position: position)
        let delegates = liveMirrorDelegates
        logger.info("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) in conversation \(conversationID.uuidString.prefix(8)) shows as WAITING for the local model (position \(position), holder \(holder.map { "\($0.runID.uuidString.prefix(8)) (\($0.origin))" } ?? "none")); \(delegates.count) mirror delegate(s) told. CONSEQUENCE: the banner follows if the wait lasts \(Self.localQueueBannerDelay).")
        for delegate in delegates {
            delegate.activeStreamManager(self, didQueueForLocalModel: agentMessage, notice: notice,
                                         startedBy: startedBy, for: conversationID)
        }
        localQueueNotices[agentMessage.id] = notice
        // The banner only for a wait that LASTS: a run admitted a second later should not flash one.
        localQueueBanners[agentMessage.id]?.cancel()
        localQueueBanners[agentMessage.id] = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: Self.localQueueBannerDelay)) != nil, let self else { return }
            logger.notice("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) is still waiting for the local model after \(Self.localQueueBannerDelay) — banner shown in conversation \(conversationID.uuidString.prefix(8)).")
            self.localQueueBannerShown.insert(agentMessage.id)
            self.postLocalQueueBanner(agentMessage.id, conversationID: conversationID)
        }
    }

    /// The queue banner — plain status, not dismissible (it goes when the wait does), above ambient
    /// advisories so a fit hint cannot hide it (phase 7).
    private func postLocalQueueBanner(_ messageID: UUID, conversationID: UUID) {
        guard let notice = localQueueNotices[messageID] else { return }
        AdvisoryCenter.shared.post(Advisory(
            conversationID: conversationID, category: .localModelBusy, message: notice,
            actionLabel: nil, action: nil,
            dedupeKey: "\(conversationID.uuidString)|localModelBusy|\(messageID.uuidString)",
            tone: .info, dismissible: false, priority: Advisory.runStatePriority))
    }

    /// The line moved: the run's notice (and its banner, when shown) says where it stands now.
    private func localPositionChanged(_ agentMessage: ChatMessage, conversationID: UUID, position: Int) {
        let holder = inferenceCoordinator.holderManifest
        localQueueNotices[agentMessage.id] = Self.localQueueNotice(
            holder: holder,
            holderTitle: holder?.conversationID.flatMap { persistenceService.getConversation(withId: $0)?.userDefinedTitle },
            position: position)
        logger.debug("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) is now number \(position) in line — notice updated\(self.localQueueBannerShown.contains(agentMessage.id) ? " and its banner rewritten" : "").")
        if localQueueBannerShown.contains(agentMessage.id) {
            postLocalQueueBanner(agentMessage.id, conversationID: conversationID)
        }
    }

    /// The pending "waiting for this conversation's run" banner per run (phase 7).
    @ObservationIgnored private var conversationQueueBanners: [UUID: Task<Void, Never>] = [:]

    /// A run is queued behind its OWN conversation's current run (`ConversationAdmission`). After the
    /// same short delay as the local-model wait, the banner says so — plain status, not dismissible.
    private func conversationQueueBegan(_ agentMessage: ChatMessage, conversationID: UUID) {
        logger.info("[ADMISSION] Run \(agentMessage.id.uuidString.prefix(8)) is queued behind conversation \(conversationID.uuidString.prefix(8))'s current run. CONSEQUENCE: shown as 'Waiting its turn'; the banner follows if the wait lasts \(Self.localQueueBannerDelay).")
        conversationQueueBanners[agentMessage.id]?.cancel()
        conversationQueueBanners[agentMessage.id] = Task { @MainActor in
            guard (try? await Task.sleep(for: Self.localQueueBannerDelay)) != nil else { return }
            logger.notice("[ADMISSION] Run \(agentMessage.id.uuidString.prefix(8)) still waits behind conversation \(conversationID.uuidString.prefix(8))'s current run — banner shown.")
            AdvisoryCenter.shared.post(Advisory(
                conversationID: conversationID, category: .conversationQueue,
                message: Self.conversationQueueNotice,
                actionLabel: nil, action: nil,
                dedupeKey: "\(conversationID.uuidString)|conversationQueue|\(agentMessage.id.uuidString)",
                tone: .info, dismissible: false, priority: Advisory.runStatePriority))
        }
    }

    /// The conversation wait ended — admitted or cancelled.
    private func conversationQueueEnded(_ agentMessage: ChatMessage, conversationID: UUID) {
        guard let banner = conversationQueueBanners.removeValue(forKey: agentMessage.id) else { return }
        banner.cancel()
        logger.debug("[ADMISSION] Run \(agentMessage.id.uuidString.prefix(8)) no longer waits behind its conversation — banner (if shown) cleared.")
        AdvisoryCenter.shared.clear(category: .conversationQueue, conversationID: conversationID)
    }

    nonisolated static let conversationQueueNotice =
        "Your message is queued behind this conversation's current run and starts by itself when that run finishes."

    // MARK: Phase 7 — asking before a run starts

    /// The run is held until its user chooses Proceed or Stop. The banner asks at once (no delay — it
    /// has a deadline), with a live countdown to the auto-deny.
    private func localConfirmationNeeded(_ agentMessage: ChatMessage, conversationID: UUID,
                                         concerns: [RunConcern], deadline: Date) {
        agentMessage.agentState = .thinking(.awaitingConfirmation)
        let message = Self.confirmationNotice(concerns)
        logger.notice("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) in conversation \(conversationID.uuidString.prefix(8)) is ASKING its user to proceed: \(concerns.map(\.description).joined(separator: "; ")). CONSEQUENCE: banner with Proceed and Stop shown; auto-denied at \(deadline.formatted(date: .omitted, time: .standard)) with no answer.")
        AdvisoryCenter.shared.post(Advisory(
            conversationID: conversationID, category: .runNeedsConfirmation, message: message,
            actionLabel: "Proceed", action: .proceedRun(messageID: agentMessage.id),
            dedupeKey: "\(conversationID.uuidString)|runNeedsConfirmation|\(agentMessage.id.uuidString)",
            secondaryActionLabel: "Stop", secondaryAction: .stopRun(messageID: agentMessage.id),
            tone: .warning, deadline: deadline, deadlineLabel: "Auto-denied in",
            dismissible: false, priority: Advisory.runQuestionPriority))
    }

    /// The user chose Proceed: the question goes; the run starts, or its queue status follows.
    private func localConfirmed(_ agentMessage: ChatMessage, conversationID: UUID) {
        logger.info("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)): Proceed chosen — question cleared in conversation \(conversationID.uuidString.prefix(8)).")
        AdvisoryCenter.shared.clear(category: .runNeedsConfirmation, conversationID: conversationID)
        if agentMessage.agentState == .thinking(.awaitingConfirmation) {
            agentMessage.agentState = .thinking(.reasoning)
        }
    }

    /// The banner's Proceed (main window and QuickAccess).
    func proceedHeldRun(messageID: UUID) {
        let accepted = inferenceCoordinator.proceed(runID: messageID)
        logger.info("[LOCAL-COORD] Proceed pressed for run \(messageID.uuidString.prefix(8)) — \(accepted ? "accepted" : "too late, nothing to do").")
    }

    /// What the asking banner says: the concern, and what may happen. The countdown and the buttons
    /// carry the rest. No advice (architecture_readme invariant 15).
    nonisolated static func confirmationNotice(_ concerns: [RunConcern]) -> String {
        let what = concerns.map { $0.description.prefix(1).uppercased() + $0.description.dropFirst() }.joined(separator: ". ")
        return "\(what). It may run very slowly or fail."
    }

    /// The wait ended (admitted or withdrawn): the banner goes, and the label stops saying "waiting".
    private func localWaitEnded(_ agentMessage: ChatMessage, conversationID: UUID) {
        logger.debug("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) is no longer waiting for the local model — its banner (if shown) is cleared in conversation \(conversationID.uuidString.prefix(8)).")
        localQueueBanners.removeValue(forKey: agentMessage.id)?.cancel()
        localQueueNotices.removeValue(forKey: agentMessage.id)
        localQueueBannerShown.remove(agentMessage.id)
        AdvisoryCenter.shared.clear(category: .localModelBusy, conversationID: conversationID)
        AdvisoryCenter.shared.clear(category: .runNeedsConfirmation, conversationID: conversationID)
        if agentMessage.agentState == .thinking(.awaitingLocalModel) || agentMessage.agentState == .thinking(.awaitingConfirmation) {
            agentMessage.agentState = .thinking(.reasoning)
        }
    }

    /// Stops a run that has used more than `limit` of COMPUTE (the global ceiling, phase 5). Returns
    /// without doing anything when the run ends first — its task is cancelled by the run itself.
    ///
    /// ⚠️ Stamps TIMED OUT before cancelling, like the scheduler's deadline: finalize writes
    /// "Cancelled by user" only when no outcome is set yet, and this is not the user's Stop.
    private func enforceGlobalCeiling(_ limit: TimeInterval, scope: UUID, on agentMessage: ChatMessage) async {
        do {
            try await ComputeTimeoutSentinel.sleepUntilComputeExceeded(
                limit: limit,
                scope: scope,
                logTag: "LOCAL-COORD",
                subject: "Run \(agentMessage.id.uuidString.prefix(8)) (global ceiling)",
                consequence: "the run is stopped and recorded as timed out (scope: global); time spent awaiting a human or waiting for the local model was excluded. The local lock passes to the next run.")
        } catch is AgentExecutionError {
            // Only a run still live: a sentinel firing in the instant after its run finalized must not
            // rewrite a finished message's outcome.
            guard activeStreams[agentMessage.id] != nil else {
                logger.info("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) reached the global ceiling just as it finished. CONSEQUENCE: nothing is changed — its recorded outcome stands.")
                return
            }
            agentMessage.terminalOutcome = .timedOut
            agentMessage.terminalReason = Self.globalCeilingMessage(limit: limit)
            cancelStream(for: agentMessage.id)
            let parks = await ExecutionSuspensionService.shared.cancel(scope: scope)
            logger.notice("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) STOPPED by the global ceiling (\(ToolExecutionMediator.describe(limit)) of compute) — stamped TIMED OUT, task cancelled, \(parks.count) park(s) in its scope cancelled. CONSEQUENCE: the run ends as timed out and the local lock passes to the next run.")
        } catch {
            return   // cancelled: the run finished first
        }
    }

    /// A run withdrawn before it did any work — Stop, a deadline or a deleted conversation while it
    /// waited behind its conversation or for the local model. Stamped exactly as the run body's own
    /// cancellation is, and then finalized WITHOUT an error.
    ///
    /// ⚠️ Finalizing with a `CancellationError` (as these two exits used to) records the run as
    /// FAILED under a "Response Error" card reading "The operation couldn't be completed
    /// (Swift.CancellationError error 1.)" — mirrored as a failure to a ChatOps chat — and leaves a
    /// workflow run's record unsettled.
    static func markWithdrawnBeforeStart(_ message: ChatMessage, workflow: WorkflowExecutionState?) {
        workflow?.handleError("Cancelled", cancelled: true)
        if message.terminalOutcome == nil {
            message.terminalOutcome = .cancelled
            message.terminalReason = message.terminalReason ?? "Cancelled by user"
        }
    }

    /// The wording of a global-ceiling stop (HITL Waiting Contract §4 style).
    nonisolated static func globalCeilingMessage(limit: TimeInterval) -> String {
        "Run stopped: it reached the \(ToolExecutionMediator.describe(limit)) maximum run time set in Settings → General. Time spent waiting for your approval or for the local model was not counted."
    }

    /// How long a run waits for the local model before its conversation shows the banner.
    static let localQueueBannerDelay: Duration = .seconds(5)

    /// What a run waiting for the local model tells the user (banner) and a remote chat. Plain
    /// status: who holds the model and where this run stands — no advice (architecture_readme invariant 15).
    nonisolated static func localQueueNotice(holder: InferenceRunManifest?, holderTitle: String?, position: Int) -> String {
        let models = holder?.localModels.map(\.modelID).joined(separator: ", ") ?? ""
        let model = models.isEmpty ? "The local model" : "The local model (\(models))"
        let title = holderTitle.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let place: String
        if case .intelligence(let feature)? = holder?.origin {
            place = "\(feature) (a background task)"
        } else {
            place = title.map { "a run in “\($0)”" } ?? "a run in another conversation"
        }
        let line = position <= 1 ? "next in line" : "number \(position) in line"
        return "\(model) is in use by \(place). This run is \(line) and starts by itself when that run finishes."
    }

    /// The execution-timeout wording (HITL Waiting Contract §4), shared by chat, Code and the scheduler.
    nonisolated static func executionTimeoutMessage(limit: TimeInterval) -> String {
        "Run stopped: it exceeded its \(ToolExecutionMediator.describe(limit)) execution limit. Time spent waiting for your approval was not counted."
    }

    private func finalizeMessage(_ message: ChatMessage, conversationID: UUID, error: Error?) async {
        message.isStreaming = false
        // A run ending (success, error or Stop) is when its file changes are complete.
        WorkspaceActivity.post(reason: "run finished")
        // [G1 Piece 1] A finalized run (success, error, or user Stop) is a clean terminal state —
        // mark it `.final` so it is NOT mistaken for an interrupted run on restart. Only a process
        // death that skips finalize leaves a persisted `.streaming` / `.parkedHITL` row behind.
        message.lifecycleState = .final
        lastInFlightFlush.removeValue(forKey: message.id)
        message.agentState = .idle
        // [HITL/P5] No center drain here: a normally-finalized stream has no parked HITL (the agent
        // can't complete while waiting), and cancel/error paths route through
        // ExecutionSuspensionService.cancel(for:) which posts .hitl*Resolved → op-id resolve.
        // A coarse resolveAll(conversationID:) here would wrongly clear a *concurrent* stream's
        // still-parked HITL in the same conversation, so it is intentionally omitted.

        // NOTE: per-conversation "Allow for this chat" grants are deliberately NOT cleared here. They
        // persist for the conversation's lifetime (and across restarts via SessionToolApprovals' durable
        // store), so a later message in the same chat isn't re-prompted; they're dropped only when the
        // conversation is deleted (ConversationManagementCoordinator.drainLiveExecution).

        // Terminal-outcome safety net: if no executor emitted `.executionFinished`
        // (legacy code path, early `continuation.finish()` in a catch block, or a
        // third-party executor), infer the outcome from how the run actually ended.
        // [ASM-4] Keying only on "did a throw reach us" stamped `.completed` (green
        // chip + `completed` trace status) over an ERROR CARD whenever a producer
        // yielded `.error` and then finished without throwing. The resolver also
        // inspects the content (pure + tested: `ChatMessage.resolveFallbackOutcome`).
        // HITL Waiting Contract §3–4: an execution limit is TIMED OUT, with the contract's message —
        // not a "Response Error" card or a generic failure.
        if message.terminalOutcome == nil,
           let agentError = error as? AgentExecutionError,
           case .executionTimeout(_, let limit) = agentError.reason {
            message.terminalOutcome = .timedOut
            message.terminalReason = Self.executionTimeoutMessage(limit: limit)
        }
        if message.terminalOutcome == nil {
            let fallback = ChatMessage.resolveFallbackOutcome(
                threwError: error,
                content: message.currentAgentContent ?? message.content
            )
            message.terminalOutcome = fallback.outcome
            if message.terminalReason == nil {
                message.terminalReason = fallback.reason
            }
            if error == nil, fallback.outcome == .failed {
                logger.warning("[STREAM_FINALIZE] messageID: \(message.id.uuidString.prefix(8)) — no .executionFinished received; inferred .failed from error-card content (previously recorded .completed) (ASM-4).")
            }
        }

        // [TL-1] Close any tool row still spinning at end-of-run — cancel and failure
        // mid-tool used to persist rows with `isExecuting == true`, so the spinner
        // survived reload forever.
        let closedRows = message.closeDanglingToolRowsReporting(outcome: message.terminalOutcome)
        if !closedRows.isEmpty {
            logger.warning("[STREAM_FINALIZE] messageID: \(message.id.uuidString.prefix(8)) — closed \(closedRows.count) dangling tool row(s) at finalize (outcome: \(message.terminalOutcome?.rawValue ?? "nil")); a persisted row must never claim to still be executing (TL-1).")
        }

        // [CF-9] Settle the LIVE CODE VIEWER TAB for every abandoned file write.
        //
        // A live tab is opened from `.toolCall`, which `ToolExecutionLoop` yields BEFORE the
        // permission park; both of its terminal transitions hang off the `.toolSucceeded` /
        // `.toolFailed` posts above. Stop pressed while a write is parked throws
        // `CancellationError` WITHOUT yielding `.toolFailed` (ToolExecutionLoop, "if
        // Task.isCancelled { throw CancellationError() }"), and a provider throw reaches the
        // generic catch the same way — so neither posted a completion and
        // `ChatHistoryViewModel.handleAgentWriteCompleted` was never called. The tab kept
        // `liveState == .active` for the rest of the session: the orange "Agent is writing this
        // file" banner stayed up, `hasLiveAgentTabs` kept the minimized pill pulsing, and the
        // proposal that never reached disk was never marked rejected.
        //
        // This runs on EVERY finalize, including the clean one — where it is a no-op, because a
        // tool that completed normally is not a dangling row. `isSuccess: false` is the honest
        // value: the write did not land.
        //
        // ⚠️ `completed(...)` is NOT the exact inverse of `began(...)`, and the log below is worded
        // for that. `began` additionally refuses an empty `content` and anything over
        // `liveContentByteLimit`, so a 600 KB write opens no tab and this loop still produces a
        // payload for it. Posting one is harmless — `handleAgentWriteCompleted` finds no matching
        // `.active` tab and says so at debug — but the line must not claim a tab settled.
        for row in closedRows {
            guard let payload = AgentLiveWriteEvent.completed(
                toolName: row.name,
                params: row.params,
                isSuccess: false,
                preWriteContent: nil,
                conversationID: conversationID
            ) else { continue }
            NotificationCenter.default.post(
                name: AgentLiveWriteEvent.completed, object: nil,
                userInfo: [AgentLiveWriteEvent.payloadKey: payload]
            )
            logger.warning("[CodeViewer] messageID: \(message.id.uuidString.prefix(8)) — the run ended without a completion event for the live write of '\(payload.fileName)'; posting a failed completion now. CONSEQUENCE: if that file has a live tab it settles as rejected (the proposal never reached disk) instead of claiming the agent is still writing for the rest of the session; if no tab was opened for it — an empty or over-cap write, which `began` refuses — the post is a no-op and the handler logs that at debug.")
        }

        if let traceID = message.traceID {
            // Derive the persisted trace status from how the run *actually* ended, not
            // merely from whether an error was thrown. A thrown exception reaching this
            // boundary is the most severe signal and always wins; otherwise we honor the
            // `terminalOutcome` the executor reported via `.executionFinished` (set just
            // above), so graceful failures (circuit-breaker, exhaustion, all-nodes-failed,
            // ImageGen) and cancellations stop being recorded as `.completed`.
            // `terminalReason` carries the human-readable cause for non-thrown failures;
            // it is sanitized inside `endTrace`.
            let traceStatus = TraceStatus.resolve(thrownError: error != nil, terminalOutcome: message.terminalOutcome)
            let endErrorSummary = error?.localizedDescription ?? message.terminalReason
            logger.info("[TRACE_END] traceID: \(traceID), status: \(traceStatus.rawValue), messageID: \(message.id.uuidString.prefix(8))")
            await TraceRecorder.shared.endTrace(traceID: traceID, status: traceStatus, error: endErrorSummary)
            if let usage = message.tokenUsage {
                await TraceRecorder.shared.recordTokenUsage(traceID: traceID, usage: usage)
            }
        }
        
        if let error = error {
            // Render typed retrieval failures (e.g. an attached image that couldn't
            // be loaded for a vision turn) with their category icon + remediation,
            // symmetric with the streaming `.error(StructuredError)` path, instead of
            // the generic "Response Error" card this chokepoint would otherwise force.
            let errorCard: MessageContent
            if let fre = error as? FileRetrievalError {
                let se = fre.structuredError
                errorCard = .error(title: se.title, details: se.message, category: se.category, suggestion: se.suggestion)
            } else {
                if let agentError = error as? AgentExecutionError,
                   case .executionTimeout(_, let limit) = agentError.reason {
                    errorCard = .error(title: "Timed out", details: Self.executionTimeoutMessage(limit: limit))
                } else if let refusal = error as? LocalInferenceRefusal {
                    errorCard = .error(title: refusal.title, details: refusal.details)
                } else {
                    errorCard = .error(title: "Response Error", details: error.localizedDescription)
                }
            }

            // [ASM-2] Don't discard prose the user watched stream: if real partial text
            // exists it stays as content and the error demotes to a timeline warning
            // (failure remains loud via the `.failed` chip + retry). No prose → the
            // error card replaces as before. Pure + tested: `resolveThrownFinalContent`.
            let resolved = ChatMessage.resolveThrownFinalContent(
                streamed: message.currentAgentContent ?? message.content,
                errorCard: errorCard
            )
            message.content = resolved.content
            if let demoted = resolved.demotedError {
                message.appendTimelineEvent(demoted)
                let kept = resolved.content.textContent?.count ?? 0
                logger.log("[STREAM_FINALIZE] messageID: \(message.id.uuidString.prefix(8)) — preserved \(kept) chars of partial streamed prose; terminal error demoted to timeline (ASM-2).")
            }

            if let agentResponse = message.agentResponse,
               agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                message.agentResponse?.variants[agentResponse.selectedVariantIndex].content = resolved.content
            }
        } else {
            // Resolve the display content: streamed text if any; else a generated
            // image (image runs stream NO text — without this promotion the artifact
            // stayed only in the timeline as a `.mediaGeneration` event, which the
            // bubble can't render, so a successful generation showed the placeholder
            // and the image was invisible — audit gap #2); else the "stopped"
            // placeholder so an empty/cancelled run doesn't masquerade as a clean
            // completion. Logic lives in `ChatMessage.resolveFinalizedContent` so it's
            // unit-testable (GeneratedImageRenderGapTests).
            let resolvedContent = ChatMessage.resolveFinalizedContent(
                streamed: message.currentAgentContent,
                imageArtifact: message.lastCompletedImageArtifact
            )
            message.content = resolvedContent
            // Keep the selected variant in sync so `currentAgentContent` (which the UI
            // reads) doesn't return a stale empty variant. A no-op when `resolvedContent`
            // IS the streamed content; load-bearing for the promoted-image / placeholder
            // cases.
            if let agentResponse = message.agentResponse,
               agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                message.agentResponse?.variants[agentResponse.selectedVariantIndex].content = resolvedContent
            }
        }
        
        // Persist final message
        await persistenceService.addMessage(message, toConversation: conversationID)
        
        // [RAG UPGRADE] Event-Driven Vectorization
        // Fire-and-forget: Index the final message into the vector database without blocking the UI.
        let persistence = persistenceService
        // Snapshot NOW, on the main actor — the detached indexer must never read the live message,
        // which a Redo can start rewriting within the 500 ms below (RAG-16).
        let indexable = IndexableMessage(message)
        Task.detached(priority: .background) {
            // Brief pause to ensure UI settles and CoreData write completes
            try? await Task.sleep(nanoseconds: 500_000_000)
            // ⚠️ CR-61: the conversation may have been DELETED meanwhile — deleting it is what
            // cancelled this run. Indexing now would put content the user deleted back into the
            // vector store, after its documents were removed.
            let stillExists = await MainActor.run { persistence.getConversation(withId: conversationID) != nil }
            guard stillExists else {
                logger.notice("[RAG] Not indexing message \(message.id.uuidString.prefix(8)) — conversation \(conversationID.uuidString.prefix(8)) was deleted. CONSEQUENCE: nothing from it re-enters the vector store.")
                return
            }
            await RAGIndexingService.shared.indexSingleMessage(indexable)
        }
        
        activeStreams.removeValue(forKey: message.id)
        liveRunQuestionIDs.removeValue(forKey: message.id)   // in lockstep with activeStreams
        streamStartedAt.removeValue(forKey: message.id)
        // ⚠️ AFTER the removal, never before: `isConversationBusy` reads `activeStreams`, so
        // admitting first would hand the next run a conversation that still looks occupied by the
        // one just finishing — and it would park again with nothing left to wake it.
        admission.admitNext(inConversation: conversationID)
        // Every run end comes through here (finished, failed, cancelled); idempotent for a run that
        // never registered (cancelled while queued behind its conversation).
        inferenceCoordinator.unregister(runID: message.id)
        for delegate in liveMirrorDelegates {
            delegate.activeStreamManager(self, didEndStream: message)
        }

        // Dispatch notification if app is in background
        let notifConversationID = conversationID
        let hasError = error != nil
        guard let notificationTitle = Self.completionNotificationTitle(outcome: message.terminalOutcome,
                                                                      hasError: hasError) else {
            logger.info("[NOTIFY] No completion notification for run \(message.id.uuidString.prefix(8)) in conversation \(conversationID.uuidString.prefix(8)) — it was cancelled. CONSEQUENCE: nothing is delivered on any channel; whoever stopped it (Stop, closing the orb, a deleted conversation) already knows.")
            return
        }
        let summaryText: String = {
            switch message.content {
            case .plainText(let text), .markdownText(let text):
                return String(text.prefix(100))
            default:
                return hasError ? "An error occurred." : "Response complete."
            }
        }()

        Task.detached(priority: .utility) {
            // [C6] Suppress when the user is actively viewing — app frontmost OR the
            // non-activating QuickAccess panel is key (which NSApp.isActive alone misses,
            // so a completion the user watches in the panel would otherwise double-notify).
            let userIsViewing = await MainActor.run { NSApp.isActive || (AppDelegate.shared?.isQuickAccessPanelKey ?? false) }
            guard !userIsViewing else { return }

            let payload = AppNotificationPayload(
                title: notificationTitle,
                body: summaryText,
                conversationID: notifConversationID
            )
            await NotificationDispatcher.shared.dispatch(payload)
        }
    }
    
    
    /// The title of the "your run finished" notification, or nil for a run that must not announce
    /// itself. Pure.
    /// ⚠️ A CANCELLED run is not announced. It used to arrive as "Query Completed", because a cancel
    /// carries no error (device test 2026-10-10: closing the orb mid-answer notified that the query
    /// had completed). Someone stopped it on purpose, so there is nothing to tell them.
    nonisolated static func completionNotificationTitle(outcome: ExecutionOutcome?, hasError: Bool) -> String? {
        if outcome == .cancelled { return nil }
        return hasError || outcome == .failed ? "Query Failed" : "Query Completed"
    }

    private func removeTask(for messageId: UUID) {
        if activeTasks.removeValue(forKey: messageId) != nil {
            logger.debug("Cleaned up and removed completed task for message ID: \(messageId.uuidString)")
        }
    }
}

// The send path's chokepoint, as a seam. See `MessageStreamStarting` for why it is this narrow
// and why a surface's hand-off is worth pinning. Both members already exist with the required
// shapes, so this is a declaration of intent rather than an adapter.
extension ActiveStreamManager: MessageStreamStarting {}
