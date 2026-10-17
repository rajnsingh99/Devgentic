// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingCompletion.swift
//  Devgentic
//
//  What the app does when the Setup Assistant closes.
//
//  ⚠️ FIELD-OBSERVED (owner, ~2026-09): on a fresh install the profile created in onboarding did
//  NOT appear in the Profiles sidebar — until the user created a second profile, when BOTH
//  appeared at once. Cause: the app-level `BackendProfileService` reads the list ONCE, in its
//  `init` at launch (empty on a first run), and onboarding saves straight to `BackendProfileStore`.
//  Nothing told the service. Creating a profile through the service calls `loadProfiles()` for a
//  new id, which is why both then showed. The service also outlives a re-run of the Setup
//  Assistant, so a re-run had the same gap.
//
//  The fix lives here, not in an inline closure in `DevgenticApp`, so a test can run it.
//

import Foundation
import os

private let logger = DGLogger(category: "OnboardingCompletion")

@MainActor
enum OnboardingCompletion {

    /// Re-reads the profile list so the sidebar shows the profile onboarding created, and selects
    /// it in the composer so the first message goes to it instead of "Select a backend…".
    ///
    /// - Parameter createdProfileID: the profile onboarding saved, or nil when a re-run was
    ///   cancelled (the list is still re-read; the selection is left alone).
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
