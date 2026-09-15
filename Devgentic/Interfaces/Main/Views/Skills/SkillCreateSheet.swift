// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillCreateSheet.swift
//  Devgentic
//
//  Writing a skill in the app instead of importing one.
//
//  ## Draft is the default, and that is a safety decision rather than a convenience
//
//  A skill is a ROUTING entry: the moment it exists and is linked, its description is rendered into
//  `<available_skills>` and the model starts matching tasks against it. A half-written skill that is
//  already live routes work to instructions that are not finished yet — and the author is the last
//  person to notice, because they are still typing.
//
//  So "Save as draft" is the primary action. `Create` is there for someone who knows the skill is
//  complete, and the difference is one click either way.
//
//  ⚠️ This is also why there is no `create_skill` TOOL. A new skill is a new ROUTING entry, and
//  liveness is decided by `SkillSD.isDraft` plus each profile's `SkillSelection.isEnabled` — neither
//  of which an agent can set. An agent-authored skill would be a routing entry no person reviewed.
//  Creation stays a human act; `update_skill` can only revise a skill someone already marked
//  writable.
//

import SwiftUI
import AppKit

struct SkillCreateSheet: View {

    /// Called after the skill is created, so the library re-reads.
    let onCreated: (SkillSD) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var files: [IngestedFile] = []
    @State private var createError: String?

    // MARK: - Validation

    /// Why the name is not acceptable yet, or nil.
    ///
    /// ⚠️ Runs the SAME `validateSkillNameShape` the importer does, rather than a second regex that
    /// agrees with it today. The charset it enforces — lowercase letters, digits and hyphens — is
    /// what makes `/`, `.` and `..` unrepresentable in a name, and a name reaches a filesystem path
    /// on export. Two copies of that rule is one copy too many.
    private var nameProblem: String? {
        guard !name.isEmpty else { return nil }
        do { try SkillFolderScanner.validateSkillNameShape(name); return nil }
        catch { return error.localizedDescription }
    }

    private var descriptionProblem: String? {
        description.count > SkillLibraryLimits.maxDescriptionChars
            ? "\(description.count) characters — the limit is \(SkillLibraryLimits.maxDescriptionChars)."
            : nil
    }

    private var canCreate: Bool {
        !name.isEmpty && nameProblem == nil
            && !description.isEmpty && descriptionProblem == nil
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var duplicateName: Bool {
        !name.isEmpty && ((try? SkillStore.shared.fetchSkills(named: name).get()) ?? []).isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nameField
                    descriptionField
                    instructionsField
                    filesSection
                    if let createError {
                        Label(createError, systemImage: "exclamationmark.triangle")
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
        .frame(width: 660, height: 640)
        .background(theme.primaryBackground)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Create a skill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.primaryText)
            Text("A skill is a set of instructions an agent loads when a task matches its description.")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(16)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            TextField("weekly-status-report", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .background(theme.textBackground, in: RoundedRectangle(cornerRadius: 6))
            // ⚠️ Says WHY the name cannot change later, at the only moment it is still free.
            Text("Lowercase letters, digits and hyphens. This is how an agent refers to the skill, and it cannot be changed afterwards — every profile that links it resolves against this name.")
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            if let nameProblem {
                Text(nameProblem).font(.system(size: 10)).foregroundStyle(.orange)
            } else if duplicateName {
                Text("Another skill is already called '\(name)'. Both can exist, but an agent addresses skills by name, so only one of them will be reachable.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Description")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Text("\(description.count)/\(SkillLibraryLimits.maxDescriptionChars)")
                    .font(.system(size: 10))
                    .foregroundStyle(descriptionProblem == nil ? theme.secondaryText : .orange)
            }
            // This text is the routing key — worth saying so where it is written.
            Text("The model reads only this when deciding whether to load the skill. Say what it does and when to use it.")
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText.opacity(0.8))
            TextField("Generate weekly status reports from recent work. Use when asked for updates or progress summaries.",
                      text: $description, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(8)
                .background(theme.textBackground, in: RoundedRectangle(cornerRadius: 6))
            if let descriptionProblem {
                Text(descriptionProblem).font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
    }

    private var instructionsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Instructions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Text("Loaded in full only when the skill is used, so length here costs nothing until then.")
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText.opacity(0.8))
            TextEditor(text: $instructions)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(theme.textBackground, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Button {
                    addFiles()
                } label: {
                    Label("Add file", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            Text("Reference documents, templates or scripts the instructions can point to. A file under scripts/ keeps its executable bit.")
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(files, id: \.relativePath) { file in
                HStack(spacing: 6) {
                    Text(file.relativePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.primaryText)
                    if file.isExecutable {
                        Text("exec")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(theme.secondaryText.opacity(0.15), in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Button {
                        files.removeAll { $0.relativePath == file.relativePath }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(theme.secondaryBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { dismiss() }
            // ⚠️ Draft FIRST and unaccented. A skill is a routing entry the moment it is linked, so
            // the safe action is the one that does not put unfinished instructions in front of the
            // model.
            Button("Save as draft") { create(isDraft: true) }
                .disabled(!canCreate)
            Button("Create") { create(isDraft: false) }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose files to bundle with this skill"
        guard panel.runModal() == .OK else { return }

        // Every file the picker handed over that did not make it into the list, with the reason.
        var refused: [String] = []

        for url in panel.urls {
            guard let content = try? Data(contentsOf: url) else {
                refused.append("\(url.lastPathComponent) — it could not be read")
                continue
            }
            // ⚠️ Flat by default. A picker gives no directory context, and inventing one (guessing
            // `scripts/` from a .sh extension, say) would put the file somewhere the author's own
            // instructions do not reference.
            //
            // ⚠️ AND IT IS NOT EDITABLE LATER — the detail sheet renders file paths as static text. An
            // earlier version of this comment promised it was, which is the kind of reassurance that
            // sends someone down a path with no exit. Re-import the skill to change its file layout.
            let relativePath = url.lastPathComponent
            // ⚠️⚠️ BOTH REFUSALS USED TO BE A BARE `continue`. Because the layout is FLAT, picking
            // `docs/README.md` and `examples/README.md` in one pass silently kept one and dropped
            // the other — and the file layout cannot be edited afterwards, so the user had no way
            // to notice or repair it. Say which, and why.
            guard SkillIngest.isSafeRelativePath(relativePath) else {
                refused.append("\(relativePath) — its name is not usable as a file path")
                continue
            }
            guard !files.contains(where: { $0.relativePath == relativePath }) else {
                refused.append("\(relativePath) — a file with that name is already in the list (files are stored flat, so two files cannot share a name)")
                continue
            }
            files.append(IngestedFile(relativePath: relativePath, content: content, isExecutable: false))
        }

        if let over = overBudget() {
            createError = over
        } else if !refused.isEmpty {
            createError = refused.count == 1
                ? "One file was not added: \(refused[0])."
                : "\(refused.count) files were not added:\n" + refused.map { "• \($0)" }.joined(separator: "\n")
        }
    }

    private func overBudget() -> String? {
        let total = files.reduce(0) { $0 + $1.content.count }
        if total > SkillLibraryLimits.maxSkillBytes {
            return "These files total \(total / 1024 / 1024) MB; the limit is \(SkillLibraryLimits.maxSkillBytes / 1024 / 1024) MB."
        }
        if files.count > SkillLibraryLimits.maxFilesPerVersion {
            return "\(files.count) files; the limit is \(SkillLibraryLimits.maxFilesPerVersion)."
        }
        return nil
    }

    private func create(isDraft: Bool) {
        createError = nil
        if let over = overBudget() { createError = over; return }

        let result = SkillStore.shared.create(
            name: name,
            description: description,
            body: instructions,
            files: files,
            origin: .created,
            isDraft: isDraft,
            note: "Created in Devgentic."
        )
        switch result {
        case .failure(let error): createError = error.localizedDescription
        case .success(let skill):
            onCreated(skill)
            dismiss()
        }
    }
}
