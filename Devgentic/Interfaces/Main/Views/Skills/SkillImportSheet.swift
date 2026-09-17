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

private let logger = DGLogger(category: "SkillImportSheet")

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

    // MARK: - Log text
    //
    // ⚠️ Rendering only. These exist so the log can name a decision in the same words the sheet
    // uses, WITHOUT putting a logger inside `SkillImportPlan` — whose functions run in the view body.

    private static func describe(_ collision: SkillImportPlan.Collision) -> String {
        switch collision {
        case .none: return "no name collision"
        case .one(let skillID, let displayName, let versionCount):
            return "collides with '\(displayName)' [skill \(skillID)], \(versionCount) existing version(s)"
        case .several(let count): return "collides with \(count) existing skills of that name"
        }
    }

    private static func describe(_ resolution: SkillImportResolution) -> String {
        switch resolution {
        case .createNew: return "IMPORT AS NEW"
        case .addVersion(let skillID): return "ADD VERSION to [skill \(skillID)]"
        case .skip: return "SKIP"
        }
    }

    private static func consequence(of resolution: SkillImportResolution) -> String {
        switch resolution {
        case .createNew:
            return "a new library entry that is linked to no profile — no agent sees it until it is linked."
        case .addVersion:
            return "this reaches EVERY profile already linked to that skill that does not pin an older version, as soon as Import is pressed."
        case .skip:
            return "nothing is written for this one unless the user changes the choice."
        }
    }

    /// ⚠️ Only an OVERRIDE is logged, never the default being re-selected. The default is already in
    /// the QUEUED line; what is worth recording is the user DISAGREEING with it, because that is the
    /// decision nothing else in the system can reconstruct afterwards.
    private static func logOverride(_ name: String, from current: SkillImportResolution, to chosen: SkillImportResolution) {
        guard current != chosen else { return }
        logger.notice("[SKILL_IMPORT] The user changed '\(name)' from \(describe(current)) to \(describe(chosen)). CONSEQUENCE: \(consequence(of: chosen))")
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
            Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    dropZone
                    hints
                    if !ready.isEmpty { readyList }
                    if !refused.isEmpty { refusedList }
                    if let commitError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.orange)
                            Text(commitError)
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
        .frame(width: 640, height: 600)
        .background(theme.primaryBackground)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.accentColor.opacity(0.15))
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
            }
            .frame(width: 36, height: 36)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.accentColor.opacity(0.3), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Add Skills")
                    .font(theme.fontTitle3.weight(.bold))
                    .foregroundStyle(theme.primaryText)
                Text("Skills are copied into Devgentic. The originals are left exactly where they are.")
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

    private var dropZone: some View {
        VStack(spacing: 10) {
            if isReading {
                ProgressView().controlSize(.small)
                Text("Scanning skill files…")
                    .font(theme.fontFootnote.weight(.medium))
                    .foregroundStyle(theme.secondaryText)
            } else {
                ZStack {
                    Circle()
                        .fill((isTargeted ? theme.accentColor : theme.secondaryText).opacity(0.1))
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isTargeted ? theme.accentColor : theme.secondaryText)
                }
                .frame(width: 44, height: 44)
                .overlay(
                    Circle().strokeBorder((isTargeted ? theme.accentColor : theme.dividerColor).opacity(0.3), lineWidth: 0.5)
                )

                VStack(spacing: 3) {
                    Text("Drag skill folders or archives here")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Text("Drop multiple items at once to scan and stage before importing")
                        .font(theme.fontCaption2)
                        .foregroundStyle(theme.secondaryText)
                }

                TactileButton(title: "Browse Files", icon: "folder", variant: .secondary, size: .compact) {
                    browse()
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isTargeted ? theme.accentColor.opacity(0.08) : theme.secondaryBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isTargeted ? theme.accentColor : theme.dividerColor.opacity(0.4),
                    style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 1, dash: [5])
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { browse() }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .animation(.easeInOut(duration: 0.2), value: isTargeted)
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SUPPORTED FORMATS")
                .font(theme.fontCodeCaption.weight(.bold))
                .foregroundStyle(theme.secondaryText)
                .tracking(0.6)

            VStack(alignment: .leading, spacing: 6) {
                formatBullet(icon: "folder.badge.gearshape", title: "Skill folder", desc: "Containing SKILL.md — or a parent folder containing multiple skills")
                formatBullet(icon: "archivebox", title: "Archive file", desc: "A .zip or .skill archive containing SKILL.md and bundled assets")
                formatBullet(icon: "doc.text", title: "Markdown file", desc: "Single .md whose YAML frontmatter defines name and description")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.secondaryBackground.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.25), lineWidth: 0.5)
        )
    }

    private func formatBullet(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.accentColor)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)

            HStack(spacing: 4) {
                Text(title)
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text("— \(desc)")
                    .font(theme.fontCaption2)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var readyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("READY TO IMPORT")
                    .font(theme.fontCodeCaption.weight(.bold))
                    .foregroundStyle(theme.secondaryText)
                    .tracking(0.6)
                Text("\(ready.count)")
                    .font(theme.fontCodeCaption.weight(.bold))
                    .foregroundStyle(theme.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(theme.accentColor.opacity(0.12), in: Capsule())
            }

            ForEach(ready, id: \.name) { skill in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.accentColor.opacity(0.12))
                            Image(systemName: "puzzlepiece")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.accentColor)
                        }
                        .frame(width: 24, height: 24)

                        Text(skill.name)
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundStyle(theme.primaryText)

                        Spacer(minLength: 0)

                        Text(summary(for: skill))
                            .font(theme.fontCodeCaption)
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.secondaryBackground, in: Capsule())
                            .overlay(Capsule().stroke(theme.dividerColor.opacity(0.3), lineWidth: 0.5))
                    }

                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(2)
                            .lineSpacing(1.5)
                    }

                    if let explanation = SkillImportPlan.explanation(for: collision(for: skill), skillName: skill.name) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.orange)
                            Text(explanation)
                                .font(theme.fontCaption2)
                                .foregroundStyle(Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(6)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                        resolutionPicker(for: skill)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.secondaryBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.dividerColor.opacity(0.3), lineWidth: 0.5)
                )
            }
        }
    }

    /// ⚠️ Refusals are SHOWN, not counted. "3 skipped" is a number the user cannot act on; the
    /// folder name plus the reason is. Silently dropping them is how the old importer made a
    /// repository look like it contained fewer skills than it did.
    private var refusedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("SKIPPED / REFUSED")
                    .font(theme.fontCodeCaption.weight(.bold))
                    .foregroundStyle(theme.secondaryText)
                    .tracking(0.6)
                Text("\(refused.count)")
                    .font(theme.fontCodeCaption.weight(.bold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }

            ForEach(Array(refused.enumerated()), id: \.offset) { _, rejection in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.orange)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(rejection.label)
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                        Text(rejection.reason)
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.secondaryBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
                )
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
                    Self.logOverride(skill.name, from: current, to: .addVersion(skillID: skillID))
                    resolutions[skill.name] = .addVersion(skillID: skillID)
                }
            }
            resolutionButton("Import as new", isOn: current == .createNew) {
                Self.logOverride(skill.name, from: current, to: .createNew)
                resolutions[skill.name] = .createNew
            }
            resolutionButton("Skip", isOn: current == .skip) {
                Self.logOverride(skill.name, from: current, to: .skip)
                resolutions[skill.name] = .skip
            }
        }
    }

    private func resolutionButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.fontCodeCaption.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 3.5)
                .background(isOn ? theme.accentColor.opacity(0.18) : theme.secondaryBackground,
                            in: Capsule())
                .overlay(
                    Capsule().strokeBorder(isOn ? theme.accentColor.opacity(0.4) : theme.dividerColor.opacity(0.3), lineWidth: 0.5)
                )
                .foregroundStyle(isOn ? theme.accentColor : theme.secondaryText)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !ready.isEmpty || !refused.isEmpty {
                TactileButton(title: "Clear", icon: "trash", variant: .subtle, size: .compact) {
                    ready = []
                    refused = []
                    resolutions = [:]
                    commitError = nil
                }
            }

            Spacer()

            TactileButton(title: "Cancel", variant: .subtle, size: .compact) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            // ⚠️ PRIMARY ACTION: Hidden when ready is empty (user requested).
            // Only shown when files are actually staged and actionLabel is an active action.
            if !ready.isEmpty && actionLabel != "Nothing to do" {
                TactileButton(
                    title: actionLabel,
                    icon: "arrow.down.doc",
                    variant: .primary,
                    size: .compact,
                    isLoading: isReading
                ) {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
                logger.error("[SKILL_IMPORT] DROP resolved \(urls.count) of \(providers.count) item(s); \(unreadable) could not be read as a file URL. CONSEQUENCE: only the resolved ones are scanned and the user is shown why — an item that yields no file URL is usually dragged from a browser or a non-file source rather than Finder.")
            } else {
                logger.notice("[SKILL_IMPORT] DROP resolved \(urls.count) item(s) for scanning.")
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
                let fresh = outcome.skills.filter { !known.contains($0.name) }
                let duplicates = outcome.skills.count - fresh.count
                ready.append(contentsOf: fresh)
                refused.append(contentsOf: outcome.rejected)
                isReading = false

                logger.notice("[SKILL_IMPORT] SCANNED \(urls.count) location(s): \(outcome.skills.count) skill(s) read, \(fresh.count) queued, \(duplicates) already queued by an earlier drop, \(outcome.rejected.count) refused. CONSEQUENCE: only the queued ones are written when Import is pressed; the refused ones are listed in the sheet with their reasons and are NOT stored.")
                for rejection in outcome.rejected {
                    logger.error("[SKILL_IMPORT] REFUSED '\(rejection.label)': \(rejection.reason) CONSEQUENCE: this one is not imported — the rest of the batch is unaffected.")
                }
                // ⚠️ THE COLLISION AND ITS DEFAULT ARE LOGGED HERE, NOT INSIDE `SkillImportPlan`.
                // Those are pure functions called from `resolution(for:)` and directly from a
                // ViewBuilder, so a `logger` inside them would fire on every SwiftUI re-render —
                // every keystroke and hover — and bury the one line that matters. Scan completion is
                // where the decision is made once.
                for skill in fresh {
                    let collision = SkillImportPlan.collision(for: skill.name, existing: librarySummary)
                    let planned = SkillImportPlan.defaultResolution(for: collision)
                    logger.notice("[SKILL_IMPORT] QUEUED '\(skill.name)' from '\(skill.sourceLabel)': \(skill.files.count) file(s), \(skill.totalBytes) byte(s), declaredTools=\(skill.allowedTools?.joined(separator: ",") ?? "none") | \(Self.describe(collision)) -> default \(Self.describe(planned)). CONSEQUENCE: \(Self.consequence(of: planned))")
                }
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
        logger.notice("[SKILL_IMPORT] COMMIT starting for \(ready.count) queued skill(s). CONSEQUENCE: each is written independently and the pass stops at the first failure, keeping whatever already landed.")
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
                switch resolution(for: skill) {
                case .skip:
                    logger.notice("[SKILL_IMPORT] SKIPPED '\(skill.name)' by the user's choice. CONSEQUENCE: the library is unchanged for this one.")
                case .createNew:
                    logger.notice("[SKILL_IMPORT] CREATED '\(skill.name)' as a NEW skill. CONSEQUENCE: it is not linked to any profile yet — link it in the Skills library before an agent can use it.")
                case .addVersion(let skillID):
                    logger.notice("[SKILL_IMPORT] ADDED A VERSION to [skill \(skillID)] from '\(skill.name)'. CONSEQUENCE: this reaches EVERY profile linked to that skill that does not pin an older version, immediately.")
                }
            case .failure(let error):
                commitError = "Handled \(handled) of \(ready.count). '\(skill.name)' failed: \(error.localizedDescription)"
                logger.error("[SKILL_IMPORT] COMMIT STOPPED at '\(skill.name)' after \(handled) of \(ready.count): \(error.localizedDescription). CONSEQUENCE: the \(handled) already written are KEPT and stay in the library; the remainder are left queued in the sheet so the user can retry or remove the offender.")
                ready = Array(ready.dropFirst(handled))
                onImported()
                return
            }
        }
        logger.notice("[SKILL_IMPORT] COMMIT finished: \(handled) of \(ready.count) handled. CONSEQUENCE: the sheet closes and the library reloads.")
        onImported()
        dismiss()
    }
}

// MARK: - Drop plumbing
