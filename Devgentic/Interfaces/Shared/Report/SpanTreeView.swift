//
//  SpanTreeView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//

import SwiftUI

struct SpanTreeView: View {
    let spans: [Span]
    @Binding var selectedSpanID: String?
    
    var body: some View {
        List(spans, children: \.children, selection: $selectedSpanID) { span in
            SpanRow(span: span)
                .tag(span.spanID)
        }
        .listStyle(.sidebar)
    }
}

private struct SpanRow: View {
    let span: Span
    
    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            
            Text(span.name)
                .lineLimit(1)
                .font(.subheadline)
            
            Spacer()
            
            if let duration = spanDuration {
                Text("\(duration)ms")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
    
    private var spanDuration: Int? {
        guard let end = span.endedAt else { return nil }
        return Int(end.timeIntervalSince(span.startedAt) * 1000)
    }
    
    private var iconName: String {
        switch span.kind {
        case .iteration: return "arrow.triangle.2.circlepath"
        case .toolExecution: return "hammer"
        case .llmCall: return "brain"
        case .workflow: return "flowchart"
        case .subtask: return "square.stack.3d.down.right"
        }
    }
    
    private var iconColor: Color {
        switch span.status {
        case .completed: return .green
        case .error: return .red
        case .running: return .orange
        }
    }
}
