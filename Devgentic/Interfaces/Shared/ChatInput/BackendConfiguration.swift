// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackendConfiguration.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = DGLogger(category: "BackendConfiguration")

// This struct will be a snapshot of the configuration, passed with each request.
struct BackendRequestConfig {
    let profile: BackendProfileModel
}

/// Why a send could not be configured: no profile selected, profile not found, or the store failed.
/// Each has a different remedy, and the caller uses the case to decide whether to clear a stale selection.
enum BackendConfigUnavailability: Error, Equatable {
    /// Nothing is selected. The composer's own gate normally prevents this.
    case noProfileSelected
    /// A profile IS selected and the store answered cleanly that it is gone — deleted, most likely
    /// from the sidebar, while the composer kept pointing at it.
    case profileDeleted(UUID)
    /// The store threw; the profile may be fine. Never treat this as deletion or clear the selection over a transient fault.
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

    /// The same resolution as `getRequestConfig()`, but reporting why it failed.
    /// Use it where the failure is user-visible; `getRequestConfig()` is for callers that only need config or nothing.
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
            // A store failure is not "profile not found": one means the profile is gone, the other that the read failed,
            // and acting on the wrong one discards a valid selection.
            logger.error(
                "[PERSISTENCE] Cannot build a request config: the store failed to read profile "
                + "\(profileID): \(error.localizedDescription). CONSEQUENCE: the send is refused "
                + "for this attempt; the selection is KEPT because the profile may be intact."
            )
            return .failure(.storeUnavailable(profileID, error.localizedDescription))
        }
    }
}
