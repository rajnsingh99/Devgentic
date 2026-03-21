//
//  EventTimelineView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//

import SwiftUI

struct EventTimelineView: View {
    let events: [SpanEvent]
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if events.isEmpty {
                    Text("No events to display.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    ForEach(events) { event in
                        EventRow(event: event)
                    }
                }
            }
            .padding()
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

private struct EventRow: View {
    let event: SpanEvent
    
    @State private var isDetailsExpanded: Bool = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline track and icon
            VStack {
                Circle()
                    .fill(severityColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 2)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(timeString)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    
                    Text(event.eventType.rawValue.uppercased())
                        .font(.caption2.bold())
                        .foregroundStyle(severityColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(severityColor.opacity(0.1))
                        .cornerRadius(4)
                    
                    Spacer()
                }
                
                Text(event.content ?? "")
                    .font(.subheadline)
                    .padding(.bottom, event.detailJSON != nil ? 4 : 0)
                
                if let details = event.detailJSON {
                    DisclosureGroup(isExpanded: $isDetailsExpanded) {
                        Text(details)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding()
                            .background(Color.secondary.opacity(0.05))
                            .cornerRadius(6)
                            .textSelection(.enabled)
                    } label: {
                        Text("Details")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accentColor(.secondary)
                }
            }
            .padding(.bottom, 8)
        }
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: event.timestamp)
    }
    
    private var severityColor: Color {
        switch event.severity {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
