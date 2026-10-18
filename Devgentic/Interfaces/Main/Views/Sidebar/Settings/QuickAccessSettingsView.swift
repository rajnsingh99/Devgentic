// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  QuickAccessSettingsView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Settings pane for the QuickAccess floating panel: enable, global shortcut, default chat profile, resume timeout.
/// Reads and writes `QuickAccessConfigManager`; asks `AppDelegate` to re-register the hotkey on activation changes.
struct QuickAccessSettingsView: View {
    @Environment(\.appTheme) private var theme
    @State private var config = QuickAccessConfigManager.shared

    /// Drives the default-profile picker. Seeded from / persisted to the same UserDefaults
    /// key the panel reads (GlobalConstants.quickAccessProfileID).
    @State private var profileConfig = BackendConfiguration()
    @State private var showingProfilePopup = false

    // Session-timeout choices in SECONDS (10 sec … 5 min).
    private let timeoutOptions = [10, 30, 60, 120, 180, 300]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: Quick Access
                SettingsCard(title: "Quick Access", icon: "bolt.circle", theme: theme) {
                    SettingsRow(
                        title: "Enable Quick Access",
                        description: "Summon a floating chat panel from anywhere with a global shortcut.",
                        theme: theme
                    ) {
                        Toggle("", isOn: enabledBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(theme.accentColor)
                    }

                    if config.isEnabled {
                        Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                        SettingsRow(
                            title: "Global Shortcut",
                            description: "Click Record, then press a modifier and a key (e.g. ⌥Space).",
                            theme: theme
                        ) {
                            HStack(spacing: 8) {
                                HotkeyRecorderView(
                                    currentDescription: config.shortcutDescription,
                                    onRecorded: { code, mods in
                                        config.setShortcut(carbonKeyCode: code, carbonModifiers: mods)
                                        AppDelegate.shared.applyHotkeyConfig()
                                    },
                                    // Pause the live global hotkey while the recorder is armed, so pressing the current combo to re-record it
                                    // is captured here instead of summoning the panel.
                                    onRecordingStateChanged: { recording in
                                        AppDelegate.shared?.setHotkeyPaused(recording)
                                    }
                                )

                                TactileIconButton(
                                    icon: "arrow.counterclockwise",
                                    tooltip: "Reset to ⌥Space"
                                ) {
                                    config.resetShortcutToDefault()
                                    AppDelegate.shared.applyHotkeyConfig()
                                }
                            }
                        }
                    }
                }

                if config.isEnabled {
                    // MARK: Default profile
                    SettingsCard(title: "Default Profile", icon: "person.crop.circle", theme: theme) {
                        SettingsRow(
                            title: "Profile",
                            description: "The chat profile new Quick Access conversations use. Only Bots and Agents can be chosen.",
                            theme: theme
                        ) {
                            BackendPickerButton(
                                profileThemeColor: selectedProfile?.profileType.displayColor ?? theme.secondaryText,
                                profileButtonText: selectedProfile?.displayName ?? "Choose profile",
                                backendConfiguration: profileConfig,
                                allowedProfileTypes: QuickAccessSessionViewModel.allowedProfileTypes,
                                showingPopup: $showingProfilePopup
                            )
                            .onChange(of: profileConfig.selectedProfileID) { _, newID in
                                if let id = newID {
                                    UserDefaults.standard.set(id.uuidString, forKey: GlobalConstants.quickAccessProfileID)
                                }
                            }
                        }
                    }

                    // MARK: Behavior
                    SettingsCard(title: "Behavior", icon: "clock.arrow.circlepath", theme: theme) {
                        SettingsRow(
                            title: "Session Timeout",
                            description: "Reopening within this window resumes your last Quick Access conversation; after it, a fresh one starts.",
                            theme: theme
                        ) {
                            Picker("", selection: timeoutBinding) {
                                ForEach(timeoutOptions, id: \.self) { seconds in
                                    Text(seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min").tag(seconds)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }
                    }
                }
            }
            .padding(24)
            .animation(.default, value: config.isEnabled)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .onAppear {
            profileConfig.selectedProfileID = UserDefaults.standard
                .string(forKey: GlobalConstants.quickAccessProfileID)
                .flatMap(UUID.init)
        }
    }

    // MARK: - Bindings & helpers

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { config.isEnabled },
            set: { newValue in
                withAnimation {
                    config.isEnabled = newValue
                }
                AppDelegate.shared.applyHotkeyConfig()
            }
        )
    }

    private var timeoutBinding: Binding<Int> {
        Binding(
            get: { config.sessionTimeoutSeconds },
            set: { config.sessionTimeoutSeconds = $0 }
        )
    }

    private var selectedProfile: BackendProfileModel? {
        guard let id = profileConfig.selectedProfileID else { return nil }
        return try? BackendProfileStore.shared.fetchProfile(byId: id)
    }
}
