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

private let logger = DGLogger(category: "SkillCreateSheet")

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
            Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identityCard
                    instructionsCard
                    filesCard
                    if let createError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.orange)
                            Text(createError)
                                .font(theme.fontCaption2)
                                .foregroundStyle(Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
                        )
                    }
                }
                .padding(20)
            }
            Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
            footer
        }
        .frame(width: 660, height: 640)
        .background(theme.primaryBackground)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.accentColor.opacity(0.15))
                Image(systemName: "puzzlepiece")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
            }
            .frame(width: 36, height: 36)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.accentColor.opacity(0.3), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Create New Skill")
                    .font(theme.fontTitle3.weight(.bold))
                    .foregroundStyle(theme.primaryText)
                Text("A skill is a set of instructions an agent loads when a task matches its description.")
                    .font(theme.fontCaption2)
                    .foregroundStyle(theme.secondaryText)
                    .lineSpacing(2)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.accentColor)
                Text("IDENTITY & ROUTING")
                    .font(theme.fontCodeCaption.weight(.bold))
                    .foregroundStyle(theme.secondaryText)
                    .tracking(0.6)
            }

            // Name
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Skill Identifier")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text("Fixed after creation")
                        .font(theme.fontCaption2)
                        .foregroundStyle(theme.secondaryText)
                }

                ZStack(alignment: .leading) {
                    if name.isEmpty {
                        Text("e.g. weekly-status-report")
                            .font(theme.fontCode)
                            .foregroundStyle(theme.placeholderText)
                            .padding(.horizontal, 10)
                            .allowsHitTesting(false)
                    }

                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .font(theme.fontCode)
                        .foregroundStyle(theme.primaryText)
                        .padding(10)
                }
                .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(nameProblem != nil || duplicateName ? Color.orange.opacity(0.6) : theme.dividerColor.opacity(0.35), lineWidth: 1)
                )

                Text("Lowercase letters, digits and hyphens. This is how agents invoke the skill, and cannot be changed.")
                    .font(theme.fontCaption2)
                    .foregroundStyle(theme.secondaryText)
                    .lineSpacing(1.5)

                if let nameProblem {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(nameProblem)
                            .font(theme.fontCaption2)
                    }
                    .foregroundStyle(Color.orange)
                } else if duplicateName {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                        Text("Another skill is already called '\(name)'. Only one will be reachable by agents.")
                            .font(theme.fontCaption2)
                    }
                    .foregroundStyle(Color.orange)
                }
            }

            Rectangle().fill(theme.dividerColor.opacity(0.2)).frame(height: 0.5)

            // Description
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Routing Description")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text("\(description.count)/\(SkillLibraryLimits.maxDescriptionChars)")
                        .font(theme.fontCodeCaption)
                        .foregroundStyle(descriptionProblem == nil ? theme.secondaryText : Color.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((descriptionProblem == nil ? theme.secondaryBackground : Color.orange.opacity(0.12)), in: Capsule())
                }

                ZStack(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("e.g. Generates weekly status reports from recent work. Use when asked for updates or progress summaries.")
                            .font(theme.fontFootnote)
                            .foregroundStyle(theme.placeholderText)
                            .lineSpacing(2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }

                    TextField("", text: $description, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(theme.fontFootnote)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(2...4)
                        .padding(10)
                }
                .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(descriptionProblem != nil ? Color.orange.opacity(0.6) : theme.dividerColor.opacity(0.35), lineWidth: 1)
                )

                Text("The model reads only this description when deciding whether to load the skill. Clearly state what it does and when to use it.")
                    .font(theme.fontCaption2)
                    .foregroundStyle(theme.secondaryText)
                    .lineSpacing(1.5)

                if let descriptionProblem {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(descriptionProblem)
                            .font(theme.fontCaption2)
                    }
                    .foregroundStyle(Color.orange)
                }
            }
        }
        .padding(16)
        .background(theme.secondaryBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.3), lineWidth: 0.5)
        )
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.accentColor)
                    Text("INSTRUCTIONS (SKILL.MD)")
                        .font(theme.fontCodeCaption.weight(.bold))
                        .foregroundStyle(theme.secondaryText)
                        .tracking(0.6)
                }

                Spacer()

                let charCount = instructions.count
                let tokenEstimate = Int(Double(charCount) / 3.8)
                Text("\(charCount) chars · ~\(tokenEstimate) tokens")
                    .font(theme.fontCodeCaption)
                    .foregroundStyle(theme.secondaryText)
            }

            ZStack(alignment: .topLeading) {
                if instructions.isEmpty {
                    Text("# Instructions\n\nProvide step-by-step guidance for the agent when this skill is invoked.\n\nExample:\n1. Check git status and recent commit logs.\n2. Summarize key changes and open pull requests.\n3. Return a clean summary report.")
                        .font(theme.fontCode)
                        .foregroundStyle(theme.placeholderText.opacity(0.7))
                        .lineSpacing(2.5)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $instructions)
                    .font(theme.fontCode)
                    .foregroundStyle(theme.primaryText)
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(10)
            }
            .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 1)
            )

            Text("Loaded in full only when the skill is used by an agent, so length here costs nothing until then.")
                .font(theme.fontCaption2)
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(1.5)
        }
        .padding(16)
        .background(theme.secondaryBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.3), lineWidth: 0.5)
        )
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.accentColor)
                    Text("BUNDLED FILES")
                        .font(theme.fontCodeCaption.weight(.bold))
                        .foregroundStyle(theme.secondaryText)
                        .tracking(0.6)

                    if !files.isEmpty {
                        Text("\(files.count)")
                            .font(theme.fontCodeCaption.weight(.bold))
                            .foregroundStyle(theme.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(theme.accentColor.opacity(0.12), in: Capsule())
                    }
                }

                Spacer()

                GlassActionButton(title: "Add Files", icon: "plus", isAccent: false) {
                    addFiles()
                }
            }

            Text("Reference documents, templates, or scripts bundled with the skill. Scripts keep their executable permissions.")
                .font(theme.fontCaption2)
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(1.5)

            if files.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 20))
                            .foregroundStyle(theme.secondaryText.opacity(0.5))
                        Text("No bundled files attached.")
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText.opacity(0.7))
                    }
                    .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(files, id: \.relativePath) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.isExecutable ? "terminal.fill" : "doc.text.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(file.isExecutable ? Color.orange : theme.accentColor)

                            Text(file.relativePath)
                                .font(theme.fontCodeCaption)
                                .foregroundStyle(theme.primaryText)

                            if file.isExecutable {
                                Text("exec")
                                    .font(theme.fontCodeCaption.weight(.medium))
                                    .foregroundStyle(Color.orange)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.orange.opacity(0.12), in: Capsule())
                            }

                            Spacer(minLength: 0)

                            Text(formatFileSize(file.content.count))
                                .font(theme.fontCodeCaption)
                                .foregroundStyle(theme.secondaryText)

                            Button {
                                files.removeAll { $0.relativePath == file.relativePath }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.secondaryText.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Remove file")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(theme.dividerColor.opacity(0.25), lineWidth: 0.5)
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(theme.secondaryBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func formatFileSize(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B"
            : bytes < 1024 * 1024 ? "\(bytes / 1024) KB"
            : String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            TactileButton(title: "Cancel", variant: .subtle, size: .compact) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            // ⚠️ Draft FIRST and unaccented. A skill is a routing entry the moment it is linked, so
            // the safe action is the one that does not put unfinished instructions in front of the
            // model.
            TactileButton(
                title: "Save as Draft",
                icon: "pencil.and.ruler",
                variant: .secondary,
                size: .compact,
                isEnabled: canCreate
            ) {
                create(isDraft: true)
            }

            TactileButton(
                title: "Create Skill",
                icon: "puzzlepiece",
                variant: .primary,
                size: .compact,
                isEnabled: canCreate
            ) {
                create(isDraft: false)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
        case .failure(let error):
            createError = error.localizedDescription
            logger.error("[SKILL_CREATE] Creating '\(name)' FAILED: \(error.localizedDescription). CONSEQUENCE: nothing was written and the sheet keeps the user's text so they can correct it and retry.")
        case .success(let skill):
            logger.notice("[SKILL_CREATE] Created '\(skill.name)' [skill \(skill.id)] version \(skill.latestVersionID ?? "?"): \(files.count) bundled file(s), draft=\(isDraft). CONSEQUENCE: \(isDraft ? "it is a DRAFT — it is NOT offered to any agent and cannot be linked until draft is turned off" : "it can now be linked to a profile; it is not linked to anything yet, so no agent sees it until you link it").")
            onCreated(skill)
            dismiss()
        }
    }
}
