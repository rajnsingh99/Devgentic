//
//  BackendConfiguration.swift
//  Devgentic
//
//  Created by Raj Singh on 05/07/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "BackendConfiguration")

// This struct will be a snapshot of the configuration, passed with each request.
struct BackendRequestConfig {
    let profile: BackendProfileModel
}

@Observable @MainActor
final class BackendConfiguration {
    var selectedProfileID: UUID?

    // Helper to get an immutable snapshot for requests.
    // All interface modes (chat, workflow, code) use selectedProfileID uniformly.
    func getRequestConfig() -> BackendRequestConfig? {
        guard let profileID = selectedProfileID,
              let profile = try? BackendProfileStore.shared.fetchProfile(byId: profileID) else {
            logger.warning("Could not create request config: Profile ID is nil or profile not found in store.")
            return nil
        }
        return BackendRequestConfig(profile: profile)
    }
}
