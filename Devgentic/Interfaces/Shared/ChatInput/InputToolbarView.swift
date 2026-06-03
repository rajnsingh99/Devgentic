//
//  InputToolbarView.swift
//  Devgentic
//
//  Extracted from ChatInputAreaView.swift — groups the left-side toolbar
//  buttons (attach, tools, schedule) into a single reusable view.
//  Mode-aware: shows/hides buttons based on interfaceMode.
//

import SwiftUI
import AppKit

struct InputToolbarView: View {

    let isInputEnabled: Bool
    let selectedProfile: BackendProfileModel?
    let selectedProfileID: UUID?
    let promptText: String
    let interfaceMode: MainApplicationViewModel.InterfaceMode

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

    @State private var isPlusButtonHovering = false
    @State private var isToolsHovering = false
    @State private var isScheduleButtonHovering = false
    @State private var isFolderButtonHovering = false
    @State private var showingFolderPopover = false

    var body: some View {
        HStack(spacing: 12) {
            if interfaceMode == .code {
                // Code mode gets a dedicated folder pill with its own "Select file..."
                // entry in the popover — the generic paperclip would be redundant.
                folderSelectorButton
                codeToolManagerButton
            } else {
                filePickerButton
                toolManagerButton
                scheduleButton
            }
        }
    }

    // MARK: - File Picker

    private var filePickerButton: some View {
        Button(action: onOpenFilePicker) {
            toolbarIcon(systemName: "paperclip", isHovering: isPlusButtonHovering)
        }
        .buttonStyle(.plain)
        .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isPlusButtonHovering = hover } }
        .help("Attach files")
        .accessibilityLabel("Attach files")
        .disabled(!isInputEnabled)
        .opacity(isInputEnabled ? 1.0 : 0.5)
    }

    // MARK: - Tool Manager (Agent only, non-code modes)

    @ViewBuilder
    private var toolManagerButton: some View {
        if selectedProfile?.profileType == .agent, let profileID = selectedProfileID {
            Button(action: { onNavigateToToolLibrary(profileID) }) {
                toolbarIcon(systemName: "hammer.fill", isHovering: isToolsHovering)
            }
            .buttonStyle(.plain)
            .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isToolsHovering = hover } }
            .help("Manage tools for this agent")
            .accessibilityLabel("Manage tools for this agent")
            .disabled(!isInputEnabled)
            .opacity(isInputEnabled ? 1.0 : 0.5)
        }
    }

    // MARK: - Tool Manager (Code mode)
    //
    // Lazily creates the code profile if needed, then routes to the same Tool Library.
    // The library applies Code-specific locking (preset tools can toggle Ask/Auto but
    // cannot be disabled) — handled in ToolLibraryContainerView / ToolLibraryView.

    private var codeToolManagerButton: some View {
        Button(action: {
            let profileID = codeSessionManager.ensureCodeProfile()
            // CodeSessionManager writes directly to the store; refresh the service's
            // in-memory list so ToolLibraryContainerView's existence check finds the
            // profile when it renders.
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

    // MARK: - Schedule (non-code modes)

    private var scheduleButton: some View {
        Button(action: { showingSchedulePopover = true }) {
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
            .help(codeSessionManager.projectPath?.path ?? "Select project folder")
            .accessibilityLabel(codeSessionManager.projectPath != nil
                ? "Project folder: \(codeSessionManager.projectPath!.lastPathComponent)"
                : "Select project folder")
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
            : "Select folder"
        return HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(hasFolder ? theme.primaryText : theme.secondaryText)
            Text(label)
                .font(theme.fontSubheadline.weight(.medium))
                .foregroundColor(hasFolder ? theme.primaryText : theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(theme.secondaryText.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isFolderButtonHovering ? theme.surfaceOverlay : Color.clear)
        )
        .overlay(
            Capsule()
                .stroke(theme.secondaryText.opacity(isFolderButtonHovering ? 0.3 : 0.15), lineWidth: 1)
        )
        .scaleEffect(isFolderButtonHovering ? 1.02 : 1.0)
    }

    // MARK: - Shared Icon Builder

    private func toolbarIcon(systemName: String, isHovering: Bool) -> some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 14, height: 14)
            .foregroundColor(isHovering ? theme.primaryText : theme.secondaryText.opacity(0.8))
            .padding(7)
            .background(
                Circle()
                    .fill(isHovering ? theme.secondaryText.opacity(0.25) : theme.secondaryText.opacity(0.18))
            )
    }
}
