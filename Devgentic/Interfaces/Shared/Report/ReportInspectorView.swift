//
//  ReportInspectorView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//

import SwiftUI

struct ReportInspectorView: View {
    @State private var viewModel: ReportViewModel
    @Environment(\.dismiss) private var dismiss
    
    init(messageID: UUID, conversationID: UUID, traceID: String?) {
        _viewModel = State(initialValue: ReportViewModel(messageID: messageID, conversationID: conversationID, traceID: traceID))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Execution Report")
                        .font(.headline)
                    if let profileName = viewModel.activeTraceRecord?.profileName {
                        Text("Profile: \(profileName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                Picker("Scope", selection: $viewModel.scope) {
                    ForEach(ReportScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
                
                Toggle("Debug", isOn: $viewModel.showDebugEvents)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                
                Button(action: exportReport) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .help("Export JSON")
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            if viewModel.isLoading {
                Spacer()
                ProgressView("Loading trace data...")
                Spacer()
            } else if let error = viewModel.error {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(error)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                HSplitView {
                    // Left Panel: Span Tree
                    SpanTreeView(
                        spans: viewModel.visibleSpans,
                        selectedSpanID: $viewModel.selectedSpanID
                    )
                    .frame(minWidth: 200, idealWidth: 300)
                    
                    // Right Panel: Event Timeline
                    if viewModel.isEventsLoading {
                        VStack {
                            Spacer()
                            ProgressView("Fetching events...")
                                .controlSize(.small)
                            Spacer()
                        }
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EventTimelineView(events: viewModel.visibleEvents)
                            .frame(minWidth: 300, idealWidth: 500)
                    }
                }
            }
            
            // Footer (Summary)
            if !viewModel.isLoading, viewModel.activeTraceRecord != nil {
                Divider()
                HStack(spacing: 16) {
                    summaryItem(icon: "clock", text: "\(viewModel.summary.totalDurationMs)ms")
                    summaryItem(icon: "bolt", text: "\(viewModel.summary.totalIterations) Steps")
                    summaryItem(icon: "exclamationmark.triangle", text: "\(viewModel.summary.parseErrors) Errors", color: viewModel.summary.parseErrors > 0 ? .red : .secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
        .frame(minWidth: 700, minHeight: 400)
        .task {
            await viewModel.loadData()
        }
    }
    
    private func summaryItem(icon: String, text: String, color: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(color)
    }
    
    private func exportReport() {
        guard let url = viewModel.exportAsJSON() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
