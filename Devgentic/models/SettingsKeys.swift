// Models/SettingsKeys.swift
import Foundation

// MARK: - UserDefaults Keys (for @AppStorage)
struct SettingsKeys {
    // --- Existing Keys ---
    static let selectedBackend = "selectedBackend"
    static let windowOpacity = "windowOpacity"
    static let llmModelName = "llmModelName"
    static let agentBaseURL = "agentBaseURL"
    static let agentDelegationStrategy = "agentDelegationStrategy"

    // --- New Key for Onboarding ---
    /// Boolean flag indicating if the user has completed the initial setup/onboarding flow.
    static let isOnboardingComplete = "isOnboardingComplete"
}