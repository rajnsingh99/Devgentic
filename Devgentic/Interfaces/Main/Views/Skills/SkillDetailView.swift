// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillDetailView.swift
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

private let logger = DGLogger(category: "SkillDetailSheet")

struct SkillDetailView: View {

    let skill: SkillSD

    /// Called after any change the library needs to re-read.
    /// ⚠️ Optional now that this is a screen rather than a sheet. The library and the sidebar both
    /// observe `SkillStore.shared.revision`, so a write here already invalidates them; the closure
    /// survives for the one caller that wants an extra local bump.
    var onChanged: () -> Void = {}

    init(skill: SkillSD, onChanged: @escaping () -> Void = {}) {
        self.skill = skill
        self.onChanged = onChanged
        // ⚠️ Resolved here rather than in `load()`: `@Bindable` needs the object at init, and the
        // store seeds from the library only on FIRST use, so re-entering a skill returns whatever
        // the user typed last time rather than overwriting it.
        self.draft = SkillDraftStore.shared.draft(for: skill)
    }

    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    /// ⚠️⚠️ THE EDITED TEXT LIVES IN `SkillDraftStore`, NOT IN `@State`, AND THAT IS THE WHOLE
    /// UNSAVED-WORK DESIGN. Inline, a skill detail can be left seven ways — the Skills sidebar,
    /// a library row, the back chevron, ⌘[, the command palette, an ActivityBar tab switch, and quit —
    /// and the tab switch has no seam to intercept.
    ///
    /// Holding the draft outside the view makes every one of those exits lossless: leave, come back,
    /// the text is still there. That is exactly how profiles work — `editBuffer` lives on the
    /// service and nothing clears it on a tab switch — and it is what lets the only prompt live at
    /// quit, where memory genuinely goes away.
    @Bindable private var draft: SkillDraft
    @State private var saveError: String?
    @FocusState private var displayNameFocused: Bool
    @State private var confirmingDelete = false
    @State private var displayName: String = ""
    @State private var loadedDisplayName = ""
    @State private var copiedIdentifier = false
    @State private var copiedBody = false
    @State private var isIdentifierHovered = false
    @State private var isPreviewMode = false

    /// Whether instructions can be previewed as markdown (non-empty content).
    private var isPreviewEnabled: Bool {
        !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Name is dirty if the trimmed, resolved label differs from what was loaded or committed.
    private var isNameDirty: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? skill.name : trimmed
        return resolved != loadedDisplayName
    }

    /// What `load()` put on screen. `isDirty` is derived from draft edits or label changes.
    private var isDirty: Bool { draft.isDirty || isNameDirty }

    private var versions: [SkillVersionSD] {
        skill.versions.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar(
                title: displayName.isEmpty ? skill.name : displayName,
                icon: "puzzlepiece",
                onBack: handleBackTap
            ) {
                trailingActions
            }

            if let saveError {
                saveErrorBanner(saveError)
            }

            ScrollView {
                VStack(spacing: 24) {
                    permissionsCard
                    overviewCard
                    instructionsCard
                    if let declared = skill.latestVersion?.allowedTools {
                        declaredToolsCard(declared)
                    }
                    if let files = skill.latestVersion?.orderedFiles, !files.isEmpty {
                        bundledFilesCard(files)
                    }
                    versionHistoryCard
                }
                .padding(.horizontal, ViewLayout.containerPadding)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: ViewLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .onAppear(perform: load)
        .onChange(of: skill.id) { _, _ in
            isPreviewMode = false
        }
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

    // MARK: - Dynamic Island Trailing Actions

    private var trailingActions: some View {
        HStack(spacing: 8) {
            if isDirty {
                Text("Unsaved")
                    .font(theme.fontCaption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(.orange.opacity(0.3), lineWidth: 0.5))

                IslandPillButton(
                    title: "Revert",
                    style: .secondary,
                    accessibilityLabel: "Revert unsaved changes"
                ) {
                    revert()
                }
            }

            IslandPillButton(
                title: "Save",
                style: .primary,
                help: isDirty ? "Save changes (⌘S)" : "No unsaved changes",
                accessibilityLabel: "Save skill changes",
                keyboardShortcut: KeyboardShortcut("s", modifiers: .command)
            ) {
                handleSave()
            }
            .disabled(!isDirty)

            Menu {
                Button {
                    export()
                } label: {
                    Label("Export as ZIP", systemImage: "arrow.up.forward.app")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(skill.name, forType: .string)
                    withAnimation { copiedIdentifier = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { copiedIdentifier = false }
                    }
                } label: {
                    Label("Copy Identifier", systemImage: "doc.on.doc")
                }

                Divider()

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete Skill", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .islandCircleAffordance()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More skill actions")
        }
    }

    // MARK: - Error Banner

    private func saveErrorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(theme.errorColor)
            Text(error)
                .font(theme.fontCaption)
                .foregroundColor(theme.errorColor)
            Spacer()
            Button {
                saveError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.errorColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.errorColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.errorColor.opacity(0.3), lineWidth: 0.5)
        )
        .padding(.horizontal, ViewLayout.containerPadding)
        .padding(.top, 8)
        .frame(maxWidth: ViewLayout.maxContentWidth)
    }

    // MARK: - Cards

    private var overviewCard: some View {
        SettingsCard(title: "Overview", icon: "puzzlepiece", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                // Display Name
                VStack(alignment: .leading, spacing: 6) {
                    Text("DISPLAY NAME")
                        .font(theme.fontCodeCaption.weight(.bold))
                        .foregroundStyle(theme.secondaryText)
                        .tracking(0.6)

                    TextField("", text: $displayName, prompt: Text("Skill Display Name").foregroundColor(theme.placeholderText))
                        .font(theme.fontTitle3.weight(.bold))
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.textBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(displayNameFocused ? theme.accentColor : theme.dividerColor.opacity(0.4), lineWidth: displayNameFocused ? 1.5 : 0.5)
                                )
                        )
                        .onSubmit(commitDisplayName)
                        .focused($displayNameFocused)
                        .onChange(of: displayNameFocused) { _, focused in
                            if !focused { commitDisplayName() }
                        }
                }

                // Metadata chips row
                HStack(spacing: 8) {
                    // Unique identifier chip (tap to copy)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(skill.name, forType: .string)
                        withAnimation { copiedIdentifier = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { copiedIdentifier = false }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: copiedIdentifier ? "checkmark" : "doc.on.doc")
                                .font(theme.fontCaption2.weight(.medium))
                                .foregroundStyle(copiedIdentifier ? .green : theme.accentColor)
                            Text(skill.name)
                                .font(theme.fontCodeCaption)
                                .foregroundStyle(theme.primaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isIdentifierHovered ? theme.surfaceOverlay : theme.surfaceOverlay.opacity(0.6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isIdentifierHovered ? theme.accentColor.opacity(0.5) : theme.dividerColor.opacity(0.4), lineWidth: 0.5)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { isIdentifierHovered = $0 }
                    .help("Copy skill identifier '\(skill.name)'")

                    // Version count
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                        Text("\(versions.count) version\(versions.count == 1 ? "" : "s")")
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.surfaceOverlay.opacity(0.4))
                    )

                    // Origin
                    HStack(spacing: 4) {
                        Image(systemName: skill.origin == .created ? "pencil" : "arrow.down.doc")
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                        Text(skill.origin == .created ? "Created here" : "Imported")
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.surfaceOverlay.opacity(0.4))
                    )

                    if skill.isDraft {
                        Text("Draft")
                            .font(theme.fontCaption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }

                    Spacer(minLength: 0)
                }

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.35))
                    .frame(height: 0.5)

                // Description section
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DESCRIPTION")
                                .font(theme.fontCodeCaption.weight(.bold))
                                .foregroundStyle(theme.secondaryText)
                                .tracking(0.6)
                            Text("The model reads this to decide when to use the skill. Keep it clear and concise.")
                                .font(theme.fontCaption2)
                                .foregroundStyle(theme.secondaryText.opacity(0.8))
                        }
                        Spacer()
                        Text("\(draft.description.count) chars")
                            .font(theme.fontCodeCaption)
                            .foregroundStyle(theme.secondaryText.opacity(0.8))
                    }

                    ZStack(alignment: .topLeading) {
                        if draft.description.isEmpty {
                            Text("e.g. Generates weekly status reports from recent work. Use when asked for updates or progress summaries.")
                                .font(theme.fontFootnote)
                                .foregroundStyle(theme.placeholderText)
                                .lineSpacing(2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }

                        TextField("", text: $draft.description, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(theme.fontFootnote)
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(2...4)
                            .padding(10)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.textBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.dividerColor.opacity(0.4), lineWidth: 0.5)
                            )
                    )
                }
            }
            .padding(16)
        }
    }

    private var instructionsCard: some View {
        SettingsCard(title: "Instructions", icon: "doc.text", theme: theme) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SKILL.MD PROMPT BODY")
                            .font(theme.fontCodeCaption.weight(.bold))
                            .foregroundStyle(theme.secondaryText)
                            .tracking(0.6)
                        Text("Detailed instructions provided to the agent when this skill is active.")
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText.opacity(0.8))
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Text("\(draft.body.count) chars · ~\(max(1, draft.body.count / 4)) tokens")
                            .font(theme.fontCodeCaption)
                            .foregroundStyle(theme.secondaryText.opacity(0.8))

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isPreviewMode.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isPreviewMode ? "pencil" : "eye")
                                    .font(theme.fontCaption2)
                                Text(isPreviewMode ? "Edit" : "Preview")
                                    .font(theme.fontCaption2.weight(.medium))
                            }
                            .foregroundStyle(
                                isPreviewEnabled
                                    ? (isPreviewMode ? theme.accentColor : theme.primaryText)
                                    : theme.secondaryText.opacity(0.4)
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isPreviewMode ? theme.accentColor.opacity(0.12) : theme.surfaceOverlay)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isPreviewMode ? theme.accentColor.opacity(0.3) : Color.clear, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!isPreviewEnabled)
                        .help(isPreviewMode ? "Switch to edit mode" : "Preview rendered markdown")
                        .accessibilityIdentifier("skills.instructions.preview")

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(draft.body, forType: .string)
                            withAnimation { copiedBody = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation { copiedBody = false }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copiedBody ? "checkmark" : "doc.on.doc")
                                    .font(theme.fontCaption2)
                                Text(copiedBody ? "Copied" : "Copy")
                                    .font(theme.fontCaption2.weight(.medium))
                            }
                            .foregroundStyle(copiedBody ? .green : theme.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.surfaceOverlay)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Copy instructions to clipboard")
                        .accessibilityIdentifier("skills.instructions.copy")
                    }
                }

                ZStack(alignment: .topLeading) {
                    if isPreviewMode {
                        WorkflowMarkdownView(text: draft.body)
                            .frame(maxWidth: .infinity, minHeight: 340, alignment: .topLeading)
                            .padding(14)
                    } else {
                        if draft.body.isEmpty {
                            Text("# Instructions\n\nProvide step-by-step guidance for the agent when this skill is active.")
                                .font(theme.fontCode)
                                .foregroundStyle(theme.placeholderText.opacity(0.7))
                                .lineSpacing(2.5)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $draft.body)
                            .font(theme.fontCode)
                            .foregroundStyle(theme.primaryText)
                            .frame(minHeight: 340)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.textBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.dividerColor.opacity(0.4), lineWidth: 0.5)
                        )
                )
                .onChange(of: draft.body) { _, newBody in
                    if newBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isPreviewMode {
                        isPreviewMode = false
                    }
                }

                if draft.isDirty {
                    Rectangle()
                        .fill(theme.dividerColor.opacity(0.35))
                        .frame(height: 0.5)

                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CHANGE NOTE")
                                .font(theme.fontCodeCaption.weight(.bold))
                                .foregroundStyle(theme.secondaryText)
                                .tracking(0.6)
                            Text("Describe what changed. This note will appear in the skill's version history.")
                                .font(theme.fontCaption2)
                                .foregroundStyle(theme.secondaryText.opacity(0.8))
                        }

                        TextField("", text: $draft.changeNote, prompt: Text("e.g. Improved error recovery instructions").foregroundColor(theme.placeholderText))
                            .textFieldStyle(.plain)
                            .font(theme.fontFootnote)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.textBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(theme.dividerColor.opacity(0.4), lineWidth: 0.5)
                                    )
                            )
                    }
                }
            }
            .padding(16)
        }
    }

    private func declaredToolsCard(_ declared: [String]) -> some View {
        let reading = SkillToolDeclaration.classify(
            declared,
            knownToApp: Set(NativeToolCatalog.byName.keys),
            // ⚠️ nil ON PURPOSE. The library is profile-independent, so nothing here can honestly
            // claim a tool is available to a run. Passing the catalogue as if it were a profile's
            // tool set would turn "this app knows this name" into "you have this tool".
            availableHere: nil
        )

        return SettingsCard(title: "Declared Tools", icon: "wrench.and.screwdriver", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                if reading?.declaresNone == true {
                    HStack(spacing: 8) {
                        Image(systemName: "slash.circle")
                            .font(theme.fontBody)
                            .foregroundStyle(theme.secondaryText)
                        Text("This skill explicitly declares that it needs no tools (allowed-tools: []).")
                            .font(theme.fontSubheadline)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(reading?.entries ?? []) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: entry.status == .foreign ? "questionmark.circle.fill" : "wrench.and.screwdriver.fill")
                                    .font(theme.fontCaption)
                                    .foregroundStyle(entry.status == .foreign ? Color.orange : theme.accentColor)
                                    .frame(width: 16, height: 16)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(entry.declared)
                                            .font(theme.fontCode)
                                            .foregroundStyle(theme.primaryText)

                                        Text(entry.status == .foreign ? "External" : "Native")
                                            .font(theme.fontCodeCaption.weight(.semibold))
                                            .foregroundStyle(entry.status == .foreign ? Color.orange : theme.accentColor)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                (entry.status == .foreign ? Color.orange : theme.accentColor).opacity(0.12),
                                                in: Capsule()
                                            )
                                    }

                                    if let hint = entry.hint {
                                        Text(hint)
                                            .font(theme.fontCaption2)
                                            .foregroundStyle(theme.secondaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.surfaceOverlay.opacity(0.4))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(theme.dividerColor.opacity(0.2), lineWidth: 0.5)
                                    )
                            )
                        }
                    }

                    if let dropped = reading?.droppedForCount, dropped > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(theme.fontCaption2)
                            Text("\(dropped) more not shown — this skill declares an unusual number of tools.")
                                .font(theme.fontCaption2)
                        }
                        .foregroundStyle(.orange)
                    }
                }

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.35))
                    .frame(height: 0.5)

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(theme.fontCaption2)
                        .foregroundStyle(theme.secondaryText.opacity(0.8))
                    Text("Devgentic does not restrict an agent to this list. It reflects what the author declared so you can verify expectations.")
                        .font(theme.fontCaption2)
                        .foregroundStyle(theme.secondaryText.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    private func bundledFilesCard(_ files: [SkillFileSD]) -> some View {
        SettingsCard(title: "Bundled Files", icon: "folder", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 6) {
                    ForEach(files, id: \.relativePath) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.isExecutable ? "terminal" : "doc.text")
                                .font(theme.fontCaption)
                                .foregroundStyle(file.isExecutable ? theme.accentColor : theme.secondaryText)
                                .frame(width: 16)

                            Text(file.relativePath)
                                .font(theme.fontCode)
                                .foregroundStyle(theme.primaryText)

                            if file.isExecutable {
                                Text("exec")
                                    .font(theme.fontCodeCaption.weight(.bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(theme.accentColor.opacity(0.15), in: Capsule())
                                    .foregroundStyle(theme.accentColor)
                            }

                            Spacer(minLength: 0)

                            Text(byteLabel(file.content.count))
                                .font(theme.fontCodeCaption)
                                .foregroundStyle(theme.secondaryText)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.surfaceOverlay.opacity(0.3))
                        )
                    }
                }

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.35))
                    .frame(height: 0.5)

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(theme.fontCaption2)
                        .foregroundStyle(theme.secondaryText.opacity(0.8))
                    Text("Bundled files are included with every version snapshot. Editing text retains them; re-import the skill package to modify the file set.")
                        .font(theme.fontCaption2)
                        .foregroundStyle(theme.secondaryText.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    private var permissionsCard: some View {
        SettingsCard(title: "Permissions & Deployment", icon: "lock.shield", theme: theme) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "Draft Mode",
                    description: "A draft stays in the library but is never offered to an agent, even where it is linked.",
                    theme: theme
                ) {
                    Toggle("", isOn: Binding(
                        get: { skill.isDraft },
                        set: { apply(SkillStore.shared.setDraft($0, skillID: skill.id), "DRAFT state") }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                }

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.35))
                    .frame(height: 0.5)

                SettingsRow(
                    title: "Allow Agent Edits",
                    description: "Lets an agent add versions with the update_skill tool. Every edit still needs your approval, and new versions reach any profile linking this skill that hasn't pinned an older version.",
                    theme: theme
                ) {
                    Toggle("", isOn: Binding(
                        get: { skill.isAgentWritable },
                        set: { apply(SkillStore.shared.setAgentWritable($0, skillID: skill.id), "the AGENT-WRITABLE permission") }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        }
    }

    private var versionHistoryCard: some View {
        SettingsCard(title: "Version History", icon: "clock.arrow.circlepath", theme: theme) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(versions, id: \.id) { version in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(version.note.isEmpty ? "Edited in the library" : version.note)
                                    .font(theme.fontSubheadline.weight(.medium))
                                    .foregroundStyle(theme.primaryText)

                                if version.id == skill.latestVersionID {
                                    Text("Current")
                                        .font(theme.fontCodeCaption.weight(.bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.green.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.green)
                                }
                            }

                            Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(theme.fontCaption2)
                                .foregroundStyle(theme.secondaryText)
                        }

                        Spacer(minLength: 0)

                        if version.id != skill.latestVersionID {
                            Button("Restore") {
                                restore(version)
                            }
                            .buttonStyle(.plain)
                            .font(theme.fontCaption.weight(.semibold))
                            .foregroundStyle(theme.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.accentColor.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(theme.accentColor.opacity(0.3), lineWidth: 0.5)
                                    )
                            )
                            .help("Copy this snapshot forward as a new current version")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(version.id == skill.latestVersionID ? theme.surfaceOverlay.opacity(0.5) : theme.surfaceOverlay.opacity(0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(version.id == skill.latestVersionID ? theme.accentColor.opacity(0.25) : theme.dividerColor.opacity(0.2), lineWidth: 0.5)
                            )
                    )
                }
            }
            .padding(16)
        }
    }

    // MARK: - Navigation

    /// Leaves the detail for the library or goes back in router stack.
    private func handleBackTap() {
        commitDisplayName()
        if router.canGoBack {
            withAnimation(.easeInOut(duration: 0.2)) {
                router.goBack()
            }
        } else {
            backToLibrary()
        }
    }

    /// Leaves the detail for the library explicitly.
    private func backToLibrary() {
        router.navigate(to: .skillLibrary(profileID: nil))
    }

    // MARK: - Actions

    /// ⚠️ Loads only the DISPLAY NAME. The description and instructions live in the draft, which is
    /// seeded from the library on first use and then belongs to the user — reloading them here would
    /// overwrite unsaved work every time the view re-appeared, which is the data loss this design
    /// removes.
    private func load() {
        displayName = skill.displayName
        loadedDisplayName = skill.displayName
    }

    /// Discards all unsaved edits to both the display name and the draft body/description.
    private func revert() {
        displayName = loadedDisplayName
        draft.discard()
    }

    /// Saves pending display name changes and appends a version if the instructions or description changed.
    private func handleSave() {
        commitDisplayName()
        if draft.isDirty {
            save()
        }
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
            description: draft.description,
            body: draft.body,
            allowedTools: skill.latestVersion?.allowedTools,
            files: carried,
            note: draft.changeNote.isEmpty ? "Edited in the library." : draft.changeNote
        )
        switch result {
        case .failure(let error):
            saveError = error.localizedDescription
            logger.error("[SKILL_EDIT] SAVE FAILED for '\(skill.name)' [skill \(skill.id)]: \(error.localizedDescription). CONSEQUENCE: nothing was written, the previous version is still current, and the sheet still holds the user's unsaved text — dismissing now loses it.")
        case .success(let version):
            logger.notice("[SKILL_EDIT] SAVED '\(skill.name)' [skill \(skill.id)] as version \(version.id) (descriptionChanged=\(draft.description != draft.loadedDescription) bodyChanged=\(draft.body != draft.loadedBody) carriedFiles=\(carried.count)). CONSEQUENCE: this becomes what every linked profile loads, except one pinning an older version; the previous version is kept and restorable.")
            draft.markSaved()
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
        case .failure(let error):
            saveError = error.localizedDescription
            logger.error("[SKILL_EDIT] RESTORE FAILED for '\(skill.name)' [skill \(skill.id)] from version \(version.id): \(error.localizedDescription). CONSEQUENCE: nothing was written and the current version is unchanged.")
        case .success(let created):
            logger.notice("[SKILL_EDIT] RESTORED '\(skill.name)' [skill \(skill.id)]: copied version \(version.id) FORWARD as \(created.id) with \(files.count) file(s). CONSEQUENCE: history stays append-only — a profile pinned to \(version.id) still reads that exact version, and the restore is visible in the history rather than looking like the later edits never happened.")
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
        let name = skill.name, id = skill.id, versionCount = skill.versions.count
        switch SkillStore.shared.deleteSkill(id: id) {
        case .failure(let error):
            saveError = error.localizedDescription
            logger.error("[SKILL_EDIT] DELETE FAILED for '\(name)' [skill \(id)]: \(error.localizedDescription). CONSEQUENCE: the skill is still there and still linked; nothing was lost.")
        case .success:
            // ⚠️ Drop the draft too. A draft outliving its skill would resurrect the deleted
            // skill's text if an id were ever reused, and would keep quit gated on work for a
            // skill that no longer exists.
            SkillDraftStore.shared.forget(skillID: id)
            logger.notice("[SKILL_EDIT] DELETED '\(name)' [skill \(id)] and its \(versionCount) version(s). CONSEQUENCE: PERMANENT — every version and bundled file went with it, and any profile still linking it now reports an unresolved skill at run time.")
            onChanged()
            backToLibrary()
        }
    }

    private func apply(_ result: Result<Void, SkillStoreError>, _ what: String = "a library flag") {
        if case .failure(let error) = result {
            saveError = error.localizedDescription
            logger.error("[SKILL_EDIT] Changing \(what) on '\(skill.name)' [skill \(skill.id)] FAILED: \(error.localizedDescription). CONSEQUENCE: the previous value still stands — the toggle in the sheet may now disagree with the library until it is reopened.")
        } else {
            logger.notice("[SKILL_EDIT] Changed \(what) on '\(skill.name)' [skill \(skill.id)]. CONSEQUENCE: this is library state, not content, so it does NOT create a version and does not change what any pinned profile reads.")
            onChanged()
        }
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
            logger.notice("[SKILL_EXPORT] Exported '\(skill.name)' [skill \(skill.id)] version \(version.id) (\(version.files.count) bundled file(s)) to \(destination.lastPathComponent). CONSEQUENCE: the archive holds a rebuilt SKILL.md plus every bundled file — re-importing it produces the same skill, which is the property that keeps the library from being a one-way door.")
        } catch {
            saveError = error.localizedDescription
            logger.error("[SKILL_EXPORT] Export of '\(skill.name)' [skill \(skill.id)] version \(version.id) FAILED: \(error.localizedDescription). CONSEQUENCE: nothing was written to the destination the user chose, and the staging directory is discarded — the library is unchanged and the export can be retried.")
        }
    }

    private func byteLabel(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B"
            : bytes < 1024 * 1024 ? "\(bytes / 1024) KB"
            : String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}
