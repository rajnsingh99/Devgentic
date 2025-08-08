//
//  PromptSuggestionView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import SwiftUI

struct PromptSuggestionView: View {
    // MARK: - Properties
    let prompts: [Prompt]
    let suggestionQuery: String
    let onSelectPrompt: (Prompt) -> Void

    // MARK: - State
    @State private var hoveredItemID: Prompt.ID?

    // MARK: - Constants
    private let rowHeight: CGFloat = 44
    private let maxListHeight: CGFloat = 220 // Increased max height
    private let cornerRadiusValue: CGFloat = 8
    private let iconSize: CGFloat = 16

    // MARK: - Body
    var body: some View {
        if !prompts.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(prompts) { prompt in
                        Button(action: {
                            onSelectPrompt(prompt)
                        }) {
                            rowContent(for: prompt)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .onHover { isHovering in
                            withAnimation(.easeInOut(duration: 0.1)) {
                                hoveredItemID = isHovering ? prompt.id : nil
                            }
                        }

                        if prompts.last?.id != prompt.id {
                            Divider().padding(.leading, 48) // Indent divider
                        }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: maxListHeight)
            .background(VisualEffectBlur(material: .popover).opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadiusValue))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadiusValue)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.15), radius: 5, x: 0, y: 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if !suggestionQuery.isEmpty {
            Text("No prompts match \"\(suggestionQuery)\"")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VisualEffectBlur(material: .popover).opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadiusValue))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadiusValue)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.15), radius: 5, x: 0, y: 4)
                .transition(.opacity)
        }
    }

    // MARK: - View Builders
    @ViewBuilder
    private func rowContent(for prompt: Prompt) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "text.quote") // Using a generic but fitting icon
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                // Prompt title with the matched query part highlighted
                Text(highlightedText(for: prompt.title, query: suggestionQuery))
                    .font(.system(size: 13))
                    .lineLimit(1)

                // The beginning of the prompt's text for context
                Text(prompt.text)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(hoveredItemID == prompt.id ? Color.gray.opacity(0.15) : Color.clear)
        .cornerRadius(6)
    }

    // MARK: - Helper Methods
    private func highlightedText(for text: String, query: String) -> AttributedString {
        var attributedString = AttributedString(text)
        
        attributedString.foregroundColor = Color(NSColor.labelColor)

        if !query.isEmpty, let range = attributedString.range(of: query, options: .caseInsensitive) {
            attributedString[range].font = .system(size: 13, weight: .bold)
        }
        
        return attributedString
    }
}


// MARK: - Preview
struct PromptSuggestionView_Previews: PreviewProvider {
    static let samplePrompts = [
        Prompt(title: "Summarize Text", text: "Please summarize the following text, focusing on the key points and main arguments.", category: "Productivity", isUserDefined: true),
        Prompt(title: "Explain Code Snippet", text: "Explain the following code snippet, including its purpose, how it works, and potential improvements.", category: "Development", isUserDefined: true),
        Prompt(title: "Brainstorm Ideas for Project X", text: "Brainstorm five innovative ideas for a new marketing campaign for 'Project X'.", category: "Creativity", isUserDefined: false)
    ]

    static var previews: some View {
        VStack(spacing: 20) {
            Text("Prompt Suggestions (Populated)").font(.headline)
            PromptSuggestionView(prompts: samplePrompts, suggestionQuery: "sum") { selectedPrompt in
                print("Selected prompt: \(selectedPrompt.title)")
            }

            Text("Prompt Suggestions (No Results)").font(.headline)
            PromptSuggestionView(prompts: [], suggestionQuery: "nonexistent") { selectedPrompt in
                print("Selected prompt: \(selectedPrompt.title)")
            }
        }
        .frame(width: 450)
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
}
