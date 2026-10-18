// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingCompletion.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "OnboardingCompletion")

/// What the app does when the Setup Assistant closes: reloads profiles into `BackendProfileService` and
/// selects the new one. Onboarding saves straight to `BackendProfileStore`, so the service must be
/// told; lives here so a test can run it.
@MainActor
enum OnboardingCompletion {

    /// Re-reads the profile list so the sidebar shows the profile onboarding created, and selects it.
    /// - Parameter createdProfileID: the saved profile, or nil when a re-run was cancelled.
    static func apply(createdProfileID: UUID?,
                      profileService: BackendProfileService,
                      backendConfiguration: BackendConfiguration) {
        profileService.loadProfiles()

        guard let createdProfileID else { return }
        guard profileService.profiles.contains(where: { $0.id == createdProfileID }) else {
            logger.error("[ONBOARDING] Created profile \(createdProfileID) is not in the reloaded list (\(profileService.profiles.count) profile(s); load error: \(profileService.lastLoadError ?? "none")). CONSEQUENCE: it is not selected, and the sidebar may not show it until the list is reloaded.")
            return
        }
        backendConfiguration.selectedProfileID = createdProfileID
        logger.info("[ONBOARDING] Profile list reloaded (\(profileService.profiles.count) profile(s)); selected the new profile \(createdProfileID) for the first chat.")
    }
}
