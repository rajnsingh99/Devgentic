// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  BackendProfileDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored on 26/08/25 to support unified BackendProfileModel.
//  Updated on 05/09/25 to integrate AgentConfigDetailView.
//
//  Renamed from BackendProfilePanelView.swift on 06/08/26 (register G93). The
//  `BackendProfilePanelView` this file was named after was DEAD: it hosted the old
//  "AI Blueprints" window (id `backend-profiles`), which was removed in a3b831d on
//  21/03/26 during the single-window refactor. Nothing constructed it afterwards except
//  its own PreviewProvider, so it sat compiled-but-unreachable for four months while
//  three of its file-mates stayed very much alive.
//
//  What remains here is all live and reached from the sidebar and the main content area:
//    - BackendProfileDetailView — wrapped by ProfileDetailContainerView
//    - ProfileRowView, DuplicateProfileSheet — used by ProfileSidebarListView
//

import SwiftUI

// MARK: - Backend Profile Detail View

struct BackendProfileDetailView: View {
    @Bindable var editBuffer: ProfileEditBuffer
    var onDelete: ((UUID) -> Void)? = nil
    @Environment(BackendProfileService.self) var profileService
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    /// ⚠️ Present ONLY to source the shared `WorkflowCanvasState` for a workflow profile — see the
    /// `.workflow` case below. Injected at the app root (`DevgenticApp`), so it is available here
    /// even though this view is reached through the Profiles destination rather than the chat area.
    @Environment(MainApplicationViewModel.self) private var mainViewModel

    /// Set when this profile's stored blob could not be decoded — carries the surviving columns so
    /// the warning can say what the profile actually was.
    ///
    /// ⚠️ `@State`, refreshed in `.task(id:)`, NEVER read from `body`: the query primes a JSON decode.
    @State private var unreadable: BackendProfileStore.UnreadableProfileInfo?
    @State private var showingDiscardAlert = false

    var body: some View {
        VStack(spacing: 0) {
            // ⚠️ ABOVE the switch, so it covers every profile type in one place — and it must, because
            // the switch itself is part of the problem: a corrupted Agent decodes to the `.bot`
            // placeholder and gets routed to `BotConfigDetailView`, where tools, capabilities, skills
            // and resilience are not rendered blank, they are NOT RENDERED. There is nothing missing
            // on screen for the user to notice.
            if let unreadable {
                unreadableConfigurationWarning(unreadable)
            }

            Group {
                switch editBuffer.draft.profileType {
                case .bot:
                    BotConfigDetailView(editBuffer: editBuffer, onDelete: onDelete)
                case .agent:
                    AgentConfigDetailView(editBuffer: editBuffer, onDelete: onDelete)
                case .workflow:
                    // ⚠️ `editGuard` is not optional plumbing here — it is the ONLY channel by
                    // which canvas dirt reaches the sidebar's navigation guard. Canvas geometry
                    // lives in `WorkflowCanvasState`/`WorkflowLayoutSD`, never in
                    // `editBuffer.draft`, so leaving this nil (as it was) meant `isDirty` stayed
                    // false however much the user had drawn, and clicking another profile row
                    // destroyed every unsaved node and edge with no prompt at all.
                    //
                    // ⚠️ `canvasState` is likewise NOT optional plumbing (WF-PE1). It MUST come from
                    // `MainApplicationViewModel.workflowCanvasState(for:)` — the same call
                    // `WorkflowDedicatedView` makes — so that both surfaces edit ONE state object
                    // per workflow. While this argument was omitted, the view fell back to its own
                    // `@State ownedCanvasState` and a second, independent graph existed for the same
                    // profile: the profile editor loaded the DISK layout while the main Workflow
                    // interface held unsaved edits, and at quit `persistDirtyWorkflowCanvases`
                    // wrote the main interface's graph and `saveHook()` then wrote this stale one
                    // straight over the same `WorkflowLayoutSD` row. The store has no
                    // compare-and-swap, so the newer nodes were destroyed with no prompt, no undo
                    // and no error log. Sharing the state makes that unrepresentable rather than
                    // merely unlikely.
                    //
                    // Safe against a reload clobbering the other surface's work:
                    // `loadLayout()` early-returns on `canvasState.acceptsDiskReload`
                    // (`!hasUnsavedChanges`), so mounting this editor over an already-dirty shared
                    // state does NOT re-read the disk layout.
                    WorkflowCanvasView(
                        profile: $editBuffer.draft,
                        onDelete: onDelete,
                        editGuard: profileService.canvasEditGuard,
                        canvasState: mainViewModel.workflowCanvasState(for: editBuffer.draft.id)
                    )
                case .imageGen:
                    ImageGenConfigDetailView(editBuffer: editBuffer, onDelete: onDelete)
                case .code:
                    // Code mode uses the dedicated Code interface, not profile-based config.
                    // This case should not be reachable, but handle gracefully.
                    Text("Code sessions are configured via the Code interface.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: editBuffer.draft.id) {
            unreadable = BackendProfileStore.shared.unreadableProfiles()
                .first { $0.id == editBuffer.draft.id }
        }
        // ⚠️ Two different alerts, because the two reasons have OPPOSITE correct actions (G18).
        // A from-the-future profile is intact and merely unreadable here, so its alert offers no
        // destructive button at all — the fix would be worthless if the UI still steered the user
        // into discarding data that a newer build can read perfectly.
        .alert(
            unreadable?.reason == .undecodable
                ? "Discard the unreadable configuration?"
                : "This profile is from a newer version",
            isPresented: $showingDiscardAlert
        ) {
            if unreadable?.reason == .undecodable {
                Button("Discard and Reconfigure", role: .destructive) { discardUnreadableConfiguration() }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            if case .writtenByNewerBuild(let storedVersion) = unreadable?.reason {
                Text(
                    "\(unreadable?.displayName ?? "This profile") was saved by a newer version of "
                    + "Devgentic (configuration format \(storedVersion); this build reads up to "
                    + "\(ProfileMigrator.currentVersion)). Its settings are intact and untouched — "
                    + "update Devgentic to use it again.\n\nDo not reconfigure it here: saving on this "
                    + "version would replace the newer settings permanently."
                )
            } else {
                Text(
                    "This profile was saved as \(unreadable?.wasSummary ?? "an earlier configuration"), but "
                    + "this version can't read it. Discarding replaces it with a fresh, empty profile of the "
                    + "same type — the original settings are gone for good and a future version will no "
                    + "longer be able to recover them."
                )
            }
        }
    }

    /// Warns without blocking.
    ///
    /// Deliberately NOT a save gate. The user can still edit and save — but now they know they are
    /// overwriting recoverable data rather than fixing a profile that "reset itself", which is the
    /// misreading the blank form invites. The one thing that MUST be visible is the type: the row
    /// still says Agent while the form is showing Bot.
    @ViewBuilder
    private func unreadableConfigurationWarning(_ info: BackendProfileStore.UnreadableProfileInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(theme.warningColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("This profile's configuration could not be read")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                if !info.wasSummary.isEmpty {
                    Text("It was saved as \(info.wasSummary). The fields below are a blank placeholder, not your settings.")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Text("Your original data is preserved. Saving now replaces it permanently.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer(minLength: 8)

            Button("Discard and Reconfigure") { showingDiscardAlert = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warningColor.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.warningColor.opacity(0.35)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Warning. This profile's configuration could not be read. It was saved as "
            + "\(info.wasSummary). Your original data is preserved; saving now replaces it permanently."
        )
    }

    private func discardUnreadableConfiguration() {
        guard let unreadable else { return }
        let didDiscard = BackendProfileStore.shared.discardUnreadableConfiguration(
            for: unreadable.id, reason: "user chose Discard and Reconfigure in the profile editor"
        )
        guard didDiscard else {
            // ⚠️ The store now genuinely logs every refusal path (it did not when this comment
            // first claimed so). A toast is still needed here: the user accepted a DESTRUCTIVE
            // confirmation, and leaving the banner up with no other feedback reads as a frozen
            // button. Deliberately worded as "could not" rather than naming a cause — the benign
            // case (the blob became readable in the meantime) and the hard failures are
            // indistinguishable from this side, and the log carries the distinction.
            toastManager.show(
                "Could not reset this profile's configuration. See the log for details.",
                style: .error
            )
            return
        }
        self.unreadable = nil
        profileService.loadProfiles()
    }
}

// MARK: - Profile Row View
struct ProfileRowView: View {
    let profile: BackendProfileModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            // Left rail = STATE: accent when selected or hovered; absent otherwise
            if isSelected || isHovering {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        LinearGradient(
                            colors: isSelected ? [theme.accentColor, theme.accentColor.opacity(0.45)] : [theme.accentColor.opacity(0.4), theme.accentColor.opacity(0.15)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, isSelected ? 2 : 5)
                    .padding(.trailing, 4)
                    .shadow(color: isSelected ? theme.accentColor.opacity(0.4) : .clear, radius: 4)
                    .transition(.opacity.combined(with: .scale))
            } else {
                Spacer().frame(width: 7)
            }

            HStack(spacing: 12) {
                Image(systemName: iconName(for: profile.profileType))
                    .font(.system(.body))
                    .foregroundColor(color(for: profile.profileType))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(theme.fontFootnote.weight(.medium))
                        .foregroundColor(theme.primaryText)
                    Text(profile.profileType.localizedTitle)
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                }
                
                Spacer()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.accentColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(theme.accentColor.opacity(0.15), lineWidth: 0.5)
                        )
                        .shadow(color: theme.accentColor.opacity(0.05), radius: 4, x: 0, y: 0)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.surfaceOverlay)
                }
            }
        )
        .overlay(alignment: .trailing) {
            if isHovering {
                HoverActionButton(
                    icon: "trash",
                    tint: .red.opacity(0.8),
                    action: onDelete
                )
                .accessibilityLabel("Delete \(profile.displayName)")
                .padding(.trailing, 8)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .contentShape(Rectangle())
        // `accessibilityLabel(_: String)` does not localize; the `Text` overload does, and a
        // nested `Text` keeps the type name translatable inside the composed phrase.
        .accessibilityLabel(Text("\(profile.displayName), \(Text(profile.profileType.localizedTitle))"))
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button {
                onDuplicate()
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }

    private func iconName(for type: ProfileType) -> String {
        type.iconName
    }

    private func color(for type: ProfileType) -> Color {
        type.displayColor
    }
}

// MARK: - Duplicate Profile Sheet

/// A lightweight sheet that lets the user choose a name before duplicating a profile.
struct DuplicateProfileSheet: View {
    let sourceProfile: BackendProfileModel
    let existingProfileNames: [String]
    let onConfirm: (BackendProfileSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var displayName: String = ""

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicateName: Bool {
        let lower = trimmedName.lowercased()
        return !lower.isEmpty && existingProfileNames.contains(where: { $0.lowercased() == lower })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .font(.system(.title3))
                    .foregroundColor(theme.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicate Profile")
                        .font(.headline)
                        .foregroundColor(theme.primaryText)
                    Text("From '\(sourceProfile.displayName)'")
                        .font(.subheadline)
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            // Name field
            VStack(alignment: .leading, spacing: 8) {
                Text("Profile Name")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(theme.primaryText)

                TextField("Enter a name for the duplicate", text: $displayName)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(theme.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isDuplicateName ? theme.warningColor : theme.dividerColor, lineWidth: 1)
                    )

                if isDuplicateName {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(.caption))
                        Text("A profile named '\(trimmedName)' already exists.")
                            .font(.system(.caption))
                    }
                    .foregroundColor(theme.warningColor)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(20)

            Divider()

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Duplicate") {
                    // ⚠️ Was a four-argument call to the memberwise init (register A31). Every
                    // parameter there has a default, so omitting `fileContextStrategy` compiled
                    // cleanly and silently produced a copy with `nil` — which resolves to
                    // `.stateless` for an agent, so duplicating an agent set to `.directInjection`
                    // gave you a copy that hands the model file PATHS instead of file CONTENT.
                    // `duplicated(as:)` copies the whole value and re-stamps only identity, so a
                    // property added later is carried instead of dropped.
                    onConfirm(sourceProfile.duplicated(as: trimmedName))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420)
        .background(theme.primaryBackground)
        .onAppear {
            displayName = "\(sourceProfile.displayName) (Copy)"
        }
    }
}

