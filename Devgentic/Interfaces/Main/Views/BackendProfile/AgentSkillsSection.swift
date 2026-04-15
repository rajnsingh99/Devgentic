//
//  AgentSkillsSection.swift
//  Devgentic
//
//  Extracted from AgentConfigDetailView to reduce file complexity.
//  Manages skill folder import, scanning, enable/disable, and auto-shell-tool injection.
//

import SwiftUI
import UniformTypeIdentifiers

struct AgentSkillsSection: View {
    @Binding var skillConfig: SkillFolderConfig?
    @Binding var tools: [Tool]
    let currentModelTier: ModelTier?
    let theme: any Theme

    @State private var showingSkillsFolderImporter = false
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
                        SkillActionButton(label: "Remove All", icon: "trash", isDestructive: true, theme: theme) {
                            skillConfig = nil
                            skillScanError = nil
                            skillScanResult = nil
                            didAutoAddShellTool = false
                            showAllSkills = false
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
        }
        .fileImporter(isPresented: $showingSkillsFolderImporter, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            handleSkillFolderSelection(result)
        }
    }

    // MARK: - Actions

    private func toggleSkillEnabled(_ id: UUID) {
        guard var config = skillConfig,
              let index = config.manifests.firstIndex(where: { $0.id == id }) else { return }
        config.manifests[index].isEnabled.toggle()
        skillConfig = config
    }

    private func handleSkillFolderSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        skillScanError = nil
        didAutoAddShellTool = false

        var allManifests: [SkillManifest] = skillConfig?.manifests ?? []
        var allFolderURLs: [URL] = skillConfig?.folderURLs ?? []
        var allSkipped: [SkippedSkillEntry] = []
        var totalSubdirs = 0

        for folderURL in urls {
            // Skip duplicate folders
            guard !allFolderURLs.contains(folderURL) else { continue }

            do {
                let scanResult = try SkillFolderScanner.scanDetailed(rootFolder: folderURL)
                // Deduplicate by name — skip manifests already present from other folders
                let existingNames = Set(allManifests.map(\.name))
                let newManifests = scanResult.manifests.filter { !existingNames.contains($0.name) }
                allManifests.append(contentsOf: newManifests)
                allSkipped.append(contentsOf: scanResult.skipped)
                totalSubdirs += scanResult.totalSubdirectories
                allFolderURLs.append(folderURL)
            } catch {
                skillScanError = (skillScanError ?? "") + "\(folderURL.lastPathComponent): \(error.localizedDescription)\n"
            }
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

        var allManifests: [SkillManifest] = []
        var allSkipped: [SkippedSkillEntry] = []
        var totalSubdirs = 0
        var validFolderURLs: [URL] = []

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
                validFolderURLs.append(folderURL)
            } catch {
                skillScanError = (skillScanError ?? "") + "\(folderURL.lastPathComponent): \(error.localizedDescription)\n"
            }
        }

        skillScanResult = SkillScanResult(manifests: allManifests, skipped: allSkipped, totalSubdirectories: totalSubdirs)
        skillConfig = SkillFolderConfig(
            folderURLs: validFolderURLs,
            manifests: allManifests,
            lastScannedAt: Date()
        )
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
            sourceId: UUID(uuidString: "00000000-SKIL-AUTO-SHEL-000000000000") ?? UUID(),
            parameters: SchemaBuilder.object(
                properties: [("command", "string", "The shell command to execute.")],
                required: ["command"]
            )
        )
        tools.append(shellTool)
        didAutoAddShellTool = true
    }
}
