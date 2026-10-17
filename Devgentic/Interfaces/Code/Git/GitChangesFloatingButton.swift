// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitChangesFloatingButton.swift
//  Devgentic
//
//  The Code interface's git pill: branch + `+N −N`. Opens the Git Changes panel. A member of the
//  floating pill stack (`FloatingPillStack`), which decides the MODE; this decides the rest.
//

import SwiftUI

struct GitChangesFloatingButton: View {

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(GitChangesStore.self) private var store
    @Environment(\.appTheme) private var theme

    @State private var isHovering = false

    /// Shown once a repository has loaded and while no side panel occupies the slot (the pill would
    /// point at — or sit on — an open panel). Not shown for "not a repository" / "git unavailable":
    /// those are answers the PANEL gives; a pill advertising them would be noise on every non-git
    /// folder. A clean tree still shows (branch name, no counts) — ZCode parity.
    ///
    /// Promoted out of the body for the reason `BackgroundTasksFloatingButton.shouldShow` gives: a
    /// test must read the same expression, not a transcription of it.
    static func shouldShow(hasLoadedRepository: Bool, anyPanelOpen: Bool) -> Bool {
        hasLoadedRepository && !anyPanelOpen
    }

    var body: some View {
        if let snapshot = store.snapshot {
            pill(snapshot)
        }
    }

    private func branchText(_ snapshot: GitChangesSnapshot) -> String {
        if let head = snapshot.branch.head { return head }
        if let oid = snapshot.branch.oid { return String(oid.prefix(7)) }
        return String(localized: "no commits")
    }

    /// Branch names past this many characters are middle-truncated IN CODE.
    ///
    /// ⚠️ Not `.frame(maxWidth:)`: a flexible frame takes the WHOLE width it is offered up to its
    /// cap, and the pill stack offers the full chat width — so "main" sat centred in a fixed 140 pt
    /// slot and the pill rendered several times wider than the Code Viewer pill beside it. A
    /// truncated string keeps the text at its natural width.
    static let branchCharacterLimit = 18

    /// `feature/very-long-branch-name` → `feature/…anch-name`. Middle, because both ends carry
    /// meaning (the prefix says what kind of branch, the suffix which one).
    static func compactBranchName(_ name: String, limit: Int = branchCharacterLimit) -> String {
        guard name.count > limit, limit >= 3 else { return name }
        let keep = limit - 1
        let head = keep / 2, tail = keep - head
        return String(name.prefix(head)) + "…" + String(name.suffix(tail))
    }

    /// Styled to match `CodeViewerFloatingButton` (its sibling in the stack): icon + compact badge,
    /// same padding, material, stroke, shadow and hover scale.
    private func pill(_ snapshot: GitChangesSnapshot) -> some View {
        let totals = snapshot.totals()
        let fileCount = snapshot.files.count + snapshot.untrackedOverflowCount
        let branch = branchText(snapshot)
        return Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            chatHistoryViewModel.showGitChanges()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold)) // Fixed size: pill affordance
                    .foregroundColor(theme.accentColor)

                Text(verbatim: Self.compactBranchName(branch))
                    .font(.system(size: 11, weight: .semibold)) // Fixed size: pill label
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .fixedSize()

                if fileCount > 0 {
                    GitLineCountsLabel(added: totals.added, deleted: totals.deleted, fontSize: 10)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(theme.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                        .contentTransition(.numericText())
                        .fixedSize()
                }

                if snapshot.inProgressOperation != nil {
                    Circle()
                        .fill(theme.warningColor)
                        .frame(width: 5, height: 5)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.secondaryBackground.opacity(0.85))
        .background(.ultraThinMaterial, in: Capsule())
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(isHovering ? theme.accentColor.opacity(0.5) : theme.dividerColor.opacity(0.4),
                        lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .fixedSize()
        .help(helpText(snapshot, fileCount: fileCount))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(helpText(snapshot, fileCount: fileCount))
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func helpText(_ snapshot: GitChangesSnapshot, fileCount: Int) -> String {
        let branch = branchText(snapshot)
        if fileCount == 0 { return String(localized: "\(branch) — working tree clean") }
        let t = snapshot.totals()
        return fileCount == 1
            ? String(localized: "\(branch) — 1 changed file, \(t.added) added, \(t.deleted) deleted")
            : String(localized: "\(branch) — \(fileCount) changed files, \(t.added) added, \(t.deleted) deleted")
    }
}
