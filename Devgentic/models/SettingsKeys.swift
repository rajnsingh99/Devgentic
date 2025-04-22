// Models/SettingsKeys.swift
import Foundation

// MARK: - UserDefaults Keys (for @AppStorage)
struct SettingsKeys {
    static let selectedBackend = "selectedBackend"
    static let windowOpacity = "windowOpacity"
    static let llmModelName = "llmModelName"
    static let agentBaseURL = "agentBaseURL"
    static let agentDelegationStrategy = "agentDelegationStrategy"
}
