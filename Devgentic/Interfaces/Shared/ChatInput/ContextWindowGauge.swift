// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ContextWindowGauge.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit
import os

private let logger = DGLogger(category: "ContextWindowGauge")

// MARK: - Occupancy Model

/// What the next send's estimate is made of: the tool, history, knowledge and attachment rows in the breakdown.
struct ContextOccupancy: Equatable, Sendable {
    var toolChars = 0
    var historyChars = 0
    var knowledgeChars = 0
    var attachmentChars = 0
    /// The fixed prompt layers `PromptFitCheck.estimatedTokens` adds on top.
    var overheadChars = PromptFitCheck.layerOverheadChars
    var imageTokens = 0

    static func tokens(_ chars: Int) -> Int { Int(Double(chars) / PromptFitCheck.charsPerToken) }
}

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
    /// True when one user turn can produce several model calls, since an agent re-sends the prompt on every tool step.
    /// `usedTokens` estimates a single next send, while `lastTurn.inputTokens` sums an entire multi-step turn.
    let turnSpansMultipleCalls: Bool
    /// What the estimate above is made of. Nil for an empty conversation (nothing to break down).
    var breakdown: ContextOccupancy? = nil
    /// Lets the breakdown read what the last turn in THIS conversation had to cut.
    var conversationID: UUID? = nil

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

    /// Bands derived from `responseHeadroom` rather than hard-coded, so the ring turns red exactly where
    /// `PromptFitCheck.exceeds` posts its banner.
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

    /// The trained max when it exceeds the effective window (Ollama `num_ctx` capping), so the user can see why a large
    /// model reads small.
    /// Nil when effective equals trained (cloud, MLX) or the trained size is unknown.
    var cappedBelowTrained: Int? {
        guard let trained = trainedTokens, trained > windowTokens else { return nil }
        return trained
    }

    // MARK: Fixed cost

    /// What every request pays before any conversation: tool definitions, instructions, and
    /// project / knowledge context. An agent re-sends all of it on EVERY step.
    var fixedTokens: Int? {
        breakdown.map { ContextOccupancy.tokens($0.toolChars + $0.overheadChars + $0.knowledgeChars) }
    }

    /// Past this share of the window, the fixed part alone crowds out the work.
    static let fixedCostWarningFraction = 0.5

    /// True when the fixed prompt and tool cost alone consumes a large share of the window, warning before the user
    /// sends.
    var fixedCostIsHigh: Bool {
        guard let fixed = fixedTokens, windowTokens > 0 else { return false }
        return Double(fixed) / Double(windowTokens) >= Self.fixedCostWarningFraction
    }
}

/// Three visual bands. Kept coarse on purpose — a gauge that changes color at five
/// thresholds reads as noise. `normal` uses the accent (Claude's blue-donut cue);
/// `high`/`over` escalate to the warning/error roles.
enum ContextGaugeLevel {
    // Thresholds are fractions of `ContextWindowUsage.usableFraction` (1 minus `PromptFitCheck.responseHeadroom`); the
    // percentages track the headroom.
    case normal   // below 80% of the usable share (< 60% of the window)
    case high     // 80–100% of the usable share (60–75% of the window)
    case over     // the usable share is gone (≥ 75% of the window): the prompt is now eating
                  // the room reserved for the reply, where `PromptFitCheck.exceeds` warns; not the same as `exceedsWindow`.

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

    /// Builds the occupancy snapshot from live composer state, or `nil` when the gauge should hide.
    /// `extraKnowledgeChars` is always-injected context (Code project knowledge); `messages` is the next request's
    /// history, oldest first.
    @MainActor
    static func resolve(
        profile: BackendProfileModel?,
        messages: [ChatMessage],
        attachedFiles: [FileSystemItem],
        conversationID: UUID?,
        extraKnowledgeChars: Int = 0
    ) -> ContextWindowUsage? {
        // Only chat-shaped profiles have a single context window; workflow resolves a model per node and imageGen has
        // none, so the gauge hides.
        guard let profile,
              profile.profileType == .bot || profile.profileType == .agent || profile.profileType == .code,
              let config = profile.resolvedLLMConfig
        else {
            logger.debug("[CTXGAUGE] Hidden — no single-window chat profile (type=\(profile?.profileType.rawValue ?? "nil")) for conv=\(conversationID?.uuidString.prefix(8).description ?? "none"). Gauge not shown.")
            return nil
        }

        let (window, trained) = windows(
            for: config,
            profileID: profile.id,
            flavour: .forProfileType(profile.profileType))
        let windowIsFallback = (trained == nil)

        // `resolvedHistoryStrategy` is nil for bot and code profiles; the estimator resolves it to `.recentHistory`, as
        // `AgentConnect` does.
        let occupancy = estimatedOccupancy(
            config: config,
            profile: profile,
            messages: messages,
            attachedFiles: attachedFiles,
            historyStrategy: profile.resolvedHistoryStrategy,
            contextWindow: window,
            extraKnowledgeChars: extraKnowledgeChars
        )
        let used = occupancy?.totalTokens ?? 0

        // Ground truth: the newest completed agent turn's real usage; the history is oldest first, so the last message
        // with usage is the newest.
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
            turnSpansMultipleCalls: profile.profileType == .agent || profile.profileType == .code,
            breakdown: occupancy?.breakdown,
            conversationID: conversationID
        )
    }

    /// Resolves the (effective, trained) window pair for a config, healing stale MLX metadata.
    /// `effective` is what the request runs under (the gauge denominator); `trained` is the model's max. They diverge
    /// only for Ollama.
    @MainActor
    /// `flavour` decides which preset ladder's `numCtx` the ring is priced against; the stored advanced config is nil
    /// if the panel was never opened.
    static func windows(for config: ProviderConfig, profileID: UUID?, flavour: OllamaConfigDefaultProfile) -> (effective: Int, trained: Int?) {
        var trained = EffectiveContextWindow.trainedWindow(for: config)
        // MLX profiles saved with nil metadata would get the 8K fallback; recover the real window and heal the stored
        // profile.
        if trained == nil, config.apiProvider == .mlx {
            trained = MLXContextWindowHealer.trainedWindow(for: config, profileID: profileID)
        }
        let effective: Int
        if config.apiProvider == .mlx {
            // MLX: the app owns the prompt, so the whole trained window is usable.
            effective = max(2_048, trained ?? 8_192)
        } else {
            // Ollama → num_ctx allocation; cloud → trained/catalog. Both via the shared resolver.
            effective = EffectiveContextWindow.resolve(for: config, flavour: flavour)
        }
        return (effective, trained)
    }

    /// Estimates the prompt size the next send will produce, using the same `PromptFitCheck` heuristic as send time.
    /// Counts history, episodic memory, attachments, knowledge, visible images and layer overhead; excludes the unsent
    /// draft and per-conversation RAG.
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
        estimatedOccupancy(config: config, profile: profile, messages: messages, attachedFiles: attachedFiles,
                           historyStrategy: historyStrategy, contextWindow: contextWindow,
                           extraKnowledgeChars: extraKnowledgeChars)?.totalTokens ?? 0
    }

    /// The estimate AND what it is made of. Nil for a conversation with nothing in it.
    @MainActor
    static func estimatedOccupancy(
        config: ProviderConfig,
        profile: BackendProfileModel,
        messages: [ChatMessage],
        attachedFiles: [FileSystemItem],
        historyStrategy: HistoryStrategy?,
        contextWindow: Int,
        extraKnowledgeChars: Int = 0
    ) -> (totalTokens: Int, breakdown: ContextOccupancy)? {
        // A brand-new chat with nothing attached reads as empty; Code mode's always-injected project knowledge counts as
        // real content.
        guard !messages.isEmpty || !attachedFiles.isEmpty || extraKnowledgeChars > 0 else { return nil }

        // The request strips error turns before building the prompt, so charging for them would report payload that is
        // never sent.
        let messages = messages.filter {
            if case .error = $0.content { return false }
            return true
        }

        // `messages` is already oldest-first, as `pairTurns` needs; the tool-schema cache is warmed so the send-time fit
        // check finds a snapshot.
        ToolSchemaSizes.refreshFromRegistry()
        let toolSchemaChars = PromptFitCheck.estimatedToolSchemaChars(for: profile)
        let knowledgeSourceChars = PromptFitCheck.estimatedKnowledgeSourceChars(for: profile)

        let episodicChars = PromptFitCheck.estimatedEpisodicChars(
            in: messages,
            strategy: historyStrategy,
            contextWindow: contextWindow,
            toolsAvailable: profile.profileType != .bot,
            // Uses the same expression as the request (`AgentConnect`), not the local `supportedModalities` check; the two
            // disagree for `.code`.
            includeImageNames: profile.supportsVisionInput,
            // Same flag the request path uses to drop `<outcome>` clips the native turns duplicate.
            carriesProse: profile.carriesHistoryProse
        )
        // Measured, not summed: the estimator applies the per-strategy turn limit, the char budget and whether the
        // provider receives prose at all.
        let proseChars = PromptFitCheck.estimatedHistoryProseChars(
            in: messages,
            carriesProse: profile.carriesHistoryProse,
            strategy: historyStrategy,
            contextWindow: contextWindow,
            toolsAvailable: profile.profileType != .bot
        )
        let historyChars = proseChars + episodicChars
        // Strategy-aware: a `.stateless` profile ships a path manifest, not file bytes; files the reader will refuse are
        // dropped.
        let attachmentChars = PromptFitCheck.estimatedAttachmentChars(
            for: attachedFiles, profile: profile
        )

        // Priced only when the model accepts vision; a non-vision model has its images stripped before the wire.
        let supportsVision = config.supportedModalities.contains(.visionInput)
        let currentImageTokens = supportsVision
            ? PromptFitCheck.estimatedImageTokens(forImageURLs: PreSendFitHint.imageURLs(of: attachedFiles), provider: config.apiProvider)
            : 0
        // Prior-turn images, on the same gate and 20-message lookback the send-time check uses.
        let historyImageTokens = PromptFitCheck.estimatedHistoryImageTokens(
            in: messages,
            provider: config.apiProvider,
            shipsHistoryImages: profile.carriesHistoryImages && historyStrategy != .pointer
        )
        let imageTokens = currentImageTokens + historyImageTokens

        // The breakdown makes a high reading diagnosable: the total alone cannot separate a big attachment from an
        // edit-heavy history.
        logger.debug("[CTXGAUGE] Breakdown — episodic \(episodicChars) chars (strategy=\(historyStrategy?.rawValue ?? "recentHistory/non-agent default"), \(messages.count) msg), prose \(proseChars) chars (carried=\(profile.carriesHistoryProse)), attachments \(attachmentChars) chars, knowledge \(extraKnowledgeChars) chars, tools \(toolSchemaChars) chars, kb \(knowledgeSourceChars) chars, images \(currentImageTokens)+\(historyImageTokens) tok.")

        let total = PromptFitCheck.estimatedTokens(
            attachmentChars: attachmentChars,
            knowledgeChars: extraKnowledgeChars + toolSchemaChars + knowledgeSourceChars,
            retrievalChars: 0,
            queryChars: 0,
            historyChars: historyChars,
            imageTokens: imageTokens
        )
        let breakdown = ContextOccupancy(
            toolChars: toolSchemaChars,
            historyChars: historyChars,
            knowledgeChars: extraKnowledgeChars + knowledgeSourceChars,
            attachmentChars: attachmentChars,
            imageTokens: imageTokens
        )
        return (total, breakdown)
    }

}

// MARK: - Ring (collapsed indicator)

/// The small toolbar ring. Just the donut — the number lives in the tooltip and the
/// tap-through breakdown, matching the "small icon" the user asked for.
struct ContextWindowGauge: View {
    let usage: ContextWindowUsage
    /// Opens the profile's Tool Library from the breakdown's Tools row. Declared BEFORE
    /// `onOpenSettings` so the hosts' trailing closure keeps binding to that one.
    var onOpenTools: ((UUID) -> Void)? = nil
    /// Summarizes older turns now. Returns what happened, in words. Nil hides the button.
    var onCompact: (() async -> String)? = nil
    /// False while a run is in flight — compacting under a running turn would summarize history
    /// the run is still reading.
    var canCompact: Bool = true
    /// Raises the window where THIS surface keeps it — Code's per-project Context Size. Nil →
    /// the breakdown falls back to `onOpenSettings` (the profile's Advanced settings).
    var onRaiseContext: (() -> Void)? = nil
    /// Optional deep-link to the profile's settings (raise Context Window). Each surface
    /// supplies the right implementation — the main window routes; QuickAccess activates
    /// the main window and posts. Nil → the breakdown falls back to instructional text.
    var onOpenSettings: ((UUID) -> Void)? = nil
    @Environment(\.appTheme) private var theme
    @State private var showBreakdown = false
    @State private var isHovered = false
    @State private var showHoverCard = false
    @State private var hoverTask: Task<Void, Never>?

    private let ringSize: CGFloat = 12
    private let ringWidth: CGFloat = 1.9

    var body: some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            showHoverCard = false
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
            .overlay(alignment: .topTrailing) {
                // The prompt and tools alone take most of the window — see `fixedCostIsHigh`.
                if usage.fixedCostIsHigh {
                    Circle()
                        .fill(theme.warningColor)
                        .frame(width: 4, height: 4)
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: ComposerStyle.buttonSize, height: ComposerStyle.buttonSize)
            .composerControlSurface(in: Circle(), isHovered: isHovered)
            .shadow(color: isHovered ? usage.level.color(theme).opacity(0.4) : .clear, radius: 4, x: 0, y: 1)
            .scaleEffect(isHovered ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = hovering }
            hoverTask?.cancel()
            if hovering && !showBreakdown {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 140_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        showHoverCard = true
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.15)) {
                    showHoverCard = false
                }
            }
        }
        .onChange(of: showBreakdown) { _, newValue in
            if newValue {
                showHoverCard = false
            }
        }
        .accessibilityLabel(Text("Context window \(usage.percent) percent used, \(usage.usedDisplay) of \(usage.windowDisplay) tokens"))
        .accessibilityAddTraits(.isButton)
        .overlay(alignment: .bottomTrailing) {
            if showHoverCard && !showBreakdown {
                ContextGaugeHoverCard(usage: usage)
                    .offset(x: 6, y: -34)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.90, anchor: .bottomTrailing)
                                .combined(with: .opacity)
                                .combined(with: .offset(y: 4)),
                            removal: .opacity
                        )
                    )
            }
        }
        .popover(isPresented: $showBreakdown, arrowEdge: .top) {
            ContextWindowBreakdown(
                usage: usage,
                // Dismiss the popover as we navigate away; nil stays nil so the button hides.
                onOpenSettings: onOpenSettings == nil ? nil : { id in
                    showBreakdown = false
                    onOpenSettings?(id)
                },
                onOpenTools: onOpenTools == nil ? nil : { id in
                    showBreakdown = false
                    onOpenTools?(id)
                },
                onCompact: onCompact,
                canCompact: canCompact,
                onRaiseContext: onRaiseContext == nil ? nil : {
                    showBreakdown = false
                    // After the popover closes — two popovers cannot be presented at once.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        onRaiseContext?()
                    }
                }
            )
            .environment(\.appTheme, theme)
        }
    }
}

// MARK: - Hover Micro-Card

/// A sleek floating micro-card that appears smoothly above the context gauge on hover.
/// Gives immediate visibility into exact tokens, headroom, and memory status without
/// requiring a click or interrupting the user's typing flow.
struct ContextGaugeHoverCard: View {
    let usage: ContextWindowUsage
    @Environment(\.appTheme) private var theme

    private var statusInfo: (text: String, icon: String, color: Color) {
        if usage.exceedsWindow {
            return ("Compaction active", "arrow.triangle.2.circlepath", theme.warningColor)
        } else if usage.level == .over {
            return ("Low reply headroom", "exclamationmark.triangle.fill", theme.errorColor)
        } else if usage.level == .high {
            return ("Capacity warning", "gauge.with.dots.needle.bottom.100percent", theme.warningColor)
        } else {
            return ("Optimal capacity", "checkmark.circle.fill", theme.accentColor)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: Model name & percentage
            HStack(spacing: 5) {
                Text(usage.modelName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.primaryText.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                Text("\(usage.percent)%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(usage.level.color(theme))
            }

            // Animated Progress Fill Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    usage.level.color(theme),
                                    usage.level.color(theme).opacity(0.75)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geo.size.width * usage.displayFraction))
                        .shadow(color: usage.level.color(theme).opacity(0.4), radius: 2, y: 0)
                }
            }
            .frame(height: 4)

            // Bottom row: Tokens used vs total & status badge
            HStack(spacing: 6) {
                Text("\(usage.usedDisplay) / \(usage.windowDisplay)")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(theme.secondaryText)

                Spacer(minLength: 4)

                HStack(spacing: 3) {
                    Image(systemName: statusInfo.icon)
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundColor(statusInfo.color)

                    Text(statusInfo.text)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(statusInfo.color)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(statusInfo.color.opacity(0.12))
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 204)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.isDark ? Color.black.opacity(0.65) : Color.white.opacity(0.85))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.24), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        .shadow(color: usage.level.color(theme).opacity(0.15), radius: 6, x: 0, y: 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Breakdown (expanded popover)

/// The tap-through detail: headline number + bar, the REAL last-turn counts, and any
/// contextual notes (including the raisable-window action).
struct ContextWindowBreakdown: View {
    let usage: ContextWindowUsage
    var onOpenSettings: ((UUID) -> Void)? = nil
    var onOpenTools: ((UUID) -> Void)? = nil
    var onCompact: (() async -> String)? = nil
    var canCompact: Bool = true
    var onRaiseContext: (() -> Void)? = nil
    @State private var isCompacting = false
    @State private var compactStatus: String?
    @Environment(\.appTheme) private var theme
    /// The app-wide "what to keep" setting. Per-tool overrides live in each tool's settings.
    @AppStorage(ContextCutStrategy.defaultsKey) private var cutStrategyRaw = ContextCutStrategy.automatic.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            headline
            bar
            if usage.fixedCostIsHigh, let fixed = usage.fixedTokens { fixedCostRow(fixed) }
            if let breakdown = usage.breakdown { usageRows(breakdown) }
            if onCompact != nil, usage.breakdown != nil { compactRow }
            if let last = usage.lastTurn { lastTurnRow(last) }
            if let cuts = ContextCutLog.shared.lastTurn(for: usage.conversationID) { cutsRow(cuts) }
            cutStrategyRow
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

    // MARK: Compact

    /// "Compact history" — summarizes older turns into a checkpoint now. Uses the Intelligence
    /// Core when it is on, otherwise this conversation's own model; the transcript is untouched,
    /// only what is sent from the next turn changes.
    private var compactRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            BreakdownActionButton(
                icon: "arrow.down.right.and.arrow.up.left",
                title: isCompacting ? "Compacting history…" : "Compact history",
                isLoading: isCompacting,
                isEnabled: canCompact && !isCompacting,
                tooltip: canCompact
                    ? "Summarize earlier turns into a checkpoint. The 5 most recent messages are kept; the transcript is not changed."
                    : "Available once the current run finishes."
            ) {
                guard let onCompact, !isCompacting else { return }
                isCompacting = true
                compactStatus = nil
                Task { @MainActor in
                    compactStatus = await onCompact()
                    isCompacting = false
                }
            }
            if let compactStatus {
                Text(compactStatus)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: Cut strategy

    /// "When a tool result doesn't fit, keep …" — the global default. Automatic picks per tool:
    /// the end of command output, the start of reads and searches, both ends otherwise.
    private var cutStrategyRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "scissors")
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryText)
                .frame(width: 14)
            Text("If a tool result doesn't fit, keep")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            Spacer()
            Picker("", selection: $cutStrategyRaw) {
                ForEach(ContextCutStrategy.allCases, id: \.rawValue) { strategy in
                    Text(strategy.label).tag(strategy.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help("Automatic keeps the end of command output, the start of files and searches, and both ends of anything else. Individual tools can override this in the Tool Library.")
        }
    }

    // MARK: What's using it

    /// The rows the total is made of, largest first, zero rows omitted — so the biggest lever is
    /// always on top. Tools gets an action: on a small window its definitions are often the
    /// largest single cost, and the Tool Library is where they are switched off.
    private func usageRows(_ b: ContextOccupancy) -> some View {
        let rows: [(label: String, icon: String, tokens: Int, isTools: Bool)] = [
            ("Tool definitions", "wrench.and.screwdriver", ContextOccupancy.tokens(b.toolChars), true),
            ("History", "clock.arrow.circlepath", ContextOccupancy.tokens(b.historyChars), false),
            ("Knowledge & project context", "books.vertical", ContextOccupancy.tokens(b.knowledgeChars), false),
            ("Attachments", "paperclip", ContextOccupancy.tokens(b.attachmentChars), false),
            ("Images", "photo", b.imageTokens, false),
            ("Instructions (fixed)", "text.alignleft", ContextOccupancy.tokens(b.overheadChars), false),
        ].filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }

        return VStack(alignment: .leading, spacing: 5) {
            Text("What's using it")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .textCase(.uppercase)
            ForEach(rows, id: \.label) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.icon)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 14)
                    Text(row.label)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                    if row.isTools, let profileID = usage.profileID, let onOpenTools {
                        BreakdownMiniIconButton(
                            icon: "slider.horizontal.3",
                            tooltip: "Open this profile's Tool Library — tools you switch off stop costing context"
                        ) {
                            onOpenTools(profileID)
                        }
                    }
                    Spacer()
                    Text("~\(PromptFitCheck.roundedK(row.tokens))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }
            }
        }
    }

    /// What the last turn had to cut. Shown here rather than on each tool card — the user's
    /// choice: the transcript stays clean, and the place you check the window is where you learn
    /// the window ran out.
    private func cutsRow(_ record: ContextCutLog.TurnRecord) -> some View {
        var parts: [String] = []
        if !record.cuts.isEmpty {
            let largest = record.cuts.max { $0.originalChars < $1.originalChars }!
            parts.append(record.cuts.count == 1
                ? "1 tool result trimmed (\(largest.toolName): \(PromptFitCheck.roundedK(ContextOccupancy.tokens(largest.originalChars))) → \(PromptFitCheck.roundedK(ContextOccupancy.tokens(largest.keptChars))) tok)"
                : "\(record.cuts.count) tool results trimmed (largest: \(largest.toolName), \(PromptFitCheck.roundedK(ContextOccupancy.tokens(largest.originalChars))) → \(PromptFitCheck.roundedK(ContextOccupancy.tokens(largest.keptChars))) tok)")
        }
        if record.compactedExchanges > 0 {
            parts.append("\(record.compactedExchanges) older tool step(s) summarized out")
        }
        return VStack(alignment: .leading, spacing: 6) {
            if let overflow = record.overflow { overflowRow(overflow) }
            if !parts.isEmpty {
                noteRow(icon: "scissors", text: "Last turn: " + parts.joined(separator: "; ") + ".")
            }
        }
    }

    /// The provider cut a step's prompt — from its real count, not the app's estimate.
    private func overflowRow(_ overflow: ContextCutLog.Overflow) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(theme.errorColor)
                .frame(width: 14)
            Text("Last turn went over the window at step \(overflow.step) (\(PromptFitCheck.roundedK(overflow.promptTokens)) of \(PromptFitCheck.roundedK(overflow.windowTokens))). The start of the prompt was dropped, so the model may have lost its instructions — which can end a run without an answer.")
                .font(.system(size: 11))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Prompt and tools use 5.5K of 8K before you type" — with the two things that change it.
    private func fixedCostRow(_ fixed: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(theme.warningColor)
                    .frame(width: 14)
                Text("Prompt and tools use \(PromptFitCheck.roundedK(fixed)) of this model's \(usage.windowDisplay) window before you type. A long task will run out of room, and the start of the prompt — the instructions — is what gets dropped.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let raise = raiseContextAction {
                    BreakdownActionButton(
                        icon: "arrow.up.forward.circle",
                        title: "Raise context size",
                        action: raise
                    )
                }
                if let profileID = usage.profileID, let onOpenTools {
                    BreakdownActionButton(
                        icon: "wrench.and.screwdriver",
                        title: "Tools…",
                        tooltip: "Fewer enabled tools means a smaller fixed cost on every step",
                        action: { onOpenTools(profileID) }
                    )
                }
            }
        }
    }

    /// Code's per-project Context Size when wired, else the profile's Advanced settings.
    private var raiseContextAction: (() -> Void)? {
        if let onRaiseContext { return onRaiseContext }
        if let profileID = usage.profileID, let onOpenSettings { return { onOpenSettings(profileID) } }
        return nil
    }

    private func lastTurnRow(_ turn: TokenUsage) -> some View {
        let prefix = turn.isEstimated ? "~" : ""
        return HStack(spacing: 6) {
            Image(systemName: "number.circle")
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryText)
                .frame(width: 14)
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
        // Ollama allocates only `num_ctx` of KV cache and truncates beyond it, so the effective window is the honest
        // ceiling; it can be raised.
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
        // Retrieval is chosen by the query and unknown before sending, so it is not in the figure above.
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
                .frame(width: 14)
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
        VStack(alignment: .leading, spacing: 8) {
            noteRow(
                icon: "arrow.up.forward.circle",
                text: "\(usage.windowDisplay) allocated of \(PromptFitCheck.roundedK(trained)) the model supports."
            )
            if let raise = raiseContextAction {
                BreakdownActionButton(
                    icon: "slider.horizontal.3",
                    title: "Raise Context Window",
                    trailingIcon: "chevron.right",
                    tooltip: "Open this profile's Advanced settings to raise its context window",
                    action: raise
                )
            } else {
                Text("Raise Context Window in the profile's Advanced settings to use more.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
    }
}

// MARK: - Breakdown Button Components

/// A tactile macOS action button with smooth hover illumination, distinct borders,
/// haptic feedback, and aligned layout within the Context Window popover.
private struct BreakdownActionButton: View {
    var icon: String? = nil
    let title: String
    var trailingIcon: String? = nil
    var isLoading: Bool = false
    var isEnabled: Bool = true
    var tooltip: String? = nil
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            guard isEnabled && !isLoading else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            action()
        }) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(iconColor)
                        .frame(width: 12)
                }

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textColor)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let trailingIcon, !isLoading {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(trailingIconColor)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5.5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 0.8)
            )
            .shadow(
                color: isHovered && isEnabled ? theme.accentColor.opacity(0.18) : Color.clear,
                radius: 3,
                x: 0,
                y: 1
            )
            .scaleEffect(isHovered && isEnabled && !reduceMotion ? 1.01 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: isEnabled && !isLoading)
        .disabled(!isEnabled || isLoading)
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                isHovered = hovering
            }
        }
        .help(tooltip ?? "")
    }

    private var iconColor: Color {
        guard isEnabled else { return theme.secondaryText.opacity(0.5) }
        return isHovered ? theme.accentColor : theme.accentColor.opacity(0.9)
    }

    private var textColor: Color {
        guard isEnabled else { return theme.secondaryText.opacity(0.5) }
        return isHovered ? theme.primaryText : theme.primaryText.opacity(0.92)
    }

    private var trailingIconColor: Color {
        guard isEnabled else { return theme.secondaryText.opacity(0.4) }
        return isHovered ? theme.accentColor : theme.secondaryText.opacity(0.7)
    }

    private var backgroundColor: Color {
        guard isEnabled else {
            return theme.isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.02)
        }
        if isHovered {
            return theme.accentColor.opacity(0.18)
        } else {
            return theme.accentColor.opacity(0.08)
        }
    }

    private var strokeColor: Color {
        guard isEnabled else {
            return theme.dividerColor.opacity(0.2)
        }
        if isHovered {
            return theme.accentColor.opacity(0.45)
        } else {
            return theme.accentColor.opacity(0.22)
        }
    }
}

/// A compact icon button (18×18pt) with hover feedback, border glow, and pointing cursor
/// for inline row actions such as opening the Tool Library.
private struct BreakdownMiniIconButton: View {
    let icon: String
    var tooltip: String? = nil
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            action()
        }) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(isHovered ? theme.accentColor : theme.accentColor.opacity(0.85))
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(theme.accentColor.opacity(isHovered ? 0.22 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            theme.accentColor.opacity(isHovered ? 0.45 : 0.20),
                            lineWidth: 0.8
                        )
                )
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                isHovered = hovering
            }
        }
        .help(tooltip ?? "")
    }
}
