//
//  ReportViewModel.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//

import Foundation
import SwiftUI
import AppKit

// MARK: - User Feedback Model

enum FeedbackRating: String, Codable, CaseIterable {
    case positive = "positive"
    case negative = "negative"
}

struct UserFeedback: Codable {
    var messageText: String = ""
    var rating: FeedbackRating?
    var screenshotData: Data?

    var isEmpty: Bool { messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && rating == nil }
}

// MARK: - Event Type Filter

enum EventTypeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case thoughts = "Thoughts"
    case tools = "Tools"
    case llm = "LLM"
    case errors = "Errors"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "line.3.horizontal.decrease"
        case .thoughts: return "brain.head.profile"
        case .tools: return "hammer"
        case .llm: return "brain"
        case .errors: return "exclamationmark.triangle"
        }
    }

    func matches(_ event: SpanEvent) -> Bool {
        switch self {
        case .all: return true
        case .thoughts: return event.eventType == .thought
        case .tools: return event.eventType == .toolCall || event.eventType == .toolResult
        case .llm: return event.eventType == .llmRequest || event.eventType == .llmResponse
        case .errors: return event.severity == .error || event.eventType == .parseError || event.eventType == .error
        }
    }
}

// MARK: - Report Scope

enum ReportScope: String, CaseIterable, Identifiable {
    case currentSpan = "This Message"
    case previousSpans = "Previous Messages"
    case fullConversation = "Full Conversation"

    var id: String { rawValue }
}

@Observable
class ReportViewModel {
    let messageID: UUID
    let conversationID: UUID
    let initialTraceID: String?
    
    // Loaded Data
    var initialTraceRecord: TraceRecord?
    var initialSummary: TraceSummary = TraceSummary()
    var activeTraceRecord: TraceRecord?
    var allTraces: [TraceRecord] = []
    var isLoading: Bool = false
    var isEventsLoading: Bool = false
    var error: String?
    
    // User Controls
    var scope: ReportScope = .currentSpan {
        didSet {
            if scope == .currentSpan {
                self.activeTraceRecord = self.initialTraceRecord
                self.summary = self.initialSummary
                
                // Keep selection within current trace
                if let root = self.initialTraceRecord?.rootSpans?.first {
                    self.selectedSpanID = root.spanID
                } else {
                    self.selectedSpanID = nil
                }
            } else if scope == .fullConversation || scope == .previousSpans {
                // Keep the current trace visible in the larger list if possible
                self.selectedSpanID = self.initialTraceID
            }
            updateVisibleData()
        }
    }
    var selectedSpanID: String? {
        didSet {
            handleSelectionChange()
        }
    }
    var showDebugEvents: Bool = false {
        didSet {
            updateVisibleEvents()
        }
    }
    var activeEventFilter: EventTypeFilter = .all {
        didSet {
            updateVisibleEvents()
        }
    }
    
    // User Feedback (for User View)
    var userFeedback: UserFeedback = UserFeedback()

    // Computed Data
    var visibleSpans: [Span] = []
    var visibleEvents: [SpanEvent] = []
    var summary: TraceSummary = TraceSummary()
    
    init(messageID: UUID, conversationID: UUID, traceID: String?) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.initialTraceID = traceID
    }
    
    @MainActor
    func loadData() async {
        guard let initialTraceID = initialTraceID else {
            self.error = "No trace data available for this message."
            return
        }
        
        self.isLoading = true
        self.error = nil
        
        // Load in background
        let (fullTrace, conversationTraces, computedSummary) = await Task.detached { () -> (TraceRecord?, [TraceRecord], TraceSummary) in
            let fullTrace = await TraceRecorder.shared.fetchFullTrace(traceID: initialTraceID)
            let convTraces = await TraceRecorder.shared.fetchTraces(forConversationID: self.conversationID.uuidString)
            let summary = await TraceRecorder.shared.computeSummary(forTraceID: initialTraceID)
            
            print("---- [REPORT INSPECTOR DIAGNOSTICS] ----")
            print("Trace ID: \(initialTraceID)")
            print("Found Trace in DB: \(fullTrace != nil)")
            print("Total Built Root Spans: \(fullTrace?.rootSpans?.count ?? 0)")
            
            var totalEvents = 0
            func countEvents(in spans: [Span]) {
                for span in spans {
                    totalEvents += span.events?.count ?? 0
                    if let children = span.children { countEvents(in: children) }
                }
            }
            if let roots = fullTrace?.rootSpans { countEvents(in: roots) }
            print("Total Fetched Events Attached to Tree: \(totalEvents)")
            print("---------------------------------------")
            
            return (fullTrace, convTraces, summary)
        }.value
        
        self.initialTraceRecord = fullTrace
        self.activeTraceRecord = fullTrace
        self.allTraces = conversationTraces
        self.initialSummary = computedSummary
        self.summary = computedSummary
        
        // Auto-select the first root span if available
        if let root = fullTrace?.rootSpans?.first {
            self.selectedSpanID = root.spanID
        }
        
        updateVisibleData()
        self.isLoading = false
    }
    
    private func updateVisibleData() {
        // Compute visible spans based on scope
        switch scope {
        case .currentSpan:
            self.visibleSpans = initialTraceRecord?.rootSpans ?? []
        case .previousSpans:
            // Find traces up to and including the current message's trace
            let relevantTraces = allTraces.prefix(while: { $0.traceID != initialTraceID }) + allTraces.filter({ $0.traceID == initialTraceID })
            self.visibleSpans = relevantTraces.compactMap { trace -> Span? in
                // For multiple traces, we simulate a "Trace-level" root span
                return Span(
                    spanID: trace.traceID,
                    traceID: trace.traceID,
                    name: "Trace: \(trace.profileName)",
                    kind: .workflow,
                    startedAt: trace.startedAt,
                    endedAt: trace.endedAt,
                    status: Self.spanStatus(forTrace: trace.status)
                )
            }
        case .fullConversation:
            self.visibleSpans = allTraces.compactMap { trace -> Span? in
                return Span(
                    spanID: trace.traceID,
                    traceID: trace.traceID,
                    name: "Trace: \(trace.profileName)",
                    kind: .workflow,
                    startedAt: trace.startedAt,
                    endedAt: trace.endedAt,
                    status: Self.spanStatus(forTrace: trace.status)
                )
            }
        }
        
        updateVisibleEvents()
    }

    /// Collapse a trace's terminal status into the 3-case `SpanStatus` used to render
    /// the synthetic trace-level root span. `.failed`/`.cancelled` have no `SpanStatus`
    /// equivalent, so they map to `.error` (any non-success terminal state) rather than
    /// silently falling back to `.completed` and rendering a failed run as green.
    private static func spanStatus(forTrace status: TraceStatus) -> SpanStatus {
        switch status {
        case .completed:                  return .completed
        case .running:                    return .running
        case .error, .failed, .cancelled, .interrupted: return .error
        }
    }

    private func handleSelectionChange() {
        guard let id = selectedSpanID else {
            updateVisibleEvents()
            return
        }
        
        // If we selected a historical trace from the broader scopes
        if (scope == .previousSpans || scope == .fullConversation) && id != activeTraceRecord?.traceID {
            Task { @MainActor in
                self.isEventsLoading = true
                
                let (newTrace, newSummary) = await Task.detached { () -> (TraceRecord?, TraceSummary) in
                    let t = await TraceRecorder.shared.fetchFullTrace(traceID: id)
                    let s = await TraceRecorder.shared.computeSummary(forTraceID: id)
                    return (t, s)
                }.value
                
                if let newTrace = newTrace {
                    self.activeTraceRecord = newTrace
                    self.summary = newSummary
                    self.updateVisibleEvents()
                }
                
                self.isEventsLoading = false
            }
        } else {
            updateVisibleEvents()
        }
    }
    
    private func updateVisibleEvents() {
        guard let trace = activeTraceRecord else {
            self.visibleEvents = []
            return
        }
        
        // Helper to flatten a span tree
        func flatten(spans: [Span]) -> [Span] {
            var flat = spans
            for span in spans {
                if let children = span.children {
                    flat.append(contentsOf: flatten(spans: children))
                }
            }
            return flat
        }
        
        let allSpans = flatten(spans: trace.rootSpans ?? [])
        
        // Collect events from the selected span (or all if none selected)
        var events: [SpanEvent] = []
        if scope == .currentSpan, let selectedSpanID = selectedSpanID, let targetSpan = allSpans.first(where: { $0.spanID == selectedSpanID }) {
            events = targetSpan.events ?? []
        } else {
            events = allSpans.flatMap { $0.events ?? [] }
        }
        
        // Filter by severity
        if !showDebugEvents {
            events = events.filter { $0.severity != .debug }
        }

        // Filter by event type
        if activeEventFilter != .all {
            events = events.filter { activeEventFilter.matches($0) }
        }

        self.visibleEvents = events.sorted(by: { $0.timestamp < $1.timestamp })
    }
    
    // MARK: - Computed Helpers

    /// All error events in the current trace (unfiltered).
    var errorEvents: [SpanEvent] {
        guard let trace = activeTraceRecord else { return [] }
        func flatten(spans: [Span]) -> [Span] {
            var flat = spans
            for span in spans {
                if let children = span.children {
                    flat.append(contentsOf: flatten(spans: children))
                }
            }
            return flat
        }
        let allSpans: [Span] = flatten(spans: trace.rootSpans ?? [])
        let allEvents: [SpanEvent] = allSpans.flatMap { $0.events ?? [] }
        let filtered: [SpanEvent] = allEvents.filter { event in
            event.severity == .error || event.eventType == .parseError || event.eventType == .error
        }
        return filtered.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Screenshot

    @MainActor
    func captureScreenshot(of view: NSView) -> NSImage? {
        guard let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmapRep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }
}
