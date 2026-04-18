//
//  CodeModelPickerButton.swift
//  Devgentic
//
//  Inline model selector for the Code interface.
//  Shows provider + model name in a capsule button; popover for selection.
//  Replaces BackendPickerButton when interfaceMode == .code.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "CodeModelPicker")

struct CodeModelPickerButton: View {

    @Environment(CodeSessionManager.self) private var codeSessionManager
    @Environment(\.appTheme) private var theme

    @State private var isHovering = false

    var body: some View {
        @Bindable var csm = codeSessionManager
        Button(action: { csm.showModelPicker.toggle() }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(codeSessionManager.modelName.isEmpty ? Color.secondary : Color.cyan)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.cyan.opacity(0.4), radius: 2)

                Text(codeSessionManager.modelName.isEmpty
                     ? "Select Model"
                     : codeSessionManager.modelDisplayName)
                    .font(theme.fontSubheadline.weight(.medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.secondaryText.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isHovering ? theme.surfaceOverlay : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(theme.secondaryText.opacity(isHovering ? 0.3 : 0.15), lineWidth: 1)
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hover }
        }
        .popover(isPresented: $csm.showModelPicker, arrowEdge: .bottom) {
            CodeModelSelectorPopover()
                .frame(width: 320, height: 400)
        }
    }
}

// MARK: - Model Selector Popover

/// A model entry with rich metadata and full cognitive profile for routing.
///
/// Note: `supportsThinking` is intentionally NOT tracked here. Code mode is a tool-heavy
/// ReAct loop (read_file → edit_code → …) and extended thinking adds 15–60s per iteration,
/// which turns a 30s task into 5+ minutes. Users who want reasoning should use Chat mode.
private struct CodeModelEntry: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let parameterSize: String?
    let parameterSizeValue: Double
    let cognitiveProfile: CognitiveProfile
    let isEligible: Bool  // .parallelActions + 14B+
}

private struct CodeModelSelectorPopover: View {

    @Environment(CodeSessionManager.self) private var codeSessionManager
    @Environment(\.appTheme) private var theme

    /// Minimum parameter count (in billions) for Code mode.
    private let minimumParameterBillions: Double = 14.0

    @State private var localModels: [CodeModelEntry] = []
    @State private var isLoadingModels = false
    @State private var modelSearchText = ""
    @State private var apiKeyInput = ""
    @State private var cloudModelNameInput = ""

    private var isCloudProvider: Bool {
        [.anthropic, .openAI, .google].contains(codeSessionManager.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Code Model")
                .font(theme.fontHeadline)
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            // Provider Picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CodeSessionManager.supportedProviders, id: \.self) { provider in
                        providerChip(provider)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Divider()

            // Model Selection Area
            if isCloudProvider {
                cloudModelInput
            } else {
                localModelList
            }

            Spacer(minLength: 0)
        }
        .background(theme.primaryBackground)
        .task {
            await loadModelsIfNeeded()
        }
    }

    // MARK: - Provider Chip

    private func providerChip(_ provider: ApiProvider) -> some View {
        let isSelected = codeSessionManager.provider == provider
        let label: String = {
            switch provider {
            case .ollama:    return "Ollama"
            case .mlx:       return "MLX"
            case .anthropic: return "Anthropic"
            case .openAI:    return "OpenAI"
            case .google:    return "Google"
            }
        }()

        return Button(action: {
            codeSessionManager.updateProvider(provider)
            Task { await loadModelsIfNeeded() }
        }) {
            Text(label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : theme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? Color.cyan : theme.controlBackground)
                )
                .overlay(
                    Capsule().stroke(isSelected ? Color.clear : theme.secondaryText.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cloud Model Input

    private var cloudModelInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            // API Key
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
                SecureField("Enter API key...", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onAppear { apiKeyInput = codeSessionManager.apiKey ?? "" }
                    .onChange(of: apiKeyInput) { _, newVal in
                        commitCloudModel()
                    }
            }

            // Model Name
            VStack(alignment: .leading, spacing: 4) {
                Text("Model Name")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
                TextField("e.g. claude-sonnet-4-20250514", text: $cloudModelNameInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onAppear { cloudModelNameInput = codeSessionManager.modelName }
                    .onChange(of: cloudModelNameInput) { _, _ in
                        commitCloudModel()
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Writes the cloud model + API key to the persisted code profile with cloudNative cognitive data.
    private func commitCloudModel() {
        let trimmedModel = cloudModelNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }
        // Cloud providers never use Ollama's `think` parameter — they have their own thinking
        // mechanisms (Anthropic extendedThinking via advancedConfiguration, Gemini thinking_config).
        codeSessionManager.updateModel(
            trimmedModel,
            provider: codeSessionManager.provider,
            cognitiveProfile: .cloudNative,
            apiKey: apiKeyInput.isEmpty ? nil : apiKeyInput,
            baseURL: nil,
            thinkingEnabled: false
        )
    }

    // MARK: - Local Model List

    private var localModelList: some View {
        VStack(spacing: 0) {
            // Search
            TextField("Search models...", text: $modelSearchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            if isLoadingModels {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if eligibleModels.isEmpty {
                VStack(spacing: 6) {
                    Text("No eligible models found")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                    Text("Code mode requires 14B+ models with tool calling support.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(eligibleModels) { entry in
                            modelRow(entry)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// Models filtered to eligible only (parallelActions + 14B+), then by search text.
    private var eligibleModels: [CodeModelEntry] {
        let eligible = localModels.filter { $0.isEligible }
        if modelSearchText.isEmpty { return eligible }
        return eligible.filter { $0.name.localizedCaseInsensitiveContains(modelSearchText) }
    }

    private func modelRow(_ entry: CodeModelEntry) -> some View {
        let isSelected = codeSessionManager.modelName == entry.name
        return Button(action: {
            // Code mode: thinking is always disabled to keep tool-heavy ReAct loops fast.
            // Users who want extended reasoning should use Chat mode.
            codeSessionManager.updateModel(
                entry.name,
                provider: codeSessionManager.provider,
                cognitiveProfile: entry.cognitiveProfile,
                apiKey: nil,
                baseURL: codeSessionManager.baseURL,
                thinkingEnabled: false
            )
        }) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .cyan : theme.secondaryText.opacity(0.4))
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 13))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    if let size = entry.parameterSize {
                        Text(size)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.cyan.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Model Loading

    private func loadModelsIfNeeded() async {
        let provider = codeSessionManager.provider
        guard provider == .ollama || provider == .mlx else {
            localModels = []
            return
        }

        isLoadingModels = true
        defer { isLoadingModels = false }

        do {
            if provider == .ollama {
                localModels = try await fetchOllamaModelsWithDetails()
            } else if provider == .mlx {
                localModels = listDownloadedMLXModels()
            }
            logger.info("Loaded \(localModels.count) models (\(localModels.filter(\.isEligible).count) eligible for Code)")
        } catch {
            logger.error("Failed to fetch models: \(error.localizedDescription)")
            localModels = []
        }
    }

    /// Fetches Ollama models with full details for capability + size filtering.
    private func fetchOllamaModelsWithDetails() async throws -> [CodeModelEntry] {
        let baseURL = codeSessionManager.baseURL ?? "http://localhost:11434"
        let rawNames = try await OllamaConnect.fetchLocalOllamaModels(baseURL: baseURL)

        var entries: [CodeModelEntry] = []
        await withTaskGroup(of: CodeModelEntry?.self) { group in
            for name in rawNames {
                group.addTask {
                    do {
                        let response = try await OllamaConnect.fetchModelDetails(name: name, baseURL: baseURL)
                        let profile = response.cognitiveProfile
                        let paramValue = response.details?.parameterSizeValue ?? 0
                        let isEligible = profile.capability == .parallelActions && paramValue >= 14.0
                        return CodeModelEntry(
                            name: name,
                            parameterSize: response.details?.parameterSize,
                            parameterSizeValue: paramValue,
                            cognitiveProfile: profile,
                            isEligible: isEligible
                        )
                    } catch {
                        return nil
                    }
                }
            }
            for await entry in group {
                if let e = entry { entries.append(e) }
            }
        }

        return entries.sorted { $0.parameterSizeValue > $1.parameterSizeValue }
    }

    /// Lists MLX models from the default HuggingFace cache directory with cognitive detection.
    private func listDownloadedMLXModels() -> [CodeModelEntry] {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil
        ) else { return [] }

        return entries
            .filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("models--") }
            .map { url in
                let name = url.lastPathComponent
                    .replacingOccurrences(of: "models--", with: "")
                    .replacingOccurrences(of: "--", with: "/")

                // Attempt cognitive profile detection from the model's snapshot directory
                let snapshotsDir = url.appendingPathComponent("snapshots")
                let modelPath: URL? = {
                    guard let snapshots = try? FileManager.default.contentsOfDirectory(
                        at: snapshotsDir, includingPropertiesForKeys: nil
                    ) else { return nil }
                    return snapshots.first { $0.hasDirectoryPath }
                }()

                let profile: CognitiveProfile
                if let path = modelPath {
                    profile = MLXTokenizerAnalyzer.detectCognitiveProfile(for: path, modelName: name)
                } else {
                    // Fallback: assume parallel actions with heuristic JSON dialect
                    profile = CognitiveProfile(capability: .parallelActions, dialect: .heuristicJson)
                }

                return CodeModelEntry(
                    name: name,
                    parameterSize: profile.metadata?.parameterCount,
                    parameterSizeValue: 0,
                    cognitiveProfile: profile,
                    isEligible: profile.capability == .parallelActions
                )
            }
            .sorted { $0.name < $1.name }
    }
}
