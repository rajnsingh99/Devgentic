// Services/OllamaService.swift
import SwiftUI
import Combine
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

    init(name: String, response: OllamaShowResponse) {
        self.name = name
        self.details = response.details
        self.tags = Self.generateTags(from: response)
    }

    /// Generates a list of tags by parsing the model's details and modelfile.
    private static func generateTags(from response: OllamaShowResponse) -> [ModelTag] {
        var generatedTags: [ModelTag] = []
        let details = response.details
        let modelfileContent = response.modelfile?.lowercased() ?? ""

        // REMOVED: Parameter size tag was removed to declutter the UI.
        // if let size = details?.parameterSize, !size.isEmpty {
        //     generatedTags.append(ModelTag(text: size, color: .gray, icon: "scalemass.fill"))
        // }

        // REMOVED: Family tags were removed to declutter the UI.
        // if let families = details?.families, !families.isEmpty {
        //     for family in families {
        //          generatedTags.append(ModelTag(text: family, color: .blue, icon: "person.2.fill"))
        //     }
        // } else if let family = details?.family, !family.isEmpty {
        //      generatedTags.append(ModelTag(text: family, color: .blue, icon: "person.2.fill"))
        // }
        
        // Add quantization level tag
        if let quant = details?.quantizationLevel, !quant.isEmpty {
            generatedTags.append(ModelTag(text: quant, color: .cyan, icon: "dial.medium.fill"))
        }

        // Check modelfile content for capability keywords
        if modelfileContent.contains("tool") || modelfileContent.contains("function") {
            generatedTags.append(ModelTag(text: "Tools", color: .orange, icon: "wrench.and.screwdriver.fill"))
        }
        
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
class OllamaService: ObservableObject {

    // MARK: - Singleton Pattern
    /// The shared singleton instance of the OllamaService.
    static let shared = OllamaService()

    // MARK: - Published Properties (for Ollama State)
    @Published var serverStatus: OllamaServerStatus = .unknown
    @Published var localModels: [LocalModel] = []
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
    @Published var pullErrorRequiresUpdate: Bool = false

    @Published var isRemovingModel: Bool = false
    @Published var removingModelName: String? = nil // To indicate which model is being removed
    @Published var modelRemoveError: String? = nil
    
    // MARK: - Task Management
    private var pullTask: Task<Void, Error>?

    // MARK: - Configuration Properties
    /// These properties are now set by a central authority (like MainApplicationViewModel) based on the active profile.
    @Published var llmModelName: String = "gemma:2b" // Default, but will be overridden by profile
    @Published var ollamaBaseURL: String = "http://localhost:11434" // Default, but will be overridden by profile

    /// The initializer is private to enforce the use of the `shared` singleton instance.
    private init() {
        logger.info("OllamaService singleton initialized.")
    }

    // MARK: - Public Methods for Ollama Management

    func checkServerStatusAndUpdateModels() async {
        guard serverStatus != .checking else { return }
        
        serverStatus = .checking
        isLoadingModels = true
        modelLoadingError = nil
        
        let isConnected = await OllamaConnect.checkOllamaServerStatus(baseURL: ollamaBaseURL)
        
        if isConnected {
            serverStatus = .connected
            await loadLocalModels()
        } else {
            serverStatus = .disconnected
            localModels = []
            modelLoadingError = "Cannot connect to Ollama server at \(ollamaBaseURL)."
            isLoadingModels = false
        }
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
