// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TurnFileChangesCard.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = DGLogger(category: "TurnFileChanges")

/// One file a turn changed.
struct TurnFileChange: Identifiable, Equatable, Sendable {
    let path: String
    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    let added: Int
    let removed: Int
    /// The file did not exist before the turn's first write to it.
    let isNew: Bool
    /// Each write's recorded diff, oldest first. Nil entries are writes with no baseline.
    let diffs: [String?]
    let isTruncated: Bool
    /// True when the counts are the file's NET change (first snapshot → last write). False when
    /// they are summed per write, which can overcount a file edited more than once.
    let isNet: Bool
    var writeCount: Int { diffs.count }
}

struct TurnFileChangesSummary: Equatable, Sendable {
    let files: [TurnFileChange]
    /// The turn ran a command that can change files the card does not list.
    let ranCommands: Bool

    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }
    var isEmpty: Bool { files.isEmpty }
}

enum TurnFileChanges {

    /// Tools that run arbitrary commands, and so may change files without recording an effect.
    static let commandTools: Set<String> = ["run_command", "batch_command", "git"]

    /// The turn's tool calls, in order — read on the main actor, summarised off it.
    @MainActor
    static func toolCalls(in message: ChatMessage) -> (calls: [ToolExecutionData], startedTasks: Bool) {
        var calls: [ToolExecutionData] = []
        var startedTasks = false
        for event in message.flattenedTimelineEvents {
            switch event {
            case .toolExecution(let data): calls.append(data)
            case .backgroundTask: startedTasks = true
            default: break
            }
        }
        return (calls, startedTasks)
    }

    /// Pure. Groups successful writes by file, first-seen order.
    static func summarize(_ calls: [ToolExecutionData], startedTasks: Bool = false) -> TurnFileChangesSummary {
        var order: [String] = []
        var writes: [String: [ToolExecutionData]] = [:]
        var ranCommands = startedTasks
        for call in calls {
            if commandTools.contains(call.name) { ranCommands = true }
            guard call.isSuccess != false, let effect = call.effect else { continue }
            let key = URL(fileURLWithPath: effect.path).standardizedFileURL.path
            if writes[key] == nil { order.append(key) }
            writes[key, default: []].append(call)
        }

        let files = order.compactMap { path -> TurnFileChange? in
            guard let group = writes[path], let first = group.first?.effect else { return nil }
            let effects = group.compactMap(\.effect)
            let firstBefore = TimelineFileViewerAction.resolve(data: group[0], missingBaseline: .recordFragment)?.preWriteContent
            let lastAfter = group.last.flatMap { TimelineFileViewerAction.resolve(data: $0, missingBaseline: .recordFragment)?.inlineContent }

            var added = effects.reduce(0) { $0 + $1.linesAdded }
            var removed = effects.reduce(0) { $0 + $1.linesRemoved }
            var isNet = group.count == 1
            // Edited more than once and both ends are still in memory: count the NET change, so a
            // line added then removed again is not reported twice.
            if group.count > 1, let firstBefore, let lastAfter {
                let counts = DiffUtility.changeCounts(rows: DiffUtility.lineLevelDiff(original: firstBefore, modified: lastAfter))
                added = counts.added
                removed = counts.deleted
                isNet = true
            }
            return TurnFileChange(path: first.path, added: added, removed: removed,
                                  isNew: firstBefore == "", diffs: effects.map(\.diff),
                                  isTruncated: effects.contains(where: \.isTruncated), isNet: isNet)
        }
        return TurnFileChangesSummary(files: files, ranCommands: ranCommands)
    }

    /// Where the card is drawn: Code turns only, once the run is done.
    @MainActor
    static func showsCard(for message: ChatMessage) -> Bool {
        message.sender == .agent && message.profileType == .code && !message.isStreaming
    }
}

// MARK: - The card

struct TurnFileChangesCard: View {
    let message: ChatMessage

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(\.appTheme) private var theme
    @State private var summary: TurnFileChangesSummary?
    @State private var isExpanded = true
    @State private var openRows: Set<String> = []
    /// Every edit this turn recorded has been undone.
    @State private var isUndone = false
    @State private var pendingUndo: PendingUndo?
    @State private var isPlanning = false
    @State private var undoNote: String?

    /// A computed plan waiting for the user's confirmation.
    struct PendingUndo: Identifiable {
        let id = UUID()
        let plan: EditUndo.Plan
        let isRewind: Bool
    }

    var body: some View {
        Group {
            if let summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header(summary)
                    if isExpanded {
                        ForEach(summary.files) { file in
                            Divider().opacity(0.4)
                            row(file)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.surfaceOverlay.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.dividerColor.opacity(0.6), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if let undoNote {
                    Text(undoNote)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .padding(.top, 4)
                }

                if summary.ranCommands {
                    Text("Commands also ran this turn — they may have changed files not listed here.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.top, 4)
                }
            }
        }
        // Recomputed only when the timeline changes, and off the main actor: a net count runs a
        // line diff per multiply-edited file.
        .task(id: message.timelineRevision) {
            let (calls, startedTasks) = TurnFileChanges.toolCalls(in: message)
            guard calls.contains(where: { $0.effect != nil }) else { summary = nil; return }
            let computed = await Task.detached(priority: .utility) {
                TurnFileChanges.summarize(calls, startedTasks: startedTasks)
            }.value
            summary = computed
            isExpanded = computed.files.count <= 6
            await refreshUndoneState()
        }
        .sheet(item: $pendingUndo) { pending in
            UndoEditsSheet(plan: pending.plan, isRewind: pending.isRewind,
                           onConfirm: { apply(pending.plan) },
                           onCancel: { pendingUndo = nil })
        }
    }

    private func header(_ summary: TurnFileChangesSummary) -> some View {
        HStack(spacing: 8) {
            Button { toggleExpanded() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plusminus.circle")
                        .foregroundColor(theme.secondaryText)
                    Text("Edited \(summary.files.count) file\(summary.files.count == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edited \(summary.files.count) files, \(summary.added) lines added, \(summary.removed) removed")

            undoControl

            Button { toggleExpanded() } label: {
                HStack(spacing: 8) {
                    counts(added: summary.added, removed: summary.removed)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
    }

    // MARK: - Undo

    /// Why Undo cannot start now, or nil. A run streaming in this conversation may be writing the
    /// same files — undoing underneath it would race it.
    private var undoRefusal: String? {
        chatHistoryViewModel.currentChatMessages.contains(where: \.isStreaming)
            ? "Wait for the current response to finish." : nil
    }

    @ViewBuilder
    private var undoControl: some View {
        if isUndone {
            Text("Undone")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.tertiaryText)
        } else if isPlanning {
            ProgressView().controlSize(.small)
        } else {
            Menu {
                Button("Undo This Turn's Edits") { startUndo(rewind: false) }
                Button("Rewind Files to Before This Turn") { startUndo(rewind: true) }
            } label: {
                Text("Undo").font(.system(size: 12, weight: .medium))
            } primaryAction: {
                startUndo(rewind: false)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(undoRefusal != nil)
            .help(undoRefusal ?? "Undo this turn's edits. The menu also rewinds every later turn's edits.")
        }
    }

    private func startUndo(rewind: Bool) {
        let writes = EditUndo.writes(from: message, newestFirst: chatHistoryViewModel.currentChatMessages,
                                     throughLatest: rewind)
        let conversationID = message.conversationId
        isPlanning = true
        undoNote = nil
        Task {
            let plan = await Task.detached(priority: .userInitiated) {
                EditUndo.plan(writes: writes, conversationID: conversationID, store: .shared, read: EditUndo.readFile)
            }.value
            isPlanning = false
            pendingUndo = PendingUndo(plan: plan, isRewind: rewind)
        }
    }

    private func apply(_ plan: EditUndo.Plan) {
        pendingUndo = nil
        Task {
            let applied = await Task.detached(priority: .userInitiated) {
                EditUndo.apply(plan, store: .shared, read: EditUndo.readFile)
            }.value
            let left = plan.files.count - applied.changed.count
            undoNote = left == 0
                ? "Undid edits to \(applied.changed.count) file\(applied.changed.count == 1 ? "" : "s")."
                : "Undid edits to \(applied.changed.count) of \(plan.files.count) files — the rest were left as they are."
            await refreshUndoneState()
        }
    }

    /// Whether every edit of THIS turn has been undone (by Undo here, or by a Rewind from earlier).
    private func refreshUndoneState() async {
        let writes = EditUndo.writes(in: message)
        let conversationID = message.conversationId
        guard !writes.isEmpty else { isUndone = false; return }
        isUndone = await Task.detached(priority: .utility) {
            writes.allSatisfy {
                EditPatchStore.shared.load(conversationID: conversationID, toolEventID: $0.toolEventID)?.revertedAt != nil
            }
        }.value
    }

    @ViewBuilder
    private func row(_ file: TurnFileChange) -> some View {
        let isOpen = openRows.contains(file.id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isOpen { openRows.remove(file.id) } else { openRows.insert(file.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                    Text(file.fileName)
                        .font(.system(size: 12.5))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if file.isNew {
                        Text("new").font(.system(size: 10, weight: .medium)).foregroundColor(theme.tertiaryText)
                    }
                    Spacer(minLength: 8)
                    counts(added: file.added, removed: file.removed, approximate: !file.isNet)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(file.path)

            if isOpen {
                diffView(file)
            }
        }
    }

    @ViewBuilder
    private func diffView(_ file: TurnFileChange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.diffs.enumerated()), id: \.offset) { index, diff in
                        if file.writeCount > 1 {
                            Text("Edit \(index + 1) of \(file.writeCount)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.vertical, 3)
                        }
                        if let diff {
                            ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Self.lineColor(line, theme: theme))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Self.lineBackground(line, theme: theme))
                            }
                        } else {
                            Text("No diff was recorded for this write — open the file to see it.")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(8)
            }
            .frame(maxHeight: 260)
            .background(theme.secondaryBackground.opacity(0.5))

            HStack {
                if file.isTruncated {
                    Text("Part of this change is not shown.")
                        .font(.system(size: 10.5)).foregroundColor(theme.tertiaryText)
                }
                Spacer()
                Button("Open") { open(file) }
                    .controlSize(.small)
                    .help("Open \(file.fileName) as it is now")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func counts(added: Int, removed: Int, approximate: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text("+\(added)").foregroundColor(theme.successColor)
            Text("−\(removed)").foregroundColor(theme.errorColor)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .help(approximate ? "Summed across this turn's edits to the file — a line changed twice counts twice." : "")
    }

    static func lineColor(_ line: String, theme: any Theme) -> Color {
        if line.hasPrefix("+") { return theme.successColor }
        if line.hasPrefix("-") { return theme.errorColor }
        return theme.secondaryText
    }

    static func lineBackground(_ line: String, theme: any Theme) -> Color {
        if line.hasPrefix("+") { return theme.successColor.opacity(0.08) }
        if line.hasPrefix("-") { return theme.errorColor.opacity(0.08) }
        return .clear
    }

    /// Opens the file as it is on disk now. Dropped if the conversation changed while reading, since a tab opened
    /// mid-switch would land in the wrong conversation.
    private func open(_ file: TurnFileChange) {
        let origin = message.conversationId
        let path = file.path
        let viewModel = chatHistoryViewModel
        Task {
            let read = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do { return .success(try String(contentsOfFile: path, encoding: .utf8)) }
                catch { return .failure(error) }
            }.value
            guard !viewModel.isInitiallyLoadingConversation,
                  viewModel.currentChatMessages.first?.conversationId == origin else {
                logger.info("[CodeViewer] Edited-files Open of '\(path)' dropped — the conversation changed while reading. CONSEQUENCE: no tab opens; re-click once the switch settles.")
                return
            }
            switch read {
            case .success(let content):
                viewModel.openTimelineFileInCodeViewer(fileName: file.fileName, filePath: path, content: content)
            case .failure(let error):
                logger.warning("[CodeViewer] Edited-files Open of '\(path)' failed — \(error.localizedDescription). CONSEQUENCE: nothing opened; the file may have been moved or deleted since the turn.")
            }
        }
    }
}

// MARK: - Confirmation

/// What Undo / Rewind will do, file by file, before anything is written.
struct UndoEditsSheet: View {
    let plan: EditUndo.Plan
    let isRewind: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isRewind ? "Rewind files to before this turn?" : "Undo this turn's edits?")
                .font(.headline)
            Text(isRewind
                 ? "Reverses this turn's edits and every later turn's, newest first. The conversation itself is not changed."
                 : "Reverses the edits this turn made. The conversation itself is not changed.")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.files) { file in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: Self.symbol(file.outcome))
                                .foregroundColor(Self.tint(file.outcome, theme: theme))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.fileName).font(.system(size: 12.5, weight: .medium))
                                Text(Self.describe(file.outcome))
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.secondaryText)
                            }
                        }
                        .help(file.path)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(Self.confirmTitle(plan, isRewind: isRewind), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.changing.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    static func confirmTitle(_ plan: EditUndo.Plan, isRewind: Bool) -> String {
        let n = plan.changing.count
        return "\(isRewind ? "Rewind" : "Undo") \(n) File\(n == 1 ? "" : "s")"
    }

    static func describe(_ outcome: EditUndo.FileOutcome) -> String {
        switch outcome {
        case .restore(_, let exact):
            return exact ? "Will be restored exactly." : "Changed since — only the agent's lines will be reversed; your later changes stay."
        case .moveToTrash: return "Created by these edits — will be moved to the Trash."
        case .conflict(let reason): return "Left as it is: \(reason)"
        case .cannotUndo(let reason): return "Can't be undone: \(reason)"
        case .alreadyUndone: return "Already undone."
        }
    }

    static func symbol(_ outcome: EditUndo.FileOutcome) -> String {
        switch outcome {
        case .restore: return "arrow.uturn.backward.circle"
        case .moveToTrash: return "trash"
        case .conflict, .cannotUndo: return "exclamationmark.triangle"
        case .alreadyUndone: return "checkmark.circle"
        }
    }

    static func tint(_ outcome: EditUndo.FileOutcome, theme: any Theme) -> Color {
        switch outcome {
        case .restore, .moveToTrash: return theme.accentColor
        case .conflict, .cannotUndo: return theme.warningColor
        case .alreadyUndone: return theme.tertiaryText
        }
    }
}
