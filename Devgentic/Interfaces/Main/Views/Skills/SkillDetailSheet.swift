// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillDetailSheet.swift
//  Devgentic
//
//  Inspect and edit one library skill: its description, its instructions, its history, and export.
//
//  ## Editing creates a VERSION — it never overwrites
//
//  Before V6 this rewrote SKILL.md on disk and kept ONE backup, in a `.history` file keyed by NAME,
//  so two skills sharing a name shared a single revert slot and a second edit destroyed the only
//  copy of the first. Saving here appends an immutable version and moves the skill's `latest`
//  pointer. Nothing that existed before is mutated, so "Restore" is a real operation rather than a
//  single-shot undo — and a profile that PINNED an older version keeps reading exactly that one.
//
//  ⚠️ THE NAME IS STILL NOT EDITABLE, but the reason changed. It is no longer that a renamed skill
//  vanishes on rescan — there is no rescan. It is that `name` is what `load_skill` matches on and
//  what every linked profile resolved against, so a rename silently repoints them. `SkillStore`
//  refuses a version that declares a different name; this sheet does not offer one. `displayName`
//  is free to change and is what the library lists.
//

import SwiftUI
import AppKit

struct SkillDetailSheet: View {

    let skill: SkillSD
    /// Called after any change the library needs to re-read.
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var description: String = ""
    @State private var body_: String = ""
    @State private var changeNote: String = ""
    @State private var saveError: String?
    @State private var showingHistory = false
    @FocusState private var displayNameFocused: Bool
    @State private var confirmingDelete = false
    @State private var displayName: String = ""
    @State private var loadedDisplayName = ""

    /// What `load()` put on screen. `isDirty` is derived from these rather than set by a flag.
    ///
    /// ⚠️ The flag version was wrong the instant the sheet opened: `load()` assigns `description`
    /// and `body_`, which fires the `.onChange` handlers that set `isDirty = true`. Save was
    /// therefore enabled — and it is the default action, so a reflexive Return on a sheet the user
    /// had only looked at created a no-op version.
    @State private var loadedDescription = ""
    @State private var loadedBody = ""

    private var isDirty: Bool { description != loadedDescription || body_ != loadedBody }

    private var versions: [SkillVersionSD] {
        skill.versions.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            editor
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        .background(theme.primaryBackground)
        .onAppear(perform: load)
        // ⚠️ Escape and click-outside run no button action, so without this a rename typed and then
        // dismissed that way is lost. `commitDisplayName` is a no-op when nothing changed.
        .onDisappear(perform: commitDisplayName)
        // Mirrors the library's dialog — same warning, because the consequence is the same and a
        // second wording would be a second thing to keep true.
        .confirmationDialog("Delete '\(skill.displayName)'?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) { deleteSkill() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all \(versions.count) version\(versions.count == 1 ? "" : "s") and every bundled file. Devgentic holds the only copy — there is no folder on disk to restore it from. Export it first if you might want it back.")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // ⚠️ THE LABEL IS EDITABLE; THE NAME BELOW IS NOT. `displayName` is what the library
                // lists and sorts by and means nothing to a run; `name` is what `load_skill` matches
                // and what every linked profile resolved against, so renaming it would silently
                // repoint them. `SkillStore.addVersion` refuses a rename outright — this field
                // exists so there is somewhere to put the urge that does no harm.
                TextField("", text: $displayName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .onSubmit(commitDisplayName)
                    .focused($displayNameFocused)
                    // ⚠️⚠️ THIS WATCHED `skill.id` AND THEREFORE NEVER FIRED. The sheet is built for
                    // ONE skill, so its id cannot change while the field is on screen — the
                    // "commit on focus loss" the comment promised did not exist, and a user who
                    // typed a label and clicked into Description or a toggle silently lost it.
                    // Focus is the thing that actually changes; watch that.
                    .onChange(of: displayNameFocused) { _, focused in
                        if !focused { commitDisplayName() }
                    }
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                    Text("· \(versions.count) version\(versions.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer()
            // ⚠️ The one reader of `origin`, and the reason that accessor still exists: the app
            // records provenance on every insert, so it should be able to tell the user which
            // skills they wrote and which arrived in an archive from somewhere else.
            Text(skill.origin == .created ? "Created here" : "Imported")
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText)
            if skill.isDraft {
                Text("Draft")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                    Text("The model reads this to decide when to use the skill. One line.")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText.opacity(0.8))
                    TextField("", text: $description, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...4)
                        .padding(8)
                        .background(theme.textBackground, in: RoundedRectangle(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Instructions")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                    TextEditor(text: $body_)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 240)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(theme.textBackground, in: RoundedRectangle(cornerRadius: 6))
                }

                if let files = skill.latestVersion?.orderedFiles, !files.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bundled files")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                        ForEach(files, id: \.relativePath) { file in
                            HStack(spacing: 6) {
                                Text(file.relativePath)
                                    .font(.system(size: 11, design: .monospaced))
                                if file.isExecutable {
                                    Text("exec")
                                        .font(.system(size: 9, weight: .medium))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(theme.secondaryText.opacity(0.15), in: Capsule())
                                }
                                Spacer(minLength: 0)
                                Text(byteLabel(file.content.count))
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        // Saving here carries the latest version's files forward unchanged: the
                        // editor edits text. Re-importing and choosing "Add version" replaces the
                        // file set — see `SkillImportPlan`.
                        Text("Files travel with every version. Editing the text above keeps them; re-import the skill to change the file set.")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText.opacity(0.8))
                    }
                    .padding(10)
                    .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 6))
                }

                if isDirty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What changed")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                        TextField("One line — shown in this skill's history", text: $changeNote)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(theme.textBackground, in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                if let declared = skill.latestVersion?.allowedTools {
                    declaredToolsSection(declared)
                }

                permissions

                if showingHistory { history }

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(16)
        }
    }

    /// What the skill's author said it needs — and that Devgentic does not enforce it.
    ///
    /// ⚠️ REINSTATED. This shipped in the pre-V6 sheet and was dropped when the sheet was rewritten
    /// onto versions, which left `SkillToolDeclaration` with no reader at all: the whole
    /// allowed-tools feature was parsed, stored and displayed nowhere.
    ///
    /// ⚠️ The last line is not a disclaimer, it is the point. Showing a restriction the app does not
    /// apply, without saying so, is worse than not showing it — the user reads a containment that
    /// does not exist.
    @ViewBuilder
    private func declaredToolsSection(_ declared: [String]) -> some View {
        let reading = SkillToolDeclaration.classify(
            declared,
            knownToApp: Set(NativeToolCatalog.byName.keys),
            // ⚠️ nil ON PURPOSE. The library is profile-independent, so nothing here can honestly
            // claim a tool is available to a run. Passing the catalogue as if it were a profile's
            // tool set would turn "this app knows this name" into "you have this tool".
            availableHere: nil
        )

        VStack(alignment: .leading, spacing: 6) {
            Text("Declared tools")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)

            if reading?.declaresNone == true {
                Text("This skill declares that it needs no tools (allowed-tools: []).")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }

            ForEach(reading?.entries ?? []) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: entry.status == .foreign ? "questionmark.circle" : "wrench.and.screwdriver")
                        .font(.system(size: 9))
                        .foregroundStyle(entry.status == .foreign ? Color.orange : theme.secondaryText)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        // The author's own text, never a translation of it.
                        Text(entry.declared)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.primaryText)
                        if let hint = entry.hint {
                            Text(hint)
                                .font(.system(size: 10))
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let dropped = reading?.droppedForCount, dropped > 0 {
                Text("\(dropped) more not shown — this skill declares an unusual number of tools.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            Text("Devgentic does not restrict an agent to this list. It is what the skill's author wrote, shown so you can see what the skill expects.")
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 6))
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { skill.isDraft },
                set: { apply(SkillStore.shared.setDraft($0, skillID: skill.id)) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Draft").font(.system(size: 12, weight: .medium))
                    Text("A draft stays in the library but is never offered to an agent, even where it is linked.")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: Binding(
                get: { skill.isAgentWritable },
                set: { apply(SkillStore.shared.setAgentWritable($0, skillID: skill.id)) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow agent edits").font(.system(size: 12, weight: .medium))
                    // States the blast radius, because the approval that permits a write is scoped
                    // to one conversation and the write is not.
                    Text("Lets an agent add versions with the update_skill tool. Every edit still needs your approval, and the new version reaches every profile linked to this skill that has not pinned an older one.")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(10)
        .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 6))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            ForEach(versions, id: \.id) { version in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(version.note.isEmpty ? "(no note)" : version.note)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.primaryText)
                        Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    if version.id == skill.latestVersionID {
                        Text("current")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    } else {
                        Button("Restore") { restore(version) }
                            .font(.system(size: 11))
                    }
                }
                .padding(8)
                .background(theme.secondaryBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Export…") { export() }
                .help("Save this skill as a .zip")
            Button(showingHistory ? "Hide History" : "History") { showingHistory.toggle() }
            Button("Delete…", role: .destructive) { confirmingDelete = true }
            Spacer()
            Button("Close") { commitDisplayName(); dismiss() }
            // Commits the label as well — Save leaves the sheet open, so a user who edited the
            // name and pressed Save would otherwise watch it revert.
            Button("Save") { commitDisplayName(); save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isDirty)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func load() {
        displayName = skill.displayName
        loadedDisplayName = skill.displayName
        let version = skill.latestVersion
        description = version?.skillDescription ?? ""
        body_ = version?.body ?? ""
        loadedDescription = description
        loadedBody = body_
    }

    /// Saving adds a VERSION. The latest version's files are carried forward unchanged — the text
    /// is what this sheet edits, and a version is a COMPLETE snapshot, so omitting them would
    /// silently delete every bundled file on the first description edit.
    private func save() {
        saveError = nil
        let carried = (skill.latestVersion?.orderedFiles ?? []).map {
            IngestedFile(relativePath: $0.relativePath, content: $0.content, isExecutable: $0.isExecutable)
        }
        let result = SkillStore.shared.addVersion(
            toSkillWithID: skill.id,
            description: description,
            body: body_,
            allowedTools: skill.latestVersion?.allowedTools,
            files: carried,
            note: changeNote.isEmpty ? "Edited in the library." : changeNote
        )
        switch result {
        case .failure(let error): saveError = error.localizedDescription
        case .success:
            loadedDescription = description
            loadedBody = body_
            changeNote = ""
            onChanged()
        }
    }

    /// Restoring COPIES an old version forward as a new one rather than moving the pointer back.
    ///
    /// ⚠️ History stays append-only, which is what makes a pin meaningful: a profile pinned to the
    /// version being restored keeps reading exactly that version, and the restore is visible in the
    /// history rather than looking like the last few edits never happened.
    private func restore(_ version: SkillVersionSD) {
        saveError = nil
        let files = version.orderedFiles.map {
            IngestedFile(relativePath: $0.relativePath, content: $0.content, isExecutable: $0.isExecutable)
        }
        let result = SkillStore.shared.addVersion(
            toSkillWithID: skill.id,
            description: version.skillDescription,
            body: version.body,
            allowedTools: version.allowedTools,
            files: files,
            note: "Restored the version from \(version.createdAt.formatted(date: .abbreviated, time: .shortened))."
        )
        switch result {
        case .failure(let error): saveError = error.localizedDescription
        case .success:
            load()
            onChanged()
        }
    }

    /// ⚠️ Saves the LABEL only, and does NOT create a version. A version is a snapshot of what the
    /// model reads; bumping the chain because someone renamed a label would make history unreadable
    /// and make pinning a version pin an unrelated preference.
    private func commitDisplayName() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty label would leave a nameless row in the library, so it falls back to the
        // addressable name rather than being rejected with an error the user has to dismiss.
        let resolved = trimmed.isEmpty ? skill.name : trimmed
        guard resolved != loadedDisplayName else { return }

        switch SkillStore.shared.setDisplayName(resolved, skillID: skill.id) {
        case .failure(let error):
            saveError = error.localizedDescription
            displayName = loadedDisplayName
        case .success:
            displayName = resolved
            loadedDisplayName = resolved
            onChanged()
        }
    }

    private func deleteSkill() {
        switch SkillStore.shared.deleteSkill(id: skill.id) {
        case .failure(let error): saveError = error.localizedDescription
        case .success:
            onChanged()
            dismiss()
        }
    }

    private func apply(_ result: Result<Void, SkillStoreError>) {
        if case .failure(let error) = result { saveError = error.localizedDescription } else { onChanged() }
    }

    /// ⚠️ `NSSavePanel`, not `.fileExporter`. The one `.fileExporter` in this app discards its
    /// result (`{ _ in }`), so every write error vanishes; a panel hands back a URL this code can
    /// actually report on.
    private func export() {
        saveError = nil
        guard let version = skill.latestVersion else {
            saveError = "This skill has no version to export."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(skill.name).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let folder = try SkillMaterializer.write(
                version: version, name: skill.name,
                allowedTools: version.allowedTools, into: staging)
            try SkillPackageExporter.export(skillAt: folder.path, to: destination)
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func byteLabel(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B"
            : bytes < 1024 * 1024 ? "\(bytes / 1024) KB"
            : String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}
