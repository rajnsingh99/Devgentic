// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  InputToolbarView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit

/// The composer's left-side toolbar buttons (attach, tools, schedule) as one reusable view.
/// Mode-aware: shows or hides buttons based on `interfaceMode`.
struct InputToolbarView: View {

    let isInputEnabled: Bool
    let selectedProfile: BackendProfileModel?
    let selectedProfileID: UUID?
    let promptText: String
    let interfaceMode: MainApplicationViewModel.InterfaceMode

    /// What this surface offers. Defaults to the main composer's set (screenshot off); enabling `screenshot` and
    /// providing `onCaptureScreenshot` adds capture here.
    var capabilities: ComposerCapabilities = .mainComposer
    /// Screenshot-capture action; the button renders only when the capability is on AND this is set.
    var onCaptureScreenshot: (() -> Void)? = nil

    let onOpenFilePicker: () -> Void
    let onNavigateToToolLibrary: (UUID) -> Void
    /// Invoked when the user taps "Open folder..." in the folder popover.
    var onSelectFolder: (() -> Void)?
    /// Invoked when the user picks one of the recent folders from the popover.
    var onSelectRecentFolder: ((URL) -> Void)?
    /// Invoked when the user taps "Select file..." in the folder popover (code mode only).
    var onSelectCodeFile: (() -> Void)?

    @Binding var showingSchedulePopover: Bool
    /// Active conversation when invoked from chat — quick-preset tasks default
    /// to continuing this conversation instead of creating an orphan thread.
    var currentConversationID: UUID?
    /// Invoked when the user taps "Custom..." in the quick-schedule popover.
    /// The parent navigates to the in-window scheduler editor via MainViewRouter.
    var onCustomSchedule: () -> Void

    @Environment(CodeSessionManager.self) private var codeSessionManager
    @Environment(BackendProfileService.self) private var profileService
    @Environment(\.appTheme) private var theme

    @State private var isToolsHovering = false
    @State private var isScheduleButtonHovering = false
    @State private var isFolderButtonHovering = false
    @State private var isQuickSettingsHovering = false
    @State private var showingFolderPopover = false

    var body: some View {
        HStack(spacing: 8) {
            if interfaceMode == .code {
                // Code mode gets a dedicated folder pill with its own "Select file..."
                // entry in the popover — the generic paperclip would be redundant.
                folderSelectorButton
                codeToolManagerButton
                codeQuickSettingsButton
            } else {
                if capabilities.attachments {
                    filePickerButton
                }
                // Capability-gated screenshot slot, off for the main composer.
                if capabilities.screenshot, let onCaptureScreenshot {
                    ComposerIconButton(
                        systemName: "camera.viewfinder",
                        help: "Capture screenshot",
                        disabled: !isInputEnabled,
                        action: onCaptureScreenshot
                    )
                }
                toolManagerButton
                scheduleButton
            }
        }
    }

    // MARK: - File Picker

    private var filePickerButton: some View {
        // Shared primitive: the same attach button as the QuickAccess panel.
        ComposerIconButton(
            systemName: "paperclip",
            help: "Attach files (⌘O)",
            disabled: !isInputEnabled,
            action: onOpenFilePicker
        )
    }

    // MARK: - Tool Manager (Agent only, non-code modes)

    @ViewBuilder
    private var toolManagerButton: some View {
        if selectedProfile?.profileType == .agent, let profileID = selectedProfileID {
            Button(action: { onNavigateToToolLibrary(profileID) }) {
                toolbarIcon(systemName: "wrench.and.screwdriver", isHovering: isToolsHovering)
            }
            .buttonStyle(.plain)
            .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isToolsHovering = hover } }
            .help("Tool Library — manage MCP and workspace tools")
            .accessibilityLabel("Manage tools for this agent profile")
            .disabled(!isInputEnabled)
            .opacity(isInputEnabled ? 1.0 : 0.5)
        }
    }

    // MARK: - Tool Manager (Code mode)
    // Lazily creates the code profile if needed, then routes to the same Tool Library, which applies Code-specific
    // locking: preset tools can toggle Ask/Auto but cannot be disabled.

    private var codeToolManagerButton: some View {
        Button(action: {
            let profileID = codeSessionManager.ensureCodeProfile()
            // CodeSessionManager writes directly to the store; refresh the service's in-memory list so
            // ToolLibraryContainerView's existence check finds the profile.
            if !profileService.profiles.contains(where: { $0.id == profileID }) {
                profileService.loadProfiles()
            }
            onNavigateToToolLibrary(profileID)
        }) {
            toolbarIcon(systemName: "hammer.fill", isHovering: isToolsHovering)
        }
        .buttonStyle(.plain)
        .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isToolsHovering = hover } }
        .help("Manage tools for the Code session")
        .accessibilityLabel("Manage tools for the Code session")
        .disabled(!isInputEnabled)
        .opacity(isInputEnabled ? 1.0 : 0.5)
    }

    // MARK: - Quick Settings (Code mode)
    // Third entry in the `interfaceMode == .code` branch, the one place this shared composer forks for Code.
    // Not `CodeDedicatedView.codeStatusHeader`: that renders only once `isConfigured`, after the setup phase.

    private var codeQuickSettingsButton: some View {
        Button(action: { codeSessionManager.showQuickSettings.toggle() }) {
            ZStack(alignment: .topTrailing) {
                toolbarIcon(systemName: "slider.horizontal.3", isHovering: isQuickSettingsHovering)
                // A dot when this project differs from the preset. Without it the only way to know
                // a folder carries an auto-approve grant is to open the popover and look.
                if !codeSessionManager.quickSettings.isDefault {
                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: 5, height: 5)
                        .offset(x: 1, y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isQuickSettingsHovering = hover } }
        .help(codeSessionManager.projectPath == nil
              ? "Choose a project folder to configure this session"
              : "Session settings for this project — iterations, compute budget, approvals")
        .accessibilityLabel("Session settings for this project")
        // Settings are keyed by project folder, so there is nothing to edit without one. Disabled rather than hidden,
        // so the control doesn't read as a missing feature; the help string names the outstanding step.
        .disabled(!isInputEnabled || codeSessionManager.projectPath == nil)
        .opacity(isInputEnabled && codeSessionManager.projectPath != nil ? 1.0 : 0.5)
        .popover(isPresented: Binding(get: { codeSessionManager.showQuickSettings },
                                      set: { codeSessionManager.showQuickSettings = $0 }),
                 arrowEdge: .bottom) {
            CodeQuickSettingsPopover()
                .environment(codeSessionManager)
                .environment(\.appTheme, theme)
                .preferredColorScheme(theme.colorScheme)
        }
    }

    // MARK: - Schedule (non-code modes)

    private var scheduleButton: some View {
        Button(action: {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            showingSchedulePopover = true
        }) {
            toolbarIcon(systemName: "calendar", isHovering: isScheduleButtonHovering)
        }
        .buttonStyle(.plain)
        .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isScheduleButtonHovering = hover } }
        .help("Schedule this message")
        .accessibilityLabel("Schedule this message")
        .disabled(!isInputEnabled)
        .opacity(isInputEnabled ? 1.0 : 0.5)
        .popover(isPresented: $showingSchedulePopover, arrowEdge: .bottom) {
            QuickSchedulePopoverView(
                promptText: promptText,
                selectedProfileID: selectedProfileID,
                currentConversationID: currentConversationID,
                isPresented: $showingSchedulePopover,
                onCustomSchedule: onCustomSchedule
            )
        }
    }

    // MARK: - Folder Selector (Code mode only)

    @ViewBuilder
    private var folderSelectorButton: some View {
        if onSelectFolder != nil {
            Button(action: { showingFolderPopover.toggle() }) {
                folderPillLabel
            }
            .buttonStyle(.plain)
            .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isFolderButtonHovering = hover } }
            .help(codeSessionManager.projectPath?.path ?? String(localized: "Select project folder"))
            .accessibilityLabel(codeSessionManager.projectPath != nil
                ? String(localized: "Project folder: \(codeSessionManager.projectPath!.lastPathComponent)")
                : String(localized: "Select project folder"))
            .disabled(!isInputEnabled)
            .opacity(isInputEnabled ? 1.0 : 0.5)
            .popover(isPresented: $showingFolderPopover, arrowEdge: .bottom) {
                FolderSelectorPopoverView(
                    isPresented: $showingFolderPopover,
                    onSelectRecent: { url in onSelectRecentFolder?(url) },
                    onOpenFolder: { onSelectFolder?() },
                    onSelectFile: { onSelectCodeFile?() }
                )
            }
        }
    }

    private var folderPillLabel: some View {
        let hasFolder = codeSessionManager.projectPath != nil
        let label = hasFolder
            ? codeSessionManager.projectPath!.lastPathComponent
            : "Project"
        return HStack(spacing: 6) {
            Image(systemName: hasFolder ? "folder.fill" : "folder")
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 11, height: 11)
                .foregroundColor(hasFolder ? theme.accentColor : theme.secondaryText.opacity(0.85))

            Text(label)
                .font(theme.fontCaption.weight(.medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundColor(theme.secondaryText.opacity(isFolderButtonHovering ? 0.9 : 0.65))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .composerControlSurface(in: Capsule(), isHovered: isFolderButtonHovering)
    }

    // MARK: - Shared Icon Builder

    private func toolbarIcon(systemName: String, isHovering: Bool) -> some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 12, height: 12)
            .foregroundColor(isHovering ? theme.primaryText : theme.secondaryText.opacity(0.85))
            .padding(6)
            .composerControlSurface(in: Circle(), isHovered: isHovering)
            .shadow(color: isHovering ? Color.black.opacity(0.2) : .clear, radius: 4, x: 0, y: 1)
            .scaleEffect(isHovering ? 1.06 : 1.0)
    }
}
