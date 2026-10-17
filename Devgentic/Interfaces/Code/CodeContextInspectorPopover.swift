// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeContextInspectorPopover.swift
//  Devgentic
//
//  Project Context: what every Code run in the project is told about it, and where the user
//  curates it.
//
//  • Memory — the entries in `.devgentic/memory/`, grouped by type, each with its evidence. The
//    user can edit or delete any of them here; that is the review step that replaced the
//    mid-task approval banner of the old `update_project_context` (2026-10-06).
//  • Instructions — the repository's `AGENTS.md`, read-only: it belongs to the people who
//    maintain the repo, and is opened in their editor to change.
//
//  Reads the disk on open and on every `.projectMemoryDidChange`, so what it shows is what the
//  next run will be given.
//

import SwiftUI

struct CodeContextInspectorPopover: View {
    let projectURL: URL?

    enum Tab: Hashable { case memory, instructions }

    @Environment(\.appTheme) private var theme

    @State private var tab: Tab = .memory
    @State private var entries: [ProjectMemoryEntry] = []
    @State private var staleFiles: [String: [String]] = [:]
    @State private var agentsInstructions: String?
    @State private var suggestions: [ProjectMemorySuggestion] = []
    @State private var expanded: Set<String> = []
    @State private var editing: ProjectMemoryEntry?
    @State private var pendingDelete: ProjectMemoryEntry?
    @State private var errorNote: String?

    private var store: ProjectMemoryStore? { projectURL.map { ProjectMemoryStore(projectRoot: $0) } }

    /// Reads the disk up front so the panel opens populated rather than empty for a frame. A
    /// project's memory is a few dozen small files at most.
    init(projectURL: URL?) {
        self.projectURL = projectURL
        let snapshot = Self.snapshot(projectURL)
        _entries = State(initialValue: snapshot.entries)
        _staleFiles = State(initialValue: snapshot.stale)
        _agentsInstructions = State(initialValue: snapshot.agents)
        _suggestions = State(initialValue: snapshot.suggestions)
    }

    private static func snapshot(_ projectURL: URL?)
        -> (entries: [ProjectMemoryEntry], stale: [String: [String]], agents: String?, suggestions: [ProjectMemorySuggestion]) {
        guard let projectURL else { return ([], [:], nil, []) }
        let store = ProjectMemoryStore(projectRoot: projectURL)
        let entries = store.entries()
        let stale = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, store.staleFiles(of: $0)) })
        return (entries, stale, ProjectInstructionsFile.read(inProject: projectURL.path),
                ProjectMemorySuggestionStore.shared.suggestions(projectPath: projectURL.path))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                Text(suggestions.isEmpty ? "Memory (\(entries.count))" : "Memory (\(entries.count) + \(suggestions.count) suggested)").tag(Tab.memory)
                Text("Instructions").tag(Tab.instructions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider().opacity(0.4)

            Group {
                switch tab {
                case .memory: memoryTab
                case .instructions: instructionsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.secondaryBackground.opacity(0.4))

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 440, height: 480)
        .background(theme.primaryBackground)
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .projectMemoryDidChange)) { _ in load() }
        .sheet(item: $editing) { entry in
            ProjectMemoryEntryEditor(entry: entry, onSave: save, onCancel: { editing = nil })
        }
        .confirmationDialog(
            "Delete memory '\(pendingDelete?.name ?? "")'?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { if let entry = pendingDelete { delete(entry) } }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Later runs will no longer be told this. The file in .devgentic/memory is removed.")
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.surfaceOverlayStrong))
            VStack(alignment: .leading, spacing: 2) {
                Text("Project Context")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("What every run in \(projectURL?.lastPathComponent ?? "this project") is told")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let errorNote {
                Text(errorNote)
                    .font(.system(size: 11))
                    .foregroundColor(theme.errorColor)
                    .lineLimit(2)
            }
            Spacer()
            if let target = revealTarget {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var revealTarget: URL? {
        guard let projectURL else { return nil }
        switch tab {
        case .memory:
            let folder = ProjectMemoryStore(projectRoot: projectURL).directory
            return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
        case .instructions:
            let file = ProjectInstructionsFile.url(inProject: projectURL.path)
            return FileManager.default.fileExists(atPath: file.path) ? file : nil
        }
    }

    // MARK: - Memory

    @ViewBuilder
    private var memoryTab: some View {
        if entries.isEmpty && suggestions.isEmpty {
            emptyState(
                icon: "brain",
                title: "No memories yet",
                body: "Ask the assistant to remember something — a rule, a decision, how you like to work — or let it save a command it ran successfully. Each fact is one file in .devgentic/memory, and every later run is told it.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Suggested — not saved until you accept")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                            ForEach(suggestions) { suggestion in suggestionRow(suggestion) }
                        }
                    }
                    ForEach(ProjectMemoryType.allCases, id: \.self) { type in
                        let group = entries.filter { $0.type == type }
                        if !group.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(type.rawValue.capitalized)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(theme.secondaryText)
                                ForEach(group, id: \.name) { entry in entryRow(entry) }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func entryRow(_ entry: ProjectMemoryEntry) -> some View {
        let isOpen = expanded.contains(entry.name)
        let stale = staleFiles[entry.name] ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isOpen { expanded.remove(entry.name) } else { expanded.insert(entry.name) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.name)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                            if !stale.isEmpty {
                                Text("May be stale")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.warningColor)
                                    .help("Changed since this was saved: \(stale.joined(separator: ", "))")
                            }
                        }
                        Text(entry.summary)
                            .font(.system(size: 11.5))
                            .foregroundColor(theme.secondaryText)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    if !entry.details.isEmpty {
                        Text(entry.details)
                            .font(.system(size: 11.5))
                            .foregroundColor(theme.primaryText.opacity(0.9))
                            .textSelection(.enabled)
                    }
                    if let command = entry.command { detail("Command", command, monospaced: true) }
                    if !entry.files.isEmpty { detail("Files", entry.files.joined(separator: ", "), monospaced: true) }
                    detail("Source", entry.evidence.isEmpty ? "—" : entry.evidence)
                    detail("Updated", entry.updated.isEmpty ? "—" : entry.updated)
                    HStack(spacing: 12) {
                        Button("Edit") { editing = entry }
                        Button("Delete", role: .destructive) { pendingDelete = entry }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.top, 2)
                }
                .padding(.leading, 2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.surfaceOverlay.opacity(0.5)))
    }

    private func suggestionRow(_ suggestion: ProjectMemorySuggestion) -> some View {
        let entry = suggestion.entry
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry?.name ?? "?")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                Text(entry?.type.rawValue ?? "")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            Text(entry?.summary ?? "Unreadable suggestion")
                .font(.system(size: 11.5))
                .foregroundColor(theme.secondaryText)
            if let command = entry?.command { detail("Command", command, monospaced: true) }
            HStack(spacing: 12) {
                Button("Accept") { accept(suggestion) }.disabled(entry == nil)
                Button("Dismiss") { ProjectMemorySuggestionStore.shared.dismiss(suggestion) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .medium))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func accept(_ suggestion: ProjectMemorySuggestion) {
        do {
            try ProjectMemorySuggestionStore.shared.accept(suggestion)
            errorNote = nil
        } catch {
            errorNote = "Could not save the suggestion: \(error.localizedDescription)"
        }
    }

    private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .foregroundColor(theme.secondaryText)
                .textSelection(.enabled)
        }
    }

    // MARK: - Instructions

    @ViewBuilder
    private var instructionsTab: some View {
        if let agentsInstructions {
            VStack(spacing: 0) {
                ScrollView {
                    Text(agentsInstructions)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(theme.primaryText.opacity(0.9))
                        .lineSpacing(3)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if let projectURL {
                    HStack {
                        Text("\(agentsInstructions.count) chars · read on every run")
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.tertiaryText)
                        Spacer()
                        Button("Open AGENTS.md") {
                            NSWorkspace.shared.open(ProjectInstructionsFile.url(inProject: projectURL.path))
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
        } else {
            emptyState(
                icon: "doc.text",
                title: "No AGENTS.md in this project",
                body: "Add an AGENTS.md at the project root with your build and test commands and house rules. Every run reads it in full; it is the same file other coding agents read.")
        }
    }

    private func emptyState(icon: String, title: String, body: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(theme.secondaryText.opacity(0.5))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(body)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
    }

    // MARK: - Actions

    private func load() {
        let snapshot = Self.snapshot(projectURL)
        entries = snapshot.entries
        staleFiles = snapshot.stale
        agentsInstructions = snapshot.agents
        suggestions = snapshot.suggestions
    }

    private func save(_ edited: ProjectMemoryEntry) {
        editing = nil
        guard let store, let projectURL else { return }
        do {
            try store.save(edited)
            errorNote = nil
        } catch {
            errorNote = "Could not save '\(edited.name)': \(error.localizedDescription)"
        }
        NotificationCenter.default.post(name: .projectMemoryDidChange, object: projectURL.path)
    }

    private func delete(_ entry: ProjectMemoryEntry) {
        pendingDelete = nil
        guard let store, let projectURL else { return }
        do {
            try store.remove(named: entry.name)
            errorNote = nil
        } catch {
            errorNote = "Could not delete '\(entry.name)': \(error.localizedDescription)"
        }
        NotificationCenter.default.post(name: .projectMemoryDidChange, object: projectURL.path)
    }
}

// MARK: - Editor

/// Edits one entry's summary and details. The user is trusted, so only the size limits apply —
/// the evidence checks are for what a MODEL claims.
struct ProjectMemoryEntryEditor: View {
    let entry: ProjectMemoryEntry
    let onSave: (ProjectMemoryEntry) -> Void
    let onCancel: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var summary: String
    @State private var details: String

    init(entry: ProjectMemoryEntry, onSave: @escaping (ProjectMemoryEntry) -> Void, onCancel: @escaping () -> Void) {
        self.entry = entry
        self.onSave = onSave
        self.onCancel = onCancel
        _summary = State(initialValue: entry.summary)
        _details = State(initialValue: entry.details)
    }

    private var cleanSummary: String {
        summary.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private var problem: String? {
        typealias Limits = ProjectMemoryStore.Limits
        if cleanSummary.isEmpty { return "The summary is empty." }
        if cleanSummary.count > Limits.summaryChars { return "Summary: \(cleanSummary.count)/\(Limits.summaryChars) characters." }
        if details.count > Limits.detailsChars { return "Details: \(details.count)/\(Limits.detailsChars) characters." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit memory '\(entry.name)'")
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Summary — one line, shown to every run").font(.system(size: 11)).foregroundColor(theme.secondaryText)
                TextField("", text: $summary)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Details").font(.system(size: 11)).foregroundColor(theme.secondaryText)
                TextEditor(text: $details)
                    .font(.system(size: 12))
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.dividerColor, lineWidth: 0.5))
            }
            HStack {
                if let problem {
                    Text(problem).font(.system(size: 11)).foregroundColor(theme.errorColor)
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(edited()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    func edited() -> ProjectMemoryEntry {
        Self.edited(entry, summary: cleanSummary, details: details, on: Date())
    }

    /// The entry as the user saved it: new text, today's date, and the source noting the edit.
    static func edited(_ entry: ProjectMemoryEntry, summary: String, details: String, on date: Date) -> ProjectMemoryEntry {
        let note = "edited by the user"
        let evidence = entry.evidence.contains(note) ? entry.evidence
            : [entry.evidence, note].filter { !$0.isEmpty }.joined(separator: "; ")
        return ProjectMemoryEntry(
            name: entry.name, type: entry.type, summary: summary,
            details: details.trimmingCharacters(in: .whitespacesAndNewlines),
            files: entry.files, command: entry.command, evidence: evidence,
            updated: RememberTool.day(date), extraFields: entry.extraFields)
    }
}
