// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeModelPickerButton.swift
//  Devgentic
//
//  Inline model selector for the Code interface.
//  Shows provider + model name in a capsule button; popover for selection.
//  Replaces BackendPickerButton when interfaceMode == .code.
//  Styled with complete parity and alignment to BackendPickerButton and ProfileSelectorPopover.
//

import SwiftUI
import AppKit
import os

private let logger = DGLogger(category: "CodeModelPicker")

struct CodeModelPickerButton: View {

    @Environment(CodeSessionManager.self) private var codeSessionManager
    @Environment(\.appTheme) private var theme

    @State private var isHovering = false

    private var profileThemeColor: Color {
        codeSessionManager.modelName.isEmpty ? Color.secondary : ProfileType.code.displayColor
    }

    private var profileButtonText: String {
        codeSessionManager.modelName.isEmpty
            ? String(localized: "Select Model")
            : codeSessionManager.modelDisplayName
    }

    var body: some View {
        @Bindable var csm = codeSessionManager
        Button(action: { csm.showModelPicker.toggle() }) {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(profileThemeColor.opacity(0.18))
                        .frame(width: 12, height: 12)
                    Circle()
                        .fill(profileThemeColor)
                        .frame(width: 6.5, height: 6.5)
                }

                Text(profileButtonText)
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(theme.secondaryText.opacity(isHovering ? 0.9 : 0.65))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isHovering ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isHovering
                            ? theme.dividerColor.opacity(0.55)
                            : theme.dividerColor.opacity(0.30),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $csm.showModelPicker, arrowEdge: .bottom) {
            CodeModelSelectorPopover()
                .frame(width: 356, height: 460)
                .environment(\.appTheme, theme)
                .tint(theme.accentColor)
                .preferredColorScheme(theme.colorScheme)
        }
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hover }
        }
        .help(codeSessionManager.modelName.isEmpty
              ? String(localized: "Select a model for Code mode")
              : "\(codeSessionManager.modelDisplayName) (\(codeSessionManager.provider.rawValue.capitalized))")
        .accessibilityLabel("\(profileButtonText). Select a model for Code mode")
    }
}

// MARK: - Model Selector Popover

/// A model entry with rich metadata and full cognitive profile for routing.
///
/// `supportsThinking` is TRACKED but not acted on: Code mode still selects models with
/// `thinkingEnabled: false`, because a tool-heavy ReAct loop (read_file → edit_code → …) pays the
/// extended-thinking cost once per ITERATION, and 15–60 s × 20 iterations turns a 30 s task into
/// minutes. That default stands.
///
/// ⚠️ What changed: the flag used to be untracked, so detection's answer was discarded at the
/// point of selection and nothing downstream could tell a thinking-capable model from one that
/// cannot think at all. That made the cost/benefit un-offerable — there was no way to expose a
/// toggle, and no record that the choice had been made. The old note here also advised users who
/// want reasoning to "use Chat mode", which is not a real alternative: Chat cannot reach the nine
/// `.codeOnly` tools, so the suggestion trades reasoning for the ability to edit files.
/// ⚠️ Deliberately INTERNAL, not private: `CodeModelListing.ordered` is the reachability seam
/// `CodeModelPickerReachabilityTests` exercises, and a private entry type would put it out of
/// reach of the one test that stops a size filter coming back.
struct CodeModelEntry: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let parameterSize: String?
    let parameterSizeValue: Double
    let cognitiveProfile: CognitiveProfile

    /// Whether detection says this model can use extended thinking. Recorded so the choice to
    /// leave it off is visible and can be offered as a setting; never used to filter or rank.
    let supportsThinking: Bool

    /// Detected tool-calling tier. NOT a gate — `.singleAction` runs fine in Code mode via the
    /// Markdown/ReAct generator, and even `.none` now proceeds with a warning rather than a refusal.
    var capability: ModelCognitiveCapability { cognitiveProfile.capability }

    /// Display order only — nothing is ever removed from the list.
    /// 0 = parallel tool calling confirmed · 1 = not confirmed (still selectable; the runtime
    /// warns and proceeds).
    ///
    /// ⚠️⚠️ Parameter count is NOT a term here any more. A 14B floor used to rank — and, until
    /// this change, FILTER — and it was the wrong measure twice over: it is a proxy for quality
    /// that gets worse every model generation (a 7B coder routinely out-edits a 70B generalist),
    /// and it was applied to exactly one of four providers (Ollama only; MLX passed `nil`, cloud
    /// never built an entry). Size is still SHOWN, as a neutral pill, because it is a fact about
    /// the model. It is no longer a judgement about it.
    var rank: Int {
        capability != .parallelActions ? 1 : 0
    }

    /// Short caveat shown on the row, or nil when nothing needs saying.
    var caveatNote: String? {
        guard capability != .parallelActions else { return nil }
        return ProfileCapabilityFilter.toolCapabilityNote(
            capability: capability,
            caveat: cognitiveProfile.toolSupportCaveat,
            profileType: .agent
        ) ?? "⚠︎ Single-action tools"
    }
}

private struct CodeModelSelectorPopover: View {

    @Environment(CodeSessionManager.self) private var codeSessionManager
    @Environment(\.appTheme) private var theme
    @FocusState private var isSearchFocused: Bool

    /// Popover dimensions: aligned with ProfileSelectorPopover (356x460).
    private let popoverWidth: CGFloat = 356
    private let popoverHeight: CGFloat = 460

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
            // Provider Segment Row at Top
            providerSegmentRow
                .padding(.bottom, 6)

            // Search Bar (for local providers)
            if !isCloudProvider {
                searchField
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }

            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.07))
                .frame(height: 1)
                .padding(.horizontal, 8)

            // Content Area
            if isCloudProvider {
                cloudModelInput
            } else {
                localModelList
            }
        }
        .padding(.vertical, 8)
        .frame(width: popoverWidth, height: popoverHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.isDark ? Color(hex: "#1E1E20") : Color(hex: "#F8F8F9"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            DispatchQueue.main.async { isSearchFocused = true }
        }
        .task {
            await loadModelsIfNeeded()
        }
    }

    // MARK: - Provider Segment Row

    private var providerSegmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(CodeSessionManager.supportedProviders, id: \.self) { provider in
                    CodeSegmentTabButton(
                        title: providerDisplayName(provider),
                        count: modelCount(for: provider),
                        isSelected: codeSessionManager.provider == provider
                    ) {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        codeSessionManager.updateProvider(provider)
                        Task { await loadModelsIfNeeded() }
                    }
                }
            }
            .padding(2.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 8)
    }

    private func providerDisplayName(_ provider: ApiProvider) -> String {
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

    private func modelCount(for provider: ApiProvider) -> Int? {
        guard provider == codeSessionManager.provider else { return nil }
        guard provider == .ollama || provider == .mlx else { return nil }
        return listedModels.count
    }

    // MARK: - Search Field

    private var searchBorderColor: Color {
        if isSearchFocused {
            return theme.isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.15)
        } else {
            return theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.06)
        }
    }

    private var searchIconColor: Color {
        if isSearchFocused {
            return theme.isDark ? Color.white.opacity(0.7) : Color.black.opacity(0.6)
        } else {
            return theme.tertiaryText
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(searchIconColor)

            TextField("", text: $modelSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .focused($isSearchFocused)
                .overlay(alignment: .leading) {
                    if modelSearchText.isEmpty {
                        Text("Search models...")
                            .font(.system(size: 12))
                            .foregroundColor(theme.placeholderText)
                            .allowsHitTesting(false)
                    }
                }

            if !modelSearchText.isEmpty {
                Button(action: { modelSearchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(searchBorderColor, lineWidth: 1)
        )
    }

    // MARK: - Cloud Model Input

    private var cloudModelInput: some View {
        ScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                cloudProviderHeader
                cloudApiKeyField
                cloudModelNameField
                cloudModelSuggestionsView
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cloudProviderHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.cyan)
                .frame(width: 6, height: 6)
            Text(providerDisplayName(codeSessionManager.provider))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
            if codeSessionManager.isConfigured && !codeSessionManager.modelName.isEmpty {
                Text("Configured")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.15))
                    )
            }
        }
        .padding(.top, 4)
    }

    private var cloudApiKeyField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("API Key")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            SecureField("Enter \(providerDisplayName(codeSessionManager.provider)) API key...", text: $apiKeyInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.06), lineWidth: 1)
                )
                .onAppear { apiKeyInput = codeSessionManager.apiKey ?? "" }
                .onChange(of: apiKeyInput) { _, _ in
                    commitCloudModel()
                }
        }
    }

    private var cloudModelNameField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Model Name")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            TextField(modelNamePlaceholder, text: $cloudModelNameInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.06), lineWidth: 1)
                )
                .onAppear { cloudModelNameInput = codeSessionManager.modelName }
                .onChange(of: cloudModelNameInput) { _, _ in
                    commitCloudModel()
                }
        }
    }

    @ViewBuilder
    private var cloudModelSuggestionsView: some View {
        if !cloudModelSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recommended Models")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.secondaryText.opacity(0.8))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(cloudModelSuggestions, id: \.self) { suggestion in
                            suggestionChip(suggestion)
                        }
                    }
                }
            }
        }
    }

    private func suggestionChip(_ suggestion: String) -> some View {
        let isSelected = cloudModelNameInput == suggestion
        let bg = isSelected
            ? (theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
            : (theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
        let border = theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)

        return Button(action: {
            cloudModelNameInput = suggestion
            commitCloudModel()
        }) {
            Text(suggestion)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var cloudModelSuggestions: [String] {
        switch codeSessionManager.provider {
        case .anthropic:
            return ["claude-3-7-sonnet-20250219", "claude-3-5-sonnet-20241022", "claude-3-5-haiku-20241022"]
        case .openAI:
            return ["gpt-4o", "gpt-4o-mini", "o3-mini"]
        case .google:
            return ["gemini-2.5-pro", "gemini-2.0-flash", "gemini-1.5-pro"]
        case .openRouter:
            return ["anthropic/claude-3.7-sonnet", "openai/gpt-4o"]
        case .openAICompatible, .ollama, .mlx:
            return []
        }
    }

    private var modelNamePlaceholder: String {
        switch codeSessionManager.provider {
        case .anthropic: return "e.g. claude-3-7-sonnet-20250219"
        case .openAI: return "e.g. gpt-4o"
        case .google: return "e.g. gemini-2.0-flash"
        default: return "e.g. model-name"
        }
    }

    /// Writes the cloud model + API key to the persisted code profile with cloudNative cognitive data.
    private func commitCloudModel() {
        let trimmedModel = cloudModelNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
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

    @ViewBuilder
    private var localModelList: some View {
        if isLoadingModels {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading models...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 24)
        } else if listedModels.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: modelSearchText.isEmpty ? "cpu" : "magnifyingglass")
                    .font(.system(size: 20))
                    .foregroundColor(theme.tertiaryText)
                Text(emptyStateTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Text(emptyStateDetail)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 24)
        } else {
            ScrollView(showsIndicators: true) {
                VStack(spacing: 1) {
                    ForEach(listedModels) { entry in
                        modelRow(entry)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listedModels: [CodeModelEntry] {
        CodeModelListing.ordered(localModels, searchText: modelSearchText)
    }

    private var emptyStateTitle: String {
        modelSearchText.isEmpty ? "No local models found" : "No models match your search"
    }

    private var emptyStateDetail: String {
        modelSearchText.isEmpty
            ? "Install a model in Ollama or the MLX model manager, then reopen this list."
            : "Clear the search to see the available models."
    }

    private func modelRow(_ entry: CodeModelEntry) -> some View {
        CodeModelRow(
            entry: entry,
            isSelected: codeSessionManager.modelName == entry.name,
            onSelect: {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                // ⚠️ Deliberately `false` even when the model supports thinking — Code pays the
                // thinking cost once per ReAct ITERATION, not once per turn. Logged rather than
                // silently dropped so the choice is visible in a trace, and so the eventual
                // per-session toggle has something to flip.
                if entry.supportsThinking {
                    logger.info(
                        "[CODE] '\(entry.name)' supports extended thinking; selected with it OFF. "
                        + "CONSEQUENCE: the model answers without a reasoning pass, which keeps "
                        + "per-iteration latency down in the tool loop. No user-facing toggle exists yet."
                    )
                }
                codeSessionManager.updateModel(
                    entry.name,
                    provider: codeSessionManager.provider,
                    cognitiveProfile: entry.cognitiveProfile,
                    apiKey: nil,
                    baseURL: codeSessionManager.baseURL,
                    thinkingEnabled: false
                )
                codeSessionManager.showModelPicker = false
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
            logger.info(
                "[CODE] Loaded \(localModels.count) local model(s) for the Code picker — "
                + "\(localModels.filter { $0.rank == 0 }.count) with confirmed parallel tool "
                + "calling, \(localModels.filter { $0.capability != .parallelActions }.count) "
                + "without, \(localModels.filter(\.supportsThinking).count) able to use extended "
                + "thinking. CONSEQUENCE: none are hidden — every installed model is listed and "
                + "selectable regardless of parameter count, ranked by tool capability only."
            )
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
                        // Size is carried for the display pill and for ordering only — it is
                        // never compared against a floor. See `rank`.
                        let knownSize: Double? = response.details?.parameterSize == nil
                            ? nil
                            : response.details?.parameterSizeValue
                        return CodeModelEntry(
                            name: name,
                            parameterSize: response.details?.parameterSize,
                            parameterSizeValue: knownSize ?? 0,
                            cognitiveProfile: profile,
                            supportsThinking: response.supportsThinking
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
                    profile = CognitiveProfile(capability: .parallelActions, dialect: .heuristicJson)
                }

                // ⚠️ `parameterSizeValue` was hardcoded 0 here, which sorted every MLX model
                // below every Ollama one for no stated reason. Parse the real value so ordering
                // is honest; nothing gates on it.
                let parsedSize = ModelFitAdvisor.parseParameterCount(profile.metadata?.parameterCount)
                return CodeModelEntry(
                    name: name,
                    parameterSize: profile.metadata?.parameterCount,
                    parameterSizeValue: parsedSize ?? 0,
                    cognitiveProfile: profile,
                    // Ollama's `think` parameter is the only extended-thinking surface the app
                    // drives (`OllamaLLMProvider`), so an MLX model has none to report.
                    supportsThinking: false
                )
            }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - Code Segment Tab Button Component

private struct CodeSegmentTabButton: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var badgeBackground: Color {
        if isSelected {
            return theme.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.09)
        } else {
            return theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
        }
    }

    private var tabBackground: Color {
        if isSelected {
            return theme.isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.09)
        } else if isHovering {
            return theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
        } else {
            return Color.clear
        }
    }

    private var tabBorder: Color {
        if isSelected {
            return theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
        } else {
            return Color.clear
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.5) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)

                if let count {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: isSelected ? .bold : .medium, design: .rounded))
                        .foregroundColor(isSelected ? theme.primaryText.opacity(0.9) : theme.tertiaryText)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(badgeBackground)
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tabBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tabBorder, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hover }
        }
    }
}

// MARK: - Model Row Component

private struct CodeModelRow: View {
    let entry: CodeModelEntry
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var rowBackground: Color {
        if isHovering {
            return theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
        } else if isSelected {
            return theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
        } else {
            return Color.clear
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Subtle 6pt identity dot for code model
                Circle()
                    .fill(isSelected ? Color.cyan : Color.cyan.opacity(0.5))
                    .frame(width: 6, height: 6)

                // Model display name
                Text(entry.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Caveat note if applicable
                if let caveat = entry.caveatNote {
                    Text(caveat)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.warningColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // Subtle parameter size badge pill (e.g. "14B")
                if let size = entry.parameterSize {
                    Text(size)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.secondaryText.opacity(0.85))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
                        )
                }

                // Right-aligned Checkmark (matching Antigravity ✓)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.1)) { isHovering = hover }
        }
        .accessibilityLabel("\(entry.name)\(isSelected ? ", selected" : "")")
    }
}

// MARK: - Model Listing

/// Ordering and search for the Code model picker.
///
/// ⚠️⚠️ INVARIANT — the reason this is a named, tested seam rather than a computed property:
/// **ordering never removes a model.** It ranks and it searches; it does not filter. A 14B size
/// floor used to drop rows inside the old `eligibleModels`, which made "too small" indistinguishable
/// from "not installed": the search box could not reach those models, the provider tab count
/// under-reported, and the empty state blamed the user's model library for a decision the picker
/// had made. Two comments in this file asserted the opposite of what the code did for as long as it
/// shipped, which is what a filter buried in a view property buys you.
///
/// `CodeModelPickerReachabilityTests` fails if any filter other than the user's own search text
/// returns. Search is the ONE permitted subsetting, because the user typed it and can clear it.
enum CodeModelListing {

    /// Tool-capable models first, then alphabetical; narrowed only by `searchText`.
    static func ordered(_ models: [CodeModelEntry], searchText: String) -> [CodeModelEntry] {
        let ranked = models.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.name < b.name
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ranked }
        return ranked.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}
