// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeQuickSettingsPopover.swift
//  Devgentic
//
//  Per-project execution settings for the Code interface: iteration cap, compute budget and
//  context size.
//
//  ⚠️ No tool settings (2026-09-25). The "Ask before running" section was removed: every Code tool
//  is in the Tool Library now, which sets Ask First / Auto Run per tool, and this popover's copy
//  of that choice was applied last on every run — silently overriding the Library.
//

import SwiftUI
import AppKit


struct CodeQuickSettingsPopover: View {

    @Environment(CodeSessionManager.self) private var codeSessionManager
    @Environment(\.appTheme) private var theme

    /// Local working copy. Committed to the store on every change so the popover can be dismissed
    /// by clicking away — there is no Save button, and a draft that needed one would be lost.
    @State private var draft: CodeQuickSettings = .default

    /// ⚠️ Set once `onAppear` has seeded `draft`. Without it, hydrating a project that HAS settings
    /// mutates `draft` and fires `onChange`, so merely OPENING the popover writes the store and
    /// bumps the entry's `updatedAt` — which is the retention cap's recency key, so browsing your
    /// settings could evict a different project's. Viewing is not changing.
    @State private var hasHydrated = false

    /// What the Max Iterations field shows. Kept apart from `draft` so an out-of-range entry can sit
    /// in the field, flagged, without being saved — the draft only ever holds a valid cap or none.
    @State private var iterationsText = ""

    /// ⚠️⚠️ F9. `draft` changes on every stepper CLICK, and each change used to persist
    /// immediately: walking maxIterations 3→15 produced nine UserDefaults writes and nine
    /// profile saves, each one bumping `lastSelected` and reordering "recently used" — for a
    /// profile the user was configuring, not selecting.
    ///
    /// Every one of those writes is a genuine value change, so the store's no-op guard cannot
    /// help; the churn has to stop at the source. The trailing edge is what the user meant —
    /// the number they stopped on, not each one they passed through.
    @State private var persistTask: Task<Void, Never>?

    /// Long enough to coalesce a burst of clicks, short enough that closing the popover by
    /// clicking away almost always lands after it. `onDisappear` flushes regardless, so this
    /// value trades write count against nothing the user can perceive.
    private static let persistDebounce = Duration.milliseconds(400)

    private var projectName: String? {
        codeSessionManager.projectPath?.lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 14) {
                executionSection
                toolApprovalsPointer
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider().opacity(0.35)

            footer
        }
        // Sized to its content: with the tool rows gone, a fixed 530 pt left half the popover empty.
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.primaryBackground)
        .onAppear {
            draft = codeSessionManager.quickSettings
            iterationsText = draft.maxIterations.map(String.init) ?? ""
            hasHydrated = true
        }
        .onChange(of: draft) { _, newValue in
            guard hasHydrated else { return }
            persistTask?.cancel()
            persistTask = Task { @MainActor in
                try? await Task.sleep(for: Self.persistDebounce)
                guard !Task.isCancelled else { return }
                codeSessionManager.updateQuickSettings(newValue)
            }
        }
        .onDisappear {
            // ⚠️ MANDATORY, not tidiness. A debounce that loses the user's last change is worse
            // than the churn it replaces: clicking + then immediately dismissing would silently
            // discard the setting. Cancel the pending write and commit the final value directly.
            // If it already landed, the store's no-op guard makes this free.
            persistTask?.cancel()
            persistTask = nil
            guard hasHydrated else { return }
            codeSessionManager.updateQuickSettings(draft)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Refined neutral icon badge
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.surfaceOverlayStrong)
                    .frame(width: 32, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.dividerColor.opacity(0.3), lineWidth: 0.8)
                    )

                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Session Settings")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    if !draft.isDefault {
                        Text("Customized")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(theme.surfaceOverlayStrong)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9.5))
                        .foregroundColor(.orange.opacity(0.85))

                    Text(projectName.map { "Scoped to '\($0)'" } ?? "No Project Selected")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if !draft.isDefault {
                Button(action: {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                        draft = .default
                    }
                }) {
                    Text("Reset")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.surfaceOverlay)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(theme.dividerColor.opacity(0.35), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .help("Reset all settings for this project back to defaults")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Execution Section

    private var executionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("EXECUTION LIMITS")

            VStack(spacing: 0) {
                // Max Iterations Row
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Max Iterations")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(theme.primaryText)
                        }

                        if case .outOfRange = Self.parseIterations(iterationsText) {
                            Text("Enter \(CodeSessionManager.iterationCapRange.lowerBound)–\(CodeSessionManager.iterationCapRange.upperBound), or leave empty for no limit")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        } else {
                            Text("Optional cap on reasoning cycles. Leave empty for no limit.")
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                        }
                    }

                    Spacer()

                    iterationsField
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                Divider().opacity(0.25).padding(.leading, 14)

                // Execution Timeout Row
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Execution Timeout")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(theme.primaryText)

                        Text("Compute budget (time awaiting approval doesn't count)")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                    }

                    Spacer()

                    timeoutMenu
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                // Context size — Ollama only: it is the one provider whose window the app chooses.
                if codeSessionManager.provider == .ollama {
                    Divider().opacity(0.25).padding(.leading, 14)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Context Size")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(theme.primaryText)

                            Text("Room for the prompt, tools and history. Larger uses more memory.")
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                        }

                        Spacer()

                        contextMenu
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.dividerColor.opacity(0.3), lineWidth: 0.8)
            )

            if Self.bothLimitsOff(draft) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("No iteration cap and no timeout: only Stop ends a run that keeps going. The loop detector warns but does not stop it.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Max Iterations field

    /// Digits only, at most four. Empty = no cap. Anything typed outside
    /// `CodeSessionManager.iterationCapRange` is shown and flagged but never saved.
    private var iterationsField: some View {
        TextField(String(localized: "No limit"), text: $iterationsText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .frame(width: 84)
            .onChange(of: iterationsText) { _, newValue in
                let digits = Self.digitsOnly(newValue)
                guard digits == newValue else {
                    iterationsText = digits      // re-enters with the cleaned text
                    return
                }
                switch Self.parseIterations(digits) {
                case .noCap:          draft.maxIterations = nil
                case .cap(let value): draft.maxIterations = value
                case .outOfRange:     break      // flagged in the row; the last valid value stands
                }
            }
            // Keeps the field honest when the draft changes from elsewhere — "Reset", hydration.
            .onChange(of: draft.maxIterations) { _, newValue in
                if Self.parseIterations(iterationsText) != Self.IterationsInput(newValue) {
                    iterationsText = newValue.map(String.init) ?? ""
                }
            }
            .accessibilityLabel(String(localized: "Max iterations"))
    }

    enum IterationsInput: Equatable {
        case noCap
        case cap(Int)
        case outOfRange

        init(_ stored: Int?) { self = stored.map(IterationsInput.cap) ?? .noCap }
    }

    /// Pure, so the field's rules are testable without rendering.
    static func parseIterations(_ text: String) -> IterationsInput {
        guard !text.isEmpty else { return .noCap }
        guard let value = Int(text), CodeSessionManager.iterationCapRange.contains(value) else { return .outOfRange }
        return .cap(value)
    }

    /// Strips everything but ASCII digits (pasted "1,000", letters, a minus sign) and keeps at most
    /// four — enough for the 1000 ceiling.
    static func digitsOnly(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(4))
    }

    /// Nothing stops a run that keeps making new, different steps except these two.
    static func bothLimitsOff(_ settings: CodeQuickSettings) -> Bool {
        settings.maxIterations == nil && settings.executionTimeout == 0
    }

    // MARK: - Timeout Menu

    private var timeoutMenu: some View {
        Menu {
            Button(action: { setTimeout(nil) }) {
                HStack {
                    Text("\(Int(CodeSessionManager.presetExecutionTimeout / 60)) minutes (Default)")
                    if draft.executionTimeout == nil { Image(systemName: "checkmark") }
                }
            }
            Divider()
            Button(action: { setTimeout(60) }) {
                HStack {
                    Text("1 minute")
                    if draft.executionTimeout == 60 { Image(systemName: "checkmark") }
                }
            }
            Button(action: { setTimeout(120) }) {
                HStack {
                    Text("2 minutes")
                    if draft.executionTimeout == 120 { Image(systemName: "checkmark") }
                }
            }
            Button(action: { setTimeout(300) }) {
                HStack {
                    Text("5 minutes")
                    if draft.executionTimeout == 300 { Image(systemName: "checkmark") }
                }
            }
            Button(action: { setTimeout(600) }) {
                HStack {
                    Text("10 minutes")
                    if draft.executionTimeout == 600 { Image(systemName: "checkmark") }
                }
            }
            Button(action: { setTimeout(900) }) {
                HStack {
                    Text("15 minutes")
                    if draft.executionTimeout == 900 { Image(systemName: "checkmark") }
                }
            }
            Button(action: { setTimeout(1800) }) {
                HStack {
                    Text("30 minutes")
                    if draft.executionTimeout == 1800 { Image(systemName: "checkmark") }
                }
            }
            Divider()
            Button(action: { setTimeout(0) }) {
                HStack {
                    Text("No limit (Unbounded)")
                    if draft.executionTimeout == 0 { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(timeoutDisplayString)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(theme.secondaryText.opacity(0.8))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(theme.surfaceOverlayStrong)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.dividerColor.opacity(0.35), lineWidth: 0.8)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Context Size

    /// The model's own trained window, when known — the ceiling offered in the menu.
    private var trainedWindow: Int? {
        EffectiveContextWindow.trainedWindow(for: codeSessionManager.currentProviderConfig)
    }

    private var contextChoices: [Int] {
        let steps = [8_192, 16_384, 32_768, 65_536, 131_072]
        guard let trained = trainedWindow else { return steps }
        return steps.filter { $0 < trained } + [trained]
    }

    private var contextMenu: some View {
        Menu {
            Button(action: { setContext(nil) }) {
                HStack {
                    Text("\(Self.tokenLabel(defaultContext)) (Default)")
                    if draft.contextTokens == nil { Image(systemName: "checkmark") }
                }
            }
            Divider()
            ForEach(contextChoices, id: \.self) { tokens in
                Button(action: { setContext(tokens) }) {
                    HStack {
                        Text(tokens == trainedWindow ? "\(Self.tokenLabel(tokens)) (model maximum)" : Self.tokenLabel(tokens))
                        if draft.contextTokens == tokens { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(Self.tokenLabel(draft.contextTokens ?? defaultContext))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(theme.secondaryText.opacity(0.8))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(theme.surfaceOverlayStrong)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.dividerColor.opacity(0.35), lineWidth: 0.8)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// What "Default" means for the current model. Unknown trained window → the provider's own
    /// ladder decides, shown as the preset's 8K.
    private var defaultContext: Int {
        trainedWindow.map { min($0, CodeSessionManager.presetContextCap) } ?? 8_192
    }

    private func setContext(_ tokens: Int?) {
        draft.contextTokens = tokens
    }

    static func tokenLabel(_ tokens: Int) -> String {
        tokens >= 1_024 ? "\(tokens / 1_024)K" : "\(tokens)"
    }

    private var timeoutDisplayString: String {
        if let timeout = draft.executionTimeout {
            if timeout == 0 {
                return "No limit"
            } else if timeout >= 60 {
                let mins = Int(timeout / 60)
                let secs = Int(timeout.truncatingRemainder(dividingBy: 60))
                if secs > 0 {
                    return "\(mins)m \(secs)s"
                } else {
                    return "\(mins) min"
                }
            } else {
                return "\(Int(timeout))s"
            }
        } else {
            return "\(Int(CodeSessionManager.presetExecutionTimeout / 60)) min (Default)"
        }
    }

    private func setTimeout(_ value: TimeInterval?) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        draft.executionTimeout = value
    }

    // MARK: - Tool approvals

    /// Where Ask/Auto went. One line, so someone who used to set it here finds it.
    private var toolApprovalsPointer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryText.opacity(0.7))
            Text("Whether a tool asks before running is set per tool in the Tool Library, and is remembered for this folder.")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryText.opacity(0.6))

            Text("Settings are scoped strictly to this folder.")
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryText.opacity(0.7))

            Spacer()

            if !draft.isDefault {
                Text("Saved automatically")
                    .font(.system(size: 9.5))
                    .foregroundColor(theme.secondaryText.opacity(0.5))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(theme.secondaryBackground.opacity(0.5))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(theme.secondaryText.opacity(0.8))
            .tracking(0.6)
    }
}
