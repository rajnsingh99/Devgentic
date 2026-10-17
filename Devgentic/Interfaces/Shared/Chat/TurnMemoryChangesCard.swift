// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TurnMemoryChangesCard.swift
//  Devgentic
//
//  "Saved 1 memory" under a finished Code answer: what the run's `remember` / `forget` calls
//  changed in project memory, each with Undo — and, when the project has memory suggestions on,
//  what the end-of-run pass proposes, each with Accept / Dismiss. Sits beside `TurnFileChangesCard`; memory is kept
//  out of that card on purpose — it is not an edit to the user's code, and Undo works differently
//  (a whole entry is put back from the ledger, not a patch applied).
//

import SwiftUI

enum TurnMemoryChanges {
    static func showsCard(for message: ChatMessage) -> Bool {
        message.sender == .agent && message.profileType == .code && !message.isStreaming
    }

    /// "Saved 2 memories, removed 1" — the header for the changes still standing.
    static func title(for changes: [ProjectMemoryChange]) -> String {
        let saved = changes.filter { $0.kind != .removed }.count
        let removed = changes.filter { $0.kind == .removed }.count
        var parts: [String] = []
        if saved > 0 { parts.append("Saved \(saved) memor\(saved == 1 ? "y" : "ies")") }
        if removed > 0 { parts.append("\(parts.isEmpty ? "Removed" : "removed") \(removed) memor\(removed == 1 ? "y" : "ies")") }
        return parts.joined(separator: ", ")
    }

    /// The note shown after Undo — one line for the whole batch.
    static func note(for results: [(name: String, result: ProjectMemoryLedger.UndoResult)]) -> String? {
        let changed = results.filter { $0.result == .changedSince }.map(\.name)
        let failed = results.compactMap { item -> String? in
            if case .failed(let why) = item.result { return "\(item.name) (\(why))" }
            return nil
        }
        var lines: [String] = []
        if !changed.isEmpty {
            lines.append("Not undone — changed since: \(changed.joined(separator: ", ")). Edit it in Project Context.")
        }
        if !failed.isEmpty { lines.append("Could not undo \(failed.joined(separator: ", ")).") }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}

struct TurnMemoryChangesCard: View {
    let message: ChatMessage

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(\.appTheme) private var theme
    @State private var changes: [ProjectMemoryChange] = []
    @State private var suggestions: [ProjectMemorySuggestion] = []
    @State private var note: String?
    @State private var isExpanded = false

    private var standing: [ProjectMemoryChange] { changes.filter { $0.revertedAt == nil } }

    var body: some View {
        Group {
            if !changes.isEmpty || !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if !changes.isEmpty {
                        header
                        if isExpanded {
                            ForEach(changes) { change in
                                Divider().opacity(0.4)
                                row(change)
                            }
                        }
                    }
                    if !suggestions.isEmpty {
                        if !changes.isEmpty { Divider().opacity(0.4) }
                        suggestionHeader
                        ForEach(suggestions) { suggestion in
                            Divider().opacity(0.4)
                            suggestionRow(suggestion)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.surfaceOverlay.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.dividerColor.opacity(0.6), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .padding(.top, 4)
                }
            }
        }
        .task(id: message.timelineRevision) { await reload() }
        // A memory pass finishes AFTER the answer, so its suggestions arrive on their own.
        .onReceive(NotificationCenter.default.publisher(for: .projectMemoryDidChange)) { _ in
            Task { await reload() }
        }
    }

    private var suggestionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundColor(theme.secondaryText)
            Text("\(suggestions.count) memor\(suggestions.count == 1 ? "y" : "ies") suggested")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
            Spacer(minLength: 8)
            Text("Not saved until you accept")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func suggestionRow(_ suggestion: ProjectMemorySuggestion) -> some View {
        let entry = suggestion.entry
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry?.type.rawValue ?? "?")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry?.summary ?? "Unreadable suggestion")
                    .font(.system(size: 12))
                    .foregroundColor(theme.primaryText)
                if let command = entry?.command {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                } else if let details = entry?.details, !details.isEmpty {
                    Text(details)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            Button("Accept") { accept(suggestion) }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .disabled(entry == nil)
            Button("Dismiss") { dismiss(suggestion) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .foregroundColor(theme.secondaryText)
                    Text(standing.isEmpty ? "Memory changes undone" : TurnMemoryChanges.title(for: standing))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(standing.isEmpty ? theme.tertiaryText : theme.primaryText)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !standing.isEmpty {
                Button("Undo") { undo(standing) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .disabled(undoRefusal != nil)
                    .help(undoRefusal ?? "Put project memory back the way it was before this answer")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func row(_ change: ProjectMemoryChange) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon(for: change.kind))
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(change.revertedAt == nil ? theme.primaryText : theme.tertiaryText)
                    .strikethrough(change.revertedAt != nil)
                if !change.summary.isEmpty {
                    Text(change.summary)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
            }
            Spacer(minLength: 8)
            if change.revertedAt != nil {
                Text("Undone").font(.system(size: 11)).foregroundColor(theme.tertiaryText)
            } else {
                Button("Undo") { undo([change]) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .disabled(undoRefusal != nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func icon(for kind: ProjectMemoryChange.Kind) -> String {
        switch kind {
        case .saved:    return "plus.circle"
        case .replaced: return "arrow.triangle.2.circlepath"
        case .removed:  return "minus.circle"
        }
    }

    /// A run streaming in this conversation may be writing memory too.
    private var undoRefusal: String? {
        chatHistoryViewModel.currentChatMessages.contains(where: \.isStreaming)
            ? "Wait for the current response to finish." : nil
    }

    private func reload() async {
        let conversationID = message.conversationId
        let messageID = message.id
        let loaded = await Task.detached(priority: .utility) {
            (ProjectMemoryLedger.shared.changes(conversationID: conversationID, messageID: messageID),
             ProjectMemorySuggestionStore.shared.suggestions(conversationID: conversationID, messageID: messageID))
        }.value
        changes = loaded.0
        suggestions = loaded.1
    }

    private func accept(_ suggestion: ProjectMemorySuggestion) {
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try ProjectMemorySuggestionStore.shared.accept(suggestion); return nil }
                catch { return error.localizedDescription }
            }.value
            note = failure.map { "Could not save the suggestion: \($0)" }
            await reload()
        }
    }

    private func dismiss(_ suggestion: ProjectMemorySuggestion) {
        Task {
            await Task.detached(priority: .userInitiated) { ProjectMemorySuggestionStore.shared.dismiss(suggestion) }.value
            await reload()
        }
    }

    /// Newest first, so a later change to the same entry is undone before the one it replaced.
    private func undo(_ selected: [ProjectMemoryChange]) {
        let ordered = selected.sorted { $0.at > $1.at }
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                ordered.map { (name: $0.name, result: ProjectMemoryLedger.shared.undo($0)) }
            }.value
            note = TurnMemoryChanges.note(for: results)
            await reload()
        }
    }
}
