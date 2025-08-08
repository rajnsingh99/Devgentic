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
    let backendType: BackendType
    let agentID: UUID?
    let integrationID: UUID?
}

@MainActor
final class BackendConfiguration: ObservableObject {
    @Published var selectedBackend: BackendType
    @Published var selectedAgentID: UUID?
    @Published var selectedIntegrationID: UUID?

    private var cancellables = Set<AnyCancellable>()
    private let userDefaultsSelectedBackendKey = "userDefaultsSelectedBackend"
    private let userDefaultsSelectedAgentIDKey = "userDefaultsSelectedAgentID"
    private let userDefaultsSelectedIntegrationIDKey = "userDefaultsSelectedIntegrationID"

    init() {
        // Load initial values from UserDefaults
        let backendRawValue = UserDefaults.standard.string(forKey: userDefaultsSelectedBackendKey)
        self.selectedBackend = BackendType(rawValue: backendRawValue ?? "") ?? .none

        if let agentIDString = UserDefaults.standard.string(forKey: userDefaultsSelectedAgentIDKey) {
            self.selectedAgentID = UUID(uuidString: agentIDString)
        }

        if let integrationIDString = UserDefaults.standard.string(forKey: userDefaultsSelectedIntegrationIDKey) {
            self.selectedIntegrationID = UUID(uuidString: integrationIDString)
        }
        
        logger.info("Initialized with backend: \(self.selectedBackend.rawValue), agent: \(self.selectedAgentID?.uuidString ?? "nil"), integration: \(self.selectedIntegrationID?.uuidString ?? "nil")")

        // Set up persistence pipeline
        setupPersistence()
    }

    private func setupPersistence() {
        $selectedBackend
            .combineLatest($selectedAgentID, $selectedIntegrationID)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] backend, agentId, integrationId in
                guard let self = self else { return }
                
                // When backend changes, ensure only the relevant ID is stored.
                var finalAgentId: UUID? = agentId
                var finalIntegrationId: UUID? = integrationId
                
                switch backend {
                case .agent:
                    finalIntegrationId = nil
                case .ollama, .remote:
                    finalAgentId = nil
                case .none:
                    finalAgentId = nil
                    finalIntegrationId = nil
                }

                UserDefaults.standard.set(backend.rawValue, forKey: self.userDefaultsSelectedBackendKey)
                UserDefaults.standard.set(finalAgentId?.uuidString, forKey: self.userDefaultsSelectedAgentIDKey)
                UserDefaults.standard.set(finalIntegrationId?.uuidString, forKey: self.userDefaultsSelectedIntegrationIDKey)
                
                logger.debug("Persisted backend config to UserDefaults.")
            }
            .store(in: &cancellables)
    }

    // Helper to get an immutable snapshot for requests
    func getRequestConfig() -> BackendRequestConfig {
        return BackendRequestConfig(
            backendType: self.selectedBackend,
            agentID: self.selectedAgentID,
            integrationID: self.selectedIntegrationID
        )
    }
}
