// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillImportSheet.swift
//  Devgentic
//
//  Adding skills to the library: drag in a folder, an archive, or a bare .md — several at once.
//
//  ## Read first, commit second
//
//  Everything dropped is INGESTED into memory and shown before a single row is written. That is not
//  politeness: the library owns the only copy of a skill now, and an import that silently took some
//  files and not others would be invisible until the skill failed to do what its instructions say.
//  The user sees what will be added and what was refused, with reasons, and then decides.
//
//  ⚠️ Reading happens OFF the main actor. An archive runs two `unzip` subprocesses and a full tree
//  walk; a folder can hold thousands of files. Doing that inline froze the UI for the whole import
//  with nothing on screen to explain why. The store write afterwards is back on the main actor,
//  where it belongs.
//
//  ⚠️ NO "SECURITY SCAN" ROW, deliberately, even though the reference UI has one. That scan is a
//  server-side service on someone else's infrastructure; this app has no equivalent and nothing to
//  put behind such a label. A row that names a check the app does not perform is worse than no row —
//  it is the user being told they are protected. What IS shown is the list of checks that genuinely
//  run, which is a shorter and truer claim.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SkillImportSheet: View {

    /// Called after skills are added, so the library re-reads.
    let onImported: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var ready: [IngestedSkill] = []
    @State private var refused: [RejectedSkill] = []
    @State private var isReading = false
    @State private var isTargeted = false
    @State private var commitError: String?

    /// What to do with each ready skill, keyed by its name.
    ///
    /// ⚠️ Preselected from `SkillImportPlan`, never applied silently — a name collision changes what
    /// the import MEANS (update an existing skill, or add a second one an agent cannot reach), and
    /// that is the user's call.
    @State private var resolutions: [String: SkillImportResolution] = [:]

    /// The library as `SkillImportPlan` wants it — id, name, label and version count.
    private var librarySummary: [(id: String, name: String, displayName: String, versionCount: Int)] {
        ((try? SkillStore.shared.fetchSkills().get()) ?? [])
            .map { ($0.id, $0.name, $0.displayName, $0.versions.count) }
    }

    private func collision(for skill: IngestedSkill) -> SkillImportPlan.Collision {
        SkillImportPlan.collision(for: skill.name, existing: librarySummary)
    }

    private func resolution(for skill: IngestedSkill) -> SkillImportResolution {
        resolutions[skill.name] ?? SkillImportPlan.defaultResolution(for: collision(for: skill))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dropZone
                    hints
                    if !ready.isEmpty { readyList }
                    if !refused.isEmpty { refusedList }
                    if let commitError {
                        Label(commitError, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        .background(theme.primaryBackground)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add skills")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.primaryText)
            Text("Skills are copied into Devgentic. The originals are left exactly where they are.")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(16)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            if isReading {
                ProgressView().controlSize(.small)
                Text("Reading…").font(.system(size: 12)).foregroundStyle(theme.secondaryText)
            } else {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.secondaryText)
                Text("Drag skills here, or browse — you can add several at once")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(isTargeted ? Color.accentColor : theme.secondaryText.opacity(0.4))
        )
        .background((isTargeted ? Color.accentColor.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { browse() }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: 3) {
            bullet("A folder containing SKILL.md — or a folder of them")
            bullet("A .zip or .skill archive that contains a SKILL.md")
            bullet("A single .md file whose YAML frontmatter has a name and a description")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(theme.secondaryText)
            Text(text).font(.system(size: 11)).foregroundStyle(theme.secondaryText)
        }
    }

    private var readyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Will be added (\(ready.count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)

            ForEach(ready, id: \.name) { skill in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                        Spacer(minLength: 0)
                        Text(summary(for: skill))
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Text(skill.description)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)

                    if let explanation = SkillImportPlan.explanation(for: collision(for: skill), skillName: skill.name) {
                        Text(explanation)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        resolutionPicker(for: skill)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// ⚠️ Refusals are SHOWN, not counted. "3 skipped" is a number the user cannot act on; the
    /// folder name plus the reason is. Silently dropping them is how the old importer made a
    /// repository look like it contained fewer skills than it did.
    private var refusedList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not added (\(refused.count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)

            ForEach(Array(refused.enumerated()), id: \.offset) { _, rejection in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rejection.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                        Text(rejection.reason)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.secondaryBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// ⚠️ Three outcomes, none of them silent. "Import as new" is offered but never preselected: it
    /// is the one that creates a name an agent cannot fully reach, and there is no later merge that
    /// undoes it.
    @ViewBuilder
    private func resolutionPicker(for skill: IngestedSkill) -> some View {
        let current = resolution(for: skill)
        HStack(spacing: 6) {
            if case .one(let skillID, _, _) = collision(for: skill) {
                resolutionButton("Add version", isOn: current == .addVersion(skillID: skillID)) {
                    resolutions[skill.name] = .addVersion(skillID: skillID)
                }
            }
            resolutionButton("Import as new", isOn: current == .createNew) {
                resolutions[skill.name] = .createNew
            }
            resolutionButton("Skip", isOn: current == .skip) {
                resolutions[skill.name] = .skip
            }
        }
    }

    private func resolutionButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: isOn ? .semibold : .regular))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(isOn ? Color.accentColor.opacity(0.18) : theme.secondaryText.opacity(0.08),
                            in: Capsule())
                .foregroundStyle(isOn ? Color.accentColor : theme.secondaryText)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Browse…") { browse() }
            if !ready.isEmpty || !refused.isEmpty {
                Button("Clear") { ready = []; refused = []; resolutions = [:]; commitError = nil }
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button(actionLabel) { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(ready.isEmpty || isReading || actionLabel == "Nothing to do")
        }
        .padding(12)
    }

    /// Names what will actually happen, because "Add 3 skills" would be a lie when one is a version
    /// and one is skipped.
    private var actionLabel: String {
        let creating = ready.filter { resolution(for: $0) == .createNew }.count
        let versioning = ready.filter { if case .addVersion = resolution(for: $0) { return true } else { return false } }.count
        var parts: [String] = []
        if creating > 0 { parts.append("Add \(creating)") }
        if versioning > 0 { parts.append("Update \(versioning)") }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: " · ")
    }

    private func summary(for skill: IngestedSkill) -> String {
        guard !skill.files.isEmpty else { return "no bundled files" }
        let bytes = skill.totalBytes
        let size = bytes < 1024 ? "\(bytes) B"
            : bytes < 1024 * 1024 ? "\(bytes / 1024) KB"
            : String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
        return "\(skill.files.count) file\(skill.files.count == 1 ? "" : "s") · \(size)"
    }

    // MARK: - Input

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose skill folders, archives, or .md files"
        guard panel.runModal() == .OK else { return }
        read(panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            var unreadable = 0
            for provider in providers {
                guard let url = await provider.loadFileURL() else {
                    unreadable += 1
                    continue
                }
                urls.append(url)
            }

            // ⚠️ A drop that yields nothing must not look like a drop that never happened. The
            // user aimed at the target and let go; silence there reads as the sheet being broken,
            // and it is the one failure they can act on (drag from Finder instead).
            if let report = SkillDropReport.message(resolved: urls.count, unreadable: unreadable) {
                commitError = report
            }
            read(urls)
        }
    }

    /// ⚠️ APPENDS rather than replaces, so a second drop adds to the first. Someone assembling an
    /// import from three places should not lose the first two by dragging the third.
    private func read(_ urls: [URL]) {
        // ⚠️ Returns WITHOUT clearing `commitError` — `handleDrop` may have just set it to explain
        // why there is nothing to read, and clearing it here is what kept the failure invisible.
        guard !urls.isEmpty else { return }
        isReading = true
        commitError = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                var combined = SkillIngestOutcome()
                for url in urls {
                    let result = SkillIngest.read(contentsOf: url)
                    combined.skills.append(contentsOf: result.skills)
                    combined.rejected.append(contentsOf: result.rejected)
                }
                return combined
            }.value

            await MainActor.run {
                // Dropping the same folder twice should not queue it twice.
                let known = Set(ready.map(\.name))
                ready.append(contentsOf: outcome.skills.filter { !known.contains($0.name) })
                refused.append(contentsOf: outcome.rejected)
                isReading = false
            }
        }
    }

    // MARK: - Commit

    /// ⚠️ Writes each skill INDEPENDENTLY and stops at the first failure, keeping what already
    /// landed. An all-or-nothing rollback would be tidier to describe and worse to live with: the
    /// common failure here is one oversized skill in a batch of twenty, and discarding nineteen
    /// good imports to stay tidy is not a trade the user would choose.
    private func commit() {
        var handled = 0
        for skill in ready {
            let result: Result<Void, SkillStoreError>
            switch resolution(for: skill) {
            case .skip:
                result = .success(())
            case .createNew:
                result = SkillStore.shared.createSkill(from: skill, origin: .imported).map { _ in () }
            case .addVersion(let skillID):
                // ⚠️ A version is a COMPLETE snapshot, so everything the import read goes in —
                // description, declaration and files. Carrying only the body would blank the routing
                // key and delete every bundled file the skill previously had.
                result = SkillStore.shared.addVersion(
                    toSkillWithID: skillID,
                    description: skill.description,
                    body: skill.body,
                    allowedTools: skill.allowedTools,
                    files: skill.files,
                    note: "Re-imported from \(skill.sourceLabel).",
                    // ⚠️ Declares the name so the store REFUSES a rename. Two skills can share a
                    // name, so a user could point "add version" at a skill this import is not
                    // actually an update of; the store's own check is the backstop.
                    declaredName: skill.name
                ).map { _ in () }
            }

            switch result {
            case .success:
                handled += 1
            case .failure(let error):
                commitError = "Handled \(handled) of \(ready.count). '\(skill.name)' failed: \(error.localizedDescription)"
                ready = Array(ready.dropFirst(handled))
                onImported()
                return
            }
        }
        onImported()
        dismiss()
    }
}

// MARK: - Drop plumbing
