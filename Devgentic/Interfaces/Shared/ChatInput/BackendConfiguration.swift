// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackendConfiguration.swift
//  Devgentic
//
//  Created by Raj Singh on 05/07/25.
//

import SwiftUI
import os

private let logger = DGLogger(category: "BackendConfiguration")

// This struct will be a snapshot of the configuration, passed with each request.
struct BackendRequestConfig {
    let profile: BackendProfileModel
}

/// Why a send could not be configured. The three cases used to collapse into one nil and one log
/// line reading "Profile ID is nil or profile not found in store", which is three different
/// problems with three different remedies — and the caller could not tell them apart to say
/// anything useful, or to decide whether the stale selection should be cleared.
enum BackendConfigUnavailability: Error, Equatable {
    /// Nothing is selected. The composer's own gate normally prevents this.
    case noProfileSelected
    /// A profile IS selected and the store answered cleanly that it is gone — deleted, most likely
    /// from the sidebar, while the composer kept pointing at it.
    case profileDeleted(UUID)
    /// The store threw. ⚠️ The profile may be perfectly fine; the read failed. Never treat this as
    /// deletion — clearing the selection here would destroy a valid choice over a transient fault.
    case storeUnavailable(UUID, String)

    var isTransient: Bool {
        if case .storeUnavailable = self { return true }
        return false
    }
}

@Observable @MainActor
final class BackendConfiguration {
    var selectedProfileID: UUID?

    // Helper to get an immutable snapshot for requests.
    // All interface modes (chat, workflow, code) use selectedProfileID uniformly.
    func getRequestConfig() -> BackendRequestConfig? {
        try? resolveRequestConfig().get()
    }

    /// The same resolution as `getRequestConfig()`, but saying *why* it failed.
    ///
    /// Use this wherever the failure is user-visible; `getRequestConfig()` remains for callers that
    /// genuinely only need "config or nothing" (background/scheduled paths).
    func resolveRequestConfig() -> Result<BackendRequestConfig, BackendConfigUnavailability> {
        guard let profileID = selectedProfileID else {
            logger.warning(
                "[PROFILE] Cannot build a request config: no profile is selected. "
                + "CONSEQUENCE: the send is refused and the backend picker is offered."
            )
            return .failure(.noProfileSelected)
        }

        do {
            guard let profile = try BackendProfileStore.shared.fetchProfile(byId: profileID) else {
                logger.warning(
                    "[PROFILE] Cannot build a request config: profile \(profileID) is selected but "
                    + "no longer in the store — it was almost certainly deleted while the composer "
                    + "still pointed at it. CONSEQUENCE: the send is refused, the stale selection "
                    + "is cleared, and the backend picker is offered."
                )
                return .failure(.profileDeleted(profileID))
            }
            return .success(BackendRequestConfig(profile: profile))
        } catch {
            // ⚠️ This arm was `try?`, so a store failure was reported — and treated — as "profile
            // not found". They are opposites: one means the profile is gone, the other means we
            // could not look. Acting on the wrong one discards a valid selection.
            logger.error(
                "[PERSISTENCE] Cannot build a request config: the store failed to read profile "
                + "\(profileID): \(error.localizedDescription). CONSEQUENCE: the send is refused "
                + "for this attempt; the selection is KEPT because the profile may be intact."
            )
            return .failure(.storeUnavailable(profileID, error.localizedDescription))
        }
    }
}
