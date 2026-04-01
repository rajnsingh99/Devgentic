//
//  TraceRecorder.swift
//  Devgentic
//
//  Created by Antigravity on 19/03/26.
//

import Foundation
import GRDB
import os

/// A global, background trace recording service.
/// Replaces `TraceLogAggregator` with persistent, structured storage via `TraceStore`.
///
/// All `emit*` methods are fire-and-forget — they buffer events in memory
/// and flush to disk in batches to minimize I/O overhead during agent loops.
actor TraceRecorder {
    
    static let shared = TraceRecorder()
    
    private let store: TraceStore?
    private var pendingEvents: [SpanEvent] = []
    private var flushTask: Task<Void, Never>?
    private var closedTraceIDs: Set<String> = []
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "TraceRecorder")
    
    // Configuration
    private let flushInterval: TimeInterval = 1.0
    private let maxBatchSize = 50
    
    // MARK: - Initialization
    
    private init() {
        do {
            self.store = try TraceStore()
            logger.info("TraceRecorder initialized with persistent store.")
        } catch {
            self.store = nil
            logger.error("Failed to initialize TraceStore: \(error.localizedDescription). Recording disabled.")
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
            status: .running
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
    
    /// Records the start of a new span within a trace.
    func beginSpan(context: TraceContext, name: String, kind: SpanKind) {
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
            try store.insertSpan(span)
            logger.debug("Began span: \(name) [\(context.spanID)]")
        } catch {
            logger.error("Failed to insert span '\(name)': \(error.localizedDescription)")
        }
    }
    
    /// Marks a span as completed or errored.
    func endSpan(spanID: String, status: SpanStatus) {
        guard let store else { return }
        
        do {
            try store.updateSpan(spanID: spanID, endedAt: Date(), status: status)
        } catch {
            logger.error("Failed to end span \(spanID): \(error.localizedDescription)")
        }
    }
    
    /// Marks a trace as completed or errored.
    func endTrace(traceID: String, status: TraceStatus, error: String? = nil) {
        // Flush any pending events for this trace synchronously on the actor
        flush()

        guard let store else { return }

        let sanitizedError = error.map { TelemetrySanitizer.sanitize($0) }

        do {
            try store.updateTrace(traceID: traceID, endedAt: Date(), status: status, errorSummary: sanitizedError)
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
    
    // MARK: - Event Recording (Fire-and-Forget)
    
    /// Appends an event to the buffer. Auto-flushes when batch size is reached.
    /// Events for already-closed traces are silently dropped.
    func emit(_ event: SpanEvent) {
        guard !closedTraceIDs.contains(event.traceID) else { return }

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
            content: text,
            severity: .info
        ))
    }
    
    /// Records a tool invocation.
    func emitToolCall(span: TraceContext, name: String, arguments: String) {
        let detail: [String: Any] = ["tool_name": name, "arguments_preview": String(arguments.prefix(500))]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            eventType: .toolCall,
            content: name,
            detailJSON: serializeDetail(detail),
            severity: .info
        ))
    }
    
    /// Records a tool execution result.
    func emitToolResult(span: TraceContext, name: String, success: Bool, output: String, durationMs: Int) {
        let detail: [String: Any] = [
            "tool_name": name,
            "is_success": success,
            "duration_ms": durationMs,
            "output_preview": String(output.prefix(500))
        ]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            eventType: .toolResult,
            content: "\(name): \(success ? "success" : "failed")",
            detailJSON: serializeDetail(detail),
            severity: success ? .info : .warning
        ))
    }
    
    /// Records an LLM request being sent.
    func emitLLMRequest(span: TraceContext, model: String, messageCount: Int) {
        let detail: [String: Any] = ["model": model, "messages_count": messageCount]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            eventType: .llmRequest,
            content: "Request to \(model)",
            detailJSON: serializeDetail(detail),
            severity: .debug
        ))
    }
    
    /// Records an LLM response received.
    func emitLLMResponse(span: TraceContext, durationMs: Int, preview: String) {
        let detail: [String: Any] = [
            "duration_ms": durationMs,
            "response_preview": String(preview.prefix(300))
        ]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            eventType: .llmResponse,
            content: "Response received (\(durationMs)ms)",
            detailJSON: serializeDetail(detail),
            severity: .debug
        ))
    }
    
    /// Records a parse error during cognitive step parsing.
    func emitParseError(span: TraceContext, rawOutput: String, error: String) {
        let detail: [String: Any] = [
            "raw_output_preview": String(rawOutput.prefix(500)),
            "error": TelemetrySanitizer.sanitize(error)
        ]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            eventType: .parseError,
            content: "Parse error: \(error)",
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
    func emitUserInteraction(span: TraceContext, type: String, toolName: String?, outcome: String) {
        var detail: [String: Any] = ["type": type, "outcome": outcome]
        if let t = toolName { detail["tool"] = t }
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            eventType: .userInteraction,
            content: "\(type): \(outcome)",
            detailJSON: serializeDetail(detail),
            severity: .info
        ))
    }
    
    /// Records a general error.
    func emitError(span: TraceContext, error: String, isRecoverable: Bool) {
        let detail: [String: Any] = [
            "error": TelemetrySanitizer.sanitize(error),
            "is_recoverable": isRecoverable
        ]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            eventType: .error,
            content: TelemetrySanitizer.sanitize(error),
            detailJSON: serializeDetail(detail),
            severity: .error
        ))
    }
    
    /// Records a performance metric.
    func emitMetric(span: TraceContext, key: String, valueMs: Int) {
        let detail: [String: Any] = ["key": key, "value_ms": valueMs]
        emit(SpanEvent(
            spanID: span.spanID,
            traceID: span.traceID,
            eventType: .metric,
            content: "\(key): \(valueMs)ms",
            detailJSON: serializeDetail(detail),
            severity: .debug
        ))
    }
    
    // MARK: - Flush
    
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
