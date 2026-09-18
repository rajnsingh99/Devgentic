// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FolderSelectorPopoverView.swift
//  Devgentic
//
//  Popover for the Code interface's folder selector. Shows a Recent list of
//  previously-opened project folders (move-to-front, persisted in CodeSessionManager)
//  plus an "Open folder..." entry that falls through to NSOpenPanel.
//

import SwiftUI

struct FolderSelectorPopoverView: View {

    @Environment(CodeSessionManager.self) private var codeSessionManager
    @Environment(\.appTheme) private var theme

    @Binding var isPresented: Bool

    /// Invoked when the user picks a recent folder. Caller updates the session.
    var onSelectRecent: (URL) -> Void

    /// Invoked when the user taps "Open folder..." — caller presents NSOpenPanel.
    var onOpenFolder: () -> Void

    /// Invoked when the user taps "Select file..." — caller presents a file-only
    /// NSOpenPanel filtered to docs/code/images and attaches results.
    var onSelectFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !codeSessionManager.recentProjectPaths.isEmpty {
                Text("Recent")
                    .font(.system(.caption, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

                ForEach(codeSessionManager.recentProjectPaths, id: \.self) { url in
                    recentRow(url)
                }

                Divider()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }

            actionRow(
                icon: "folder.badge.plus",
                label: "Open folder...",
                action: { onOpenFolder() }
            )

            actionRow(
                icon: "doc.badge.plus",
                label: "Select file...",
                action: { onSelectFile() }
            )
            .padding(.bottom, 4)
        }
        .padding(.vertical, 4)
        .frame(width: 260)
    }

    private func actionRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            isPresented = false
            // Defer the sheet/panel so the popover's dismissal animation doesn't
            // conflict with NSOpenPanel.begin (same guard used by QuickSchedulePopoverView).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                action()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(.caption))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 16)
                Text(label)
                    .font(theme.fontSubheadline)
                    .foregroundColor(theme.primaryText)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popoverRowHighlight()
    }

    private func recentRow(_ url: URL) -> some View {
        // Trailing-slash-insensitive so the active project keeps its highlight however the two
        // URLs were built. **Hardening, not a fixed bug** — both sides are directory-flavoured
        // today. Deliberately the LEXICAL variant: this runs in a view body on every render and
        // `sameLocation` touches the filesystem, while `rememberRecentPath` has already
        // collapsed the list to one canonical entry per folder.
        let isActive = codeSessionManager.projectPath?.sameLocationLexically(as: url) == true
        return Button {
            isPresented = false
            onSelectRecent(url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(.caption))
                    .foregroundColor(isActive ? Color.cyan : theme.accentColor)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(theme.fontSubheadline)
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Text(abbreviatedParent(for: url))
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 4)

                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.cyan)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popoverRowHighlight()
        .help(url.path)
        // Read as a pile ("folder, Devgentic, ~/Documents/…, checkmark") with the ACTIVE
        // folder marked only by a bare glyph and a cyan tint. `.help()` doesn't fill the
        // label, so the full path was reachable by mouse hover only.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityValue(url.path)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    /// `~/…/parent` style abbreviation so long paths don't overflow the popover.
    private func abbreviatedParent(for url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if parent.hasPrefix(home) {
            return "~" + parent.dropFirst(home.count)
        }
        return parent
    }
}
