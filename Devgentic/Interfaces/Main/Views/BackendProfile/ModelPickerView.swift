//
//  ModelPickerView.swift
//  Devgentic
//
//  Created by Raj Singh on 05/09/25.
//

import SwiftUI

private let logger = DGLogger(category: "ModelPicker")

// MARK: - Cloud Model Picker (Shared)

/// Shared implementation for cloud provider model pickers (Gemini, Anthropic, OpenAI).
/// Uses a fetch closure to abstract the service call and a 15-second timeout to prevent hangs.
private struct CloudModelPickerView: View {
    @Binding var selectedModel: String
    let apiKey: String
    let fetchClosure: (String) async throws -> [String]
    let fetchOnAppear: Bool
    /// Provider name + resolved endpoint, for the failure log only.
    /// ⚠️ Passed in rather than derived: the wrappers bake `baseURL` into `fetchClosure`, so this
    /// view cannot see where the request actually went — and after A18 that may be a corporate
    /// gateway rather than the vendor, which is exactly what a failure log has to name.
    let endpointDescription: String

    @State private var models: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var fetchTask: Task<Void, Never>?
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Verifying key...").foregroundColor(theme.secondaryText)
            } else if let errorMessage = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(theme.errorColor).accessibilityHidden(true)
                Text(errorMessage).foregroundColor(theme.secondaryText).font(theme.fontCaption)
            } else if models.isEmpty {
                Text("Enter a valid API key to see models.").foregroundColor(theme.secondaryText).font(theme.fontCaption)
            } else {
                Picker("Available Models", selection: $selectedModel) {
                    ForEach(models, id: \.self) { modelName in
                        Text(modelName).tag(modelName)
                    }
                }
            }
        }
        .task {
            if fetchOnAppear, !apiKey.isEmpty, models.isEmpty {
                await fetchModels()
            }
        }
        .onChange(of: apiKey) { _, _ in
            fetchTask?.cancel()
            fetchTask = Task {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                await fetchModels()
            }
        }
        .onDisappear { fetchTask?.cancel() }
    }

    private func fetchModels() async {
        guard !apiKey.isEmpty else {
            self.models = []
            self.errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let fetchedModels = try await withThrowingTaskGroup(of: [String].self) { group in
                group.addTask { try await fetchClosure(apiKey) }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw URLError(.timedOut)
                }
                guard let result = try await group.next() else { throw URLError(.timedOut) }
                group.cancelAll()
                return result
            }
            await MainActor.run {
                self.models = fetchedModels
                // ⚠️ This is the G95 defect, still live here after the OpenRouter picker below
                // fixed it: an id absent from the fetched catalogue was REPLACED with whatever
                // sorted first — silently, with no log. Anthropic and OpenAI pass
                // `fetchOnAppear: true`, so merely OPENING a profile to look at it could change
                // which model it runs: different cost, different context window, possibly no tool
                // support. `selectedModel` is bound straight to `providerConfig.modelName`.
                //
                // An unrecognised id is not a wrong id. It may be newly published, region-limited,
                // trimmed out by a corporate gateway's catalogue, or typed deliberately. Only a
                // genuinely EMPTY selection is filled in — that is a new profile with nothing to
                // preserve.
                switch ModelSelectionPolicy.resolve(saved: self.selectedModel,
                                                    available: fetchedModels) {
                case .fill(let candidate):
                    self.selectedModel = candidate
                case .keptUnlisted(let saved):
                    logger.notice("""
                        [PROFILE] \(self.endpointDescription) listed \(fetchedModels.count) model(s) \
                        but not the saved '\(saved)'. CONSEQUENCE: keeping the user's value \
                        unchanged — it may be newly added, region-limited, or hand-entered.
                        """)
                case .keep, .nothingAvailable:
                    break
                }
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                // ⚠️ The user-facing string is a summary; the LOG must carry the underlying error.
                // Without this a 401 from a rotated key, a 403 from a corporate proxy, a decode
                // failure against a gateway that returns a different shape, and an actually-down
                // endpoint were all just "the model list is empty" with nothing to tell them apart.
                logger.error("""
                    [PROFILE] Cloud model fetch failed for \(self.endpointDescription): \(error). \
                    CONSEQUENCE: the picker shows an error and an empty model list; the user cannot \
                    select a model for this profile until it succeeds.
                    """)
                self.models = []
                self.errorMessage = error is URLError && (error as? URLError)?.code == .timedOut
                    ? "Request timed out. Check your network connection."
                    : error.localizedDescription
                self.isLoading = false
            }
        }
    }

}

// MARK: - Cloud Provider Wrappers

struct GeminiModelPickerView: View {
    @Binding var selectedModel: String
    let apiKey: String
    /// The profile's configured API Endpoint, or nil to use the vendor default.
    /// ⚠️ Not optional plumbing — see `GeminiService.verifyAndFetchModels`.
    var baseURL: URL? = nil

    var body: some View {
        CloudModelPickerView(
            selectedModel: $selectedModel,
            apiKey: apiKey,
            fetchClosure: { key in try await GeminiService().verifyAndFetchModels(apiKey: key, baseURL: baseURL) },
            fetchOnAppear: false,
            endpointDescription: "Gemini at \(baseURL?.absoluteString ?? "the default endpoint")"
        )
    }
}

struct AnthropicModelPickerView: View {
    @Binding var selectedModel: String
    let apiKey: String
    /// The profile's configured API Endpoint, or nil to use the vendor default.
    /// ⚠️ Not optional plumbing — see `AnthropicService.verifyAndFetchModels`.
    var baseURL: URL? = nil

    var body: some View {
        CloudModelPickerView(
            selectedModel: $selectedModel,
            apiKey: apiKey,
            fetchClosure: { key in try await AnthropicService().verifyAndFetchModels(apiKey: key, baseURL: baseURL) },
            fetchOnAppear: true,
            endpointDescription: "Anthropic at \(baseURL?.absoluteString ?? "the default endpoint")"
        )
    }
}

struct OpenAIModelPickerView: View {
    @Binding var selectedModel: String
    let apiKey: String
    /// The profile's configured API Endpoint, or nil to use the vendor default.
    /// ⚠️ Not optional plumbing — see `OpenAIService.verifyAndFetchModels`.
    var baseURL: URL? = nil

    var body: some View {
        CloudModelPickerView(
            selectedModel: $selectedModel,
            apiKey: apiKey,
            fetchClosure: { key in try await OpenAIService().verifyAndFetchModels(apiKey: key, baseURL: baseURL) },
            fetchOnAppear: true,
            endpointDescription: "OpenAI at \(baseURL?.absoluteString ?? "the default endpoint")"
        )
    }
}


// MARK: - OpenRouter Model Picker View

/// Rich picker for OpenRouter's multi-vendor catalog (~340 models). Unlike the
/// other cloud pickers this binds capability metadata, because OpenRouter's
/// /models response declares tool support, vision input, and context length
/// up front — the one cloud provider where the agent tool-capability gate can
/// run BEFORE the first request instead of via the runtime 400-classifier.
struct OpenRouterModelPickerView: View {
    @Binding var selectedModel: String
    @Binding var cognitiveCapability: ModelCognitiveCapability
    @Binding var modelMetadata: ModelMetadata?
    @Binding var supportedModalities: SupportedModalities

    let apiKey: String

    /// The profile's configured API Endpoint, or nil to use the vendor default.
    /// ⚠️ Not optional plumbing — see `OpenRouterService.verifyAndFetchModels`.
    var baseURL: URL? = nil

    /// If true (Agents), models without tool support are hidden entirely.
    var filterForTools: Bool = false

    @Environment(\.appTheme) private var theme
    @State private var allModels: [OpenRouterModel] = []
    @State private var searchText: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var fetchTask: Task<Void, Never>?

    /// ⚠️ Agent mode used to DROP every model whose `toolCapable` was false. That was a gate, and a
    /// uniquely inescapable one (register G95): the tool filter ran BEFORE the search filter, so
    /// typing a model's exact id still returned "No models match". A user who knew a model called
    /// tools had no way to reach it.
    ///
    /// Catalogue size is a real constraint here — this list runs to several hundred models, unlike a
    /// local provider's handful — so the answer is to DEMOTE rather than remove: tool-capable models
    /// sort first, the rest follow, labelled. Grouping is the rule-compliant way to keep the list
    /// usable, and search now reaches everything.
    ///
    /// ⚠️ `toolCapable` reads `?? false` upstream, so "false" means "declares no tools OR published no
    /// metadata". The two are indistinguishable here, which is exactly why the row note hedges.
    private var visibleModels: [OpenRouterModel] {
        var models = allModels
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            models = models.filter { $0.id.lowercased().contains(query) || $0.name.lowercased().contains(query) }
        }
        guard filterForTools else { return models }
        // Stable band sort: tool-capable first, original order preserved within each band.
        return models.enumerated()
            .sorted { a, b in
                if a.element.toolCapable != b.element.toolCapable { return a.element.toolCapable }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                if isLoading {
                    ProgressView().controlSize(.small)
                    Text("Verifying key...").foregroundColor(theme.secondaryText)
                } else if let errorMessage = errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(theme.errorColor).accessibilityHidden(true)
                    Text(errorMessage).foregroundColor(theme.secondaryText).font(theme.fontCaption)
                } else if allModels.isEmpty {
                    Text("Enter a valid API key to see models.").foregroundColor(theme.secondaryText).font(theme.fontCaption)
                } else if visibleModels.isEmpty {
                    Text("No models match \"\(searchText)\".")
                        .foregroundColor(theme.warningColor)
                        .font(theme.fontCaption)
                } else {
                    Picker("Available Models", selection: $selectedModel) {
                        // Keep an out-of-filter selection visible so the Picker
                        // never renders an empty selection while searching.
                        if !visibleModels.contains(where: { $0.id == selectedModel }), !selectedModel.isEmpty {
                            Text(selectedModel).tag(selectedModel)
                        }
                        ForEach(visibleModels) { model in
                            Text(model.id
                                 + (model.visionInput ? "  👁 Vision" : "")
                                 + Self.toolNote(for: model, filterForTools: filterForTools))
                                .tag(model.id)
                        }
                    }
                    .labelsHidden()
                }
            }

            if !allModels.isEmpty {
                TextField("Filter models (e.g. deepseek, claude)", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .font(theme.fontCaption)
            }
        }
        .task {
            if !apiKey.isEmpty, allModels.isEmpty {
                await fetchModels()
            }
        }
        .onChange(of: apiKey) { _, _ in
            fetchTask?.cancel()
            fetchTask = Task {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                await fetchModels()
            }
        }
        .onChange(of: selectedModel) { _, newValue in
            seedBindings(for: newValue)
        }
        .onDisappear { fetchTask?.cancel() }
    }

    /// Row suffix for a model's tool support, routed through the shared policy so OpenRouter words
    /// a verdict the same way every other picker does.
    ///
    /// Passes `.undetected` deliberately: `toolCapable` is `?? false` upstream, so a false value
    /// cannot distinguish "the vendor declares no tool support" from "the vendor published no
    /// metadata". Only the hedged wording is honest about that.
    private static func toolNote(for model: OpenRouterModel, filterForTools: Bool) -> String {
        guard let note = ProfileCapabilityFilter.toolCapabilityNote(
            capability: model.toolCapable ? .parallelActions : .none,
            caveat: .undetected,
            profileType: filterForTools ? .agent : .bot
        ) else { return "" }
        return "  \(note)"
    }

    private func fetchModels() async {
        guard !apiKey.isEmpty else {
            allModels = []
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let fetched = try await withThrowingTaskGroup(of: [OpenRouterModel].self) { group in
                group.addTask { try await OpenRouterService().verifyAndFetchModels(apiKey: apiKey, baseURL: baseURL) }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw URLError(.timedOut)
                }
                guard let result = try await group.next() else { throw URLError(.timedOut) }
                group.cancelAll()
                return result
            }
            await MainActor.run {
                self.allModels = fetched
                // ⚠️ This used to SILENTLY REWRITE the user's saved model (register G95): if the
                // stored id was absent from the tool-capable subset, it was replaced with whatever
                // sorted first — no alert, no undo, and the profile was left dirty. Opening an agent
                // profile to read it could therefore change which model it used. A capability verdict
                // may label a row; it must never reassign the user's choice behind their back.
                //
                // Only fill in a genuinely EMPTY selection, which is a new profile with nothing to
                // preserve. An id we do not recognise is left exactly as the user set it: it may be a
                // model the catalogue has not listed yet, or one they typed deliberately.
                switch ModelSelectionPolicy.resolve(saved: self.selectedModel,
                                                    available: fetched.map(\.id)) {
                case .fill(let candidate):
                    self.selectedModel = candidate
                case .keptUnlisted(let saved):
                    logger.notice(
                        "[PROFILE] OpenRouter catalogue (\(fetched.count) models) does not list the "
                        + "saved model '\(saved)'. CONSEQUENCE: keeping the user's value "
                        + "unchanged — it may be newly added, region-limited, or hand-entered."
                    )
                case .keep, .nothingAvailable:
                    break
                }
                self.seedBindings(for: self.selectedModel)
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.allModels = []
                self.errorMessage = error is URLError && (error as? URLError)?.code == .timedOut
                    ? "Request timed out. Check your network connection."
                    : error.localizedDescription
                self.isLoading = false
            }
        }
    }

    /// Seeds capability fields from the catalog entry so downstream routing
    /// (memory budgeting via contextWindow, the vision-input gate, agent
    /// capability checks) sees real values instead of cloud-blind defaults.
    /// Tier stays `.medium` — the same effective default AgentConnect applies
    /// when cloud metadata is absent — so seeding never shifts memory-strategy
    /// behavior relative to the other cloud providers.
    private func seedBindings(for modelID: String) {
        guard let model = allModels.first(where: { $0.id == modelID }) else { return }
        cognitiveCapability = model.toolCapable ? .parallelActions : .none
        modelMetadata = ModelMetadata(tier: .medium, contextWindow: model.contextLength)
        supportedModalities = model.visionInput ? .visionCapable : .textOnly
    }
}


// MARK: - OpenAI-Compatible Model Picker View

/// Picker for a user-supplied OpenAI-compatible endpoint (LM Studio, vLLM,
/// llama.cpp, Groq, DeepSeek, …). The manual TextField is the source of truth —
/// many servers implement `/models`, but some don't, so "Load Models" is a
/// convenience that populates a Menu rather than the only way to pick.
/// The API key is optional; discovery is gated on a non-empty base URL.
struct OpenAICompatibleModelPickerView: View {
    @Binding var selectedModel: String
    let baseURL: String
    let apiKey: String

    @Environment(\.appTheme) private var theme
    @State private var models: [String] = []
    @State private var isLoading: Bool = false
    @State private var statusMessage: String? = nil
    @State private var fetchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Model id (e.g. qwen2.5-coder)", text: $selectedModel)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .frame(maxWidth: 300)

            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(theme.fontCaption).foregroundColor(theme.secondaryText)
                } else if !models.isEmpty {
                    Menu {
                        ForEach(models, id: \.self) { model in
                            Button(model) { selectedModel = model }
                        }
                    } label: {
                        Label("\(models.count) models", systemImage: "list.bullet")
                    }
                    .fixedSize()
                } else if let statusMessage {
                    Text(statusMessage)
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Button("Load Models") {
                    fetchTask?.cancel()
                    fetchTask = Task { await fetchModels() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(maxWidth: 300)
        }
        .onDisappear { fetchTask?.cancel() }
    }

    private func fetchModels() async {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }

        isLoading = true
        statusMessage = nil

        do {
            let fetched = try await withThrowingTaskGroup(of: [String].self) { group in
                group.addTask {
                    try await OpenAICompatibleService().fetchModels(
                        baseURL: trimmedURL,
                        apiKey: apiKey.isEmpty ? nil : apiKey
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw URLError(.timedOut)
                }
                guard let result = try await group.next() else { throw URLError(.timedOut) }
                group.cancelAll()
                return result
            }
            await MainActor.run {
                self.models = fetched
                switch ModelSelectionPolicy.resolve(saved: self.selectedModel, available: fetched) {
                case .fill(let candidate):
                    self.selectedModel = candidate
                case .keptUnlisted(let saved):
                    // This arm produced NOTHING before — the picker preserved the value correctly
                    // but said nothing, so "my model vanished from the list" had no explanation.
                    logger.notice(
                        "[PROFILE] \(trimmedURL) listed \(fetched.count) model(s) but not the saved "
                        + "'\(saved)'. CONSEQUENCE: keeping the user's value unchanged — an "
                        + "OpenAI-compatible gateway often serves models it does not enumerate."
                    )
                case .keep, .nothingAvailable:
                    break
                }
                self.statusMessage = fetched.isEmpty
                    ? "No models listed — enter the model id manually."
                    : nil
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                logger.error("""
                    [PROFILE] OpenAI-compatible model fetch failed at \(trimmedURL): \(error). \
                    CONSEQUENCE: the picker lists no models and the user must type the model id by \
                    hand; the underlying cause is only visible here.
                    """)
                self.models = []
                self.statusMessage = "Couldn't reach \(trimmedURL)/models — enter the model id manually."
                self.isLoading = false
            }
        }
    }
}


// MARK: - Ollama Model Picker View
struct OllamaModelPickerView: View {
    @Binding var selectedModel: String
    @Binding var cognitiveCapability: ModelCognitiveCapability
    @Binding var modelDialect: ModelDialect
    @Binding var modelMetadata: ModelMetadata?
    @Binding var supportedModalities: SupportedModalities
    @Binding var thinkingEnabled: Bool

    let baseURL: String
    let profileID: UUID

    /// If true, incompatible models will be disabled/dimmed (Agents). If false, all are available (Bots).
    var filterForTools: Bool = false

    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var models: [String] = []
    @State private var loadedLocalModels: [LocalModel] = [] // Cache to look up capabilities
    @State private var lastDaemonVersion: String? = nil // Invalidates digest reuse across daemon upgrades
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    // Alert state for unsupported model selection
    @State private var showUnsupportedAlert: Bool = false
    @State private var unsupportedReason: String = ""
    @State private var currentFitAssessment: ModelFitAssessment?

    /// The in-flight refresh, so a new one can cancel its predecessor.
    ///
    /// ⚠️ This picker used to launch a bare `Task {}` per call with no handle, no debounce and no
    /// `.onDisappear` cancellation — unlike the three sibling pickers in this same file, which all
    /// hold a `fetchTask` and cancel it. `baseURLBinding` commits on EVERY keystroke, so retyping a
    /// host fired one full `/api/tags` + `/api/version` + per-model `/api/show` sweep per character
    /// and the SLOWEST response won, writing its model list and capability bindings into the
    /// profile after the user had already moved on.
    @State private var fetchTask: Task<Void, Never>?

    /// Monotonic token: a response whose generation is stale must not touch state.
    /// Cancellation alone is not enough — a task can be cancelled after its network call returns
    /// but before it hops back to the main actor.
    @State private var fetchGeneration: Int = 0

    /// The model name `fetchModels` wrote itself while filling an empty selection, held until the
    /// resulting `.onChange` arrives (register A41).
    ///
    /// ⚠️ A VALUE, deliberately, not a `isApplyingFetchedSelection` boolean set and cleared around
    /// the write. `.onChange` runs on the NEXT update pass, so such a flag is always back to false
    /// by the time the handler reads it — the failure mode that made
    /// `ProviderAdvancedConfigManager.isLoading` a no-op for its entire life (register A9).
    @State private var selectionAppliedByFetch: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                GlassActionButton(title: "Manage Models", icon: "slider.horizontal.3") {
                    router.navigateToModelStore(backend: .ollama, profileID: profileID)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading models...")
                        .foregroundColor(theme.secondaryText)
                } else if let errorMessage = errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.errorColor)
                        .accessibilityHidden(true)
                    Text(errorMessage)
                        .foregroundColor(theme.secondaryText)
                        .font(theme.fontCaption)
                } else if loadedLocalModels.isEmpty {
                    Text("No models found.")
                        .foregroundColor(theme.secondaryText)
                        .font(theme.fontCaption)
                } else {
                    // Every installed model is listed — blocked ones carry their reason
                    // in the row and bounce on selection (handleSelectionChange) instead
                    // of being silently absent from the list.
                    Picker("Available Models", selection: $selectedModel) {
                        ForEach(loadedLocalModels, id: \.name) { model in
                            Text(rowLabel(for: model))
                                .tag(model.name)
                        }
                    }
                    .labelsHidden()
                }
            }

            // Inline fit indicator
            if let assessment = currentFitAssessment, assessment.estimatedRuntimeRAM > 0 {
                ModelFitInlineView(assessment: assessment)
            }

            // Reliability warning for a selected reasoning-focused model: the daemon
            // accepts tool requests, but the fine-tune's tool-call quality is suspect.
            if filterForTools,
               let selected = loadedLocalModels.first(where: { $0.name == selectedModel }),
               selected.cognitiveCapability != .none,
               selected.cognitiveProfile.toolSupportCaveat == .reasoningFocused {
                Label("Reasoning-focused model — tool calls may be unreliable in agent runs.", systemImage: "exclamationmark.triangle.fill")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.warningColor)
            }

            // Agent profile with zero usable models: every row is blocked, so say so
            // (selection bouncing alone would read as a broken picker).
            if filterForTools, !loadedLocalModels.isEmpty,
               !loadedLocalModels.contains(where: { $0.cognitiveCapability != .none }) {
                Text("No tool-capable models installed — agent profiles need tool support.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.warningColor)
            }
        }
        .onAppear(perform: fetchModels)
        .onChange(of: baseURL) { _, _ in
            // Debounced: the binding commits per keystroke, so an un-debounced refresh here is one
            // full daemon sweep per character typed. 500 ms matches the sibling cloud pickers.
            fetchTask?.cancel()
            fetchTask = Task {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled else { return }
                fetchModels()
            }
        }
        .onChange(of: selectedModel) { oldValue, newValue in
            handleSelectionChange(oldValue: oldValue, newValue: newValue)
        }
        .onDisappear { fetchTask?.cancel() }
        .alert("Unsupported Model", isPresented: $showUnsupportedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(unsupportedReason)
        }
    }

    /// Row badges: blocked models show why they can't back an agent; reasoning-focused
    /// ones show the reliability flag. Bot pickers keep the plain name + vision badge.
    private func rowLabel(for model: LocalModel) -> String {
        var label = model.name
        if model.cognitiveProfile.modalities.contains(.visionInput) {
            label += "  👁 Vision"
        }
        // The tool note comes from the shared policy so every picker words the same verdict the
        // same way (register G95). It keys off the CAVEAT, so an authoritative daemon "no tools"
        // reads differently from a name-based guess — which is the whole point.
        if let note = ProfileCapabilityFilter.toolCapabilityNote(
            capability: model.cognitiveCapability,
            caveat: model.cognitiveProfile.toolSupportCaveat,
            profileType: filterForTools ? .agent : .bot
        ) {
            label += "  \(note)"
        }
        return label
    }

    /// Human-readable note on a model's tool support, from its caveat.
    ///
    /// ⚠️ Wording deliberately DESCRIBES rather than forbids: nothing refuses this model any more
    /// (register G92/G94/G95), so copy claiming agent profiles "require" tool support would be
    /// stating a rule the app no longer has.
    private static func blockReason(for model: LocalModel) -> String {
        switch model.cognitiveProfile.toolSupportCaveat {
        case .serverRejectsTools:
            return "Ollama reports '\(model.name)' has no tool support — the server will reject tool requests, so this agent's tool calls are expected to fail. You can still select it."
        case .reasoningFocused:
            return "'\(model.name)' is a reasoning-focused model and this Ollama version can't confirm tool support. Upgrade Ollama for authoritative capability data."
        case .undetected:
            return "Tool support for '\(model.name)' couldn't be verified on this Ollama version. Upgrade Ollama for authoritative capability detection."
        case nil:
            return "Tool support for '\(model.name)' could not be detected. Agent tool calls may not work. If you know it supports tools, keep it selected."
        }
    }

    /// Sort band for agent pickers: 0 = clean tool support, 1 = usable with a
    /// caveat (reasoning-focused), 2 = blocked.
    private static func agentRank(_ model: LocalModel) -> Int {
        if model.cognitiveCapability == .none { return 2 }
        return model.cognitiveProfile.toolSupportCaveat == nil ? 0 : 1
    }

    private func fetchModels() {
        guard !baseURL.isEmpty, let _ = URL(string: baseURL) else {
            self.errorMessage = "Invalid Base URL."
            self.models = []
            return
        }
        
        isLoading = true
        errorMessage = nil

        // Snapshot state on the main actor before hopping into the task.
        let cachedModels = loadedLocalModels
        let cachedVersion = lastDaemonVersion

        // Claim a generation and supersede any refresh already running.
        fetchGeneration &+= 1
        let generation = fetchGeneration
        fetchTask?.cancel()

        fetchTask = Task {
            do {
                // Digest-aware refresh (shared with the model manager): cheap
                // /api/tags + /api/version probe; /api/show detection re-runs only
                // for new/changed models. Also fixes a silent-hide path — a model
                // whose detail fetch failed used to be dropped from the picker
                // entirely; the refresher degrades it to a bare entry instead.
                let result = try await LocalModelRefresher.refresh(
                    baseURL: baseURL,
                    cached: cachedModels,
                    cachedDaemonVersion: cachedVersion
                )
                let fetchedDetails = result.models

                // Agent mode ordering: clean tool support → usable-with-caveat
                // (reasoning-focused) → blocked; alphabetical within each band.
                let sortedModels = fetchedDetails.sorted { m1, m2 in
                    if filterForTools {
                        let r1 = Self.agentRank(m1), r2 = Self.agentRank(m2)
                        if r1 != r2 { return r1 < r2 }
                    }
                    // Fallback to alphabetical sorting
                    return m1.name < m2.name
                }
                let fetchedNames = sortedModels.map { $0.name }

                await MainActor.run {
                    // ⚠️ Discard a superseded response. Without this the SLOWEST in-flight sweep
                    // wins and rewrites `selectedModel` (and the capability bindings behind it)
                    // for a base URL the user has already replaced.
                    guard generation == self.fetchGeneration else {
                        logger.notice("""
                            [PROFILE] Discarded a superseded Ollama model refresh for \(baseURL) \
                            (generation \(generation), current \(self.fetchGeneration)). \
                            CONSEQUENCE: none — a newer refresh is in flight and owns the picker.
                            """)
                        return
                    }
                    self.loadedLocalModels = sortedModels
                    self.lastDaemonVersion = result.daemonVersion
                    self.models = fetchedNames
                    
                    // Smart Selection Logic
                    let modelBeforeAutoSelect = self.selectedModel
                    if !sortedModels.isEmpty {

                        // ⚠️ Register A37. This used to read
                        // `if !fetchedNames.contains(selectedModel) || selectedModel.isEmpty`, so a
                        // saved model the daemon no longer lists was SILENTLY REPLACED with a
                        // different one — on `.onAppear`, i.e. by opening the profile to change
                        // something unrelated. `ollama rm` on one model, or a daemon that has not
                        // finished starting, was enough to repoint the profile at another model
                        // with no notice and no undo.
                        //
                        // The rule now comes from `ModelSelectionPolicy`, shared with the cloud and
                        // OpenRouter pickers below — the three had drifted, and each was fixed
                        // separately (G95, MP-01, A37) because each owned its own copy of it.
                        // In agent mode the fill prefers a tool-capable model.
                        let fillCandidate = filterForTools
                            ? (sortedModels.first(where: { $0.cognitiveCapability != .none })?.name ?? fetchedNames.first)
                            : fetchedNames.first

                        switch ModelSelectionPolicy.resolve(saved: self.selectedModel,
                                                            available: fetchedNames,
                                                            fillCandidate: fillCandidate) {
                        case .fill(let candidate):
                            self.selectedModel = candidate
                        case .keptUnlisted(let saved):
                            logger.notice("""
                                [PROFILE] Ollama at \(baseURL) listed \(fetchedNames.count) model(s) \
                                but not the saved '\(saved)'. CONSEQUENCE: keeping the user's value \
                                unchanged — the model may have been removed, the daemon may still be \
                                starting, or the name may have been typed by hand. The run reports \
                                the failure honestly if it really is gone.
                                """)
                        case .keep, .nothingAvailable:
                            break
                        }
                    } else if self.errorMessage == nil {
                        if filterForTools {
                            self.errorMessage = "No models available."
                        }
                    }

                    // Bind the detected values for the resolved selection.
                    //
                    // ⚠️ `seedUserPreferences` is false unless the fill above actually CHANGED the
                    // model. This runs on every `.onAppear`, and re-seeding a user preference on a
                    // plain refresh is what silently reverted the Extended Thinking toggle every
                    // time the editor was opened (register G98).
                    let selectionChangedHere = self.selectedModel != modelBeforeAutoSelect

                    // ⚠️ Register A41: that guard was being BYPASSED. Assigning `selectedModel` above
                    // fires `.onChange(of: selectedModel)` → `handleSelectionChange` → a second
                    // `updateCapabilityLevel(seedUserPreferences: true)`, so whenever the fill ran,
                    // the careful flag below was irrelevant — the preference had already been
                    // re-seeded by the re-entrant path.
                    //
                    // ⚠️ Recorded as a VALUE, not a boolean flag set-and-cleared around the write:
                    // `.onChange` runs on the NEXT update pass, so a synchronous flag can never
                    // suppress it (that is exactly how `ProviderAdvancedConfigManager.isLoading`
                    // failed, register A9). This token is cleared when the change actually arrives.
                    if selectionChangedHere {
                        self.selectionAppliedByFetch = self.selectedModel
                    }

                    updateCapabilityLevel(
                        for: self.selectedModel,
                        seedUserPreferences: selectionChangedHere
                    )

                    self.isLoading = false
                }
            } catch is CancellationError {
                // Superseded or the view went away — leave state to whoever owns it now.
                return
            } catch {
                await MainActor.run {
                    guard generation == self.fetchGeneration else { return }
                    // ⚠️ The underlying error used to be discarded entirely and replaced with this
                    // one fixed sentence, so a TLS failure, a 403 from a reverse proxy, a decode
                    // error from a newer daemon and an actually-down daemon were indistinguishable
                    // to the user AND absent from the log.
                    logger.error("""
                        [PROFILE] Ollama model fetch failed at \(baseURL): \(error). \
                        CONSEQUENCE: the picker shows "Connection failed. Is Ollama running?" and \
                        an empty model list — the real cause is only visible here.
                        """)
                    self.errorMessage = "Connection failed. Is Ollama running?"
                    self.models = []
                    self.isLoading = false
                }
            }
        }
    }
    
    /// Updates capability bindings when the selection changes. In agent mode, selecting a model
    /// with no detected tool support raises an explanatory alert and the selection STANDS.
    ///
    /// ⚠️ This used to REVERT the selection (`selectedModel = oldValue`), and that was wrong twice
    /// over (register G95). First, it gated on a capability verdict, which the project rule forbids
    /// — and with `ProfileValidator` now advisory and `AgentConnect`'s 405 removed, this picker was
    /// the last thing standing between the user and a model they may well know better than the
    /// heuristic does. Second, the revert was ASYMMETRIC by accident of its own guard: it required
    /// the PREVIOUS model to be tool-capable, so once you were parked on a blocked model you could
    /// move freely among blocked models, but could never return to one after picking a good one.
    /// That is not a policy anyone chose.
    ///
    /// The alert stays: the user should hear it once, in prose, at the moment it becomes relevant.
    /// This now matches `MLXModelPickerView`, and honours the intent the old doc comment already
    /// claimed — "the runtime gate reports the failure honestly rather than trapping the picker".
    private func handleSelectionChange(oldValue: String, newValue: String) {
        guard !loadedLocalModels.isEmpty else { return }

        // ⚠️ Register A41. `fetchModels` writing `selectedModel` lands here one update pass later,
        // indistinguishable from the user picking a model — and this path always seeds. Recognise
        // the fetch's own write by VALUE and let the decision it already made stand.
        if let applied = selectionAppliedByFetch, applied == newValue {
            selectionAppliedByFetch = nil
            logger.debug(
                "[PROFILE] Ignoring the .onChange for '\(newValue)' — this picker wrote it while "
                + "filling an empty selection and has already applied capability and preferences."
            )
            return
        }
        // Any other change is a real selection, so a stale token must not survive it.
        selectionAppliedByFetch = nil

        if filterForTools,
           let selected = loadedLocalModels.first(where: { $0.name == newValue }),
           selected.cognitiveCapability == .none {
            unsupportedReason = Self.blockReason(for: selected)
            showUnsupportedAlert = true
        }

        // A deliberate model change: the new model's defaults are the right starting point, so
        // detection may seed the preference here. This is the "at model-selection time" the
        // property's own documentation describes — and the only place it should happen.
        updateCapabilityLevel(for: newValue, seedUserPreferences: true)
    }
    
    /// Writes the detected values for `modelName` into the profile bindings.
    ///
    /// - Parameter seedUserPreferences: whether this is a genuine model CHANGE, and detection may
    ///   therefore set fields the user also controls. Pass `false` for a plain refresh.
    ///
    /// ⚠️ Four of these five bindings are pure measurements — capability, dialect, metadata and
    /// modalities describe the model and nobody can set them by hand, so refreshing them is always
    /// correct. `thinkingEnabled` is different in kind: it is the Extended Thinking **switch** in
    /// Advanced Configuration, so `supportsThinking` is a sensible DEFAULT for it and never a
    /// truth about it (register G98).
    ///
    /// It used to be assigned unconditionally, and this function runs at the end of every
    /// `fetchModels()` — which fires on `.onAppear`. So a user who turned Extended Thinking off,
    /// saved, and reopened the editor found it back on, with nothing having reported a change.
    /// Their setting survived exactly until they next looked at it.
    ///
    /// The property's own doc comment already said "seeded by detection **at model-selection
    /// time**"; the defect was that the seeding also ran when nothing had been selected.
    private func updateCapabilityLevel(for modelName: String, seedUserPreferences: Bool) {
        guard let matchedModel = loadedLocalModels.first(where: { $0.name == modelName }) else {
            // Not in the fetched list — a hand-typed name, or a model since removed. Leave every
            // stored value untouched rather than resetting it to a default we cannot justify.
            return
        }

        // Measurements: always refreshed.
        self.cognitiveCapability = matchedModel.cognitiveCapability
        self.modelDialect = matchedModel.modelDialect
        self.modelMetadata = matchedModel.cognitiveProfile.metadata
        self.supportedModalities = matchedModel.cognitiveProfile.modalities
        self.currentFitAssessment = ModelFitAdvisor.assess(metadata: matchedModel.cognitiveProfile.metadata)

        // Preference: seeded only when the user actually picked a different model.
        if seedUserPreferences {
            if self.thinkingEnabled != matchedModel.supportsThinking {
                logger.info(
                    "[PROFILE] Seeding Extended Thinking = \(matchedModel.supportsThinking) for newly "
                    + "selected model '\(modelName)'. CONSEQUENCE: this overwrites the previous "
                    + "setting because the model changed; a plain refresh leaves it alone."
                )
            }
            self.thinkingEnabled = matchedModel.supportsThinking
        } else if self.thinkingEnabled && !matchedModel.supportsThinking {
            // Worth a line: the user's switch is on for a model detection says cannot do it. Not
            // overridden — the runtime auto-disables on a 400, which is the authoritative answer.
            logger.notice(
                "[PROFILE] Extended Thinking is ON for '\(modelName)', which detection reports as "
                + "non-reasoning. CONSEQUENCE: the setting is PRESERVED (it is the user's); if the "
                + "server rejects it at runtime the existing 400 handler disables it."
            )
        }
    }
}
