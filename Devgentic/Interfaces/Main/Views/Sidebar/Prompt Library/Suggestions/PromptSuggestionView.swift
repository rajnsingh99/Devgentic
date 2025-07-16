//
//  PromptSuggestionView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import SwiftUI

struct PromptSuggestionView: View {
    let prompts: [Prompt]
    let suggestionQuery: String // Pass the current query to determine "no results" state
    let onSelectPrompt: (Prompt) -> Void

    var body: some View {
        // Only show the container if there's a query or if there are prompts (initial display after typing '#')
        if !prompts.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(prompts) { prompt in
                        Button(action: {
                            onSelectPrompt(prompt)
                        }) {
                            Text(prompt.title)
                                .font(.system(size: NSFont.systemFontSize))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .foregroundColor(Color(NSColor.labelColor))

                        if prompts.last?.id != prompt.id {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(VisualEffectBlur(material: .popover))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.15), radius: 5, x: 0, y: 4)
            .padding(.horizontal, 5)
        } else if !suggestionQuery.isEmpty {
            // If prompts are empty BUT there was a query, show "No results"
            Text("No prompts match \"\(suggestionQuery)\"")
                .font(.system(size: NSFont.systemFontSize - 1)) // Slightly smaller
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(VisualEffectBlur(material: .popover))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.15), radius: 5, x: 0, y: 4)
                .padding(.horizontal, 5)
        }
        // If prompts are empty and suggestionQuery is also empty (e.g., initial '#' typed but before filtering or if initial list is empty),
        // this view will render nothing, which is fine. The parent (ChatInputAreaView) controls overall visibility.
    }
}

// MARK: - Preview
struct PromptSuggestionView_Previews: PreviewProvider {
    static let samplePrompts = [
        Prompt(title: "Summarize Text", text: "Summarize:", category: "Productivity", isUserDefined: true),
        Prompt(title: "Explain Code Snippet", text: "Explain:", category: "Development", isUserDefined: true),
        Prompt(title: "Brainstorm Ideas for Project X", text: "Brainstorm:", category: "Creativity", isUserDefined: false)
    ]

    static var previews: some View {
        VStack(spacing: 20) {
            PromptSuggestionView(prompts: samplePrompts, suggestionQuery: "sum") { selectedPrompt in
                print("Selected prompt: \(selectedPrompt.title)")
            }
            .previewDisplayName("With Prompts")

            PromptSuggestionView(prompts: [], suggestionQuery: "xyz") { selectedPrompt in
                print("Selected prompt: \(selectedPrompt.title)")
            }
            .previewDisplayName("No Matching Prompts")
            
            PromptSuggestionView(prompts: [], suggestionQuery: "") { selectedPrompt in
                print("Selected prompt: \(selectedPrompt.title)")
            }
            .previewDisplayName("Empty Query (Initial)")
        }
        .frame(width: 300)
        .padding()
    }
}
