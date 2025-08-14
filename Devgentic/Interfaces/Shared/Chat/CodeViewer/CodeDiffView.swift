//
//  CodeDiffView.swift
//  Devgentic
//
//  Created by Raj Singh on 08/08/25.
//

import SwiftUI

/// A view specifically designed to render the results of a code diff operation.
/// It displays added, deleted, and unchanged lines with distinct visual cues.
struct CodeDiffView: View {
    let originalCode: String
    let modifiedCode: String

    // The diff results are calculated once and stored.
    private var diffResults: [DiffResult] {
        return DiffUtility.generateDiff(original: originalCode, modified: modifiedCode)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diffResults) { result in
                    HStack(alignment: .top, spacing: 8) {
                        // Gutter prefix (+, -, or empty)
                        Text(prefix(for: result.type))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(prefixColor(for: result.type))
                            .frame(width: 20, alignment: .trailing)

                        // Code content
                        Text(result.line)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                    .background(backgroundColor(for: result.type))
                }
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: NSColor(hex: "#282a36"))) // Matches editor background
    }

    // MARK: - Helper Functions

    /// Provides the background color for a given line change type.
    private func backgroundColor(for type: LineChangeType) -> Color {
        switch type {
        case .added:
            return Color.green.opacity(0.15)
        case .deleted:
            return Color.red.opacity(0.15)
        case .unchanged:
            return Color.clear
        }
    }

    /// Provides the gutter prefix string for a given line change type.
    private func prefix(for type: LineChangeType) -> String {
        switch type {
        case .added:
            return "+"
        case .deleted:
            return "-"
        case .unchanged:
            return " "
        }
    }

    /// Provides the gutter prefix color for a given line change type.
    private func prefixColor(for type: LineChangeType) -> Color {
        switch type {
        case .added:
            return .green
        case .deleted:
            return .red
        case .unchanged:
            return .gray
        }
    }
}

// MARK: - Preview Provider
struct CodeDiffView_Previews: PreviewProvider {
    static var previews: some View {
        let original = """
        struct ContentView: View {
            var body: some View {
                Text("Hello, world!")
                    .padding()
            }
        }
        """

        let modified = """
        struct ContentView: View {
            // A greeting
            var body: some View {
                Text("Hello, Swift!")
                    .padding()
                    .background(Color.blue)
            }
        }
        """

        CodeDiffView(originalCode: original, modifiedCode: modified)
            .frame(width: 600, height: 400)
    }
}
