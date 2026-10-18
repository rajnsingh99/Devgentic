// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AdvanceConfigurationView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

// MARK: - Shared Components

/// A visible numeric text field for the MLX/Ollama advanced configuration panels, replacing `.roundedBorder`, which is
/// nearly invisible in dark theme. Pair with a `Stepper` bound to the same `value`.
struct AdvancedConfigNumericField: View {
    @Binding var value: Int
    let width: CGFloat
    /// Spoken name for the field: the `TextField` label is empty, so without this it announces as a nameless field.
    /// Required rather than defaulted so a new caller cannot omit it.
    let accessibilityName: LocalizedStringKey
    @Environment(\.appTheme) private var theme

    var body: some View {
        TextField("", value: $value, format: .number)
            .accessibilityLabel(accessibilityName)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: width)
            .background(theme.textBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.dividerColor, lineWidth: 1)
            )
    }
}

struct GeminiSettingsView: View {
    @Binding var config: GeminiAdvancedConfig
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            
            // Temperature
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Controls the randomness of the generated response. Gemini accepts 0.0–2.0; above 1.0 is markedly more divergent.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                }
                Spacer(minLength: 16)
                HStack {
                    // Spans the full 0.0-2.0 range that `generationConfig.temperature` accepts, matching the OpenAI panel.
                    Slider(value: $config.temperature.toNonOptional(defaultValue: 0.9), in: 0.0...2.0, step: 0.05)
                        .frame(width: 150)
                        .accessibilityLabel("Temperature")
                        .accessibilityValue(String(format: "%.2f", config.temperature ?? 0.9))
                    Text("\(config.temperature ?? 0.9, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            
            Divider()
            
            // Top P
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top P")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Cumulative probability of tokens to consider.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.topP.toNonOptional(defaultValue: 1.0), in: 0.0...1.0, step: 0.05)
                        .frame(width: 150)
                        .accessibilityLabel("Top P")
                        .accessibilityValue(String(format: "%.2f", config.topP ?? 1.0))
                    Text("\(config.topP ?? 1.0, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            
            Divider()
            
            // Top K
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top K")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Maximum number of tokens to consider.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                }
                Spacer(minLength: 16)
                HStack {
                    // The nil fallback is 40 (Google's own default is 64), so touching the stepper does not persist greedy decoding.
                    Text(config.topK.map(String.init) ?? "Default").monospacedDigit()
                    Stepper("", value: $config.topK.toNonOptional(defaultValue: 40), in: 1...100).labelsHidden()
                        .accessibilityLabel("Top K")
                        .accessibilityValue(config.topK.map(String.init) ?? "Default")
                }
            }

            // Warns rather than clamps, as the Ollama panel does for num_ctx: Top K 1 is legitimate greedy decoding.
            if config.topK == 1 {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.warningColor)
                    Text("Top K 1 selects only the single most likely token, so Temperature and Top P above have no effect and responses repeat verbatim. Raise Top K to let them apply.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }

            Divider()
            
            // Max Output Tokens
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max Output Tokens")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Maximum length of the generated response.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                }
                Spacer(minLength: 16)
                HStack {
                    Text("\(config.maxOutputTokens ?? 2048)").monospacedDigit()
                    Stepper("", value: $config.maxOutputTokens.toNonOptional(defaultValue: 2048), in: 256...8192, step: 256).labelsHidden()
                        .accessibilityLabel("Max output tokens")
                        .accessibilityValue("\(config.maxOutputTokens ?? 2048)")
                }
            }
            
            Divider()
            
            // Safety Settings Header
            Text("Safety Settings")
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
                .padding(.top, 8)
            
            ForEach($config.safetySettings.toNonOptional(defaultValue: GeminiAdvancedConfig.default().safetySettings ?? [])) { $setting in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(setting.category.localizedTitle)
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                    }
                    
                    Spacer(minLength: 16)
                    
                    Picker("", selection: $setting.threshold) {
                        ForEach(HarmBlockThreshold.allCases, id: \.self) { threshold in
                            Text(threshold.localizedTitle).tag(threshold)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    // The category name is the only thing distinguishing these four pickers.
                    .accessibilityLabel(setting.category.localizedTitle)
                }
                Divider()
            }
        }
    }
    
    // Formatting Helpers for Gemini Safety Labels
}

// MARK: - Localized names for the Gemini safety enums (audit C2)

// Why: the rawValues are wire values sent to the Gemini API and persisted in profiles; never change them
// Localized titles for the harm categories and thresholds, as String Catalog keys.

extension HarmCategory {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .harassment:       return "Harassment"
        case .hateSpeech:       return "Hate Speech"
        case .sexuallyExplicit: return "Sexually Explicit"
        case .dangerousContent: return "Dangerous Content"
        }
    }
}

extension HarmBlockThreshold {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .unspecified:         return "Default"
        case .blockLowAndAbove:    return "Block Low and Above"
        case .blockMediumAndAbove: return "Block Medium and Above"
        case .blockOnlyHigh:       return "Block Only High"
        case .blockNone:           return "Block None"
        }
    }
}

struct OllamaSettingsView: View {
    @Binding var config: OllamaAdvancedConfig
    @Binding var thinkingEnabled: Bool

    /// Active model metadata that sets the Context Window cap (from `/api/show` for Ollama).
    /// Nil when no model is selected; the view then falls back to the catalog lookup.
    let modelMetadata: ModelMetadata?
    /// Active model name, a fallback for context-window detection when `modelMetadata.contextWindow` is nil.
    let modelName: String?
    /// Whether this view is hosted in an Agent or Bot profile; selects the strict agent or warm chat preset.
    /// No default, so a Bot profile never silently inherits agent defaults.
    let defaultProfile: OllamaConfigDefaultProfile

    @Environment(\.appTheme) private var theme

    // Why: committing per keystroke would normalize the value and strip trailing newlines, yanking the cursor back
    /// Local draft of the stop-sequences editor text, committed to `config.stop` only on focus loss.
    @State private var stopsDraft: String = ""

    /// Tracks whether the stops editor is the active responder so we can commit
    /// the draft on focus loss and resync the draft on external changes (Apply
    /// Optimal etc.) without clobbering whatever the user is currently typing.
    @FocusState private var stopsFocused: Bool

    /// Effective context window for bound derivation, mirroring AgentConnect's runtime fallback: captured metadata,
    /// then `KnownModelContextWindows.lookup(modelName)`, then 8192.
    private var contextWindow: Int {
        if let cw = modelMetadata?.contextWindow { return cw }
        if let name = modelName, let cw = KnownModelContextWindows.lookup(name) { return cw }
        return 8192
    }

    /// Upper bound for `numCtx`. Ollama can serve up to the model's full
    /// context window (Llama-3.1 = 128K, Qwen3 = 1M). Capped at 1M for stepper
    /// usability — covers every model shipping today.
    private var numCtxCap: Int {
        max(2048, min(contextWindow, 1_000_000))
    }

    /// Suffix shown next to range hints — surfaces the model context window so
    /// the user understands where the cap came from.
    private var modelContextSuffix: String {
        if let ctx = modelMetadata?.contextWindow {
            return " · model context: \(ctx) tokens"
        }
        if let name = modelName, let ctx = KnownModelContextWindows.lookup(name) {
            return " · model context: \(ctx) tokens (catalog)"
        }
        return ""
    }

    init(
        config: Binding<OllamaAdvancedConfig>,
        thinkingEnabled: Binding<Bool>,
        modelMetadata: ModelMetadata? = nil,
        modelName: String? = nil,
        defaultProfile: OllamaConfigDefaultProfile
    ) {
        self._config = config
        self._thinkingEnabled = thinkingEnabled
        self.modelMetadata = modelMetadata
        self.modelName = modelName
        self.defaultProfile = defaultProfile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Temperature
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Sharpens or flattens the next-token distribution. 0.0 = pick the single most likely token (deterministic, best for tool calls). 0.5–0.7 = natural conversation. 1.0+ = creative/varied. Above 1.5 is rarely useful.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.temperature.toNonOptional(defaultValue: 0.8), in: 0.0...2.0, step: 0.05)
                        .accessibilityLabel("Temperature")
                        .accessibilityValue(String(format: "%.2f", config.temperature ?? 0.8))
                        .frame(width: 150)
                    Text("\(config.temperature ?? 0.8, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Divider()

            // Top P
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top P")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("After temperature, restricts sampling to the smallest set of tokens whose combined probability reaches this value (nucleus sampling). 1.0 = no filter. 0.9–0.95 = standard chat. 0.7–0.85 = tighter; pairs with higher temperature to keep output coherent.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.topP.toNonOptional(defaultValue: 0.9), in: 0.0...1.0, step: 0.05)
                        .accessibilityLabel("Top P")
                        .accessibilityValue(String(format: "%.2f", config.topP ?? 0.9))
                        .frame(width: 150)
                    Text("\(config.topP ?? 0.9, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Divider()

            // Top K — TextField + Stepper combo, allows 0 (= disabled)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top K")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Caps the number of candidate tokens at each step. 0 = disabled (sample from full vocabulary). 1–10 = very tight, near-greedy. 40–100 = standard. Higher = more variety. Combine with low temperature for predictable structured output.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Range: 0–1000")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                }
                Spacer(minLength: 16)
                HStack(spacing: 6) {
                    AdvancedConfigNumericField(value: $config.topK.toNonOptional(defaultValue: 40), width: 70, accessibilityName: "Top K")
                    Stepper("", value: $config.topK.toNonOptional(defaultValue: 40), in: 0...1000, step: 5)
                        .accessibilityLabel("Top K stepper")
                        .accessibilityValue("\(config.topK ?? 40)")
                        .labelsHidden()
                }
            }
            .onChange(of: config.topK) { _, newVal in
                guard let v = newVal else { return }
                let clamped = max(0, min(v, 1000))
                if clamped != v { config.topK = clamped }
            }

            Divider()

            // Context Window (numCtx) — model-derived cap
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Context Window")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Number of tokens the model holds in working memory (num_ctx). Ollama's default of 2048 is too low for modern long-context use — set this to your model's actual context size to unlock its full capability. Costs a few MB of RAM per 1K tokens.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Range: 256–\(numCtxCap)\(modelContextSuffix)")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText.opacity(0.7))

                    // Warns when the saved value exceeds this model's cap (e.g. after switching to a smaller-context model).
                    // It does not auto-clamp, which would destroy tuning.
                    if let current = config.numCtx, current > numCtxCap {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .accessibilityHidden(true)
                            Text("Current value \(current) exceeds this model's max context \(numCtxCap). Ollama may reject or silently clamp the request.")
                                .font(theme.fontCaption2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundColor(theme.warningColor)
                    }
                }
                Spacer(minLength: 16)
                HStack(spacing: 6) {
                    AdvancedConfigNumericField(value: $config.numCtx.toNonOptional(defaultValue: 2048), width: 90, accessibilityName: "Context window size")
                    Stepper("", value: $config.numCtx.toNonOptional(defaultValue: 2048), in: 256...numCtxCap, step: 256)
                        .accessibilityLabel("Context window size stepper")
                        .accessibilityValue("\(config.numCtx ?? 2048)")
                        .labelsHidden()
                }
            }
            .onChange(of: config.numCtx) { _, newVal in
                guard let v = newVal else { return }
                // Clamps only below the absolute floor; values above the model's context window are surfaced by the warning above.
                if v < 256 { config.numCtx = 256 }
            }

            Divider()

            // Stop Sequences — multi-line editor (one stop per line)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stop Sequences")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Sequences that immediately end generation when produced. One per line. Useful for cutting off model output at specific tokens (e.g. '<|end|>', '\\n\\n###'). Leave empty to use the model's built-in stops.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                stopSequencesEditor
            }

            Divider()

            // Seed — visible TextField styling matching the rest of the panel
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fixed Seed")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Optional fixed seed for reproducible outputs. Same seed + same prompt + same model produces identical output. Useful for testing, evaluation, and debugging. Leave empty for random.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                TextField("Optional", value: $config.seed, format: .number)
                    .accessibilityLabel("Random seed")
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: 110)
                    .background(theme.textBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.dividerColor, lineWidth: 1)
                    )
            }

            Divider()

            // Repeat Penalty
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repeat Penalty")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Multiplier applied to the probability of recently-emitted tokens. 1.0 = off. 1.05–1.1 = mild (suits chat). 1.15–1.3 = stronger (helps small/Q4 models break repetition loops). Above 1.5 can make output incoherent.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.repeatPenalty.toNonOptional(defaultValue: 1.1), in: 1.0...2.0, step: 0.05)
                        .accessibilityLabel("Repeat penalty")
                        .accessibilityValue(String(format: "%.2f", config.repeatPenalty ?? 1.1))
                        .frame(width: 150)
                    Text("\(config.repeatPenalty ?? 1.1, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Divider()

            // Extended Thinking
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extended Thinking")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Enable reasoning traces before the response. Only works on reasoning models (deepseek-r1, qwq, qwen3, etc.). If the model rejects this, it will be disabled automatically.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: $thinkingEnabled)
                    .accessibilityLabel("Extended thinking")
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Divider()

            // Reset to Defaults: the tier is auto-detected from `modelMetadata.tier`; agent profiles get the strict preset,
            // bot profiles the warm chat preset.
            HStack {
                Spacer()
                GlassActionButton(title: "Reset to Defaults", icon: "arrow.counterclockwise", isAccent: false) {
                    withAnimation {
                        if let metadata = modelMetadata {
                            config = OllamaAdvancedConfig.recommended(for: metadata, profile: defaultProfile)
                        } else {
                            // No model selected — fall back to the static default
                            // for the host profile type.
                            config = defaultProfile == .agent
                                ? .default()
                                : .botPreset(for: .smallMedium)
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Helpers

    /// Multi-line editor for stop sequences, backed by `stopsDraft`; commits on focus loss, and external changes sync into
    /// the draft only when the user is not editing.
    private var stopSequencesEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $stopsDraft)
                .focused($stopsFocused)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(width: 240, height: 80)
                .background(theme.textBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.dividerColor, lineWidth: 1)
                )

            // Placeholder shown only when the editor is genuinely empty.
            // `.allowsHitTesting(false)` so clicks pass through to the editor.
            if stopsDraft.isEmpty {
                Text("e.g.\n<|end|>\n###")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(theme.secondaryText.opacity(0.5))
                    .padding(.leading, 12)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            // Initial sync from persisted config.
            stopsDraft = (config.stop ?? []).joined(separator: "\n")
        }
        .onChange(of: stopsFocused) { _, focused in
            // Commits when the editor loses focus; Save buttons shift focus first, so persistence reads a committed `config.stop`.
            if !focused { commitStopsDraft() }
        }
        .onChange(of: config.stop) { _, _ in
            // External update (e.g. a preset replacing the config): refresh only when not editing, to avoid clobbering input.
            if !stopsFocused {
                stopsDraft = (config.stop ?? []).joined(separator: "\n")
            }
        }
    }

    /// Parses the draft into a clean `[String]?` and writes it to `config.stop`; blank lines are dropped.
    /// An empty result becomes nil, which Ollama reads as the model's built-in stops.
    private func commitStopsDraft() {
        let lines = stopsDraft
            .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        config.stop = lines.isEmpty ? nil : lines
    }
}

// MARK: - Anthropic Claude Settings

struct AnthropicSettingsView: View {
    @Binding var config: AnthropicAdvancedConfig
    /// Selected model id; drives which controls are shown, since the request contract differs by model generation.
    /// Nil is treated as newest (see `AnthropicModelGeneration`).
    var modelName: String?
    @Environment(\.appTheme) private var theme

    private var generation: AnthropicModelGeneration {
        AnthropicModelGeneration.classify(modelName: modelName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Max Tokens
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max Output Tokens")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Maximum length of the generated response. Claude requires this explicitly.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                }
                Spacer(minLength: 16)
                HStack {
                    Text("\(config.maxTokens)").monospacedDigit()
                    Stepper("", value: $config.maxTokens, in: 256...128000, step: 256).labelsHidden()
                        .accessibilityLabel("Max tokens")
                        .accessibilityValue("\(config.maxTokens)")
                }
            }

            Divider()

            // Sampling controls are hidden, not disabled, on models that removed these parameters (sending any returns 400);
            // the note below says so.
            if generation.acceptsSamplingParams {
                // Temperature
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Temperature")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        if config.extendedThinking {
                            Text("Not sent while Extended Thinking is on — thinking does not permit sampling parameters.")
                                .font(theme.fontCaption2).foregroundColor(.orange)
                        } else {
                            Text("Controls the randomness of the generated response.")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                                .lineSpacing(2.5)
                        }
                    }
                    Spacer(minLength: 16)
                    HStack {
                        Slider(value: $config.temperature.toNonOptional(defaultValue: 1.0), in: 0.0...1.0, step: 0.05)
                            .frame(width: 150)
                            .disabled(config.extendedThinking)
                            .accessibilityLabel("Temperature")
                            .accessibilityValue(String(format: "%.2f", config.temperature ?? 1.0))
                        Text("\(config.temperature ?? 1.0, specifier: "%.2f")")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    .opacity(config.extendedThinking ? 0.5 : 1.0)
                }

                Divider()

                // Top P
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top P")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        if config.extendedThinking {
                            Text("Not sent while Extended Thinking is on.")
                                .font(theme.fontCaption2).foregroundColor(.orange)
                        } else if config.temperature != nil {
                            Text("Not sent while Temperature is set — Claude accepts one or the other, never both.")
                                .font(theme.fontCaption2).foregroundColor(.orange)
                        } else {
                            Text("Cumulative probability of tokens to consider.")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                                .lineSpacing(2.5)
                        }
                    }
                    Spacer(minLength: 16)
                    HStack {
                        Slider(value: $config.topP.toNonOptional(defaultValue: 1.0), in: 0.0...1.0, step: 0.05)
                            .frame(width: 150)
                            .disabled(config.extendedThinking)
                            .accessibilityLabel("Top P")
                            .accessibilityValue(String(format: "%.2f", config.topP ?? 1.0))
                        Text("\(config.topP ?? 1.0, specifier: "%.2f")")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    .opacity((config.extendedThinking || config.temperature != nil) ? 0.5 : 1.0)
                }

                Divider()

                // Top K
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top K")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Maximum number of tokens to consider when sampling.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2.5)
                    }
                    Spacer(minLength: 16)
                    HStack {
                        Text("\(config.topK ?? 250)").monospacedDigit()
                        Stepper("", value: $config.topK.toNonOptional(defaultValue: 250), in: 1...500)
                            .labelsHidden()
                            .disabled(config.extendedThinking)
                            .accessibilityLabel("Top K")
                            .accessibilityValue("\(config.topK ?? 250)")
                    }
                    .opacity(config.extendedThinking ? 0.5 : 1.0)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(theme.secondaryText)
                    Text("Temperature, Top P and Top K are not available on this model — Anthropic removed them for this generation. Steer the response with your system instructions and the Thinking Effort setting instead.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }

            Divider()

            // Extended Thinking Section
            Text("Extended Thinking")
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
                .padding(.top, 8)

            // Hidden, not disabled, on models where thinking is always on; Sonnet 5.5 keeps the toggle (its off is `between_tools`).
            // A greyed-out switch would imply a stored, honoured value.
            if generation.canTurnThinkingOff {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Thinking")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Claude will reason internally before responding. Improves complex task performance.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2.5)
                    }
                    Spacer(minLength: 16)
                    Toggle("", isOn: $config.extendedThinking)
                        .accessibilityLabel("Extended thinking")
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(theme.secondaryText)
                    Text("Thinking is always on for this model and cannot be switched off. Use Thinking Effort below to control how much reasoning Claude spends before answering.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }

            // Effort is the only depth control on an always-on model, so it must stay reachable
            // there even though the toggle above is gone.
            if config.extendedThinking || !generation.canTurnThinkingOff {
                Divider()

                // Two controls for one concept because the API contract differs by model: `budget_tokens` (a token count) on older
                // models, `output_config.effort` (a ladder) on newer ones, which reject the old shape.
                if generation.acceptsEffort {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Thinking Effort")
                                .font(theme.fontFootnote.weight(.semibold))
                                .foregroundColor(theme.primaryText)
                            Text("How much reasoning Claude spends before answering. Higher costs more tokens and latency.")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                                .lineSpacing(2.5)
                        }
                        Spacer(minLength: 16)
                        Picker("", selection: $config.thinkingEffort.toNonOptional(defaultValue: "")) {
                            Text("Default (\(AnthropicModelGeneration.defaultEffort(for: modelName ?? "")))").tag("")
                            ForEach(generation.supportedEffortLevels, id: \.self) { level in
                                Text(level.capitalized).tag(level)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .accessibilityLabel("Thinking effort")
                        .accessibilityValue(config.thinkingEffort?.capitalized
                                            ?? "Default, \(AnthropicModelGeneration.defaultEffort(for: modelName ?? ""))")
                    }
                } else {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Thinking Budget")
                                .font(theme.fontFootnote.weight(.semibold))
                                .foregroundColor(theme.primaryText)
                            Text("Max tokens for internal reasoning. Must be less than Max Output Tokens.")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                                .lineSpacing(2.5)
                            if (config.thinkingBudgetTokens ?? 10000) >= config.maxTokens {
                                Text("Exceeds Max Output Tokens (\(config.maxTokens)) — the request will be sent with a raised limit of \((config.thinkingBudgetTokens ?? 10000) + 1024).")
                                    .font(theme.fontCaption2).foregroundColor(.orange)
                            }
                        }
                        Spacer(minLength: 16)
                        HStack {
                            Text("\(config.thinkingBudgetTokens ?? 10000)").monospacedDigit()
                            Stepper("", value: $config.thinkingBudgetTokens.toNonOptional(defaultValue: 10000), in: 1024...100000, step: 1024)
                                .labelsHidden()
                                .accessibilityLabel("Thinking budget tokens")
                                .accessibilityValue("\(config.thinkingBudgetTokens ?? 10000)")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - OpenAI Settings

struct OpenAISettingsView: View {
    @Binding var config: OpenAIAdvancedConfig
    /// The selected model, so the panel can hide controls it would reject (register A55).
    /// Empty when nothing is selected yet — treated as `.standard`, the permissive shape.
    var modelName: String = ""
    /// True only for an OpenRouter profile. OpenAI and OpenAI-compatible endpoints share this
    /// panel and this config type, but `provider.data_collection` means nothing to them — so,
    /// per the hide-don't-disable rule below, the control is not rendered there at all.
    var showsOpenRouterRouting: Bool = false
    @Environment(\.appTheme) private var theme

    /// Hides rather than disables Reasoning Effort for models that do not accept it, since setting it fails the request.
    private var family: OpenAIModelFamily { OpenAIModelFamily.classify(modelName: modelName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Max Tokens
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max Output Tokens")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Maximum length of the generated response. Leave at 0 for model default.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                }
                Spacer(minLength: 16)
                HStack {
                    Text("\(config.maxTokens ?? 0)").monospacedDigit()
                    Stepper("", value: $config.maxTokens.toNonOptional(defaultValue: 0), in: 0...128000, step: 256).labelsHidden()
                        .accessibilityLabel("Max tokens")
                        .accessibilityValue(config.maxTokens ?? 0 == 0 ? "Model decides" : "\(config.maxTokens ?? 0)")
                }
            }

            Divider()

            // Temperature and Top P are hidden for reasoning-model families, which run at fixed sampling
            // (`OpenAILLMProvider.applyGenerationParams` omits them).
            if family.acceptsSamplingParameters {
                // Temperature
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Temperature")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Controls the randomness of the generated response.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2.5)
                    }
                    Spacer(minLength: 16)
                    HStack {
                        Slider(value: $config.temperature.toNonOptional(defaultValue: 1.0), in: 0.0...2.0, step: 0.1)
                            .accessibilityLabel("Temperature")
                            .accessibilityValue(String(format: "%.2f", config.temperature ?? 1.0))
                            .frame(width: 150)
                        Text("\(config.temperature ?? 1.0, specifier: "%.2f")")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Divider()

                // Top P
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top P")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Cumulative probability of tokens to consider.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2.5)
                    }
                    Spacer(minLength: 16)
                    HStack {
                        Slider(value: $config.topP.toNonOptional(defaultValue: 1.0), in: 0.0...1.0, step: 0.05)
                            .frame(width: 150)
                            .accessibilityLabel("Top P")
                            .accessibilityValue(String(format: "%.2f", config.topP ?? 1.0))
                        Text("\(config.topP ?? 1.0, specifier: "%.2f")")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } else {
                // Says which controls are gone, why, and what to steer with instead, like the Anthropic panel's note.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(theme.secondaryText)
                    Text("Temperature and Top P are not available on reasoning models — OpenAI fixes sampling for this family and rejects both. Steer the response with your system instructions and the Reasoning Effort setting instead.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }

            if family.acceptsReasoningEffort {
                Divider()

                // Reasoning Effort — o-series and GPT-5 only; other models reject the parameter.
                Text("Reasoning")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .padding(.top, 8)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reasoning Effort")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Controls how much the model thinks before answering.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2.5)
                    }
                    Spacer(minLength: 16)
                    Picker("Reasoning Effort", selection: $config.reasoningEffort.toNonOptional(defaultValue: "")) {
                        Text("Auto").tag("")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Reasoning effort")
                }
            }

            if showsOpenRouterRouting {
                Divider()

                Text("Privacy")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .padding(.top, 8)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Deny Data Collection")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Only route to providers that don't store or train on your prompts. Many free (:free) models have no such provider and will stop working while this is on.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2.5)
                    }
                    Spacer(minLength: 16)
                    Toggle("", isOn: $config.denyDataCollection.toNonOptional(defaultValue: false))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Deny data collection")
                }
            }
        }
    }
}
