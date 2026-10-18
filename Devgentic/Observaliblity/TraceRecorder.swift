// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TraceRecorder.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import GRDB
import os

/// A global, background trace recording service backed by persistent, structured storage via `TraceStore`.
/// All `emit*` methods are fire-and-forget: they buffer events in memory and flush to disk in batches to minimize I/O
/// overhead during agent loops.
actor TraceRecorder {
    
    static let shared = TraceRecorder()
    
    private let store: TraceStore?
    private var pendingEvents: [SpanEvent] = []
    private var flushTask: Task<Void, Never>?
    private var closedTraceIDs: Set<String> = []
    
    private let logger = Logger(subsystem: DGLogger.subsystem, category: "TraceRecorder")
    
    // Configuration
    private let flushInterval: TimeInterval = 1.0
    private let maxBatchSize = 50
    
    // MARK: - Initialization
    
    /// `store` is injectable so tests can drive a real recorder against a hermetic `TraceStore(inMemory:)`;
    /// production uses the default `.shared`, which keeps the one-pool/one-migration topology.
    init(store: TraceStore? = TraceStore.shared) {
        // Use the shared TraceStore singleton so LogRecorder, MetricsAggregator and other observability actors share one
        // connection pool and one migration run; separate stores would race on migrations.
        self.store = store
        if self.store != nil {
            logger.info("TraceRecorder initialized with shared persistent store.")
        } else {
            logger.error("TraceStore.shared is nil — recording disabled.")
        }

        // Start the periodic flush loop after initialization completes
        Task {
            await self.startFlushLoop()
        }
    }
    
    private func startFlushLoop() {
        flushTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.flushInterval))
                await self.flush()
            }
        }
    }
    
    deinit {
        flushTask?.cancel()
    }
    
    // MARK: - Trace Lifecycle
    
    /// Begins recording a new trace for a request → response cycle.
    func beginTrace(
        context: TraceContext,
        conversationID: UUID,
        messageID: UUID,
        modelName: String?
    ) {
        guard let store else { return }

        // Stamp the build on every trace (config snapshots are chat-path-only) so the 30-day DB can be split by version.
        let info = Bundle.main.infoDictionary

        let record = TraceRecord(
            traceID: context.traceID,
            conversationID: conversationID.uuidString,
            messageID: messageID.uuidString,
            profileID: context.profileInfo.id.uuidString,
            profileName: context.profileInfo.name,
            profileType: context.profileInfo.type.rawValue,
            provider: context.profileInfo.provider?.rawValue,
            modelName: modelName,
            startedAt: context.requestStartTime,
            status: .running,
            appVersion: info?["CFBundleShortVersionString"] as? String,
            buildNumber: info?["CFBundleVersion"] as? String
        )
        
        do {
            try store.insertTrace(record)
            
            // Auto-create a root span to satisfy foreign key constraints 
            // for events emitted against the trace-level context.
            let rootSpan = Span(
                spanID: context.spanID,
                traceID: context.traceID,
                parentSpanID: nil,
                name: "root",
                kind: .workflow,
                startedAt: context.requestStartTime,
                status: .running
            )
            try store.insertSpan(rootSpan)
            
            logger.debug("Began trace: \(context.traceID) with root span: \(context.spanID)")
        } catch {
            logger.error("Failed to insert trace: \(error.localizedDescription)")
        }
    }
    
    // Why: use this, not `beginSpan`, for a context not created via `newSpan()`: an unconditional insert collides with
    // `beginTrace`'s row (UNIQUE constraint on `spans.spanID`).
    /// Idempotently guarantees the span row for `context.spanID` exists, carrying the caller's `name`/`kind`.
    /// Chat pipeline: renames the root span `beginTrace` created, keeping its startedAt/status/endedAt.
    /// Headless flows (tests, nested sub-workflows, direct executor calls): `beginTrace` never ran, so this inserts the row.
    func ensureRootSpan(context: TraceContext, name: String, kind: SpanKind) {
        guard let store else { return }

        let span = Span(
            spanID: context.spanID,
            traceID: context.traceID,
            parentSpanID: context.parentSpanID,
            name: name,
            kind: kind,
            startedAt: Date(),
            status: .running
        )

        do {
            let inserted = try store.ensureSpan(span)
            logger.debug("Ensured root span: \(name) [\(context.spanID)] (\(inserted ? "inserted" : "renamed existing"))")
        } catch {
            logger.error("Failed to ensure root span '\(name)': \(error.localizedDescription)")
        }
    }

    /// Records the start of a new span within a trace.
    /// `at` defaults to `Date()`, evaluated at the call site, so callers hopping through an unstructured `Task {}` must
    /// capture the date before the hop and pass it explicitly.
    func beginSpan(context: TraceContext, name: String, kind: SpanKind, at: Date = Date(), metadata: [String: String]? = nil) {
        guard let store else { return }

        let span = Span(
            spanID: context.spanID,
            traceID: context.traceID,
            parentSpanID: context.parentSpanID,
            name: name,
            kind: kind,
            startedAt: at,
            status: .running,
            metadataJSON: Self.serializeSpanMetadata(metadata)
        )

        do {
            try store.insertSpan(span)
            logger.debug("Began span: \(name) [\(context.spanID)]")
        } catch {
            logger.error("Failed to insert span '\(name)': \(error.localizedDescription)")
        }
    }

    /// Marks a span as completed or errored. `at` is call-site-stamped (see `beginSpan`); `defer { Task { … } }` sites
    /// capture it before the hop so the persisted end is the real end (earliest wins in `TraceStore.updateSpan`).
    func endSpan(spanID: String, status: SpanStatus, at: Date = Date(), metadata: [String: String]? = nil) {
        guard let store else { return }

        do {
            try store.updateSpan(spanID: spanID, endedAt: at, status: status,
                                 metadataJSON: Self.serializeSpanMetadata(metadata))
        } catch {
            logger.error("Failed to end span \(spanID): \(error.localizedDescription)")
        }
    }

    /// Span metadata is a flat, short-string bag (per-call tokens, durations, model ids) —
    /// sanitized per value because callers occasionally pass tool-derived strings. Sorted
    /// keys so byte-identical inputs produce byte-identical blobs.
    static func serializeSpanMetadata(_ metadata: [String: String]?) -> String? {
        guard let metadata, !metadata.isEmpty else { return nil }
        var sanitized: [String: String] = [:]
        for (k, v) in metadata { sanitized[k] = TelemetrySanitizer.sanitize(v) }
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    /// Marks a trace as completed or errored.
    func endTrace(traceID: String, status: TraceStatus, error: String? = nil) {
        // Flush any pending events for this trace synchronously on the actor
        flush()

        guard let store else { return }

        let sanitizedError = error.map { TelemetrySanitizer.sanitize($0) }

        do {
            let endedAt = Date()
            try store.updateTrace(traceID: traceID, endedAt: endedAt, status: status, errorSummary: sanitizedError)
            // Close any spans still open for this trace (notably the root span, plus any leaked by an abnormal exit).
            // Degraded success is still success at span level, and a user Stop clamps open spans as .cancelled, not .error.
            let spanStatus: SpanStatus = switch status {
            case .completed, .completedWithWarnings: .completed
            case .cancelled: .cancelled
            case .running, .failed, .error, .interrupted: .error
            }
            try store.closeOpenSpans(traceID: traceID, endedAt: endedAt, status: spanStatus)
            logger.debug("Ended trace: \(traceID) with status: \(status.rawValue)")
        } catch {
            logger.error("Failed to end trace \(traceID): \(error.localizedDescription)")
        }

        // Reject any late-arriving events for this trace
        closedTraceIDs.insert(traceID)
        if closedTraceIDs.count > 100 {
            closedTraceIDs.removeAll()
        }
    }

    /// Records the run's accumulated token usage and cost on the trace; no-op for zero usage. Call once at trace end.
    /// The cost is `usage.costUSD`: each call priced at its own model when read (`ModelPriceList`), then summed.
    func recordTokenUsage(traceID: String, usage: TokenUsage) {
        guard let store, usage.totalTokens > 0 else { return }
        let modelName = (try? store.fetchTrace(traceID: traceID))?.modelName
        let cost = usage.costUSD
        if usage.costIsPartial, let cost {
            logger.notice("[PRICING] trace \(traceID): cost $\(String(format: "%.6f", cost)) covers only the calls that could be priced. CONSEQUENCE: the run's real cost is higher — a call ran on a model with no known price (a local model, a custom endpoint, or one missing from ModelPrices.json).")
        }
        // Run-level evidence of a provider prompt cache, for every provider at once (Claude also logs `[ANTHROPIC-CACHE]`
        // per request). The split is not stored: the trace keeps the prompt total, and the cost already prices it.
        if usage.cacheReadTokens > 0 || usage.cacheWriteTokens > 0 {
            logger.info("[TOKENS] trace \(traceID): \(usage.inputTokens) prompt tokens, \(usage.cacheReadTokens) read from the provider's cache, \(usage.cacheWriteTokens) written to it; \(usage.outputTokens) out; model '\(modelName ?? "?")'.")
        }
        do {
            try store.updateTraceTokens(
                traceID: traceID,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                estimatedCostUSD: cost,
                estimated: usage.isEstimated
            )
        } catch {
            logger.error("Failed to record token usage for trace \(traceID): \(error.localizedDescription)")
        }
    }

    // MARK: - Event Recording (Fire-and-Forget)
    
    /// Appends an event to the buffer. Auto-flushes when batch size is reached.
    /// Events for already-closed traces are silently dropped.
    func emit(_ event: SpanEvent) {
        // A userInteraction event can arrive just after its trace closes (a HITL resolved on Stop/cancel ends the run first);
        // the root span row still exists, so let these through rather than dropping the decision span.
        guard !closedTraceIDs.contains(event.traceID) || event.eventType == .userInteraction else { return }

        pendingEvents.append(event)

        if pendingEvents.count >= maxBatchSize {
            flush()
        }
    }
    
    // MARK: - Convenience Emitters
    
    /// Records an agent thought / reasoning step.
    func emitThought(span: TraceContext, text: String) {
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            eventType: .thought,
            content: TelemetrySanitizer.sanitize(text),
            severity: .info
        ))
    }
    
    /// Records a tool invocation.
    func emitToolCall(span: TraceContext, name: String, arguments: String) {
        let detail: [String: Any] = ["tool_name": name, "arguments_preview": String(TelemetrySanitizer.sanitize(arguments).prefix(500))]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            eventType: .toolCall,
            content: name,
            detailJSON: serializeDetail(detail),
            severity: .info
        ))
    }
    
    /// Records a tool execution result, populating the indexed `durationMs` column so aggregation can compute latency.
    /// Failures also get a best-effort `AgentErrorCategory` (`.toolSemanticFail` for error-shaped output).
    /// `failureCategory` is the real category when the caller knows it (e.g. `.toolTimeout`); nil keeps the inference.
    func emitToolResult(span: TraceContext, name: String, success: Bool, output: String, durationMs: Int, at: Date = Date(),
                        failureCategory: AgentErrorCategory? = nil) {
        let detail: [String: Any] = [
            "tool_name": name,
            "is_success": success,
            "duration_ms": durationMs,
            "output_preview": String(TelemetrySanitizer.sanitize(output).prefix(500))
        ]
        // v2 analytics columns are sanitized and non-PII (enums/ints), so they are recorded whenever diagnostics are enabled,
        // not just in developer mode; failures without an explicit category default to `.toolSemanticFail`.
        let recordV2 = UserDefaults.standard.bool(forKey: AppSettings.developerModeKey) || AppSettings.diagnosticsRecordingEnabled
        let inferredCategory: AgentErrorCategory? = success ? nil : (failureCategory ?? .toolSemanticFail)

        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            timestamp: at,
            eventType: .toolResult,
            content: "\(name): \(success ? "success" : "failed")",
            detailJSON: serializeDetail(detail),
            severity: success ? .info : .warning,
            errorCategory: recordV2 ? inferredCategory : nil,
            phase: recordV2 ? .tooling : nil,
            durationMs: recordV2 ? durationMs : nil
        ))
    }
    
    /// Records an LLM request being sent.
    func emitLLMRequest(span: TraceContext, model: String, messageCount: Int, at: Date = Date()) {
        let detail: [String: Any] = ["model": model, "messages_count": messageCount]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            timestamp: at,
            eventType: .llmRequest,
            content: "Request to \(model)",
            detailJSON: serializeDetail(detail),
            severity: .debug
        ))
    }
    
    /// Records an LLM response received.
    func emitLLMResponse(span: TraceContext, durationMs: Int, preview: String, at: Date = Date()) {
        let detail: [String: Any] = [
            "duration_ms": durationMs,
            "response_preview": String(TelemetrySanitizer.sanitize(preview).prefix(300))
        ]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            timestamp: at,
            eventType: .llmResponse,
            content: "Response received (\(durationMs)ms)",
            detailJSON: serializeDetail(detail),
            severity: .debug
        ))
    }
    
    /// Records a parse error during cognitive step parsing.
    func emitParseError(span: TraceContext, rawOutput: String, error: String) {
        let detail: [String: Any] = [
            "raw_output_preview": String(TelemetrySanitizer.sanitize(rawOutput).prefix(500)),
            "error": TelemetrySanitizer.sanitize(error)
        ]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            eventType: .parseError,
            content: "Parse error: \(TelemetrySanitizer.sanitize(error))",
            detailJSON: serializeDetail(detail),
            severity: .warning
        ))
    }
    
    /// Records an agent state transition.
    func emitStateChange(span: TraceContext, from: String, to: String) {
        let detail: [String: Any] = ["from": from, "to": to]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            eventType: .stateChange,
            content: "\(from) → \(to)",
            detailJSON: serializeDetail(detail),
            severity: .debug
        ))
    }
    
    /// Records a user interaction event (HITL permission, clarification).
    func emitUserInteraction(span: TraceContext, type: String, toolName: String?, outcome: String, at: Date = Date()) {
        let safeOutcome = TelemetrySanitizer.sanitize(outcome)
        var detail: [String: Any] = ["type": type, "outcome": safeOutcome]
        if let t = toolName { detail["tool"] = t }
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            timestamp: at,
            eventType: .userInteraction,
            content: "\(type): \(safeOutcome)",
            detailJSON: serializeDetail(detail),
            severity: .info
        ))
    }

    // MARK: - HITL Audit (C2 — durable, cross-restart)

    /// [HITL/C2] Persist the RAISE of a HITL request to the durable audit table, so a request still
    /// pending at app quit/crash survives (the launch reconcile pass stamps it `interrupted`). Covers
    /// chat, code, and ALL workflow HITL including gates — independent of the C1 trace-span path.
    func recordHITLRaised(
        operationID: String,
        conversationID: String,
        interface: String,
        type: String,
        toolName: String?,
        nodeName: String?,
        title: String,
        raisedAt: Date,
        traceID: String? = nil,
        spanID: String? = nil
    ) {
        guard let store else { return }
        let record = HITLAuditRecord(
            operationID: operationID,
            conversationID: conversationID,
            interface: interface,
            type: type,
            toolName: toolName,
            nodeName: nodeName,
            title: TelemetrySanitizer.sanitize(title),
            raisedAt: raisedAt,
            traceID: traceID,
            spanID: spanID
        )
        do {
            try store.insertHITLAudit(record)
        } catch {
            logger.error("HITL audit raise persist failed: \(error.localizedDescription)")
        }
    }

    // Why: the raise and resolve are independent Tasks; stranding the outcome would make the launch reconcile mislabel the
    // row as interrupted.
    /// Stamps the durable audit row with the resolution outcome and time, keyed by operationID.
    /// Retries briefly when the raise INSERT has not landed yet (UPDATE matches 0 rows), yielding via `Task.sleep`.
    /// A 0-row result on an already-resolved row (late duplicate) just retries harmlessly.
    func recordHITLResolved(operationID: String, outcome: String, resolvedAt: Date) async {
        guard let store else { return }
        let safeOutcome = TelemetrySanitizer.sanitize(outcome)
        for attempt in 0..<3 {
            do {
                if try store.resolveHITLAudit(operationID: operationID, resolvedAt: resolvedAt, outcome: safeOutcome) > 0 {
                    return
                }
            } catch {
                logger.error("HITL audit resolve persist failed: \(error.localizedDescription)")
                return
            }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(30)) }
        }
        logger.warning("HITL audit resolve found no pending row for op \(operationID) after retries.")
    }

    /// [G1 Piece 2] A parked-then-interrupted HITL was successfully resumed — flip its audit row from
    /// `interrupted` to `resumed` so the log reflects the recovery. No-op (logged) if no interrupted row
    /// exists for this operationID (resolved cleanly before quit, or purged).
    func recordHITLResumed(operationID: String) async {
        guard let store else { return }
        do {
            if try store.markHITLAuditResumed(operationID: operationID) == 0 {
                logger.info("HITL audit resume: no interrupted row for op \(operationID) (nothing to update).")
            }
        } catch {
            logger.error("HITL audit resume persist failed: \(error.localizedDescription)")
        }
    }

    /// Records a general error.
    func emitError(span: TraceContext, error: String, isRecoverable: Bool, at: Date = Date()) {
        let detail: [String: Any] = [
            "error": TelemetrySanitizer.sanitize(error),
            "is_recoverable": isRecoverable
        ]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            timestamp: at,
            eventType: .error,
            content: TelemetrySanitizer.sanitize(error),
            detailJSON: serializeDetail(detail),
            severity: .error
        ))
    }
    
    /// Records one prompt-context injection: a system-prompt layer that shipped in this run's request, with its provenance.
    /// Rides the existing `.memoryOp` event type rather than a new case, so old builds reading new rows keep decoding.
    /// `preview` should arrive pre-truncated and is sanitized here at `.minimal`.
    func emitContextInjection(span: TraceContext, source: String, chars: Int, preview: String, at: Date = Date()) {
        let detail: [String: Any] = [
            "source": source,
            "chars": chars,
            "preview": TelemetrySanitizer.sanitize(String(preview.prefix(200)))
        ]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            timestamp: at,
            eventType: .memoryOp,
            content: source,
            detailJSON: serializeDetail(detail),
            severity: .info
        ))
    }

    /// Records a performance metric.
    func emitMetric(span: TraceContext, key: String, valueMs: Int, at: Date = Date()) {
        let detail: [String: Any] = ["key": key, "value_ms": valueMs]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            timestamp: at,
            eventType: .metric,
            content: "\(key): \(valueMs)ms",
            detailJSON: serializeDetail(detail),
            severity: .debug
        ))
    }

    /// Captures the full request configuration snapshot for a trace; call once per trace, right after `beginTrace(...)`.
    /// Safe before or after the trace row is persisted (both writes are sequential on this actor).
    /// On any serialization or persistence error it logs and swallows; the trace then exists without a snapshot.
    func captureConfigSnapshot(_ snapshot: TraceConfigSnapshot) {
        guard let store else { return }

        do {
            // Serialize the full snapshot, then sanitize again at the JSON level to catch secret-looking patterns the
            // struct-level capture missed in free-text fields (instructions, tool params).
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try encoder.encode(snapshot)
            guard let rawJSON = String(data: jsonData, encoding: .utf8) else {
                logger.warning("Config snapshot JSON encoding produced no UTF-8 string")
                return
            }
            let sanitizedJSON = TelemetrySanitizer.sanitizeFull(rawJSON, level: .standard)

            let row = TraceConfigRow(
                traceID:           snapshot.traceID,
                provider:          snapshot.provider,
                modelName:         snapshot.modelName,
                profileType:       snapshot.profileType,
                appVersion:        snapshot.appVersion,
                osVersion:         snapshot.osVersion,
                toolsCount:        snapshot.toolsEnabled.count,
                capabilitiesCount: snapshot.capabilitiesEnabled.count,
                instructionsHash:  snapshot.instructionsHash,
                memoryBudgetBytes: Int64(snapshot.hardware.effectiveBudgetBytes),
                historyStrategy:   snapshot.historyStrategy,
                thinkingEnabled:   snapshot.thinkingEnabled,
                snapshotJSON:      sanitizedJSON
            )

            try store.saveConfigSnapshot(row)
            logger.debug("Captured config snapshot for trace \(snapshot.traceID.prefix(8))")
        } catch {
            // Fail-soft: log and move on. The rest of the trace still works.
            logger.warning("Config snapshot capture failed for trace \(snapshot.traceID.prefix(8)): \(error.localizedDescription)")
        }
    }

    /// Fetches the persisted config snapshot for a trace. Returns nil for traces
    /// predating v3 migration or where capture was skipped.
    func fetchConfigSnapshot(traceID: String) -> TraceConfigRow? {
        guard let store else { return nil }
        return try? store.fetchConfigSnapshot(traceID: traceID)
    }

    /// Records a classified `ClassifiedAgentError`: the canonical entry point for structured error telemetry.
    /// Failure sites should `error.classify(...)` first, then route the result here. v2 columns need developer mode.
    /// `iteration` is the optional ReAct iteration; `causedBy` the optional id of an earlier SpanEvent that triggered this.
    func emitAgentError(
        span: TraceContext,
        error: ClassifiedAgentError,
        iteration: Int? = nil,
        causedBy: Int64? = nil,
        at: Date = Date()
    ) {
        let devModeOn = UserDefaults.standard.bool(forKey: AppSettings.developerModeKey)
        // v2 columns (sanitized, non-PII) record whenever diagnostics are enabled; the
        // heavier stack-signature diagnostics below stay developer-mode-only (Gap #4).
        let recordV2 = devModeOn || AppSettings.diagnosticsRecordingEnabled

        // Message and context are sanitized at the strictest level compatible with debug readability: API keys/tokens are
        // redacted but paths' tails survive (e.g. read_file failed on [USER_PATH]/foo.swift).
        let sanitizedMessage = TelemetrySanitizer.sanitizeFull(error.message, level: .standard)

        var detail: [String: Any] = [
            "category":    error.category.rawValue,
            "phase":       error.phase.rawValue,
            "severity":    error.category.severity.rawValue,
            "origin":      error.origin,
            "chain_id":    error.chainID.uuidString,
            "retryable":   error.isRecoverable
        ]
        // Context is already short-string valued. Sanitize each value defensively.
        if !error.context.isEmpty {
            var sanitizedContext: [String: String] = [:]
            for (k, v) in error.context {
                sanitizedContext[k] = TelemetrySanitizer.sanitizeFull(v, level: .standard)
            }
            detail["context"] = sanitizedContext
        }

        // Diagnostics are only present when developer mode was on at classify() time.
        // Include them in detailJSON so the Report Inspector can render them later.
        if devModeOn, let diag = error.diagnostics {
            var diagBlob: [String: Any] = [:]
            if let d = diag.errorDomain  { diagBlob["error_domain"] = d }
            if let c = diag.errorCode    { diagBlob["error_code"] = c }
            if let k = diag.userInfoKeys { diagBlob["user_info_keys"] = k }
            if let s = diag.stackSignature {
                diagBlob["stack_signature"] = TelemetrySanitizer.sanitizeFull(s, level: .standard)
            }
            if !diagBlob.isEmpty { detail["diagnostics"] = diagBlob }
        }

        // Severity mapping: AgentErrorCategory.severity → SpanEventSeverity.
        let severity: SpanEventSeverity
        switch error.category.severity {
        case .informational: severity = .warning   // warning-level log entry, not error spam
        case .recoverable:   severity = .warning
        case .fatal:         severity = .error
        }

        // Populate the v2 columns only when enabled; otherwise the structured detailJSON is still written (readable in
        // exported traces) but the indexed analytics columns stay empty, keeping tables compact.
        let event = SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            timestamp: at,
            eventType: .error,
            content: sanitizedMessage,
            detailJSON: serializeDetail(detail),
            severity: severity,
            errorCategory: recordV2 ? error.category : nil,
            errorChainID:  recordV2 ? error.chainID  : nil,
            phase:         recordV2 ? error.phase    : nil,
            iterationNumber: recordV2 ? iteration    : nil,
            causedByEventID: recordV2 ? causedBy     : nil,
            durationMs:    nil
        )

        emit(event)
    }
    
    // MARK: - Flush

    /// Drains the event buffer NOW. The Run Report calls this when it opens (and on
    /// each live tick) so the panel never misses the tail of a just-ended run — the
    /// periodic loop alone leaves up to 1s / 50 events unflushed at any moment.
    func flushNow() {
        flush()
    }

    /// Flushes all pending events to the persistent store in a single transaction.
    private func flush() {
        guard !pendingEvents.isEmpty, let store else { return }

        let batch = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)

        do {
            try store.insertEvents(batch)
            logger.debug("Flushed \(batch.count) events to TraceStore.")
        } catch let dbError as DatabaseError where dbError.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY {
            // FK violation — at least one event references a non-existent span.
            // Fall back to per-event insertion, dropping only orphaned events.
            logger.warning("FK constraint error in batch flush. Inserting \(batch.count) events individually.")
            for event in batch {
                do {
                    try store.insertEvents([event])
                } catch {
                    logger.debug("Dropped orphaned span event (spanID: \(event.spanID), type: \(event.eventType.rawValue))")
                }
            }
        } catch {
            logger.error("Failed to flush \(batch.count) events: \(error.localizedDescription)")
            // Re-queue failed events (with a cap to prevent unbounded growth)
            if pendingEvents.count < 500 {
                pendingEvents.append(contentsOf: batch)
            }
        }
    }
    
    // MARK: - Query Passthrough
    
    /// Fetches a fully-hydrated trace (for the Report Inspector).
    func fetchFullTrace(traceID: String) -> TraceRecord? {
        guard let store else { return nil }
        do {
            return try store.fetchFullTrace(traceID: traceID)
        } catch {
            logger.error("Failed to fetch full trace \(traceID): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Fetches the trace for a specific message.
    func fetchTrace(forMessageID messageID: String) -> TraceRecord? {
        guard let store else { return nil }
        do {
            return try store.fetchTrace(forMessageID: messageID)
        } catch {
            logger.error("Failed to fetch trace for message \(messageID): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Fetches all traces for a conversation.
    func fetchTraces(forConversationID conversationID: String) -> [TraceRecord] {
        guard let store else { return [] }
        do {
            return try store.fetchTraces(forConversationID: conversationID)
        } catch {
            logger.error("Failed to fetch traces for conversation: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Computes summary statistics for a trace.
    func computeSummary(forTraceID traceID: String) -> TraceSummary {
        guard let store else { return TraceSummary() }
        do {
            return try store.computeSummary(forTraceID: traceID)
        } catch {
            logger.error("Failed to compute summary for trace \(traceID): \(error.localizedDescription)")
            return TraceSummary()
        }
    }
    
    // MARK: - Maintenance

    /// Flushes pending events synchronously and stops the periodic flush task. Called
    /// from `applicationWillTerminate` so up to `flushInterval` of buffered span events
    /// aren't lost on a graceful quit (mirrors `LogRecorder.prepareForTermination`).
    func prepareForTermination() {
        flushTask?.cancel()
        flushTask = nil
        flush()
    }

    /// Purges traces older than the given date. Call periodically or at app launch.
    func purgeOlderThan(_ date: Date) {
        guard let store else { return }
        do {
            try store.purgeOlderThan(date)
            logger.info("Purged traces older than \(date).")
        } catch {
            logger.error("Failed to purge old traces: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helpers
    
    private func serializeDetail(_ detail: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
