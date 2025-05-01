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

    // --- New Keys for Ollama Advanced Parameters ---
    /// Temperature: Controls randomness (0.0 to 1.0+)
    static let ollamaTemperature = "ollamaTemperature"
    /// Top K: Limits the sampling pool to the top K tokens
    static let ollamaTopK = "ollamaTopK"
    /// Top P: Limits the sampling pool based on cumulative probability (0.0 to 1.0)
    static let ollamaTopP = "ollamaTopP"
    /// Repeat Penalty: Penalizes repeated tokens (1.0+)
    static let ollamaRepeatPenalty = "ollamaRepeatPenalty"
    /// Context Window Size: Sets the model's context window size
    static let ollamaContextWindowSize = "ollamaContextWindowSize"
    /// Number of GPU Layers: Specifies layers to offload to GPU (-1 for all)
    static let ollamaGpuLayers = "ollamaGpuLayers"

    // You could add other advanced parameters here as needed,
    // e.g., mirostat, mirostat_eta, mirostat_tau, num_predict, etc.
}
