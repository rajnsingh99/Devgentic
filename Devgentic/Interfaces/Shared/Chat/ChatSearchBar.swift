// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    @State private var isCloseHovered: Bool = false
    @State private var isPrevHovered: Bool = false
    @State private var isNextHovered: Bool = false
    @Environment(\.appTheme) private var theme
    // [vm-3] Deliberately NO `ChatHistoryViewModel` here. The bar used to pull it from the
    // environment for `unreachableMatchCount(in:)`, which walks the computed `searchCorpus` —
    // and reading that from `body` made every keystroke rebuild the corpus and made the bar an
    // observer of every resident message's text. The count now arrives on `searchViewModel`,
    // written by `ChatHistoryViewModel.runSearch` alongside the matches it describes.

    var body: some View {
        HStack(spacing: 10) {
            // Search Icon
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isTextFieldFocused ? theme.accentColor : theme.secondaryText)
                .accessibilityHidden(true)

            // Search TextField
            TextField("Search in conversation…", text: $searchViewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .focused($isTextFieldFocused)
                .onSubmit {
                    searchViewModel.nextMatch()
                }
                .accessibilityLabel("Search in conversation")

            // Match Count Badge
            if !searchViewModel.searchQuery.isEmpty {
                // Both strings come from the view model, built from its STORED unreachable
                // count ([vm-3]) — nothing here walks the corpus.
                Text(searchViewModel.matchCountLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(searchViewModel.totalMatchCount > 0 ? theme.accentColor : theme.errorColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(searchViewModel.totalMatchCount > 0 ? theme.accentColor.opacity(0.14) : theme.errorColor.opacity(0.14))
                    )
                    .overlay(
                        Capsule().stroke(searchViewModel.totalMatchCount > 0 ? theme.accentColor.opacity(0.3) : theme.errorColor.opacity(0.3), lineWidth: 0.5)
                    )
                    .fixedSize()
                    .accessibilityLabel(searchViewModel.matchCountAccessibilityLabel)
                    .task(id: searchViewModel.totalMatchCount) {
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        AccessibilityAnnouncer.announce(resultCountAnnouncement, urgency: .polite)
                    }
            }

            // Unreachable-match caption (CF-35): the active match exists in the stored
            // history but lies past the resident window's cap, so Next/Previous landed on
            // it without the transcript moving. Say so, rather than leave "N of M" pointing
            // at nothing.
            if searchViewModel.totalMatchCount > 0, searchViewModel.currentMatchUnreachable {
                Text("Older than the loaded history")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .help("This match is beyond the \(ChatHistoryViewModel.maxResidentMessages) most recent messages kept on screen, so it can't be scrolled to. Scroll-back stops there to bound memory.")
                    .accessibilityLabel("This match is older than the loaded history and can't be scrolled to")
            }

            // Navigation Buttons (Previous / Next match)
            if searchViewModel.totalMatchCount > 0 {
                HStack(spacing: 3) {
                    Button(action: { searchViewModel.previousMatch() }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(isPrevHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.primaryText.opacity(0.85))
                    .onHover { hovering in withAnimation(.easeInOut(duration: 0.15)) { isPrevHovered = hovering } }
                    .accessibilityLabel("Previous match")

                    Button(action: { searchViewModel.nextMatch() }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(isNextHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.primaryText.opacity(0.85))
                    .onHover { hovering in withAnimation(.easeInOut(duration: 0.15)) { isNextHovered = hovering } }
                    .accessibilityLabel("Next match")
                }
            }

            // Keyboard Shortcut ESC Hint
            Text("ESC")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.surfaceOverlay))

            // Close Button
            Button(action: { searchViewModel.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 20, height: 20)
                    .background(isCloseHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in withAnimation(.easeInOut(duration: 0.15)) { isCloseHovered = hovering } }
            .accessibilityLabel("Close search")
            .help("Close search (Esc)")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceOverlay.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            isTextFieldFocused ? theme.accentColor.opacity(0.6) : theme.surfaceOverlayStrong,
                            theme.surfaceOverlayStrong.opacity(0.4)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isTextFieldFocused ? 1.0 : 0.5
                )
        )
        .shadow(color: theme.shadowColor.opacity(0.4), radius: 10, y: 4)
        .padding(.horizontal, 16)
        .onAppear {
            isTextFieldFocused = true
        }
    }

    // [CF-37] The unreachable count keeps "N of M" honest — without it the badge counted
    // matches Next/Previous could never land on, with nothing distinguishing them from a
    // reachable one until the user pressed toward one and hit the silent "Older than the
    // loaded history" case CF-35 added below. [vm-3] Both badge strings now live on
    // `ChatSearchViewModel` (`matchCountLabel`, `matchCountAccessibilityLabel`), built from the
    // stored count, so they are unit-tested there.

    /// Announced while typing, so it reports the COUNT rather than the position — which
    /// match you're on is meaningless until you start navigating.
    private var resultCountAnnouncement: String {
        let count = searchViewModel.totalMatchCount
        // NB the "N result(s)" plural is a manual `count == 1` construction — left as-is
        // pending a String Catalog plural entry (localization follow-up).
        return count == 0 ? String(localized: "No results") : "\(count) result\(count == 1 ? "" : "s")"
    }
}
