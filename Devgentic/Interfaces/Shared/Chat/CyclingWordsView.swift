//
//  CyclingWordsView.swift
//  Devgentic
//
//  Animated word-cycling indicator inspired by Claude's macOS app.
//  Cycles through contextual words with a fade + slide-up transition.
//  Used in ThinkingDynamicIsland during agent processing.
//
//  Created by Raj Singh on 21/03/26.
//

import SwiftUI

struct CyclingWordsView: View {
    /// The current agent state, used to select the word pool.
    let agentState: AgentState

    /// When non-nil, overrides cycling with a static label (e.g., tool name, workflow step).
    let overrideText: String?

    @Environment(\.appTheme) private var theme
    @State private var currentIndex: Int = 0
    @State private var isVisible: Bool = true

    /// Cycling interval in seconds.
    private let interval: TimeInterval = 2.5

    private var words: [String] {
        Self.wordPool(for: agentState)
    }

    var body: some View {
        Group {
            if let override = overrideText {
                // Static mode: concrete headline (tool name, workflow step, etc.)
                Text(override)
                    .transition(.identity)
            } else {
                // Cycling mode: animated word rotation
                Text(words[currentIndex % words.count])
                    .id(currentIndex) // Force view identity change for transition
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .opacity.combined(with: .offset(y: -6))
                        )
                    )
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(theme.primaryText)
        .lineLimit(1)
        .animation(.easeInOut(duration: 0.35), value: currentIndex)
        .onAppear { startCycling() }
        .onChange(of: agentState) { _ in
            // Reset index when state changes to start fresh with new word pool
            currentIndex = 0
        }
    }

    // MARK: - Timer

    private func startCycling() {
        guard overrideText == nil else { return }

        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard overrideText == nil else { continue }
                withAnimation {
                    currentIndex += 1
                }
            }
        }
    }

    // MARK: - Word Pools

    static func wordPool(for state: AgentState) -> [String] {
        switch state {
        case .thinking(let detail):
            switch detail {
            case .reasoning:
                return ["Reasoning", "Thinking", "Analyzing", "Considering", "Processing"]
            case .planning:
                return ["Planning", "Strategizing", "Organizing", "Decomposing"]
            case .reflecting:
                return ["Reflecting", "Evaluating", "Critiquing", "Reviewing"]
            case .finalizing:
                return ["Finalizing", "Composing", "Summarizing", "Wrapping up"]
            case .errorRecovery:
                return ["Recovering", "Retrying", "Correcting"]
            case .preparing:
                return ["Preparing", "Retrieving context", "Loading"]
            }
        case .acting(.subtask(let current, let total)):
            return ["Step \(current) of \(total)", "Working", "Executing"]
        default:
            return ["Thinking", "Processing", "Working"]
        }
    }
}

#if DEBUG
struct CyclingWordsView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            CyclingWordsView(agentState: .thinking(.reasoning), overrideText: nil)
            CyclingWordsView(agentState: .thinking(.planning), overrideText: nil)
            CyclingWordsView(agentState: .acting(.tool(name: "list_directory")), overrideText: "Using tool: list_directory")
        }
        .padding()
    }
}
#endif
