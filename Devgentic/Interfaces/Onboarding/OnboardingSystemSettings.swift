// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingSystemSettings.swift
//  Devgentic
//
//  Everything the Setup Assistant reads or changes OUTSIDE onboarding: macOS privacy permissions,
//  the Quick Access and Orb switches, Sparkle's update-check answer and the diagnostics opt-out.
//
//  ⚠️ Behind a protocol on purpose. The test host is the real app: a test that touched the live
//  implementation would raise real macOS permission prompts, register real global hotkeys and
//  rewrite the developer's own settings (`QuickAccessConfigManager` writes `UserDefaults.standard`).
//  Tests inject a fake; only the app uses `LiveOnboardingSystemSettings`.
//
//  ⚠️ Each switch goes through the SAME path its Settings pane uses (set the flag, then ask
//  AppDelegate to re-register the hotkey), so onboarding cannot leave a state Settings can't.
//

import AppKit
import AVFAudio
import CoreGraphics
import EventKit
import os

private let logger = DGLogger(category: "OnboardingSystemSettings")

// MARK: - Permissions

/// A macOS privacy permission the Setup Assistant can ask for. Every one is optional.
enum OnboardingPermission: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case calendar
    case reminders
    case screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return String(localized: "Microphone")
        case .calendar: return String(localized: "Calendar")
        case .reminders: return String(localized: "Reminders")
        case .screenRecording: return String(localized: "Screen Recording")
        }
    }

    var iconName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .screenRecording: return "rectangle.dashed.badge.record"
        }
    }

    /// The System Settings pane where the user can change their answer.
    var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .calendar: pane = "Privacy_Calendars"
        case .reminders: pane = "Privacy_Reminders"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

enum OnboardingPermissionStatus: Equatable, Sendable {
    /// macOS has not asked yet. Asking shows the system prompt.
    case notAsked
    case granted
    /// Refused or restricted. macOS will not ask again; only System Settings can change it.
    case denied
}

// MARK: - The seam

@MainActor
protocol OnboardingSystemSettings: AnyObject {
    var quickAccessEnabled: Bool { get set }
    var orbEnabled: Bool { get set }

    /// Sparkle's stored answer, or nil if the user has never been asked.
    var automaticUpdateChecks: Bool? { get }
    func setAutomaticUpdateChecks(_ enabled: Bool)

    var diagnosticsEnabled: Bool { get set }

    func status(of permission: OnboardingPermission) -> OnboardingPermissionStatus
    func request(_ permission: OnboardingPermission) async -> OnboardingPermissionStatus
    func openSystemSettings(for permission: OnboardingPermission)

    /// Free space, in bytes, on the volume a model for this engine downloads to — the space macOS
    /// counts as available for important data (purgeable caches included). Nil when it cannot be
    /// read; the caller then does not block a download on a guess.
    func availableDiskBytes(for backend: ApiProvider) -> Int64?
}

// MARK: - Live implementation

@MainActor
final class LiveOnboardingSystemSettings: OnboardingSystemSettings {

    /// The key Sparkle writes when the user answers "check automatically?". Absent until then —
    /// Info.plist deliberately leaves `SUEnableAutomaticChecks` out (see `SoftwareUpdater`).
    static let sparkleAutomaticChecksKey = "SUEnableAutomaticChecks"

    var quickAccessEnabled: Bool {
        get { QuickAccessConfigManager.shared.isEnabled }
        set {
            QuickAccessConfigManager.shared.isEnabled = newValue
            AppDelegate.shared?.applyHotkeyConfig()
            logger.info("[ONBOARDING] Quick Access \(newValue ? "enabled" : "disabled") (\(QuickAccessConfigManager.shared.shortcutDescription)).")
        }
    }

    var orbEnabled: Bool {
        get { OrbConfigManager.shared.isEnabled }
        set {
            OrbConfigManager.shared.isEnabled = newValue
            AppDelegate.shared?.applyOrbHotkeyConfig()
            logger.info("[ONBOARDING] Orb \(newValue ? "enabled" : "disabled"). Microphone is asked on the Permissions step, not here.")
        }
    }

    var automaticUpdateChecks: Bool? {
        UserDefaults.standard.object(forKey: Self.sparkleAutomaticChecksKey) as? Bool
    }

    func setAutomaticUpdateChecks(_ enabled: Bool) {
        SoftwareUpdater.shared.automaticallyChecksForUpdates = enabled
        logger.info("[ONBOARDING] Automatic update checks \(enabled ? "ON" : "OFF") — answered during setup, so Sparkle will not ask again.")
    }

    var diagnosticsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: AppSettings.diagnosticsEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: AppSettings.diagnosticsEnabledKey) }
    }

    func status(of permission: OnboardingPermission) -> OnboardingPermissionStatus {
        switch permission {
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .notAsked
            @unknown default: return .notAsked
            }
        case .calendar:
            return Self.eventKitStatus(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return Self.eventKitStatus(EKEventStore.authorizationStatus(for: .reminder))
        case .screenRecording:
            // macOS exposes only "granted or not". Not-granted reads as not asked; a refused
            // request is reported as denied by `request`, for the rest of this setup.
            return CGPreflightScreenCaptureAccess() ? .granted : .notAsked
        }
    }

    func request(_ permission: OnboardingPermission) async -> OnboardingPermissionStatus {
        switch permission {
        case .microphone:
            _ = await AVAudioApplication.requestRecordPermission()
        case .calendar:
            do { _ = try await EKEventStore().requestFullAccessToEvents() } catch {
                logger.error("[ONBOARDING] Calendar access request failed: \(error.localizedDescription). CONSEQUENCE: the row shows the current status; the agent asks again when it first uses the calendar.")
            }
        case .reminders:
            do { _ = try await EKEventStore().requestFullAccessToReminders() } catch {
                logger.error("[ONBOARDING] Reminders access request failed: \(error.localizedDescription). CONSEQUENCE: the row shows the current status; the agent asks again when it first uses reminders.")
            }
        case .screenRecording:
            // Same call Quick Access makes. A grant takes effect only after relaunch.
            let state = QuickAccessScreenCaptureService.ensurePermission()
            return state == .granted ? .granted : .denied
        }
        let result = status(of: permission)
        logger.info("[ONBOARDING] \(permission.rawValue) permission after request: \(String(describing: result)).")
        return result
    }

    func openSystemSettings(for permission: OnboardingPermission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    func availableDiskBytes(for backend: ApiProvider) -> Int64? {
        let target: URL?
        switch backend {
        case .mlx:
            // The user can move this folder (`MLXModelsLocation`), e.g. to an external SSD, so the
            // volume that matters is the folder's, not the boot volume.
            target = MLXModelsLocation.effectiveDirectory()
        case .ollama:
            // ⚠️ An estimate. The Ollama SERVER decides where models go (`~/.ollama/models`, or
            // `OLLAMA_MODELS` in its own environment, which this app cannot see).
            target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models")
        default:
            target = nil
        }
        guard let target else { return nil }
        let existing = Self.nearestExistingAncestor(of: target)
        do {
            let values = try existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let important = values.volumeAvailableCapacityForImportantUsage { return important }
            if let plain = values.volumeAvailableCapacity { return Int64(plain) }
        } catch {
            logger.error("[ONBOARDING] Could not read free space at \(existing.path): \(error.localizedDescription). CONSEQUENCE: downloads are not blocked on disk space.")
        }
        return nil
    }

    /// The folder may not exist before the first download; its volume is the nearest existing parent's.
    private static func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    private static func eventKitStatus(_ status: EKAuthorizationStatus) -> OnboardingPermissionStatus {
        switch status {
        case .fullAccess: return .granted
        case .notDetermined: return .notAsked
        // Write-only is not enough: the tools read events and reminders.
        case .denied, .restricted, .writeOnly: return .denied
        @unknown default: return .denied
        }
    }
}
