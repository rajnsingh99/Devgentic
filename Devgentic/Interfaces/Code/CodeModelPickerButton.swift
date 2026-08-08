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

    /// ⚠️ These two used to be ONE `isEligible: Bool` that ANDed a capability verdict with a size
    /// floor, and every model failing either simply vanished from the list (register G95). Fusing
    /// them made the two rationales inseparable, which mattered because they are not the same kind
    /// of judgement: capability is classification metadata, which may label but never gate, while
    /// the size floor is a deliberate quality position stated to the user in `CodeDedicatedView`.
    /// Kept apart so each can be presented on its own terms.

    /// Detected tool-calling tier. NOT a gate — `.singleAction` runs fine in Code mode via the
    /// Markdown/ReAct generator, and even `.none` now proceeds with a warning rather than a refusal.
    var capability: ModelCognitiveCapability { cognitiveProfile.capability }

    /// Display order only — nothing is ever removed from the list.
    /// 0 = matches every Code-mode recommendation · 1 = runnable, below the size guidance ·
    /// 2 = parallel tool calling not confirmed (still selectable; the runtime warns and proceeds).
    var rank: Int {
        if capability != .parallelActions { return 2 }
        return belowRecommendedSize == true ? 1 : 0
    }

    /// Short caveat shown on the row, or nil when the model matches every recommendation.
    var caveatNote: String? {
        if capability != .parallelActions {
            return ProfileCapabilityFilter.toolCapabilityNote(
                capability: capability,
                caveat: cognitiveProfile.toolSupportCaveat,
                profileType: .agent
            ) ?? "⚠︎ Single-action tools"
        }
        if belowRecommendedSize == true { return "⚠︎ Below 14B" }
        return nil
    }

    /// Below the size Code mode recommends. `nil` when the size could not be read at all.
    ///
    /// ⚠️ Deliberately OPTIONAL. The old code took `parameterSizeValue ?? 0` and compared it to the
    /// floor, so a missing or unparseable `parameter_size` scored 0 and the model disappeared —
    /// "we could not read the size" was silently treated as "too small". Unknown must never resolve
    /// to excluded; it resolves to unknown, and the row says so.
    let belowRecommendedSize: Bool?
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
                    // ⚠️ The old copy was a single string — "No eligible models found / Code mode
                    // requires 14B+ models with tool calling support" — shown for THREE unrelated
                    // causes: everything filtered out, a search typo, and the Ollama daemon being
                    // unreachable. It told a user whose daemon was simply not running to go install
                    // bigger models. Capability no longer hides anything, so only two causes remain
                    // and they are now distinguished.
                    Text(emptyStateTitle)
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.secondaryText)
                    Text(emptyStateDetail)
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

    /// Models that clear the size guidance, tool-capable ones first, then by search text.
    ///
    /// ⚠️ The old filter ANDed two unlike judgements — `capability == .parallelActions && size >= 14`
    /// — and dropped anything failing either (register G95). Two separate problems:
    ///
    /// 1. **Capability was a gate.** A `.singleAction` model runs fine in Code mode via the
    ///    Markdown/ReAct generator, and `.none` now proceeds with a warning rather than a refusal,
    ///    yet both were indistinguishable from "not installed" and the search box could not reach
    ///    them. Capability is classification metadata: it may label, never gate. It now ranks and
    ///    annotates the row instead.
    /// 2. **The size floor failed CLOSED on missing data.** `parameterSizeValue` returns 0 for an
    ///    unparseable or absent `parameter_size`, so "we could not read the size" was silently
    ///    treated as "too small". Unknown now means unknown and the model is shown.
    ///
    /// The floor itself SURVIVES as a filter, deliberately: a parameter count is a quality judgement,
    /// not a capability classification, and Code mode states the 14B guidance to the user as a
    /// promise. Only its fail-closed behaviour was a defect.
    private var eligibleModels: [CodeModelEntry] {
        let sizeAppropriate = localModels.filter { $0.belowRecommendedSize != true }
        let ranked = sizeAppropriate.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.name < b.name
        }
        if modelSearchText.isEmpty { return ranked }
        return ranked.filter { $0.name.localizedCaseInsensitiveContains(modelSearchText) }
    }

    /// Installed models hidden purely for being under the size guidance — needed so the empty state
    /// can say which of several unrelated causes it is looking at.
    private var hiddenForSize: Int {
        localModels.filter { $0.belowRecommendedSize == true }.count
    }

    private var emptyStateTitle: String {
        if !modelSearchText.isEmpty { return "No models match your search" }
        if hiddenForSize > 0 { return "No models meet the size guidance" }
        return "No local models found"
    }

    private var emptyStateDetail: String {
        if !modelSearchText.isEmpty {
            return "Clear the search to see the available models."
        }
        if hiddenForSize > 0 {
            return "\(hiddenForSize) installed model\(hiddenForSize == 1 ? " is" : "s are") under the "
                + "14B Code mode recommends. Larger models finish multi-step edits in far fewer turns."
        }
        return "Install a model in Ollama or the MLX model manager, then reopen this list."
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
            logger.info(
                "[CODE] Loaded \(localModels.count) local model(s) for the Code picker — "
                + "\(localModels.filter { $0.rank == 0 }.count) fully recommended, "
                + "\(localModels.filter { $0.belowRecommendedSize == true }.count) below the 14B "
                + "guidance, \(localModels.filter { $0.capability != .parallelActions }.count) "
                + "without confirmed parallel tool calling. CONSEQUENCE: none are hidden — all are "
                + "listed and selectable, ranked with the recommended ones first."
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
                        // `parameterSizeValue` returns 0 for a nil or unparseable size, so the raw
                        // field decides whether we know anything at all — never the computed 0.
                        let knownSize: Double? = response.details?.parameterSize == nil
                            ? nil
                            : response.details?.parameterSizeValue
                        return CodeModelEntry(
                            name: name,
                            parameterSize: response.details?.parameterSize,
                            parameterSizeValue: knownSize ?? 0,
                            cognitiveProfile: profile,
                            belowRecommendedSize: knownSize.map { $0 > 0 && $0 < 14.0 }
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
                    // MLX exposes no parsed parameter count here, so the size is genuinely unknown.
                    // The old code passed 0 and the Ollama arm's floor made that "too small"; this
                    // arm never applied the floor at all, so the two providers silently disagreed.
                    belowRecommendedSize: nil
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

                    // Caveats are DESCRIBED here rather than enforced by hiding the row (G95).
                    if let caveat = entry.caveatNote {
                        Text(caveat)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.warningColor)
                            .lineLimit(1)
                    } else if let size = entry.parameterSize {
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
