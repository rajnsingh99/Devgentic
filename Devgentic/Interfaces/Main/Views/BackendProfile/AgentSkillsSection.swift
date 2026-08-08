//
//  AgentSkillsSection.swift
//  Devgentic
//
//  Extracted from AgentConfigDetailView to reduce file complexity.
//  Manages skill folder import, scanning, enable/disable, and auto-shell-tool injection.
//

import SwiftUI
import UniformTypeIdentifiers

private let logger = DGLogger(category: "AgentSkillsSection")

struct AgentSkillsSection: View {
    @Binding var skillConfig: SkillFolderConfig?
    @Binding var tools: [Tool]
    let currentModelTier: ModelTier?
    let theme: any Theme

    @State private var showingSkillsFolderImporter = false
    @State private var showingRemoveAllConfirmation = false
    @State private var skillScanError: String?
    @State private var skillScanResult: SkillScanResult?
    @State private var didAutoAddShellTool = false
    @State private var showAllSkills = false

    var body: some View {
        SettingsCard(title: "Skills", icon: "sparkles", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                // Header: folder info + actions
                if let config = skillConfig {
                    // Source folders list
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(config.folderURLs, id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(theme.accentColor)
                                    .font(theme.fontCaption)
                                Text(url.path)
                                    .font(theme.fontCaption2)
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        SkillActionButton(label: "Add More", icon: "plus.circle", theme: theme) {
                            showingSkillsFolderImporter = true
                        }
                        SkillActionButton(label: "Rescan", icon: "arrow.clockwise", theme: theme) {
                            rescanSkillFolders()
                        }
                        // ⚠️ Register A59: this used to nil `skillConfig` on the first click. It
                        // discards every folder AND every per-skill enable/disable decision, and
                        // the only recovery is the profile-wide Revert — which also throws away
                        // every other unsaved edit the user has made. One click, no confirmation,
                        // no targeted undo.
                        SkillActionButton(label: "Remove All", icon: "trash", isDestructive: true, theme: theme) {
                            showingRemoveAllConfirmation = true
                        }
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Skill Folder")
                                .font(theme.fontBody.weight(.medium))
                                .foregroundColor(theme.primaryText)
                            Text("Add folders containing SKILL.md definitions for on-demand task expertise.")
                                .font(theme.fontCaption)
                                .foregroundColor(theme.secondaryText)
                        }
                        Spacer(minLength: 16)
                        SkillActionButton(label: "Import Folder", icon: "folder.badge.plus", theme: theme) {
                            showingSkillsFolderImporter = true
                        }
                    }
                }

                // Scan error
                if let error = skillScanError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.warningColor)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.warningColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }

                // Scan result summary + skipped
                if let result = skillScanResult, skillConfig != nil {
                    HStack(spacing: 6) {
                        Image(systemName: result.isEmpty ? "info.circle" : "checkmark.circle")
                            .foregroundColor(result.isEmpty ? theme.warningColor : theme.successColor)
                            .font(theme.fontCaption)
                        Text(result.summary)
                            .font(theme.fontCaption)
                            .foregroundColor(result.isEmpty ? theme.warningColor : theme.secondaryText)
                    }

                    if !result.skipped.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(result.skipped, id: \.directoryName) { entry in
                                    HStack(spacing: 6) {
                                        Image(systemName: "xmark.circle")
                                            .font(theme.fontCaption2)
                                            .foregroundColor(theme.errorColor.opacity(0.7))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.directoryName)
                                                .font(theme.fontCaption.weight(.medium))
                                                .foregroundColor(theme.primaryText)
                                            Text(entry.reason.displayText)
                                                .font(theme.fontCaption2)
                                                .foregroundColor(theme.secondaryText)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text("\(result.skippedCount) folder\(result.skippedCount == 1 ? "" : "s") skipped")
                                .font(theme.fontCaption)
                                .foregroundColor(theme.warningColor)
                        }
                    }
                }

                // Skill manifest list with enable/disable checkboxes
                if let manifests = skillConfig?.manifests, !manifests.isEmpty {
                    Divider().background(theme.dividerColor)
                    let visibleManifests = showAllSkills ? manifests : Array(manifests.prefix(3))
                    ForEach(visibleManifests) { manifest in
                        SkillManifestRow(
                            manifest: manifest,
                            theme: theme,
                            onToggleEnabled: { toggleSkillEnabled(manifest.id) }
                        )
                    }
                    // Footer: count + expand/collapse
                    let enabledCount = manifests.filter(\.isEnabled).count
                    HStack {
                        Text("\(enabledCount)/\(manifests.count) skill\(manifests.count == 1 ? "" : "s") enabled")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                        if manifests.count > 3 {
                            SkillActionButton(
                                label: showAllSkills ? "Show Less" : "Show All \(manifests.count)",
                                icon: showAllSkills ? "chevron.up" : "chevron.down",
                                theme: theme
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) { showAllSkills.toggle() }
                            }
                        }
                    }
                }

                // Model tier warning
                if let manifests = skillConfig?.manifests, manifests.contains(where: \.isEnabled) {
                    if let tier = currentModelTier, !tier.isFrontier {
                        Label {
                            Text("Skills work best with large models (70B+). The selected model may not retain full skill instructions during multi-step tasks.")
                                .font(theme.fontCaption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(theme.warningColor)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.warningColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                // Auto-added execute_shell banner
                if didAutoAddShellTool {
                    Label {
                        Text("execute_shell was added automatically — some imported skills bundle scripts that require it. Runs in Ask mode (requires your approval).")
                            .font(theme.fontCaption)
                    } icon: {
                        Image(systemName: "terminal.fill")
                            .foregroundColor(.blue)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .fileImporter(isPresented: $showingSkillsFolderImporter, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            handleSkillFolderSelection(result)
        }
        .confirmationDialog(
            "Remove all skill folders?",
            isPresented: $showingRemoveAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) { removeAllSkillFolders() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // States what is actually lost. "Are you sure?" would not have helped: the part users
            // do not expect to lose is the per-skill enable/disable state, not the folder paths.
            Text(removeAllConfirmationMessage)
        }
    }

    /// Spells out the cost of Remove All, including the per-skill state that is easy to forget.
    private var removeAllConfirmationMessage: String {
        let folderCount = skillConfig?.folderURLs.count ?? 0
        let manifests = skillConfig?.manifests ?? []
        let disabledCount = manifests.filter { !$0.isEnabled }.count

        var message = String(
            localized: "This removes \(folderCount) folder(s) and all \(manifests.count) skill(s) from this profile.")
        if disabledCount > 0 {
            message += " " + String(
                localized: "Your enabled/disabled choices for \(disabledCount) skill(s) are discarded too.")
        }
        message += " " + String(localized: "The folders themselves are not deleted from disk.")
        return message
    }

    // MARK: - Actions

    private func removeAllSkillFolders() {
        let folderCount = skillConfig?.folderURLs.count ?? 0
        let manifestCount = skillConfig?.manifests.count ?? 0
        logger.notice(
            "[SKILLS] Remove All CONFIRMED: dropping \(folderCount) folder(s) and \(manifestCount) "
            + "manifest(s) from the profile draft. CONSEQUENCE: the skill configuration is cleared "
            + "in the editor; nothing is deleted from disk, and the change is not persisted until "
            + "the profile is saved."
        )
        skillConfig = nil
        skillScanError = nil
        skillScanResult = nil
        didAutoAddShellTool = false
        showAllSkills = false
    }

    private func toggleSkillEnabled(_ id: UUID) {
        guard var config = skillConfig,
              let index = config.manifests.firstIndex(where: { $0.id == id }) else { return }
        config.manifests[index].isEnabled.toggle()
        skillConfig = config
    }

    private func handleSkillFolderSelection(_ result: Result<[URL], Error>) {
        let urls: [URL]
        switch result.fileImportOutcome() {
        case .selected(let selected):
            urls = selected

        case .cancelled:
            // Not an error. Logged at debug so a support trace still shows the picker opened and
            // closed — otherwise "I tried to add a folder and nothing happened" has no trace at all.
            logger.debug("[SKILLS] Skill folder import dismissed by the user; nothing imported.")
            return

        case .failed(let message):
            // ⚠️ Register A40/A60. This arm did not exist: `.failure` was dropped, so a permission
            // denial or an ejected volume looked exactly like pressing Cancel.
            logger.error(
                "[SKILLS] Skill folder import FAILED: \(message). CONSEQUENCE: no folder was added "
                + "and the profile's skill configuration is unchanged; the reason is shown inline "
                + "so the user can retry rather than assume the picker is broken."
            )
            skillScanError = String(localized: "Couldn't open the selected folder: \(message)")
            return
        }

        skillScanError = nil
        didAutoAddShellTool = false

        var allManifests: [SkillManifest] = skillConfig?.manifests ?? []
        var allFolderURLs: [URL] = skillConfig?.folderURLs ?? []
        var allSkipped: [SkippedSkillEntry] = []
        var totalSubdirs = 0
        var duplicateFolderCount = 0

        // Which folder each already-loaded skill name came from, so a name collision can say WHICH
        // copy was kept instead of just dropping one.
        var sourceFolderByName: [String: String] = [:]
        for manifest in allManifests {
            sourceFolderByName[manifest.name] =
                URL(fileURLWithPath: manifest.folderPath).deletingLastPathComponent().lastPathComponent
        }

        for folderURL in urls {
            // Skip duplicate folders
            guard !allFolderURLs.contains(folderURL) else {
                duplicateFolderCount += 1
                logger.notice(
                    "[SKILLS] Folder '\(folderURL.path)' is already in this profile. "
                    + "CONSEQUENCE: skipped — it is not imported twice; the existing entry stands."
                )
                continue
            }

            do {
                let scanResult = try SkillFolderScanner.scanDetailed(rootFolder: folderURL)

                // ⚠️ Deduplicate by NAME — but say so (register A40). This used to be a silent
                // `filter`, so importing a folder whose skills were already loaded elsewhere just
                // appeared to import fewer skills than the folder contains. Rejected names now
                // travel in `skipped`, which the UI already renders in its disclosure list.
                var newManifests: [SkillManifest] = []
                for manifest in scanResult.manifests {
                    if let keptFrom = sourceFolderByName[manifest.name] {
                        allSkipped.append(SkippedSkillEntry(
                            directoryName: manifest.name,
                            reason: .duplicateName(keptFrom: keptFrom)))
                        logger.notice(
                            "[SKILLS] Skill '\(manifest.name)' from '\(folderURL.lastPathComponent)' "
                            + "duplicates one already loaded from '\(keptFrom)'. CONSEQUENCE: the "
                            + "existing copy is kept and this one is NOT loaded; the skip is listed "
                            + "in the import summary."
                        )
                        continue
                    }
                    sourceFolderByName[manifest.name] = folderURL.lastPathComponent
                    newManifests.append(manifest)
                }

                allManifests.append(contentsOf: newManifests)
                allSkipped.append(contentsOf: scanResult.skipped)
                totalSubdirs += scanResult.totalSubdirectories
                allFolderURLs.append(folderURL)
            } catch {
                logger.error(
                    "[SKILLS] Scan FAILED for newly selected folder '\(folderURL.path)': "
                    + "\(error.localizedDescription). CONSEQUENCE: the folder is NOT added to the "
                    + "profile and contributes no skills; the reason is shown inline."
                )
                skillScanError = (skillScanError ?? "") + "\(folderURL.lastPathComponent): \(error.localizedDescription)\n"
            }
        }

        if duplicateFolderCount > 0 {
            skillScanError = (skillScanError ?? "") + String(
                localized: "\(duplicateFolderCount) folder(s) were already added and were skipped.\n")
        }

        skillScanResult = SkillScanResult(manifests: allManifests, skipped: allSkipped, totalSubdirectories: totalSubdirs)

        skillConfig = SkillFolderConfig(
            folderURLs: allFolderURLs,
            manifests: allManifests,
            lastScannedAt: Date()
        )

        // Auto-add execute_shell if needed
        autoAddShellToolIfNeeded(manifests: allManifests)
    }

    private func rescanSkillFolders() {
        guard let folderURLs = skillConfig?.folderURLs else { return }
        skillScanError = nil
        skillScanResult = nil

        // Preserve existing enabled/disabled state by name
        let previousStates: [String: Bool] = {
            guard let manifests = skillConfig?.manifests else { return [:] }
            return Dictionary(uniqueKeysWithValues: manifests.map { ($0.name, $0.isEnabled) })
        }()

        let previousManifests = skillConfig?.manifests ?? []

        var allManifests: [SkillManifest] = []
        var allSkipped: [SkippedSkillEntry] = []
        var totalSubdirs = 0
        var retainedFolderURLs: [URL] = []
        var unreachableFolders: [String] = []

        for folderURL in folderURLs {
            do {
                let scanResult = try SkillFolderScanner.scanDetailed(rootFolder: folderURL)
                // Restore previous enabled state
                var restoredManifests = scanResult.manifests
                for i in restoredManifests.indices {
                    if let previousState = previousStates[restoredManifests[i].name] {
                        restoredManifests[i].isEnabled = previousState
                    }
                }
                allManifests.append(contentsOf: restoredManifests)
                allSkipped.append(contentsOf: scanResult.skipped)
                totalSubdirs += scanResult.totalSubdirectories
                retainedFolderURLs.append(folderURL)
            } catch {
                // ⚠️ A failed scan is NOT a request to delete. This used to omit the folder from
                // the rebuilt config, so an unmounted external volume, a renamed directory or a
                // lapsed permission silently removed the folder AND every skill it contributed —
                // and the next Save made that permanent. Remounting did not bring it back; the
                // user had to re-import and re-toggle every skill by hand.
                //
                // Keeping the folder and carrying its last-known manifests forward means a
                // transient failure stays transient: the next successful Rescan replaces them.
                let carried = Self.manifests(in: previousManifests, under: folderURL)
                allManifests.append(contentsOf: carried)
                retainedFolderURLs.append(folderURL)
                unreachableFolders.append(folderURL.lastPathComponent)

                skillScanError = (skillScanError ?? "")
                    + "\(folderURL.lastPathComponent): \(error.localizedDescription) — "
                    + "keeping \(carried.count) previously scanned skill\(carried.count == 1 ? "" : "s") "
                    + "from this folder.\n"

                logger.error("""
                    [SKILLS] Rescan failed for folder '\(folderURL.path)': \
                    \(error.localizedDescription). CONSEQUENCE: the folder is RETAINED in the \
                    profile and \(carried.count) previously scanned manifest(s) are carried \
                    forward unchanged — nothing was deleted. The next successful Rescan replaces \
                    them.
                    """)
            }
        }

        if !unreachableFolders.isEmpty {
            logger.notice("""
                [SKILLS] Rescan completed with \(unreachableFolders.count) unreachable folder(s): \
                \(unreachableFolders.joined(separator: ", ")). CONSEQUENCE: their skills remain \
                configured and enabled from the last successful scan; they may no longer match \
                what is on disk.
                """)
        }

        skillScanResult = SkillScanResult(manifests: allManifests, skipped: allSkipped, totalSubdirectories: totalSubdirs)
        skillConfig = SkillFolderConfig(
            folderURLs: retainedFolderURLs,
            manifests: allManifests,
            lastScannedAt: Date()
        )
    }

    /// The manifests that came from `folderURL`, matched on `SkillManifest.folderPath` — which is
    /// the absolute path of the skill's own subdirectory, so a manifest belongs to a root folder
    /// when its path sits underneath that folder.
    ///
    /// ⚠️ Compares standardized paths with a trailing separator. Without the separator,
    /// `/Users/x/skills` would also claim `/Users/x/skills_backup`, silently pulling another
    /// folder's skills into a folder that failed to scan.
    static func manifests(in manifests: [SkillManifest], under folderURL: URL) -> [SkillManifest] {
        let root = folderURL.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return manifests.filter { manifest in
            let path = URL(fileURLWithPath: manifest.folderPath).standardizedFileURL.path
            return path == root || path.hasPrefix(prefix)
        }
    }

    /// Auto-adds `execute_shell` tool if skills contain scripts and it's missing.
    /// Only triggers on initial import (not Rescan) — respects manual removal.
    private func autoAddShellToolIfNeeded(manifests: [SkillManifest]) {
        let skillsHaveScripts = manifests.contains(where: \.hasScripts)
        let hasShellTool = tools.contains(where: { $0.name == "execute_shell" })

        guard skillsHaveScripts && !hasShellTool else { return }

        let shellTool = Tool(
            name: "execute_shell",
            description: "Executes a non-interactive ZSH shell command on the host.",
            isEnabled: true,
            requiresConfirmation: true,
            // ⚠️ `execute_shell` IS a native catalogue tool, so this is the only correct source.
            //
            // This used to be `UUID(uuidString: "00000000-SKIL-AUTO-SHEL-000000000000") ?? UUID()`.
            // S, K, I, L, U, T, O and H are not hex digits, so the parse failed on EVERY call and
            // the `?? UUID()` minted a fresh random id per import. The Tool Library matches rows on
            // `(name, sourceId)`, so the tool rendered as OFF while it was live; ticking it appended
            // a SECOND copy; un-ticking removed only the built-in-sourced one, leaving the
            // auto-added copy enabled and unreachable from any UI.
            //
            // Never write `X ?? UUID()` for a compile-time-constant identity — a typo degrades to a
            // random value at runtime instead of failing the build.
            sourceId: ToolSource.builtInSourceID,
            parameters: SchemaBuilder.object(
                properties: [("command", "string", "The shell command to execute.")],
                required: ["command"]
            )
        )
        tools.append(shellTool)
        didAutoAddShellTool = true

        logger.notice("""
            [TOOLRESOLVE] Auto-granted execute_shell because an imported skill folder bundles \
            scripts. CONSEQUENCE: this agent can run shell commands, every call gated by \
            requiresConfirmation (Ask mode); the tool is removable from the Tool Library.
            """)
    }
}
