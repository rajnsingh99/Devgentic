// Services/OllamaService.swift
import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OllamaService")

/// Represents a single, styled tag for a model.
struct ModelTag: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let color: Color
    let icon: String?
}

/// Represents a local model with its name, details, and generated tags.
struct LocalModel: Identifiable, Hashable {
    // FIX: Use the model's unique name as the stable identifier.
    // This prevents SwiftUI from getting confused when the list is refreshed.
    var id: String { name }
    let name: String
    let details: OllamaModelDetails?
    let tags: [ModelTag]

    /// The full cognitive profile (capability + dialect) as detected from the Ollama response.
    let cognitiveProfile: CognitiveProfile

    /// Whether this model supports Ollama's `think` parameter (detected via Option A).
    let supportsThinking: Bool

    /// Convenience accessor for the capability tier (backward compat).
    var cognitiveCapability: ModelCognitiveCapability { cognitiveProfile.capability }

    /// Convenience accessor for the output dialect.
    var modelDialect: ModelDialect { cognitiveProfile.dialect }

    init(name: String, response: OllamaShowResponse) {
        self.name = name
        self.details = response.details
        self.cognitiveProfile = response.cognitiveProfile
        self.supportsThinking = response.supportsThinking
        self.tags = Self.generateTags(from: response)
    }

    /// Generates a list of tags by parsing the model's details and modelfile.
    private static func generateTags(from response: OllamaShowResponse) -> [ModelTag] {
        var generatedTags: [ModelTag] = []
        let details = response.details
        
        // Add quantization level tag
        if let quant = details?.quantizationLevel, !quant.isEmpty {
            generatedTags.append(ModelTag(text: quant, color: .cyan, icon: "dial.medium.fill"))
        }

        // Check native tool capabilities explicitly based on the API response evaluation
        if response.cognitiveCapability != .none {
            generatedTags.append(ModelTag(text: "Tools", color: .orange, icon: "wrench.and.screwdriver.fill"))
        }
        
        let modelfileContent = response.modelfile?.lowercased() ?? ""
        if modelfileContent.contains("vision") || modelfileContent.contains("multimodal") || details?.supportsVision == true {
             generatedTags.append(ModelTag(text: "Vision", color: .purple, icon: "eye.fill"))
        }
        
        if modelfileContent.contains("think") {
            generatedTags.append(ModelTag(text: "Thinking", color: .green, icon: "brain.head.profile"))
        }

        return generatedTags
    }
    
    // Conformance to Hashable and Equatable
    static func == (lhs: LocalModel, rhs: LocalModel) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}


@MainActor // Ensure the entire class runs on the MainActor by default
@Observable
class OllamaService {

    // MARK: - Singleton Pattern
    /// The shared singleton instance of the OllamaService.
    static let shared = OllamaService()

    // MARK: - Published Properties (for Ollama State)
    var serverStatus: OllamaServerStatus = .unknown
    var localModels: [LocalModel] = []
    var isLoadingModels: Bool = false
    var modelLoadingError: String? = nil

    var modelToPull: String = "" // For UI binding
    var isPullingModel: Bool = false
    var pullStatusMessage: String = ""
    var modelPullError: String? = nil
    var pullProgress: Double = 0.0
    var pullStage: String = "" // e.g., "downloading", "verifying"
    var pullTotalBytes: Int64? = nil
    var pullCompletedBytes: Int64? = nil
    var pullErrorRequiresUpdate: Bool = false

    var isRemovingModel: Bool = false
    var removingModelName: String? = nil // To indicate which model is being removed
    var modelRemoveError: String? = nil
    
    // MARK: - Task Management
    private var pullTask: Task<Void, Error>?

    // MARK: - Probe Caching
    /// Tracks when the last failed server check occurred to prevent rapid-fire socket errors.
    private var lastFailedCheckTime: Date? = nil
    private let failedCheckCooldown: TimeInterval = 30

    // MARK: - Configuration Properties
    /// These properties are now set by a central authority (like MainApplicationViewModel) based on the active profile.
    var llmModelName: String = "gemma:2b" // Default, but will be overridden by profile
    var ollamaBaseURL: String = ProviderDefaults.ollamaBaseURL.absoluteString // Default, but will be overridden by profile

    /// The initializer is private to enforce the use of the `shared` singleton instance.
    private init() {
        logger.info("OllamaService singleton initialized.")
    }

    // MARK: - Public Methods for Ollama Management

    func checkServerStatusAndUpdateModels() async {
        guard serverStatus != .checking else { return }

        // Skip re-probing if the last failure was recent and status is still disconnected.
        // This prevents socket error spam when Ollama is not running.
        if serverStatus == .disconnected,
           let lastFailed = lastFailedCheckTime,
           Date().timeIntervalSince(lastFailed) < failedCheckCooldown {
            logger.debug("Skipping Ollama probe — last failure was \(Int(Date().timeIntervalSince(lastFailed)))s ago (cooldown: \(Int(self.failedCheckCooldown))s).")
            return
        }

        serverStatus = .checking
        isLoadingModels = true
        modelLoadingError = nil

        let isConnected = await OllamaConnect.checkOllamaServerStatus(baseURL: ollamaBaseURL)

        if isConnected {
            serverStatus = .connected
            lastFailedCheckTime = nil
            await loadLocalModels()
        } else {
            serverStatus = .disconnected
            lastFailedCheckTime = Date()
            localModels = []
            modelLoadingError = "Cannot connect to Ollama server at \(ollamaBaseURL)."
            isLoadingModels = false
        }
    }

    /// Forces a server check regardless of cooldown. Use for explicit user-triggered refresh actions.
    func forceCheckServerStatus() async {
        lastFailedCheckTime = nil
        await checkServerStatusAndUpdateModels()
    }

    func loadLocalModels() async {
        guard serverStatus == .connected, !isPullingModel, !isRemovingModel else {
            return
        }

        isLoadingModels = true
        modelLoadingError = nil
        
        do {
            let modelNames = try await OllamaConnect.fetchLocalOllamaModels(baseURL: ollamaBaseURL)
            
            var detailedModels: [LocalModel] = []
            
            // Fetch details for each model concurrently
            await withTaskGroup(of: LocalModel?.self) { group in
                for name in modelNames {
                    group.addTask {
                        do {
                            let response = try await OllamaConnect.fetchModelDetails(name: name, baseURL: self.ollamaBaseURL)
                            return LocalModel(name: name, response: response)
                        } catch {
                            logger.error("Failed to fetch details for model \(name): \(error.localizedDescription)")
                            // Even if details fail, we can create a model with no tags
                            let emptyResponse = OllamaShowResponse(license: nil, modelfile: nil, parameters: nil, template: nil, details: nil)
                            return LocalModel(name: name, response: emptyResponse)
                        }
                    }
                }
                
                for await model in group {
                    if let model = model {
                        detailedModels.append(model)
                    }
                }
            }
            
            // Sort the models alphabetically by name
            self.localModels = detailedModels.sorted { $0.name < $1.name }
            
        } catch {
            let errorMessage = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: .ollama)
            self.localModels = []
            self.modelLoadingError = "Failed to load models: \(errorMessage)"
            if let urlError = error as? URLError,
               (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost) {
                self.serverStatus = .disconnected
            }
        }
        isLoadingModels = false
    }

    func pullModel(name: String, baseURL: String) async {
        let trimmedModelName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else { return }
        guard !isPullingModel else { return }
        guard !isRemovingModel else {
            self.modelPullError = "Cannot pull model while another is being removed."
            return
        }
        guard await OllamaConnect.checkOllamaServerStatus(baseURL: baseURL) else {
            self.modelPullError = "Ollama server at \(baseURL) is not connected."
            self.serverStatus = .disconnected
            return
        }
        self.ollamaBaseURL = baseURL

        isPullingModel = true
        pullStatusMessage = "Starting pull for \(trimmedModelName)..."
        modelPullError = nil
        pullProgress = 0.0
        pullStage = "Starting..."
        pullErrorRequiresUpdate = false
        
        pullTask = OllamaConnect.pullOllamaModel(name: trimmedModelName, baseURL: baseURL) { progressUpdate in
            DispatchQueue.main.async {
                self.pullStage = progressUpdate.status
                self.pullTotalBytes = progressUpdate.total
                self.pullCompletedBytes = progressUpdate.completed
                self.pullProgress = progressUpdate.percentage ?? self.pullProgress
                
                if let percentage = progressUpdate.percentage {
                    self.pullStatusMessage = "\(progressUpdate.status.capitalized): \(String(format: "%.0f%%", percentage * 100))"
                } else {
                    self.pullStatusMessage = progressUpdate.status.capitalized
                }

                if let streamedError = progressUpdate.error {
                    self.modelPullError = "Stream Error: \(streamedError)"
                }
            }
        }

        do {
            try await pullTask?.value
            pullStatusMessage = "Successfully pulled \(trimmedModelName)."
            await loadLocalModels()
        } catch is CancellationError {
            pullStatusMessage = "Download cancelled."
            modelPullError = nil
        } catch {
            let rawErrorMessage = error.localizedDescription
            if rawErrorMessage.contains("requires a newer version of Ollama") {
                self.pullErrorRequiresUpdate = true
                self.modelPullError = "This model requires a newer version of Ollama."
            } else {
                self.modelPullError = "Pull failed: \(ErrorHandling.generateUserFriendlyMessage(for: error, backendType: .ollama))"
            }
            pullStatusMessage = "Failed to pull \(trimmedModelName)."
        }
        
        isPullingModel = false
        pullTask = nil
    }

    func cancelPullModel() {
        pullTask?.cancel()
    }

    func removeModel(name: String, baseURL: String) async {
        let trimmedModelName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            self.modelRemoveError = "Model name cannot be empty for removal."
            return
        }
        guard trimmedModelName != self.llmModelName else {
            self.modelRemoveError = "Cannot remove the currently active model. Please select a different model."
            return
        }
        guard self.localModels.contains(where: { $0.name == trimmedModelName }) else {
            self.modelRemoveError = "Model '\(trimmedModelName)' not found in local list."
            return
        }
        guard !isRemovingModel else {
            logger.warning("Already removing a model. Request to remove '\(trimmedModelName)' ignored.")
            return
        }
        guard !isPullingModel else {
            self.modelRemoveError = "Cannot remove model: Another model is currently being pulled."
            return
        }
        guard await OllamaConnect.checkOllamaServerStatus(baseURL: baseURL) else {
            self.modelRemoveError = "Cannot remove model: Ollama server at \(baseURL) is not connected."
            logger.warning("Remove model attempt failed: \(self.modelRemoveError!)")
            self.serverStatus = .disconnected
            return
        }
        self.ollamaBaseURL = baseURL

        isRemovingModel = true
        removingModelName = trimmedModelName
        modelRemoveError = nil
        logger.info("Attempting to remove model: \(trimmedModelName) from \(baseURL).")

        do {
            try await OllamaConnect.removeOllamaModel(name: trimmedModelName, baseURL: baseURL)
            logger.info("Model \(trimmedModelName) removed successfully.")
            
            // FIX: Directly remove the model from the local array to ensure the UI updates instantly.
            // This is more efficient and reliable than reloading all models from the server.
            localModels.removeAll { $0.name == trimmedModelName }
            
            self.removingModelName = nil
        } catch {
            let errorMessage = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: .ollama)
            self.modelRemoveError = "Removal of '\(trimmedModelName)' failed: \(errorMessage)"
            logger.error("Failed to remove model \(trimmedModelName): \(error.localizedDescription)")
            if let urlError = error as? URLError,
               (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                self.serverStatus = .disconnected
            }
        }
        isRemovingModel = false
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if modelRemoveError == nil {
             clearRemoveActionStatus()
        }
    }
    
    // MARK: - Resource Management
    
    /// Unloads any currently running models from VRAM by checking /api/ps and sending keep_alive: 0.
    /// This ensures that when we switch conversations or close the app, the GPU is freed immediately.
    func unloadModel() async {
        guard let url = URL(string: "\(ollamaBaseURL)/api/ps") else { return }
        
        do {
            // 1. Fetch running models
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Minimal structure to parse /api/ps response
            struct ProcessResponse: Decodable {
                struct Model: Decodable {
                    let name: String
                }
                let models: [ProcessResponse.Model]
            }
            
            let response = try JSONDecoder().decode(ProcessResponse.self, from: data)
            
            if response.models.isEmpty {
                logger.debug("No running models to unload.")
                return
            }
            
            // 2. Unload each found model
            for model in response.models {
                await unloadSpecificModel(name: model.name)
            }
            
        } catch {
            logger.error("Failed to check/unload models: \(error.localizedDescription)")
        }
    }
    
    /// Helper to unload a specific model by name
    private func unloadSpecificModel(name: String) async {
        guard let url = URL(string: "\(ollamaBaseURL)/api/chat") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": name,
            "keep_alive": 0
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (_, _) = try await URLSession.shared.data(for: request)
            logger.info("Model '\(name)' unloaded successfully.")
        } catch {
            logger.error("Failed to unload model '\(name)': \(error.localizedDescription)")
        }
    }
    
    func clearPullActionStatus() {
        pullStatusMessage = ""
        modelPullError = nil
        pullProgress = 0.0
        pullStage = ""
        pullTotalBytes = nil
        pullCompletedBytes = nil
    }

    func clearRemoveActionStatus() {
        modelRemoveError = nil
        removingModelName = nil
    }
    
    func clearAllModelActionStatuses() {
        clearPullActionStatus()
        clearRemoveActionStatus()
    }
}
