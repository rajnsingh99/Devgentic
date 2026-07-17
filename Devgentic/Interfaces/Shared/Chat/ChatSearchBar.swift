//
//  ChatSearchBar.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI

struct ChatSearchBar: View {
    @Bindable var searchViewModel: ChatSearchViewModel
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            // Search Icon
            Image(systemName: "magnifyingglass")
                .font(theme.fontSubheadline.weight(.medium))
                .foregroundColor(theme.secondaryText)
                .accessibilityHidden(true)

            // Search TextField
            TextField("Search in conversation... (Esc to close)", text: $searchViewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(theme.fontSubheadline)
                .focused($isTextFieldFocused)
                .onSubmit {
                    searchViewModel.nextMatch()
                }
                .accessibilityLabel("Search in conversation")

            // Match Count
            if !searchViewModel.searchQuery.isEmpty {
                Text(matchCountLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced)) // Fixed size: monospaced
                    .foregroundColor(searchViewModel.totalMatchCount > 0 ? theme.secondaryText : theme.errorColor.opacity(0.8))
                    .fixedSize()
                    .accessibilityLabel(matchCountAccessibilityLabel)
                    // Typing silently changes the count. It's on screen, but VoiceOver is
                    // focused in the text field and never hears it — so a search that found
                    // nothing was indistinguishable from one that found everything.
                    //
                    // `.task(id:)` cancels and restarts whenever the count changes, so the
                    // sleep debounces for free: mid-typing counts are cancelled before they
                    // speak, and only the one you land on is announced.
                    .task(id: searchViewModel.totalMatchCount) {
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        AccessibilityAnnouncer.announce(resultCountAnnouncement, urgency: .polite)
                    }
            }

            // Navigation Buttons
            if searchViewModel.totalMatchCount > 0 {
                HStack(spacing: 2) {
                    Button(action: { searchViewModel.previousMatch() }) {
                        Image(systemName: "chevron.up")
                            .font(.system(.caption, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.secondaryText)
                    .accessibilityLabel("Previous match")

                    Button(action: { searchViewModel.nextMatch() }) {
                        Image(systemName: "chevron.down")
                            .font(.system(.caption, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.secondaryText)
                    .accessibilityLabel("Next match")
                }
            }

            // Close Button
            Button(action: { searchViewModel.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(.caption2, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 20, height: 20)
                    .background(theme.surfaceOverlay)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
            .help("Close search (Esc)")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.dividerColor.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: theme.shadowColor, radius: 4, y: 2)
        .padding(.horizontal, 16)
        .onAppear {
            isTextFieldFocused = true
        }
    }

    private var matchCountLabel: String {
        if searchViewModel.totalMatchCount == 0 {
            return String(localized: "No results")
        }
        return String(localized: "\(searchViewModel.currentMatchIndex + 1) of \(searchViewModel.totalMatchCount)")
    }

    private var matchCountAccessibilityLabel: String {
        if searchViewModel.totalMatchCount == 0 { return String(localized: "No results") }
        return String(localized: "Match \(searchViewModel.currentMatchIndex + 1) of \(searchViewModel.totalMatchCount)")
    }

    /// Announced while typing, so it reports the COUNT rather than the position — which
    /// match you're on is meaningless until you start navigating.
    private var resultCountAnnouncement: String {
        let count = searchViewModel.totalMatchCount
        // NB the "N result(s)" plural is a manual `count == 1` construction — left as-is
        // pending a String Catalog plural entry (localization follow-up).
        return count == 0 ? String(localized: "No results") : "\(count) result\(count == 1 ? "" : "s")"
    }
}
