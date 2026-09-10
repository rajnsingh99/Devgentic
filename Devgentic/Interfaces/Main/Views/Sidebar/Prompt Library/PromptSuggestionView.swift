// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  PromptSuggestionView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import SwiftUI

struct PromptSuggestionView: View {
    // MARK: - Properties
    let prompts: [DevPrompt]
    let suggestionQuery: String
    let onSelectPrompt: (DevPrompt) -> Void
    @Binding var selectedItemID: DevPrompt.ID? // The ID of the item selected via keyboard

    // MARK: - State
    @State private var hoveredItemID: DevPrompt.ID?
    @Environment(\.appTheme) private var theme

    // MARK: - Constants
    private let rowHeight: CGFloat = 44
    private let maxListHeight: CGFloat = 220 // Increased max height
    private let cornerRadiusValue: CGFloat = 8
    private let iconSize: CGFloat = 16

    // MARK: - Body
    var body: some View {
        if !prompts.isEmpty {
            ScrollViewReader { scrollViewProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(prompts) { prompt in
                            Button(action: {
                                onSelectPrompt(prompt)
                            }) {
                                rowContent(for: prompt)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .id(prompt.id) // Assign an ID for ScrollViewReader
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
                .onChange(of: selectedItemID) { _, newId in
                    // When the selection changes, scroll to make it visible
                    if let newId {
                        withAnimation {
                            scrollViewProxy.scrollTo(newId, anchor: .center)
                        }
                    }
                }
            }
            .frame(maxHeight: maxListHeight)
            .appSurface(in: .rect(cornerRadius: cornerRadiusValue), elevation: .popover)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .onAppear {
                // When the view appears, if no item is selected, select the first one.
                if selectedItemID == nil, let firstId = prompts.first?.id {
                    selectedItemID = firstId
                }
            }
        } else if !suggestionQuery.isEmpty {
            Text("No prompts match \"\(suggestionQuery)\"")
                .font(.caption)
                .foregroundColor(theme.secondaryText)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appSurface(in: .rect(cornerRadius: cornerRadiusValue), elevation: .popover)
                .transition(.opacity)
        }
    }

    // MARK: - View Builders
    @ViewBuilder
    private func rowContent(for prompt: DevPrompt) -> some View {
        let isSelected = selectedItemID == prompt.id
        let isHovered = hoveredItemID == prompt.id

        HStack(spacing: 12) {
            Image(systemName: "text.quote") // Using a generic but fitting icon
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundColor(theme.secondaryText)
                .frame(width: 20, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                // Prompt title with the matched query part highlighted
                Text(highlightedText(for: prompt.title, query: suggestionQuery))
                    .font(theme.fontSubheadline)
                    .lineLimit(1)

                // The beginning of the prompt's text for context
                Text(prompt.text)
                    .font(.caption2)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(
            (isSelected || isHovered) ? theme.secondaryText.opacity(isSelected ? 0.25 : 0.15) : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Helper Methods
    private func highlightedText(for text: String, query: String) -> AttributedString {
        var attributedString = AttributedString(text)
        
        attributedString.foregroundColor = theme.primaryText

        if !query.isEmpty, let range = attributedString.range(of: query, options: .caseInsensitive) {
            attributedString[range].font = .system(.subheadline, weight: .bold)
        }
        
        return attributedString
    }
}


// MARK: - Preview
struct PromptSuggestionView_Previews: PreviewProvider {
    static let samplePrompts = [
        DevPrompt(title: "Summarize Text", text: "Please summarize the following text, focusing on the key points and main arguments.", category: "Productivity", isUserDefined: true),
        DevPrompt(title: "Explain Code Snippet", text: "Explain the following code snippet, including its purpose, how it works, and potential improvements.", category: "Development", isUserDefined: true),
        DevPrompt(title: "Brainstorm Ideas for Project X", text: "Brainstorm five innovative ideas for a new marketing campaign for 'Project X'.", category: "Creativity", isUserDefined: false)
    ]

    static var previews: some View {
        VStack(spacing: 20) {
            Text("Prompt Suggestions (Populated)").font(.headline)
            PromptSuggestionView(prompts: samplePrompts, suggestionQuery: "sum", onSelectPrompt: { selectedPrompt in
                print("Selected prompt: \(selectedPrompt.title)")
            }, selectedItemID: .constant(samplePrompts.first?.id))

            Text("Prompt Suggestions (No Results)").font(.headline)
            PromptSuggestionView(prompts: [], suggestionQuery: "nonexistent", onSelectPrompt: { selectedPrompt in
                print("Selected prompt: \(selectedPrompt.title)")
            }, selectedItemID: .constant(nil))
        }
        .frame(width: 450)
        .padding()
        .background(AppThemes.MaterialTheme().primaryBackground)
    }
}
