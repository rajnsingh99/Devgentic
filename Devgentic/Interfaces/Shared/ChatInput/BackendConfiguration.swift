//
//  BackendConfiguration.swift
//  Devgentic
//
//  Created by Raj Singh on 27/07/25.
//

import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "BackendConfiguration")

// This struct will be a snapshot of the configuration, passed with each request.
struct BackendRequestConfig {
    let profile: BackendProfileModel
}

@MainActor
final class BackendConfiguration: ObservableObject {
    @Published var selectedProfileID: UUID?

    private var cancellables = Set<AnyCancellable>()
    private let userDefaultsSelectedProfileIDKey = "userDefaultsSelectedProfileIDKey"

    init() {
        // Load initial values from UserDefaults
        if let profileIDString = UserDefaults.standard.string(forKey: userDefaultsSelectedProfileIDKey) {
            self.selectedProfileID = UUID(uuidString: profileIDString)
        }
        
        logger.info("Initialized with selected profile ID: \(self.selectedProfileID?.uuidString ?? "nil")")

        // Set up persistence pipeline
        setupPersistence()
    }

    private func setupPersistence() {
        $selectedProfileID
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] profileId in
                guard let self = self else { return }
                
                UserDefaults.standard.set(profileId?.uuidString, forKey: self.userDefaultsSelectedProfileIDKey)
                
                logger.debug("Persisted selected profile ID to UserDefaults.")
            }
            .store(in: &cancellables)
    }

    // Helper to get an immutable snapshot for requests
    func getRequestConfig() -> BackendRequestConfig? {
        guard let profileID = selectedProfileID,
              let profile = (try? BackendProfileStore.shared.fetchProfiles())?.first(where: { $0.id == profileID }) else {
            logger.warning("Could not create request config: Profile ID is nil or profile not found in store.")
            return nil
        }
        return BackendRequestConfig(profile: profile)
    }
}
