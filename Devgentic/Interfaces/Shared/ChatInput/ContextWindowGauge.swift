// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ContextWindowGauge.swift
//  Devgentic
//
//  A composer-side "how full is the context window" indicator (occupancy, NOT
//  cumulative billing). A small ring in the toolbar shows what fraction of the
//  SELECTED model's window this conversation currently fills; tapping it opens a
//  breakdown with the real last-turn token counts, and — when the effective window is
//  capped below the model's trained max (Ollama num_ctx) — a direct action to raise it.
//
//  Design decisions (see the feasibility discussion):
//    • Occupancy is measured with the SAME estimator the orchestrator uses at
//      send-time (`PromptFitCheck`) against the SAME denominator every budget in
//      the app uses (`EffectiveContextWindow.resolve`). So the ring agrees with the
//      engine's own fit / truncation / compaction decision instead of inventing a
//      second, divergent number.
//    • The ring is an ESTIMATE (chars→tokens heuristic), flagged with a "~". The
//      breakdown also surfaces the REAL provider-reported usage of the last turn,
//      so the exact counts the app already captures aren't wasted.
//    • Recomputed on turn / model / attachment changes — never per keystroke — so
//      it stays cheap on long transcripts. The unsent draft is deliberately
//      excluded from the ring (PreSendFitHint already warns on draft overflow).
//

import SwiftUI
import os

private let logger = DGLogger(category: "ContextWindowGauge")

// MARK: - Occupancy Model

/// A snapshot of how full the selected model's context window is for the current
/// conversation. Pure value type — the display math (`fraction`, `level`,
/// formatting) is unit-testable without a view or a store.
struct ContextWindowUsage: Equatable, Sendable {
    /// Estimated tokens the next send will occupy (history + attachments + overhead).
    let usedTokens: Int
    /// The window the request actually runs under (the gauge denominator) — Ollama's
    /// num_ctx allocation, MLX/cloud's trained window.
    let windowTokens: Int
    /// The model's TRAINED max, when known. Diverges from `windowTokens` only for Ollama,
    /// whose num_ctx caps well below it — surfaced in the breakdown so the gap is visible
    /// and actionable ("raise Context Window"). nil for cloud/MLX (they match) or unknown.
    let trainedTokens: Int?
    let modelName: String
    let provider: ApiProvider?
    /// The profile driving this gauge — lets the "raise context window" action in the
    /// breakdown deep-link straight to its settings. Nil only when unresolved.
    let profileID: UUID?
    /// Real provider-reported usage of the most recent completed agent turn, shown as
    /// ground truth in the breakdown. Nil on a fresh chat or before any reply lands.
    let lastTurn: TokenUsage?
    /// True when the window is a provider fallback guess rather than a model-declared
    /// size (e.g. an MLX model with no metadata → 8K). Surfaced so a surprising
    /// denominator is explainable from the UI itself.
    let windowIsFallback: Bool
    /// True when this profile retrieves conversation memory at send time. That payload is
    /// chosen by the query, so the composer cannot size it — the breakdown says so instead of
    /// letting the send-time banner appear from nowhere.
    let usesRetrieval: Bool
    /// True when ONE user turn can produce SEVERAL model calls — an agent re-sends the whole
    /// prompt on every tool step, and `TokenUsage.accumulate` sums them.
    ///
    /// This is why the breakdown showed two numbers that looked like a contradiction:
    /// `usedTokens` estimates a SINGLE next send, while `lastTurn.inputTokens` is the SUM
    /// over an entire multi-step turn. "~12K / 128K" above "Last turn 40K in" is not an error
    /// — they answer different questions, and nothing said so.
    let turnSpansMultipleCalls: Bool

    var fraction: Double { windowTokens > 0 ? Double(usedTokens) / Double(windowTokens) : 0 }
    /// Clamped for the bar/ring — the raw `fraction` can exceed 1.0 when the
    /// conversation has outgrown the window (compaction then trims before sending).
    var displayFraction: Double { min(1.0, max(0, fraction)) }
    var percent: Int { Int((fraction * 100).rounded()) }

    /// The share of the window actually available to the PROMPT — the rest is reserved for
    /// the model's reply, and the send-time check refuses to go past it.
    static var usableFraction: Double { 1.0 - PromptFitCheck.responseHeadroom }

    /// True once the conversation exceeds the whole window, not merely the usable share.
    /// Distinct from `.over`, which now means "past the limit the engine enforces".
    var exceedsWindow: Bool { fraction >= 1.0 }

    /// Bands derived from `responseHeadroom` rather than hard-coded, so the ring turns red at
    /// exactly the point `PromptFitCheck.exceeds` posts its banner.
    ///
    /// They used to disagree: red at 100%, banner at 75%. Between those the user saw an amber
    /// ring beside a red "content will be cut off" advisory — the gauge implying headroom the
    /// engine had already decided was gone.
    var level: ContextGaugeLevel {
        let limit = Self.usableFraction
        switch fraction {
        case ..<(limit * 0.8): return .normal
        case ..<limit:         return .high
        default:               return .over
        }
    }

    /// "~47K" — always prefixed because the ring is an estimate; a truly empty
    /// conversation prints a bare "0" rather than "~0".
    var usedDisplay: String { usedTokens == 0 ? "0" : "~" + PromptFitCheck.roundedK(usedTokens) }
    var windowDisplay: String { PromptFitCheck.roundedK(windowTokens) }

    /// The trained max when it EXCEEDS the effective window (Ollama num_ctx capping) — the
    /// "supported but not allocated" ceiling, surfaced so the user understands why a 131K
    /// model reads as 8K and can raise it. Nil when effective == trained (cloud / MLX) or
    /// the trained size is unknown.
    var cappedBelowTrained: Int? {
        guard let trained = trainedTokens, trained > windowTokens else { return nil }
        return trained
    }
}

/// Three visual bands. Kept coarse on purpose — a gauge that changes color at five
/// thresholds reads as noise. `normal` uses the accent (Claude's blue-donut cue);
/// `high`/`over` escalate to the warning/error roles.
enum ContextGaugeLevel {
    // The thresholds are fractions of `ContextWindowUsage.usableFraction` (= 1 −
    // PromptFitCheck.responseHeadroom), not of the whole window. The window percentages in
    // brackets are what today's 25% headroom works out to; they move if the headroom does.
    case normal   // below 80% of the usable share (< 60% of the window)
    case high     // 80–100% of the usable share (60–75% of the window)
    case over     // the usable share is gone (≥ 75% of the window): the prompt is now eating
                  // the room reserved for the reply, which is exactly where
                  // `PromptFitCheck.exceeds` posts its "content will be cut" banner. This does
                  // NOT mean the conversation outgrew the window — that is `exceedsWindow`,
                  // a separate property that needs the full 100%.

    func color(_ theme: any Theme) -> Color {
        switch self {
        case .normal: return theme.accentColor
        case .high:   return theme.warningColor
        case .over:   return theme.errorColor
        }
    }
}

// MARK: - Resolver

extension ContextWindowUsage {

    /// Builds the occupancy snapshot from live composer state, or `nil` when the gauge
    /// should hide (non-chat profile / no resolvable model). `@MainActor` because it
    /// reads the profile store for the cross-model comparison.
    /// - Parameter extraKnowledgeChars: characters of KNOWN, always-injected context the
    ///   generic history/attachment estimate can't see from the composer — today, Code
    ///   mode's `.devgentic/context.md` project context, added into the system prompt on
    ///   every message. 0 for ordinary chat.
    /// - Parameter messages: the history the NEXT request would carry, **OLDEST-FIRST** —
    ///   from `ChatHistoryViewModel.resolveContextHistory(for:)`, NOT `currentChatMessages`.
    ///   Passing the render window is the bug this signature exists to prevent: the window is
    ///   a pagination artefact (20 on open, +10 per scroll) and sizing a request from it made
    ///   the ring move when the user scrolled.
    @MainActor
    static func resolve(
        profile: BackendProfileModel?,
        messages: [ChatMessage],
        attachedFiles: [FileSystemItem],
        conversationID: UUID?,
        extraKnowledgeChars: Int = 0
    ) -> ContextWindowUsage? {
        // Only chat-shaped profiles have a SINGLE context window. Workflow resolves a
        // model per node and imageGen has none, so a window gauge would be meaningless —
        // hide it rather than show a misleading number. (Matches PreSendFitHint's gate.)
        guard let profile,
              profile.profileType == .bot || profile.profileType == .agent || profile.profileType == .code,
              let config = profile.resolvedLLMConfig
        else {
            logger.debug("[CTXGAUGE] Hidden — no single-window chat profile (type=\(profile?.profileType.rawValue ?? "nil")) for conv=\(conversationID?.uuidString.prefix(8).description ?? "none"). Gauge not shown.")
            return nil
        }

        let (window, trained) = windows(for: config, profileID: profile.id)
        let windowIsFallback = (trained == nil)

        // `resolvedHistoryStrategy` is nil for bot / code profiles; the estimator resolves
        // that to `.recentHistory`, matching AgentConnect's own non-agent fallback. All
        // three profile types the gauge shows for DO receive episodic memory
        // (`PromptLayerConfig.bot/.agent/.code` all set `includeEpisodicMemory`), so none of
        // them is being charged for payload it never sees.
        let used = estimatedOccupancyTokens(
            config: config,
            profile: profile,
            messages: messages,
            attachedFiles: attachedFiles,
            historyStrategy: profile.resolvedHistoryStrategy,
            contextWindow: window,
            extraKnowledgeChars: extraKnowledgeChars
        )

        // Ground truth for the breakdown: the newest completed agent turn's REAL usage.
        // The resolved history is ASCENDING (oldest first), so the LAST agent message
        // carrying usage is the most recent one. This read `.first` while being handed the
        // descending render window; both changed together and must stay in step.
        let lastTurn = messages.last(where: { $0.sender == .agent && $0.tokenUsage != nil })?.tokenUsage

        logger.debug("[CTXGAUGE] \(config.modelName) — ~\(used)/\(window) tok (\(window > 0 ? Int((Double(used) / Double(window)) * 100) : 0)%), fallbackWindow=\(windowIsFallback), lastTurnReal=\(lastTurn.map { "\($0.inputTokens)in/\($0.outputTokens)out" } ?? "none"), conv=\(conversationID?.uuidString.prefix(8).description ?? "none")")

        return ContextWindowUsage(
            usedTokens: used,
            windowTokens: window,
            trainedTokens: trained,
            modelName: config.modelName,
            provider: config.apiProvider,
            profileID: profile.id,
            lastTurn: lastTurn,
            windowIsFallback: windowIsFallback,
            // Matches `profileUsesConversationRAG` in the orchestrator.
            usesRetrieval: profile.profileType == .bot || profile.profileType == .agent,
            // Agent and Code both run the ReAct loop (`ExecutorFactory`); a bot is one call.
            turnSpansMultipleCalls: profile.profileType == .agent || profile.profileType == .code
        )
    }

    /// Resolves the (effective, trained) window pair for a config, healing stale MLX
    /// metadata along the way. `effective` = what the request actually runs under (the
    /// gauge denominator); `trained` = the model's max. They diverge only for Ollama
    /// (num_ctx caps below trained) and match for cloud / MLX.
    @MainActor
    static func windows(for config: ProviderConfig, profileID: UUID?) -> (effective: Int, trained: Int?) {
        var trained = EffectiveContextWindow.trainedWindow(for: config)
        // MLX profiles saved before the config.json window read carry nil metadata → the
        // shared resolver would return the 8K fallback. Recover the real window (and heal
        // the stored profile) so both the gauge and the budgets stop guessing.
        if trained == nil, config.apiProvider == .mlx {
            trained = MLXContextWindowHealer.trainedWindow(for: config, profileID: profileID)
        }
        let effective: Int
        if config.apiProvider == .mlx {
            // MLX: the app owns the prompt, so the whole trained window is usable.
            effective = max(2_048, trained ?? 8_192)
        } else {
            // Ollama → num_ctx allocation; cloud → trained/catalog. Both via the shared resolver.
            effective = EffectiveContextWindow.resolve(for: config)
        }
        return (effective, trained)
    }

    /// Occupancy = the assembled prompt size the NEXT send will produce, via the same
    /// `PromptFitCheck` heuristic the orchestrator applies at send-time. Includes the
    /// conversation history (the whole point of this gauge, and exactly what PreSendFitHint
    /// omits) + current text/code attachments + the fixed layer overhead. Images are
    /// counted only when the model can see them.
    ///
    /// `extraKnowledgeChars` is caller-supplied KNOWN context (Code mode's project
    /// context) that IS counted — it's a fixed per-message injection, not a send-time
    /// unknown.
    ///
    /// Episodic memory IS counted (since 2026-07-28). It used to be invisible here:
    /// `textContent` is nil for tool params, outcomes and `<effect>` diffs, so a
    /// conversation full of file edits — the case most likely to overflow — read as almost
    /// empty. The blob is rendered for real rather than approximated, which is affordable
    /// because this recomputes on turn boundaries, not keystrokes.
    ///
    /// Documented, deliberate under-counts that keep this a STABLE, conservative gauge:
    ///   • the unsent draft (excluded so the ring doesn't jump per keystroke),
    ///   • per-conversation RAG (chosen by the query; surfaced as a note instead).
    ///
    /// Profile knowledge sources and prior-turn images ARE counted now. The images were
    /// excluded because "the recency window needs ascending order and this array is
    /// descending" — no longer true since the gauge began resolving history the way the
    /// request does.
    @MainActor
    static func estimatedOccupancyTokens(
        config: ProviderConfig,
        profile: BackendProfileModel,
        messages: [ChatMessage],
        attachedFiles: [FileSystemItem],
        historyStrategy: HistoryStrategy?,
        contextWindow: Int,
        extraKnowledgeChars: Int = 0
    ) -> Int {
        // A brand-new chat with nothing attached reads as empty, not as the ~0.7K the
        // fixed layer overhead alone would imply. Code mode's always-injected project
        // context counts as real content, so a fresh code session with a large context.md
        // correctly reads as already partly full.
        guard !messages.isEmpty || !attachedFiles.isEmpty || extraKnowledgeChars > 0 else { return 0 }

        // The request strips error turns before building the prompt
        // (`BackendOrchestrationService`, "Sanitize History"), so charging for them here
        // reports payload that is never sent.
        let messages = messages.filter {
            if case .error = $0.content { return false }
            return true
        }

        // No reversal: `messages` is already oldest-first, which is what `pairTurns` needs.
        // It previously had to be reversed because the caller passed the descending render
        // window — the reversal and the wrong source were the same bug.
        // Warmed here because the composer always renders before a send, so the orchestrator's
        // (non-MainActor) fit check finds a populated snapshot.
        ToolSchemaSizes.refreshFromRegistry()
        let toolSchemaChars = PromptFitCheck.estimatedToolSchemaChars(for: profile)
        let knowledgeSourceChars = PromptFitCheck.estimatedKnowledgeSourceChars(for: profile)

        let episodicChars = PromptFitCheck.estimatedEpisodicChars(
            in: messages,
            strategy: historyStrategy,
            contextWindow: contextWindow,
            toolsAvailable: profile.profileType != .bot,
            // Same expression the request uses (`AgentConnect`), not the local
            // `supportedModalities` check below it: the two disagree for `.code` profiles, and
            // the ring's whole claim is that it measures what actually ships. Omitting it
            // defaulted to false and left every `<attached_images>` line in the blob
            // unmeasured — an under-count, i.e. the direction that fails to warn.
            includeImageNames: profile.supportsVisionInput
        )
        // Measured, not summed. The raw `textContent` sum over every message ignored the
        // per-strategy turn limit AND the char budget's trimming AND whether the provider
        // receives prose at all — on MLX it charged a full transcript that never ships,
        // reading 248% of an 8K window where the truth was 24%.
        let proseChars = PromptFitCheck.estimatedHistoryProseChars(
            in: messages,
            carriesProse: profile.carriesHistoryProse,
            strategy: historyStrategy,
            contextWindow: contextWindow
        )
        let historyChars = proseChars + episodicChars
        // Strategy-aware: a `.stateless` profile ships a path manifest, not the files, so
        // charging their bytes over-warned by orders of magnitude on a large attachment.
        // Also drops files the reader will refuse rather than clipping them to the budget.
        let attachmentChars = PromptFitCheck.estimatedAttachmentChars(
            for: attachedFiles, profile: profile
        )

        // Priced only when the model accepts vision — a non-vision model has its images
        // stripped before the wire, so charging for them would inflate the gauge for
        // payload that never ships.
        let supportsVision = config.supportedModalities.contains(.visionInput)
        let currentImageTokens = supportsVision
            ? PromptFitCheck.estimatedImageTokens(forImageURLs: PreSendFitHint.imageURLs(of: attachedFiles), provider: config.apiProvider)
            : 0
        // Prior-turn images, on the same gate and the same 20-message lookback the send-time
        // check uses — so a vision conversation with several screenshots no longer reads
        // ~10K tokens lighter here than it does at send.
        let historyImageTokens = PromptFitCheck.estimatedHistoryImageTokens(
            in: messages,
            provider: config.apiProvider,
            shipsHistoryImages: profile.carriesHistoryImages && historyStrategy != .pointer
        )
        let imageTokens = currentImageTokens + historyImageTokens

        // Without the breakdown, "the ring says 80% on a short chat" is undiagnosable — the
        // total alone can't distinguish a big attachment from an edit-heavy history whose
        // cost is entirely invisible in the transcript.
        logger.debug("[CTXGAUGE] Breakdown — episodic \(episodicChars) chars (strategy=\(historyStrategy?.rawValue ?? "recentHistory/non-agent default"), \(messages.count) msg), prose \(proseChars) chars (carried=\(profile.carriesHistoryProse)), attachments \(attachmentChars) chars, knowledge \(extraKnowledgeChars) chars, tools \(toolSchemaChars) chars, kb \(knowledgeSourceChars) chars, images \(currentImageTokens)+\(historyImageTokens) tok.")

        return PromptFitCheck.estimatedTokens(
            attachmentChars: attachmentChars,
            knowledgeChars: extraKnowledgeChars + toolSchemaChars + knowledgeSourceChars,
            retrievalChars: 0,
            queryChars: 0,
            historyChars: historyChars,
            imageTokens: imageTokens
        )
    }

}

// MARK: - Ring (collapsed indicator)

/// The small toolbar ring. Just the donut — the number lives in the tooltip and the
/// tap-through breakdown, matching the "small icon" the user asked for.
struct ContextWindowGauge: View {
    let usage: ContextWindowUsage
    /// Optional deep-link to the profile's settings (raise Context Window). Each surface
    /// supplies the right implementation — the main window routes; QuickAccess activates
    /// the main window and posts. Nil → the breakdown falls back to instructional text.
    var onOpenSettings: ((UUID) -> Void)? = nil
    @Environment(\.appTheme) private var theme
    @State private var showBreakdown = false
    @State private var isHovered = false

    private let ringSize: CGFloat = 14
    private let ringWidth: CGFloat = 2.2

    var body: some View {
        Button {
            showBreakdown.toggle()
        } label: {
            ZStack {
                Circle()
                    .stroke(theme.secondaryText.opacity(0.3), lineWidth: ringWidth)
                Circle()
                    .trim(from: 0, to: usage.displayFraction)
                    .stroke(usage.level.color(theme), style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.25), value: usage.displayFraction)
            }
            .frame(width: ringSize, height: ringSize)
            .frame(width: 28, height: 28)
            .background(
                Circle()
                    .fill(isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
            )
            .overlay(
                Circle()
                    .stroke(isHovered ? theme.secondaryText.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .shadow(color: isHovered ? usage.level.color(theme).opacity(0.4) : .clear, radius: 4, x: 0, y: 1)
            .scaleEffect(isHovered ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = hovering }
        }
        .help(Text("Context window · \(usage.percent)% used (\(usage.usedDisplay) of \(usage.windowDisplay))"))
        .accessibilityLabel(Text("Context window \(usage.percent) percent used, \(usage.usedDisplay) of \(usage.windowDisplay) tokens"))
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $showBreakdown, arrowEdge: .top) {
            ContextWindowBreakdown(
                usage: usage,
                // Dismiss the popover as we navigate away; nil stays nil so the button hides.
                onOpenSettings: onOpenSettings == nil ? nil : { id in
                    showBreakdown = false
                    onOpenSettings?(id)
                }
            )
            .environment(\.appTheme, theme)
        }
    }
}

// MARK: - Breakdown (expanded popover)

/// The tap-through detail: headline number + bar, the REAL last-turn counts, and any
/// contextual notes (including the raisable-window action).
struct ContextWindowBreakdown: View {
    let usage: ContextWindowUsage
    var onOpenSettings: ((UUID) -> Void)? = nil
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            headline
            bar
            if let last = usage.lastTurn { lastTurnRow(last) }
            notes
        }
        .padding(14)
        .frame(width: 288)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            Text("Context window")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
            Spacer(minLength: 8)
            Text(usage.modelName)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Next send")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .textCase(.uppercase)
            headlineFigures
        }
    }

    private var headlineFigures: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(usage.usedDisplay)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(usage.level.color(theme))
            Text("/ \(usage.windowDisplay)")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
            Spacer()
            Text("\(usage.percent)%")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(usage.level.color(theme))
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surfaceOverlayStrong)
                Capsule()
                    .fill(usage.level.color(theme))
                    .frame(width: max(3, geo.size.width * usage.displayFraction))
            }
        }
        .frame(height: 6)
    }

    private func lastTurnRow(_ turn: TokenUsage) -> some View {
        let prefix = turn.isEstimated ? "~" : ""
        return HStack(spacing: 6) {
            Image(systemName: "number.circle")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            Text(usage.turnSpansMultipleCalls ? "Last turn (all steps)" : "Last turn (actual)")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            Spacer()
            Text("\(prefix)\(PromptFitCheck.roundedK(turn.inputTokens)) in · \(prefix)\(PromptFitCheck.roundedK(turn.outputTokens)) out")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.secondaryText)
        }
    }

    @ViewBuilder
    private var notes: some View {
        // The "why is my 131K model showing 8K?" answer: Ollama only allocates num_ctx
        // KV cache and truncates beyond it, so the effective window is the honest ceiling —
        // but the model supports more, and it's raisable.
        if let trained = usage.cappedBelowTrained {
            cappedNote(trained: trained)
        }
        // Two different statements. `.over` now means "past the usable share"; only
        // `exceedsWindow` means the conversation genuinely outgrew the window.
        if usage.exceedsWindow {
            noteRow(
                icon: "arrow.triangle.2.circlepath",
                text: "This conversation is larger than the window — older turns are trimmed or summarized before each send."
            )
        } else if usage.level == .over {
            noteRow(
                icon: "exclamationmark.triangle",
                text: "Past the \(Int(ContextWindowUsage.usableFraction * 100))% the prompt can use — the rest of the window is reserved for the reply, so content will be cut before sending."
            )
        }
        // Retrieval is chosen by the query and cannot be known before you send, so it is not
        // in the figure above. Saying so beats letting the send-time banner look like a
        // contradiction.
        if usage.usesRetrieval {
            noteRow(
                icon: "magnifyingglass",
                text: "Conversation memory adds retrieved context at send time — not included above."
            )
        }
        // Without this the breakdown reads as self-contradictory: an estimate for ONE send
        // sitting directly above a measured total for a turn that made many.
        if usage.turnSpansMultipleCalls, usage.lastTurn != nil {
            noteRow(
                icon: "arrow.trianglehead.2.clockwise",
                text: "\"Next send\" estimates one request. \"Last turn\" is the measured total across every model call in that turn — this profile re-sends the prompt on each tool step, so it is normally the larger number."
            )
        }
        if usage.windowIsFallback {
            noteRow(
                icon: "questionmark.circle",
                text: "\(usage.modelName) didn't report a context length — showing a \(usage.windowDisplay) estimate."
            )
        }
    }

    private func noteRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryText)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The "why is my 131K model showing 8K?" note plus a direct action to raise the
    /// window. Falls back to instructional text when no settings action is wired.
    @ViewBuilder
    private func cappedNote(trained: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            noteRow(
                icon: "arrow.up.forward.circle",
                text: "\(usage.windowDisplay) allocated of \(PromptFitCheck.roundedK(trained)) the model supports."
            )
            if let profileID = usage.profileID, let onOpenSettings {
                Button {
                    onOpenSettings(profileID)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 10))
                        Text("Raise Context Window").font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
                .help("Open this profile's Advanced settings to raise its context window")
            } else {
                Text("Raise Context Window in the profile's Advanced settings to use more.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
            }
        }
    }
}
