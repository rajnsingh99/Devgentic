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

private let logger = DGLogger(category: "CodeModelPicker")

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
                .frame(width: 340, height: 440)
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
    @FocusState private var isSearchFocused: Bool

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
        VStack(alignment: .leading, spacing: 10) {
            // Search Bar at Top (if not cloud provider)
            if !isCloudProvider {
                searchField
                    .padding(.top, 14)
            } else {
                Spacer().frame(height: 6)
            }

            // Provider Picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CodeSessionManager.supportedProviders, id: \.self) { provider in
                        ProviderChipView(
                            provider: provider,
                            isSelected: codeSessionManager.provider == provider,
                            action: {
                                codeSessionManager.updateProvider(provider)
                                Task { await loadModelsIfNeeded() }
                            }
                        )
                    }
                }
                .padding(.horizontal, 14)
            }

            Rectangle()
                .fill(theme.dividerColor.opacity(0.25))
                .frame(height: 1)
                .padding(.horizontal, 10)

            // Model Selection Area
            if isCloudProvider {
                cloudModelInput
            } else {
                localModelList
            }

            Spacer(minLength: 0)
        }
        .onAppear {
            DispatchQueue.main.async { isSearchFocused = true }
        }
        .task {
            await loadModelsIfNeeded()
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isSearchFocused ? Color.cyan : theme.tertiaryText)

            TextField("", text: $modelSearchText)
                .textFieldStyle(.plain)
                .font(theme.fontSubheadline)
                .foregroundColor(theme.primaryText)
                .focused($isSearchFocused)
                .overlay(alignment: .leading) {
                    if modelSearchText.isEmpty {
                        Text("Search models...")
                            .font(theme.fontSubheadline)
                            .foregroundColor(theme.placeholderText)
                            .allowsHitTesting(false)
                    }
                }

            if !modelSearchText.isEmpty {
                Button(action: { modelSearchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceOverlayStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSearchFocused ? Color.cyan.opacity(0.6) : theme.secondaryText.opacity(0.18),
                    lineWidth: 1
                )
        )
        .shadow(color: isSearchFocused ? Color.cyan.opacity(0.2) : Color.black.opacity(0.1), radius: 4)
        .padding(.horizontal, 14)
    }

    // MARK: - Cloud Model Input

    private var cloudModelInput: some View {
        VStack(alignment: .leading, spacing: 14) {
            // API Key
            VStack(alignment: .leading, spacing: 5) {
                Text("API Key")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.secondaryText)
                SecureField("Enter API key...", text: $apiKeyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceOverlayStrong))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.secondaryText.opacity(0.2), lineWidth: 1))
                    .onAppear { apiKeyInput = codeSessionManager.apiKey ?? "" }
                    .onChange(of: apiKeyInput) { _, _ in
                        commitCloudModel()
                    }
            }

            // Model Name
            VStack(alignment: .leading, spacing: 5) {
                Text("Model Name")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.secondaryText)
                TextField("e.g. claude-sonnet-4-20250514", text: $cloudModelNameInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceOverlayStrong))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.secondaryText.opacity(0.2), lineWidth: 1))
                    .onAppear { cloudModelNameInput = codeSessionManager.modelName }
                    .onChange(of: cloudModelNameInput) { _, _ in
                        commitCloudModel()
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Writes the cloud model + API key to the persisted code profile with cloudNative cognitive data.
    private func commitCloudModel() {
        let trimmedModel = cloudModelNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }
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
        VStack(spacing: 8) {
            if isLoadingModels {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if eligibleModels.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 24))
                        .foregroundColor(theme.tertiaryText)
                    Text("No eligible models found")
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.secondaryText)
                    Text("Code mode requires 14B+ models with tool calling support.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: true) {
                    LazyVStack(spacing: 6) {
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
        CodeModelRow(
            entry: entry,
            isSelected: codeSessionManager.modelName == entry.name,
            onSelect: {
                codeSessionManager.updateModel(
                    entry.name,
                    provider: codeSessionManager.provider,
                    cognitiveProfile: entry.cognitiveProfile,
                    apiKey: nil,
                    baseURL: codeSessionManager.baseURL,
                    thinkingEnabled: false
                )
            }
        )
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

// MARK: - Provider Chip Component

private struct ProviderChipView: View {
    let provider: ApiProvider
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    private var label: String {
        switch provider {
        case .ollama:           return "Ollama"
        case .mlx:              return "MLX"
        case .anthropic:        return "Anthropic"
        case .openAI:           return "OpenAI"
        case .google:           return "Google"
        case .openRouter:       return "OpenRouter"
        case .openAICompatible: return "Custom"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isSelected {
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 6, height: 6)
                        .shadow(color: Color.cyan.opacity(0.8), radius: 3)
                }
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.cyan.opacity(0.18) : (isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.cyan.opacity(0.65) : (isHovered ? theme.secondaryText.opacity(0.3) : Color.clear),
                        lineWidth: 1
                    )
            )
            .shadow(color: isSelected ? Color.cyan.opacity(0.25) : .clear, radius: 4)
            .scaleEffect(isHovered ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = h }
        }
    }
}

// MARK: - Model Row Component

private struct CodeModelRow: View {
    let entry: CodeModelEntry
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.cyan.opacity(0.2) : (isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay))
                        .frame(width: 24, height: 24)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: isSelected ? .bold : .regular))
                        .foregroundColor(isSelected ? Color.cyan : theme.secondaryText.opacity(0.4))
                        .shadow(color: isSelected ? Color.cyan.opacity(0.6) : .clear, radius: 4)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let size = entry.parameterSize {
                        Text(size)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                    }
                }

                Spacer(minLength: 4)

                if let size = entry.parameterSize {
                    Text(size)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? Color.cyan : theme.tertiaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(isSelected ? Color.cyan.opacity(0.15) : theme.surfaceOverlayStrong)
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected
                          ? Color.cyan.opacity(0.14)
                          : (isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay.opacity(0.4)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color.cyan.opacity(0.55)
                            : (isHovered ? theme.secondaryText.opacity(0.3) : Color.clear),
                        lineWidth: 1
                    )
            )
            .shadow(color: isSelected ? Color.cyan.opacity(0.2) : (isHovered ? Color.black.opacity(0.15) : .clear), radius: 4, y: 2)
            .scaleEffect(isHovered ? 1.015 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = hover }
        }
    }
}
