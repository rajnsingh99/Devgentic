//
//  InputToolbarView.swift
//  Devgentic
//
//  Extracted from ChatInputAreaView.swift — groups the left-side toolbar
//  buttons (attach, tools, schedule) into a single reusable view.
//

import SwiftUI
import AppKit

struct InputToolbarView: View {

    let isInputEnabled: Bool
    let selectedProfile: BackendProfileModel?
    let selectedProfileID: UUID?
    let promptText: String

    let onOpenFilePicker: () -> Void
    let onNavigateToToolLibrary: (UUID) -> Void

    @Binding var showingSchedulePopover: Bool
    @Binding var showingFullScheduleCreator: Bool

    @Environment(\.appTheme) private var theme

    @State private var isPlusButtonHovering = false
    @State private var isToolsHovering = false
    @State private var isScheduleButtonHovering = false

    var body: some View {
        HStack(spacing: 12) {
            filePickerButton
            toolManagerButton
            scheduleButton
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

    // MARK: - Tool Manager (Agent only)

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

    // MARK: - Schedule

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
                isPresented: $showingSchedulePopover,
                onCustomSchedule: {
                    showingFullScheduleCreator = true
                }
            )
        }
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
