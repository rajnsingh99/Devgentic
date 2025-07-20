//
//  CodeBlockCardView.swift
//  Devgentic
//
//  Created by Raj Singh on 20/07/25.
//

import SwiftUI

/// A view that represents a collapsed card for a code block.
/// It displays the language, line count, and a button to view the full code.
struct CodeBlockCardView: View {
    let language: String
    let lineCount: Int
    let action: () -> Void 

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: "doc.text.fill")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                    .padding(.leading, 5)

                VStack(alignment: .leading, spacing: 5) {
                    Text(language.isEmpty ? "Code Block" : "\(language.capitalized) Code")
                        .font(.headline)
                        .foregroundColor(Color(NSColor.labelColor))

                    Text("\(lineCount) lines of code")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("Tap to view full code")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding(15)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
            )
            .drawingGroup()
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 300, alignment: .leading)
        .padding(.vertical, 20)
    }
}

// MARK: - Preview Provider
struct CodeBlockCardView_Previews: PreviewProvider {
    static var previews: some View {
        CodeBlockCardView(language: "python", lineCount: 150) {
            print("Code block card tapped!")
        }
        .padding()
        .preferredColorScheme(.dark)
        .previewLayout(.sizeThatFits)
    }
}
