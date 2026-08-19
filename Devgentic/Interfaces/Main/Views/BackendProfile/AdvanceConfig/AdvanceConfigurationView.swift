//
//  AdvanceConfigurationView.swift
//  Devgentic
//
//  Created by Raj Singh on 05/09/25.
//  Updated on 28/02/26 to adopt Modern UI Layout and alignment.
//

import SwiftUI

// MARK: - Shared Components

/// Visible numeric text field used by MLX/Ollama advanced configuration panels.
/// Replaces SwiftUI's `.roundedBorder` style which is nearly invisible in dark
/// theme — users couldn't tell the value was tappable. Pair with a `Stepper`
/// bound to the same `value` for the standard "type-or-step" combo.
///
/// Lives here (not as a private helper in each view) so the two providers'
/// Advanced Configuration panels stay visually consistent — any future styling
/// tweak lands in one place instead of drifting across copies.
struct AdvancedConfigNumericField: View {
    @Binding var value: Int
    let width: CGFloat
    /// Spoken name for the field. ⚠️ Register A61: the `TextField` label is `""` so the control
    /// announces as a bare, nameless text field — the parameter name lives in a sibling `Text` that
    /// VoiceOver reads as unrelated static text. Required rather than defaulted, so a new caller
    /// cannot add another unlabeled field by omission.
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
                    Text("Temperature").fontWeight(.medium)
                    Text("Controls the randomness of the generated response. Gemini accepts 0.0–2.0; above 1.0 is markedly more divergent.")
                        .font(.caption).foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 16)
                HStack {
                    // ⚠️ Register A73: capped at 1.0, while `generationConfig.temperature` accepts
                    // 0.0–2.0. The upper half of the model's range was simply unreachable, and
                    // silently so — the slider bottomed out at its own maximum with no indication
                    // it was the UI's limit rather than the API's. The OpenAI panel below already
                    // uses 0.0...2.0 for the same parameter.
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
                    Text("Top P").fontWeight(.medium)
                    Text("Cumulative probability of tokens to consider.").font(.caption).foregroundColor(theme.secondaryText)
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
                    Text("Top K").fontWeight(.medium)
                    Text("Maximum number of tokens to consider.").font(.caption).foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 16)
                HStack {
                    // ⚠️ register A54 — the nil fallback was `1`, so merely touching the stepper
                    // persisted greedy decoding. Google's own default is 64; 40 is the value the
                    // stepper lands on when the user starts adjusting from an unset config.
                    Text(config.topK.map(String.init) ?? "Default").monospacedDigit()
                    Stepper("", value: $config.topK.toNonOptional(defaultValue: 40), in: 1...100).labelsHidden()
                        .accessibilityLabel("Top K")
                        .accessibilityValue(config.topK.map(String.init) ?? "Default")
                }
            }

            // ⚠️ Warn rather than clamp — the same choice the Ollama panel makes for num_ctx.
            // Top K 1 is legitimate if you actually want greedy decoding, so the floor stays at 1;
            // what was wrong was arriving there by accident and silently losing two other controls.
            if config.topK == 1 {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.warningColor)
                    Text("Top K 1 selects only the single most likely token, so Temperature and Top P above have no effect and responses repeat verbatim. Raise Top K to let them apply.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }

            Divider()
            
            // Max Output Tokens
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max Output Tokens").fontWeight(.medium)
                    Text("Maximum length of the generated response.").font(.caption).foregroundColor(theme.secondaryText)
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
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.top, 8)
            
            ForEach($config.safetySettings.toNonOptional(defaultValue: GeminiAdvancedConfig.default().safetySettings ?? [])) { $setting in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(setting.category.localizedTitle)
                            .fontWeight(.medium)
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

// ⚠️ These replace `formatCategory` / `formatThreshold`, which string-munged the WIRE value at
// runtime ("HARM_CATEGORY_HATE_SPEECH" -> "Hate Speech"). That output could never be localized:
// a runtime-built string is not a String Catalog key, and `LocalizedStringKey(someString)` is
// invisible to the extractor. It was also fragile — it depended on Google's constant spelling,
// and the `text == "None" ? "Block None"` special case existed only to patch up what the
// munging produced. ⚠️ The rawValues are WIRE values sent to the Gemini API and are `Codable`
// (persisted in a profile's advanced config): never change them.

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

    /// Active model metadata. Currently only used to derive the Context Window
    /// cap; populated from `/api/show` for Ollama models. Nil when the profile
    /// has no model selected — the view falls back to the catalog lookup.
    let modelMetadata: ModelMetadata?
    /// Active model name. Used as a secondary fallback for context-window
    /// detection when `modelMetadata.contextWindow` is nil — Ollama populates
    /// tier/quant/family from `/api/show.details` but doesn't currently extract
    /// the context window itself, so the catalog lookup is the practical source.
    let modelName: String?
    /// Whether this view is hosted in an Agent or Bot profile. Drives which
    /// preset the "Apply Optimal" menu produces (strict agent vs warm chat).
    /// No default — every callsite must specify so a Bot profile never silently
    /// inherits agent-strict defaults from a forgotten parameter.
    let defaultProfile: OllamaConfigDefaultProfile

    @Environment(\.appTheme) private var theme

    /// Local draft of the stop-sequences editor text. Backed by `@State` so the
    /// TextEditor's normal Enter-to-add-line behaviour works — committing
    /// directly to `config.stop` per keystroke would normalize the value
    /// (split → trim → filter) and round-trip via `get` would strip trailing
    /// newlines, yanking the cursor back from the new line the user just opened.
    /// We commit to `config.stop` only on focus loss.
    @State private var stopsDraft: String = ""

    /// Tracks whether the stops editor is the active responder so we can commit
    /// the draft on focus loss and resync the draft on external changes (Apply
    /// Optimal etc.) without clobbering whatever the user is currently typing.
    @FocusState private var stopsFocused: Bool

    /// Effective context window for bound derivation. Layered fallback that
    /// mirrors AgentConnect.swift's runtime logic so the UI bounds match what
    /// the executor will accept:
    ///   1. ModelMetadata.contextWindow if captured during scan
    ///   2. KnownModelContextWindows.lookup(modelName) catalog entry
    ///   3. 8192 safe default
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
                    Text("Temperature").fontWeight(.medium)
                    Text("Sharpens or flattens the next-token distribution. 0.0 = pick the single most likely token (deterministic, best for tool calls). 0.5–0.7 = natural conversation. 1.0+ = creative/varied. Above 1.5 is rarely useful.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
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
                    Text("Top P").fontWeight(.medium)
                    Text("After temperature, restricts sampling to the smallest set of tokens whose combined probability reaches this value (nucleus sampling). 1.0 = no filter. 0.9–0.95 = standard chat. 0.7–0.85 = tighter; pairs with higher temperature to keep output coherent.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
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
                    Text("Top K").fontWeight(.medium)
                    Text("Caps the number of candidate tokens at each step. 0 = disabled (sample from full vocabulary). 1–10 = very tight, near-greedy. 40–100 = standard. Higher = more variety. Combine with low temperature for predictable structured output.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Range: 0–1000")
                        .font(.caption2)
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
                    Text("Context Window").fontWeight(.medium)
                    Text("Number of tokens the model holds in working memory (num_ctx). Ollama's default of 2048 is too low for modern long-context use — set this to your model's actual context size to unlock its full capability. Costs a few MB of RAM per 1K tokens.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Range: 256–\(numCtxCap)\(modelContextSuffix)")
                        .font(.caption2)
                        .foregroundColor(theme.secondaryText.opacity(0.7))

                    // Warning when the saved value exceeds this model's cap. Happens
                    // when a user switches to a smaller-context model after tuning
                    // numCtx for a larger one. We don't auto-clamp (would silently
                    // destroy tuning) — the user gets the choice.
                    if let current = config.numCtx, current > numCtxCap {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .accessibilityHidden(true)
                            Text("Current value \(current) exceeds this model's max context \(numCtxCap). Ollama may reject or silently clamp the request.")
                                .font(.caption2)
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
                // Only clamp when the user typed a value below the absolute floor.
                // We don't clamp the upper bound here — values exceeding the model's
                // context window are surfaced via the warning above so the user can
                // choose to keep their setting (e.g. switching models for comparison).
                if v < 256 { config.numCtx = 256 }
            }

            Divider()

            // Stop Sequences — multi-line editor (one stop per line)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stop Sequences").fontWeight(.medium)
                    Text("Sequences that immediately end generation when produced. One per line. Useful for cutting off model output at specific tokens (e.g. '<|end|>', '\\n\\n###'). Leave empty to use the model's built-in stops.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                stopSequencesEditor
            }

            Divider()

            // Seed — visible TextField styling matching the rest of the panel
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fixed Seed").fontWeight(.medium)
                    Text("Optional fixed seed for reproducible outputs. Same seed + same prompt + same model produces identical output. Useful for testing, evaluation, and debugging. Leave empty for random.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
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
                    Text("Repeat Penalty").fontWeight(.medium)
                    Text("Multiplier applied to the probability of recently-emitted tokens. 1.0 = off. 1.05–1.1 = mild (suits chat). 1.15–1.3 = stronger (helps small/Q4 models break repetition loops). Above 1.5 can make output incoherent.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
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
                    Text("Extended Thinking").fontWeight(.medium)
                    Text("Enable reasoning traces before the response. Only works on reasoning models (deepseek-r1, qwq, qwen3, etc.). If the model rejects this, it will be disabled automatically.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: $thinkingEnabled)
                    .accessibilityLabel("Extended thinking")
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Divider()

            // Reset to Defaults — single click, matches MLX. Tier auto-detected
            // from `modelMetadata.tier` (populated by OllamaConnect.buildMetadata
            // from /api/show.details.parameter_size). Agent profiles get the
            // strict preset; bot profiles get the warm chat preset. Replaces
            // the legacy "Apply Optimal" 2-click menu cascade — the manual
            // tier picker existed because auto-tier detection was unreliable
            // before; we now have reliable metadata for every model.
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

    /// Multi-line editor for stop sequences. Backed by `@State stopsDraft` so
    /// pressing Enter doesn't trip the immediate-commit binding's normalization
    /// (split → trim → filter empties), which would round-trip back through
    /// `get` without a trailing newline and yank the cursor back to the
    /// previous line. Commit happens on focus loss; external changes (Apply
    /// Optimal) sync into the draft only when the user isn't editing.
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
            // Commit when the editor loses focus. Save buttons elsewhere
            // shift focus first, so the parent's persistence path always
            // reads a freshly-committed config.stop.
            if !focused { commitStopsDraft() }
        }
        .onChange(of: config.stop) { _, _ in
            // External update (e.g. Apply Optimal replacing the entire config)
            // — refresh display only when the user isn't actively editing, to
            // avoid clobbering in-progress input.
            if !stopsFocused {
                stopsDraft = (config.stop ?? []).joined(separator: "\n")
            }
        }
    }

    /// Parses the draft string into a clean `[String]?` and writes to `config.stop`.
    /// Whitespace-only lines and empty lines are filtered. An empty result
    /// becomes `nil` (Ollama interprets nil/missing as "use the model's
    /// built-in stops", which is the desired default).
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
    /// Selected model id. Drives which controls are shown — the Anthropic request contract
    /// differs by model generation, and a control the model rejects is worse than no control:
    /// it 400s the request instead of being ignored. Nil is treated as newest (see
    /// `AnthropicModelGeneration`).
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
                    Text("Max Output Tokens").fontWeight(.medium)
                    Text("Maximum length of the generated response. Claude requires this explicitly.").font(.caption).foregroundColor(theme.secondaryText)
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

            // --- SAMPLING ---
            // ⚠️ Hidden entirely, not disabled, on models that removed these parameters. A
            // disabled-but-visible control still implies the value is stored and honoured
            // somewhere; on Opus 4.7+ / Sonnet 5 / Fable 5 it is neither — sending any of the
            // three returns 400. The note below says so rather than leaving dead sliders.
            if generation.acceptsSamplingParams {
                // Temperature
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Temperature").fontWeight(.medium)
                        if config.extendedThinking {
                            Text("Not sent while Extended Thinking is on — thinking does not permit sampling parameters.")
                                .font(.caption).foregroundColor(.orange)
                        } else {
                            Text("Controls the randomness of the generated response.").font(.caption).foregroundColor(theme.secondaryText)
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
                        Text("Top P").fontWeight(.medium)
                        if config.extendedThinking {
                            Text("Not sent while Extended Thinking is on.").font(.caption).foregroundColor(.orange)
                        } else if config.temperature != nil {
                            Text("Not sent while Temperature is set — Claude accepts one or the other, never both.")
                                .font(.caption).foregroundColor(.orange)
                        } else {
                            Text("Cumulative probability of tokens to consider.").font(.caption).foregroundColor(theme.secondaryText)
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
                        Text("Top K").fontWeight(.medium)
                        Text("Maximum number of tokens to consider when sampling.").font(.caption).foregroundColor(theme.secondaryText)
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
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }

            Divider()

            // Extended Thinking Section
            Text("Extended Thinking")
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.top, 8)

            // ⚠️ HIDDEN, not disabled, on models where thinking is always on (Fable 5 / Mythos 5).
            // A greyed-out switch still implies the value is stored and honoured somewhere, and
            // here it is neither: the request ignores it, and the "off" shape the provider used to
            // send — `{"type": "disabled"}` — is rejected with a 400 by those models at every
            // effort level. Same rule as the ImageGen Quality gate (register A56).
            if generation.acceptsDisabledThinking {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Thinking").fontWeight(.medium)
                        Text("Claude will reason internally before responding. Improves complex task performance.").font(.caption).foregroundColor(theme.secondaryText)
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
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }

            // Effort is the only depth control on an always-on model, so it must stay reachable
            // there even though the toggle above is gone.
            if config.extendedThinking || !generation.acceptsDisabledThinking {
                Divider()

                // ⚠️ Two different controls for the same concept, because the API contract
                // differs by model. `budget_tokens` (a token count) was replaced by
                // `output_config.effort` (a ladder) on Opus 4.7+ / Sonnet 5 / Fable 5, where the
                // old shape now returns 400. Showing the stepper there would steer a parameter
                // the model rejects.
                if generation.acceptsEffort {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Thinking Effort").fontWeight(.medium)
                            Text("How much reasoning Claude spends before answering. Higher costs more tokens and latency.")
                                .font(.caption).foregroundColor(theme.secondaryText)
                        }
                        Spacer(minLength: 16)
                        Picker("", selection: $config.thinkingEffort.toNonOptional(defaultValue: "")) {
                            Text("Default (high)").tag("")
                            ForEach(generation.supportedEffortLevels, id: \.self) { level in
                                Text(level.capitalized).tag(level)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .accessibilityLabel("Thinking effort")
                        .accessibilityValue(config.thinkingEffort?.capitalized ?? "Default, high")
                    }
                } else {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Thinking Budget").fontWeight(.medium)
                            Text("Max tokens for internal reasoning. Must be less than Max Output Tokens.").font(.caption).foregroundColor(theme.secondaryText)
                            if (config.thinkingBudgetTokens ?? 10000) >= config.maxTokens {
                                Text("Exceeds Max Output Tokens (\(config.maxTokens)) — the request will be sent with a raised limit of \((config.thinkingBudgetTokens ?? 10000) + 1024).")
                                    .font(.caption).foregroundColor(.orange)
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
    @Environment(\.appTheme) private var theme

    /// ⚠️ Register A55. **Hide, don't disable** (the rule A56 established): a greyed-out control
    /// still implies the value is stored and honoured. Reasoning Effort was shown for every model
    /// and sent to every endpoint, so setting it on a normal model failed the whole request.
    private var family: OpenAIModelFamily { OpenAIModelFamily.classify(modelName: modelName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Max Tokens
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max Output Tokens").fontWeight(.medium)
                    Text("Maximum length of the generated response. Leave at 0 for model default.").font(.caption).foregroundColor(theme.secondaryText)
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

            // ⚠️ register B33 — the panel STATED the hide-don't-disable rule above and then applied
            // it to one control out of three. `family` was consulted exactly once, for Reasoning
            // Effort, while Temperature and Top P rendered unconditionally at full opacity with
            // captions that said nothing about reasoning models. On an o1/o3/o4/GPT-5 profile the
            // user could drag Temperature to 0.2, watch it save, reopen the panel to see 0.20 — and
            // every request omitted it and ran at the model's fixed sampling
            // (`OpenAILLMProvider.applyGenerationParams`). That is the decorative knob A56 exists to
            // prevent, and it was strictly worse disclosure than the Anthropic panel it is modelled
            // on, which hides the block and explains why.
            if family.acceptsSamplingParameters {
                // Temperature
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Temperature").fontWeight(.medium)
                        Text("Controls the randomness of the generated response.").font(.caption).foregroundColor(theme.secondaryText)
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
                        Text("Top P").fontWeight(.medium)
                        Text("Cumulative probability of tokens to consider.").font(.caption).foregroundColor(theme.secondaryText)
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
                // ⚠️ Same shape as the Anthropic panel's note: say WHICH controls are gone, WHY,
                // and what to steer with instead. A hidden control with no explanation reads as a
                // missing feature.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(theme.secondaryText)
                    Text("Temperature and Top P are not available on reasoning models — OpenAI fixes sampling for this family and rejects both. Steer the response with your system instructions and the Reasoning Effort setting instead.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }

            if family.acceptsReasoningEffort {
                Divider()

                // Reasoning Effort — o-series and GPT-5 only; other models reject the parameter.
                Text("Reasoning")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .padding(.top, 8)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reasoning Effort").fontWeight(.medium)
                        Text("Controls how much the model thinks before answering.").font(.caption).foregroundColor(theme.secondaryText)
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
        }
    }
}
