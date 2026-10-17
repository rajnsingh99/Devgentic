// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FakeOnboardingSystemSettings.swift
//  DevgenticTests
//
//  Stands in for `LiveOnboardingSystemSettings`, which would raise real macOS permission prompts,
//  register real global hotkeys and rewrite the developer's settings from inside the test host.
//  Every onboarding test builds its view model with this.
//

import Foundation
@testable import devgentic

@MainActor
final class FakeOnboardingSystemSettings: OnboardingSystemSettings {
    var quickAccessEnabled: Bool = true
    var orbEnabled: Bool = false
    var automaticUpdateChecks: Bool? = nil
    var diagnosticsEnabled: Bool = true

    var statuses: [OnboardingPermission: OnboardingPermissionStatus] = [:]
    /// What `request` returns; `statuses` is left alone so a test can model macOS reporting
    /// "not asked" after a refusal (Screen Recording).
    var requestResults: [OnboardingPermission: OnboardingPermissionStatus] = [:]

    private(set) var updateAnswersSet: [Bool] = []
    private(set) var requested: [OnboardingPermission] = []
    private(set) var openedSettings: [OnboardingPermission] = []

    func setAutomaticUpdateChecks(_ enabled: Bool) {
        updateAnswersSet.append(enabled)
        automaticUpdateChecks = enabled
    }

    func status(of permission: OnboardingPermission) -> OnboardingPermissionStatus {
        statuses[permission] ?? .notAsked
    }

    func request(_ permission: OnboardingPermission) async -> OnboardingPermissionStatus {
        requested.append(permission)
        return requestResults[permission] ?? .granted
    }

    func openSystemSettings(for permission: OnboardingPermission) {
        openedSettings.append(permission)
    }

    /// Free space per engine. Unset = unknown (nil), which must never block a download.
    var availableBytes: [ApiProvider: Int64] = [:]
    func availableDiskBytes(for backend: ApiProvider) -> Int64? { availableBytes[backend] }
}
