// Services/OllamaService.swift
import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OllamaService")

@MainActor // Ensure the entire class runs on the MainActor by default
class OllamaService: ObservableObject {

    // MARK: - Published Properties (for Ollama State)
    @Published var serverStatus: OllamaServerStatus = .unknown
    @Published var localModels: [String] = []
    @Published var isLoadingModels: Bool = false
    @Published var modelLoadingError: String? = nil

    @Published var modelToPull: String = "" // For UI binding
    @Published var isPullingModel: Bool = false
    @Published var pullStatusMessage: String = ""
    @Published var modelPullError: String? = nil
    @Published var pullProgress: Double = 0.0
    @Published var pullStage: String = "" // e.g., "downloading", "verifying"
    @Published var pullTotalBytes: Int64? = nil
    @Published var pullCompletedBytes: Int64? = nil

    @Published var isRemovingModel: Bool = false
    @Published var removingModelName: String? = nil // To indicate which model is being removed
    @Published var modelRemoveError: String? = nil
    
    // MARK: - Modified: llmModelName and ollamaBaseURL are now @Published, not @AppStorage
    // They will be set by MainApplicationViewModel based on the selected OllamaProfile
    @Published var llmModelName: String = "gemma:2b" // Default, but will be overridden by profile
    @Published var ollamaBaseURL: String = "http://localhost:11434" // Default, but will be overridden by profile


    init() {
        logger.info("OllamaService initialized.")
    }

    // MARK: - Public Methods for Ollama Management

    // checkServerStatusAndUpdateModels now uses the internal ollamaBaseURL
    func checkServerStatusAndUpdateModels() async {
        // All @Published updates within this function are now implicitly on MainActor
        // because the class itself is marked @MainActor.
        guard serverStatus != .checking else { return }
        
        logger.info("Checking Ollama server status at \(self.ollamaBaseURL)...")
        serverStatus = .checking
        isLoadingModels = true
        modelLoadingError = nil
        
        let isConnected = await AIConnect.checkOllamaServerStatus(baseURL: ollamaBaseURL)
        
        if isConnected {
            serverStatus = .connected
            logger.info("Ollama server connected. Loading local models.")
            await loadLocalModels()
        } else {
            serverStatus = .disconnected
            localModels = []
            modelLoadingError = "Cannot connect to Ollama server at \(ollamaBaseURL)."
            isLoadingModels = false
            logger.error("Ollama server status check failed: Server not reachable at \(self.ollamaBaseURL).")
        }
    }

    // loadLocalModels now uses the internal ollamaBaseURL
    func loadLocalModels() async {
        // All @Published updates within this function are now implicitly on MainActor.
        guard serverStatus == .connected else {
            logger.warning("Cannot load local models: Ollama server is not connected.")
            localModels = []
            isLoadingModels = false
            return
        }
        guard !isPullingModel && !isRemovingModel else {
            logger.info("Skipping model load: A pull or remove operation is in progress.")
            return
        }

        isLoadingModels = true
        modelLoadingError = nil
        logger.info("Loading local Ollama models from \(self.ollamaBaseURL)...")
        
        do {
            let models = try await AIConnect.fetchLocalOllamaModels(baseURL: ollamaBaseURL)
            self.localModels = models.sorted()
            self.modelLoadingError = nil
            logger.info("Loaded \(self.localModels.count) local Ollama models.")

            // Only update llmModelName if the current one isn't in the list AND there are local models
            if !self.localModels.contains(self.llmModelName) && !self.localModels.isEmpty {
                logger.warning("Currently selected model '\(self.llmModelName)' not found in fetched list. Setting to first available model.")
                self.llmModelName = self.localModels.first!
            } else if self.localModels.isEmpty {
                self.llmModelName = ""
                logger.warning("Local model list is empty. Clearing selected llmModelName.")
            }
        } catch {
            let errorMessage = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: .ollama)
            self.localModels = []
            self.modelLoadingError = "Failed to load models: \(errorMessage)"
            logger.error("Failed to load local Ollama models: \(error.localizedDescription)")
            if let urlError = error as? URLError,
               (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                self.serverStatus = .disconnected
            }
        }
        isLoadingModels = false
    }

    // pullModel now accepts a baseURL parameter
    func pullModel(name: String, baseURL: String) async {
        // All @Published updates within this function are now implicitly on MainActor.
        let trimmedModelName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            self.modelPullError = "Model name cannot be empty."
            return
        }
        guard !isPullingModel else {
            logger.warning("Already pulling a model. Request to pull '\(trimmedModelName)' ignored.")
            return
        }
        guard !isRemovingModel else {
            self.modelPullError = "Cannot pull model: Another model is currently being removed."
            return
        }
        // Use the passed baseURL for the check
        guard await AIConnect.checkOllamaServerStatus(baseURL: baseURL) else {
            self.modelPullError = "Cannot pull model: Ollama server at \(baseURL) is not connected."
            logger.warning("Pull model attempt failed: \(self.modelPullError!)")
            self.serverStatus = .disconnected // Update status if connection failed
            return
        }
        // Ensure ollamaService's internal baseURL matches the one used for the pull
        self.ollamaBaseURL = baseURL

        isPullingModel = true
        self.pullStatusMessage = "Starting pull for \(trimmedModelName)..."
        modelPullError = nil
        pullProgress = 0.0
        pullStage = "Starting..."
        pullTotalBytes = nil
        pullCompletedBytes = nil
        
        logger.info("Attempting to pull model: \(trimmedModelName) with streaming from \(baseURL).")
        
        do {
            try await AIConnect.pullOllamaModel(name: trimmedModelName, baseURL: baseURL) { progressUpdate in
                // The closure is already running on the MainActor because the class is @MainActor
                self.pullStage = progressUpdate.status
                self.pullTotalBytes = progressUpdate.total
                self.pullCompletedBytes = progressUpdate.completed
                self.pullProgress = progressUpdate.percentage ?? 0.0
                
                if let percentage = progressUpdate.percentage {
                    self.pullStatusMessage = "\(progressUpdate.status.capitalized): \(String(format: "%.0f%%", percentage * 100))"
                } else if !progressUpdate.status.isEmpty {
                    self.pullStatusMessage = progressUpdate.status.capitalized
                } else {
                    self.pullStatusMessage = "In progress..."
                }

                if let streamedError = progressUpdate.error {
                    self.modelPullError = "Stream Error: \(streamedError)"
                    logger.error("Received streamed error during pull of '\(trimmedModelName)': \(streamedError).")
                }
            }
            self.pullStatusMessage = "Successfully pulled \(trimmedModelName)."
            self.modelPullError = nil
            self.pullProgress = 1.0
            self.pullStage = "Complete"
            logger.info("Model \(trimmedModelName) pulled successfully.")
            await loadLocalModels() // Reload models for the current ollamaBaseURL
            if self.modelToPull == trimmedModelName { self.modelToPull = "" }

        } catch {
            let errorMessage = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: .ollama)
            self.pullStatusMessage = "Failed to pull \(trimmedModelName)."
            self.modelPullError = "Pull failed: \(errorMessage)"
            self.pullProgress = 0.0
            self.pullStage = "Error"
            logger.error("Failed to pull model \(trimmedModelName): \(error.localizedDescription)")
            if let urlError = error as? URLError,
               (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                self.serverStatus = .disconnected
            }
        }
        isPullingModel = false
        // Delay clearing status to allow user to see final message/error
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds delay
        if modelPullError == nil {
            clearPullActionStatus()
        }
    }

    // removeModel now accepts a baseURL parameter
    func removeModel(name: String, baseURL: String) async {
        // All @Published updates within this function are now implicitly on MainActor.
        let trimmedModelName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            self.modelRemoveError = "Model name cannot be empty for removal."
            return
        }
        guard trimmedModelName != self.llmModelName else {
            self.modelRemoveError = "Cannot remove the currently active model. Please select a different model first."
            return
        }
        guard self.localModels.contains(trimmedModelName) else {
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
        // Use the passed baseURL for the check
        guard await AIConnect.checkOllamaServerStatus(baseURL: baseURL) else {
            self.modelRemoveError = "Cannot remove model: Ollama server at \(baseURL) is not connected."
            logger.warning("Remove model attempt failed: \(self.modelRemoveError!)")
            self.serverStatus = .disconnected // Update status if connection failed
            return
        }
        // Ensure ollamaService's internal baseURL matches the one used for the remove
        self.ollamaBaseURL = baseURL


        isRemovingModel = true
        removingModelName = trimmedModelName
        modelRemoveError = nil
        logger.info("Attempting to remove model: \(trimmedModelName) from \(baseURL).")

        do {
            try await AIConnect.removeOllamaModel(name: trimmedModelName, baseURL: baseURL)
            logger.info("Model \(trimmedModelName) removed successfully.")
            await loadLocalModels() // Reload models for the current ollamaBaseURL
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
        // Delay clearing status to allow user to see final message/error
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
        if modelRemoveError == nil {
             clearRemoveActionStatus()
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
