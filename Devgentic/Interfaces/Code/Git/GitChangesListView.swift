// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitChangesListView.swift
//  Devgentic
//
//  The Git Changes panel's body: filter, banners, one row per changed file, and an explainer for
//  every state that is not a list — never a silent blank.
//

import SwiftUI
import AppKit

private let logger = DGLogger(category: "GitUI")

struct GitChangesListView: View {

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(GitChangesStore.self) private var store
    @Environment(\.appTheme) private var theme
    @AppStorage(AppSettings.chatFontSizeKey) private var chatFontSize: Double = 14.0

    /// Expanded rows, by path. Survives refreshes so an open diff stays open while the agent works.
    @State private var expanded: Set<String> = []

    var body: some View {
        switch store.phase {
        case .noProject:
            if store.projectPath != nil {
                loading
            } else {
                explainer(icon: "folder", title: String(localized: "No folder open"),
                          body: String(localized: "Open a project folder to see its uncommitted changes."))
            }
        case .gitUnavailable:
            explainer(icon: "wrench.and.screwdriver", title: String(localized: "Git isn't available"),
                      body: String(localized: "Install the Xcode Command Line Tools (run `xcode-select --install` in Terminal) to see changes here."))
        case .notARepository(let detail):
            explainer(icon: "questionmark.folder", title: String(localized: "Not a git repository"),
                      body: String(localized: "This folder isn't inside a git repository."),
                      detail: detail)
        case .failed(let message):
            explainer(icon: "exclamationmark.triangle", title: String(localized: "Couldn't read changes"),
                      body: String(localized: "Git reported an error. Try Refresh."),
                      detail: message, tint: theme.warningColor)
        case .loaded(let snapshot):
            loaded(snapshot)
        }
    }

    // MARK: - Loaded

    @ViewBuilder
    private func loaded(_ snapshot: GitChangesSnapshot) -> some View {
        @Bindable var vm = chatHistoryViewModel
        let filter = chatHistoryViewModel.gitChangesFilter
        let files = snapshot.files(for: filter)
        let totals = snapshot.totals(for: filter)

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker(String(localized: "Show"), selection: $vm.gitChangesFilter) {
                    Text(String(localized: "All")).tag(GitChangesFilter.all)
                    Text(String(localized: "Staged")).tag(GitChangesFilter.staged)
                    Text(String(localized: "Unstaged")).tag(GitChangesFilter.unstaged)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help(String(localized: "Show all changes, only staged, or only unstaged"))
                .onChange(of: chatHistoryViewModel.gitChangesFilter) { _, _ in
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                }

                Text(files.count == 1 ? String(localized: "1 file") : String(localized: "\(files.count) files"))
                    .font(.system(size: chatFontSize - 3))
                    .foregroundStyle(theme.secondaryText)

                Spacer()

                if totals.added + totals.deleted > 0 {
                    GitLineCountsLabel(added: totals.added, deleted: totals.deleted, fontSize: chatFontSize - 2)
                }
                if store.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if let operation = snapshot.inProgressOperation {
                banner(icon: "arrow.triangle.merge", tint: theme.warningColor,
                       text: inProgressText(operation, conflicts: snapshot.files.filter { $0.kind == .unmerged }.count))
            }
            if snapshot.isTruncated {
                banner(icon: "exclamationmark.triangle", tint: theme.warningColor,
                       text: String(localized: "Git's output was incomplete — some files may be missing from this list."))
            }

            if files.isEmpty && (filter != .all || snapshot.untrackedOverflowCount == 0) {
                explainer(icon: "checkmark.circle", title: emptyTitle(filter, snapshot: snapshot),
                          body: emptyBody(filter, snapshot: snapshot), tint: theme.successColor)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            GitChangeRow(file: file, filter: filter, repoRoot: snapshot.repoRoot,
                                         isExpanded: expanded.contains(file.path)) {
                                if expanded.contains(file.path) { expanded.remove(file.path) }
                                else { expanded.insert(file.path) }
                            }
                        }
                        if snapshot.untrackedOverflowCount > 0 && filter != .staged {
                            Text(String(localized: "+ \(snapshot.untrackedOverflowCount) more untracked files — check your .gitignore"))
                                .font(.system(size: chatFontSize - 3))
                                .foregroundStyle(theme.tertiaryText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }
        }
    }

    private func inProgressText(_ operation: GitInProgressOperation, conflicts: Int) -> String {
        let name: String = switch operation {
        case .merge: String(localized: "Merge in progress")
        case .rebase: String(localized: "Rebase in progress")
        case .cherryPick: String(localized: "Cherry-pick in progress")
        case .revert: String(localized: "Revert in progress")
        }
        guard conflicts > 0 else { return name }
        return conflicts == 1
            ? String(localized: "\(name) — 1 conflicted file")
            : String(localized: "\(name) — \(conflicts) conflicted files")
    }

    private func emptyTitle(_ filter: GitChangesFilter, snapshot: GitChangesSnapshot) -> String {
        switch filter {
        case .all: return String(localized: "Working tree clean")
        case .staged: return String(localized: "Nothing staged")
        case .unstaged: return String(localized: "No unstaged changes")
        }
    }

    private func emptyBody(_ filter: GitChangesFilter, snapshot: GitChangesSnapshot) -> String {
        switch filter {
        case .all: return String(localized: "No uncommitted changes in this repository.")
        case .staged, .unstaged:
            let total = snapshot.files.count
            return total == 1
                ? String(localized: "1 file has changes under All.")
                : String(localized: "\(total) files have changes under All.")
        }
    }

    // MARK: - Pieces

    private var loading: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(String(localized: "Reading changes…"))
                .font(.system(size: chatFontSize - 2))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func banner(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: chatFontSize - 3, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(tint.opacity(0.10))
        .accessibilityElement(children: .combine)
    }

    private func explainer(icon: String, title: String, body: String, detail: String? = nil,
                           tint: Color? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(tint ?? theme.tertiaryText)
            Text(title)
                .font(.system(size: chatFontSize - 1, weight: .semibold))
                .foregroundStyle(theme.primaryText)
            Text(body)
                .font(.system(size: chatFontSize - 3))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: chatFontSize - 4, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Row

private struct GitChangeRow: View {
    let file: GitFileChange
    let filter: GitChangesFilter
    let repoRoot: String
    let isExpanded: Bool
    let onToggle: () -> Void

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(\.appTheme) private var theme
    @AppStorage(AppSettings.chatFontSizeKey) private var chatFontSize: Double = 14.0
    @State private var isHovering = false
    @State private var openFailure: String?

    private var absolutePath: String { (repoRoot as NSString).appendingPathComponent(file.path) }
    private var fileName: String { (file.path as NSString).lastPathComponent }
    private var directory: String { (file.path as NSString).deletingLastPathComponent }
    private var existsInWorktree: Bool { file.worktreeStatus != "D" }

    private var glyphColor: Color {
        switch file.statusGlyph {
        case "A": return theme.successColor
        case "D": return theme.errorColor
        case "M", "T": return theme.warningColor
        case "R", "C": return .purple
        case "U": return theme.errorColor
        default: return theme.tertiaryText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                onToggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.tertiaryText)
                        .frame(width: 10)
                    Text(verbatim: String(file.statusGlyph))
                        .font(.system(size: chatFontSize - 3, weight: .bold, design: .monospaced))
                        .foregroundStyle(glyphColor)
                        .frame(width: 12)
                        .help(file.statusDescription)
                    HStack(spacing: 6) {
                        Text(fileName)
                            .font(.system(size: chatFontSize - 2, weight: .medium))
                            .foregroundStyle(file.isOutsideProject ? theme.secondaryText : theme.primaryText)
                            .lineLimit(1)
                        if let original = file.originalPath {
                            Text(String(localized: "from \((original as NSString).lastPathComponent)"))
                                .font(.system(size: chatFontSize - 4))
                                .foregroundStyle(theme.tertiaryText)
                                .lineLimit(1)
                        }
                        if !directory.isEmpty {
                            Text(directory)
                                .font(.system(size: chatFontSize - 4))
                                .foregroundStyle(theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        if file.isOutsideProject {
                            Text(String(localized: "outside project"))
                                .font(.system(size: chatFontSize - 5, weight: .medium))
                                .foregroundStyle(theme.tertiaryText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(Capsule().stroke(theme.tertiaryText.opacity(0.4), lineWidth: 0.5))
                        }
                    }
                    Spacer(minLength: 8)
                    countsLabel
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(isHovering ? theme.secondaryText.opacity(0.06) : Color.clear)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(file.path)
            .accessibilityLabel(file.accessibilitySummary(for: filter))
            .accessibilityValue(isExpanded ? String(localized: "expanded") : String(localized: "collapsed"))
            .accessibilityHint(isExpanded ? String(localized: "Hides the diff") : String(localized: "Shows the diff"))
            .contextMenu { contextMenu }

            if let openFailure {
                Text(openFailure)
                    .font(.system(size: chatFontSize - 4))
                    .foregroundStyle(theme.warningColor)
                    .padding(.horizontal, 44)
                    .padding(.bottom, 4)
            }

            if isExpanded {
                GitFileDiffView(file: file, filter: filter)
                    .padding(.leading, 30)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var countsLabel: some View {
        if let info = file.untracked {
            switch info {
            case .lines(let n): GitLineCountsLabel(added: n, deleted: 0, fontSize: chatFontSize - 3)
            case .binary: tag(String(localized: "Binary"))
            case .tooLarge: tag(String(localized: "Large"))
            case .unreadable: tag(String(localized: "Unreadable"))
            }
        } else if file.isBinary {
            tag(String(localized: "Binary"))
        } else {
            let t = file.totals(for: filter)
            GitLineCountsLabel(added: t.added, deleted: t.deleted, fontSize: chatFontSize - 3)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: chatFontSize - 4, weight: .medium))
            .foregroundStyle(theme.tertiaryText)
    }

    @ViewBuilder
    private var contextMenu: some View {
        if existsInWorktree && chatHistoryViewModel.canPresentCodeViewer {
            Button(String(localized: "Open in Code Viewer")) { openInCodeViewer() }
        }
        Button(String(localized: "Copy Path")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(absolutePath, forType: .string)
        }
        if existsInWorktree {
            Button(String(localized: "Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
            }
        }
    }

    /// Same off-main read and explicit failure path as `ContentBlockView.openFileReference`: the file
    /// can change between the snapshot and the click.
    private func openInCodeViewer() {
        let path = absolutePath
        let viewModel = chatHistoryViewModel
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do { return .success(try String(contentsOfFile: path, encoding: .utf8)) }
                catch { return .failure(error) }
            }.value
            switch result {
            case .failure(let error):
                openFailure = ContentBlockView.openFailureText(for: error, path: path)
                logger.warning("[GitUI] Open in Code Viewer of '\(path)' failed — \(error.localizedDescription). Reason shown under the row; nothing opened.")
            case .success(let content) where content.isEmpty:
                openFailure = String(localized: "This file is now empty — nothing to show.")
            case .success(let content):
                openFailure = nil
                viewModel.openTimelineFileInCodeViewer(fileName: (path as NSString).lastPathComponent,
                                                       filePath: path, content: content)
            }
        }
    }
}

// MARK: - Shared label

/// `+N −N` in success / error tints; a zero side is omitted (ZCode parity), both-zero shows `±0`.
struct GitLineCountsLabel: View {
    let added: Int
    let deleted: Int
    var fontSize: Double = 11
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            // `verbatim`: symbols and numbers, not words — nothing here for a translator.
            if added == 0 && deleted == 0 {
                Text(verbatim: "±0").foregroundStyle(theme.tertiaryText)
            } else {
                if added > 0 { Text(verbatim: "+\(added)").foregroundStyle(theme.successColor) }
                if deleted > 0 { Text(verbatim: "−\(deleted)").foregroundStyle(theme.errorColor) }
            }
        }
        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GitLineTotals.spoken(GitLineTotals(added: added, deleted: deleted)))
    }
}
