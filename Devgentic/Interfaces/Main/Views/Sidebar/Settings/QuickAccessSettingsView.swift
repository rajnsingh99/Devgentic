//
//  QuickAccessSettingsView.swift
//  Devgentic
//
//  [QA revival P1d] Settings pane for the QuickAccess floating panel: enable/disable, the
//  configurable global shortcut (via HotkeyRecorderView), a sticky default chat profile, and
//  the session-resume timeout. Reads/writes QuickAccessConfigManager (UserDefaults-backed) and
//  asks AppDelegate to re-register the Carbon hotkey when activation settings change.
//

import SwiftUI

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
            VStack(alignment: .leading, spacing: 22) {
                header

                // MARK: Activation
                SettingsCard(title: "Activation", icon: "command", theme: theme) {
                    SettingsRow(
                        title: "Enable Quick Access",
                        description: "Summon a floating chat panel from anywhere with a global shortcut.",
                        theme: theme
                    ) {
                        Toggle("", isOn: enabledBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider().background(theme.dividerColor.opacity(0.3))

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
                                // [M3] Pause the live global hotkey while the recorder is armed so
                                // pressing the CURRENT combo to re-record it is captured here
                                // instead of summoning the panel over Settings.
                                onRecordingStateChanged: { recording in
                                    AppDelegate.shared?.setHotkeyPaused(recording)
                                }
                            )
                            .disabled(!config.isEnabled)
                            .opacity(config.isEnabled ? 1 : 0.5)

                            Button("Reset") {
                                config.resetShortcutToDefault()
                                AppDelegate.shared.applyHotkeyConfig()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .help("Reset to ⌥Space")
                        }
                    }
                }

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
            .padding(24)
        }
        .background(theme.primaryBackground)
        .onAppear {
            profileConfig.selectedProfileID = UserDefaults.standard
                .string(forKey: GlobalConstants.quickAccessProfileID)
                .flatMap(UUID.init)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick Access")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(theme.primaryText)
            Text("A floating chat panel you can summon over any app.")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
    }

    // MARK: - Bindings & helpers

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { config.isEnabled },
            set: { newValue in
                config.isEnabled = newValue
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
