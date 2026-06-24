//
//  InteractionBannerStack.swift
//  Devgentic
//
//  [HITL Standardization — P3]
//  The single above-input HITL surface for EVERY interface (chat, code, workflow, scheduled).
//  Reads `InteractionCenter.current(for:)` so it shows exactly one request at a time in strict
//  FIFO order (D1) — the next slides in once the current resolves. Each banner carries a
//  source-attribution header from `PendingHITL.origin` (D2: which interface / workflow node).
//
//  Dismissal is driven entirely by the center (resolved via the `.hitl*Resolved` notifications
//  → `InteractionCenter.resolve`); there is NO optimistic timer like the legacy banner.
//
//  P3 dual-mounts this beside the legacy `AgentInterruptBannerView` for verification; P4 removes
//  the legacy host and the `interfaceMode != .workflow` gate.
//

import SwiftUI

/// Captures the user's exact action on a HITL banner (approve / deny / always-allow / edits / skip).
/// These are the only places the user's intent is known with full context (tool name, edited values,
/// question), so logging here makes runtime behavior auditable from the logs.
private let bannerLogger = DGLogger(category: "InteractionBanner")

// MARK: - Host

struct InteractionBannerStack: View {
    @Environment(MainApplicationViewModel.self) private var vm
    @Environment(\.appTheme) private var theme
    /// [HITL/E2] One-shot attention flash, driven by InteractionCenter.attentionPulse.
    @State private var pulse = false

    var body: some View {
        let selected = vm.selectedConversationID
        let current = selected.flatMap { vm.interactionCenter.current(for: $0) }
        let otherCount = otherConversationCount(excluding: selected)

        return VStack(spacing: 6) {
            // Background-conversation affordance: a HITL raised in a conversation the user
            // is NOT viewing (e.g. a scheduled / remote run) would otherwise be invisible
            // now that the legacy per-message banner is gone. This chip surfaces it and
            // navigates there on tap.
            if otherCount > 0 {
                OtherConversationsChip(count: otherCount) {
                    navigateToOtherConversation(excluding: selected)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let pending = current {
                banner(for: pending)
                    // Reset per-item @State (typed answer, edited plan) when the FIFO advances.
                    .id(pending.id)
                    .scaleEffect(pulse ? 1.025 : 1.0)
                    .shadow(color: theme.warningColor.opacity(pulse ? 0.55 : 0), radius: pulse ? 14 : 0)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: current?.id)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: otherCount)
        // [HITL/E2] Flash the banner when the user taps an "awaiting input" node.
        .onChange(of: vm.interactionCenter.attentionPulse) { _, _ in
            guard current != nil else { return }
            withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) { pulse = false }
            }
        }
    }

    /// Number of distinct OTHER conversations (not the focused one) with a pending HITL.
    private func otherConversationCount(excluding selected: UUID?) -> Int {
        Set(
            vm.interactionCenter.pending
                .lazy
                .filter { $0.origin.conversationID != selected }
                .map { $0.origin.conversationID }
        ).count
    }

    /// Navigate to the oldest other conversation that has a pending HITL. Routes through the VM so
    /// interfaceMode is aligned to the request's origin (correct dedicated view + sidebar) and the
    /// workflow edit-guard still fires for a dirty canvas.
    private func navigateToOtherConversation(excluding selected: UUID?) {
        guard let target = vm.interactionCenter.pending
            .first(where: { $0.origin.conversationID != selected })
        else { return }
        vm.navigateToPendingInteraction(
            conversationID: target.origin.conversationID,
            interface: target.origin.interface
        )
    }

    @ViewBuilder
    private func banner(for pending: PendingHITL) -> some View {
        switch pending.kind {
        case .toolConfirmation(let confirmation):
            PermissionInteractionBanner(pending: pending, confirmation: confirmation)
        case .clarification(let clarification):
            ClarificationInteractionBanner(pending: pending, clarification: clarification)
        case .planReview(let planReview):
            PlanReviewInteractionBanner(pending: pending, planReview: planReview)
        case .gate(let gate):
            GateInteractionBanner(pending: pending, gate: gate)
        }
    }
}

// MARK: - Cross-conversation affordance

/// Compact chip shown above the input when one or more OTHER conversations have a pending HITL.
/// Tapping it navigates to that conversation so its banner becomes visible (D1/background case).
private struct OtherConversationsChip: View {
    let count: Int
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(.caption2, weight: .semibold))
                Text("\(count) other conversation\(count == 1 ? "" : "s") awaiting your input")
                    .font(.system(.caption, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "arrow.right")
                    .font(.system(.caption2, weight: .semibold))
            }
            .foregroundColor(theme.warningColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) other conversations awaiting your input. Activate to switch.")
    }
}

// MARK: - Source-attribution helpers

/// SF Symbol for the originating interface — gives the banner header a glanceable origin cue (D2).
private func hitlInterfaceIcon(_ interface: HITLOrigin.Interface) -> String {
    switch interface {
    case .chat:      return "bubble.left.fill"
    case .code:      return "chevron.left.forwardslash.chevron.right"
    case .workflow:  return "point.3.connected.trianglepath.dotted"
    case .scheduled: return "clock.fill"
    }
}

/// Shared header row: interface icon + the origin title (e.g. "Security Agent · Question").
private struct InteractionHeader: View {
    let pending: PendingHITL
    let accent: Color
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: hitlInterfaceIcon(pending.origin.interface))
                .font(.system(.caption2, weight: .semibold))
                .foregroundColor(accent)
                .accessibilityHidden(true)

            Text(pending.origin.title)
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(accent)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
    }
}

// MARK: - Permission Banner

private struct PermissionInteractionBanner: View {
    let pending: PendingHITL
    let confirmation: PendingToolConfirmation
    @Environment(MainApplicationViewModel.self) private var vm
    @Environment(BackendProfileService.self) private var profileService
    @Environment(\.appTheme) private var theme

    @State private var isProcessing: Bool = false
    @State private var argsExpanded: Bool
    // A3: inline argument editing before approval.
    @State private var editing: Bool = false
    @State private var editedValues: [String: String] = [:]

    init(pending: PendingHITL, confirmation: PendingToolConfirmation) {
        self.pending = pending
        self.confirmation = confirmation
        // Destructive ops reveal their full arguments by default so what's at stake is visible.
        _argsExpanded = State(initialValue: confirmation.risk == .destructive)
    }

    /// A1: banner accent driven by the tool's risk tier.
    private var riskColor: Color {
        switch confirmation.risk {
        case .safe:        return theme.secondaryText
        case .moderate:    return theme.warningColor
        case .destructive: return theme.errorColor
        }
    }

    /// A1: pretty-printed structured arguments (nil if params weren't valid JSON or are empty).
    private var prettyArgs: String? {
        guard let args = confirmation.arguments else { return nil }
        switch args {                                      // empty {} / [] → no expand affordance
        case .object(let d) where d.isEmpty: return nil
        case .array(let a) where a.isEmpty:  return nil
        default: break
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(args),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private var hasInlineParams: Bool {
        !confirmation.params.isEmpty && confirmation.params != "{}"
    }

    /// A2: a parsed file operation, when this confirmation is a file-mutating tool.
    private var fileChange: FileChange? {
        FileChange.parse(toolName: confirmation.toolName, arguments: confirmation.arguments)
    }

    /// A3: top-level string arguments that can be corrected inline (skip huge values like file content).
    private var editableArgs: [(key: String, value: String)] {
        guard case .object(let dict)? = confirmation.arguments else { return [] }
        return dict.compactMap { (k, v) -> (key: String, value: String)? in
            if case .string(let s) = v, s.count <= 2000 { return (key: k, value: s) }
            return nil
        }.sorted { $0.key < $1.key }
    }

    private var hasEditableArgs: Bool { !editableArgs.isEmpty }

    /// A3: false if the user blanked a field that originally had a value — that would fail the tool's
    /// required-argument validation server-side (after the banner is gone), so block the approve.
    private var editsValid: Bool {
        guard editing else { return true }
        for arg in editableArgs where !arg.value.isEmpty {
            let edited = editedValues[arg.key] ?? arg.value
            if edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        }
        return true
    }

    /// A3: the full arguments object with the user's string edits applied (nil when not editing).
    private func buildEditedArguments() -> [String: JSONValue]? {
        guard editing, case .object(let original)? = confirmation.arguments else { return nil }
        var result = original
        for (key, value) in editedValues { result[key] = .string(value) }
        return result
    }

    private func toggleEditing() {
        if !editing {
            // Seed only un-edited keys so closing/reopening the editor preserves in-progress edits.
            for arg in editableArgs where editedValues[arg.key] == nil {
                editedValues[arg.key] = arg.value
            }
        }
        withAnimation(.easeInOut(duration: 0.15)) { editing.toggle() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: source title + risk pill (A1)
            HStack(spacing: 7) {
                Image(systemName: hitlInterfaceIcon(pending.origin.interface))
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(riskColor)
                    .accessibilityHidden(true)
                Text(pending.origin.title)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(riskColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                riskPill
            }

            // Tool + arguments
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(.caption2))
                        .foregroundColor(theme.secondaryText)
                        .accessibilityHidden(true)
                    Text(confirmation.toolName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                    Spacer(minLength: 4)
                    if hasEditableArgs {
                        Button { toggleEditing() } label: {
                            Image(systemName: editing ? "checkmark.circle.fill" : "pencil")
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundColor(editing ? theme.successColor : theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(editing ? "Done editing arguments" : "Edit arguments")
                    }
                    if !editing, fileChange == nil, prettyArgs != nil {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { argsExpanded.toggle() }
                        } label: {
                            Image(systemName: argsExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(argsExpanded ? "Hide arguments" : "Show arguments")
                    }
                }

                if editing {
                    // A3: inline-editable string arguments (paths, commands, queries). Scroll-capped
                    // so a tool with many args can't push the chat input off-screen.
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(editableArgs, id: \.key) { arg in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(arg.key)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(theme.tertiaryText)
                                        .frame(minWidth: 48, alignment: .leading)
                                    TextField("", text: Binding(
                                        get: { editedValues[arg.key] ?? arg.value },
                                        set: { editedValues[arg.key] = $0 }
                                    ))
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(theme.primaryText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.surfaceOverlay.opacity(0.6)))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.warningColor.opacity(0.4), lineWidth: 1))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                    if !editsValid {
                        Text("A field you edited can't be left empty.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.errorColor)
                    }
                } else if let fileChange {
                    // A2: file-mutating tools get a diff / source→destination preview.
                    FileChangePreviewView(change: fileChange)
                } else if let pretty = prettyArgs, argsExpanded {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(pretty)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                } else if hasInlineParams {
                    Text(confirmation.params)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.surfaceOverlay.opacity(0.5)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(riskColor.opacity(confirmation.risk == .destructive ? 0.4 : 0.0), lineWidth: 1)
            )

            HStack(spacing: 8) {
                Spacer()
                if isProcessing {
                    ProgressView().controlSize(.small).scaleEffect(0.8).frame(height: 28)
                } else {
                    HITLActionButton(label: "Deny", icon: "xmark", style: .ghost, isDisabled: false, keyboardShortcut: .cancelAction) {
                        decide(approved: false)
                    }

                    // A4: "Always allow" → flip this tool to auto-approve in its profile. Hidden for
                    // destructive tools (those always prompt) and when the profile is unknown.
                    if confirmation.risk != .destructive, pending.origin.profileID != nil {
                        HITLActionButton(label: "Always allow", icon: "checkmark.circle", style: .ghost, isDisabled: !editsValid) {
                            allowAlways()
                        }
                    }

                    // B1: Allow has NO Return shortcut. The chat input is an always-focused NSTextView
                    // whose Return is claimed window-wide, so Return=Allow could approve a tool while the
                    // user is mid-sentence. Approve is click-only; Esc=Deny is safe (bare Esc isn't a send).
                    HITLActionButton(
                        label: confirmation.risk == .destructive ? "Allow anyway" : "Allow",
                        icon: "checkmark",
                        style: .primary(color: confirmation.risk == .destructive ? theme.errorColor : theme.successColor),
                        isDisabled: !editsValid   // A3: block approving with a required field emptied
                    ) {
                        decide(approved: true)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    /// A4: auto-approve this tool in its originating profile, then approve the current request.
    private func allowAlways() {
        guard !isProcessing, let profileID = pending.origin.profileID else { return }
        let tool = confirmation.toolName
        let conversationID = pending.origin.conversationID
        let edited = buildEditedArguments()   // capture @State on MainActor before hopping off it
        profileService.setToolAutoApprove(profileID: profileID, toolName: tool)
        bannerLogger.info("[HITL/UI] '\(tool)' ALWAYS-ALLOW by user — persisted to profile + session allowlist [conv \(conversationID)]")
        withAnimation { isProcessing = true }
        // [HITL/Bug2] The persisted flip only affects the NEXT run (the live tool set was resolved at
        // stream start). Register a session grant for THIS run, chained BEFORE the approval resume so the
        // tool's next call in the same run observes it — ordered by construction, not by Task timing.
        Task { @MainActor in
            await SessionToolApprovals.shared.allow(toolName: tool, conversationID: conversationID)
            vm.submitToolApproval(operationID: pending.id, approved: true, editedArguments: edited)
        }
    }

    private var riskPill: some View {
        HStack(spacing: 3) {
            Image(systemName: confirmation.risk.icon)
                .font(.system(size: 9, weight: .bold))
            Text(confirmation.risk.label)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(riskColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(riskColor.opacity(0.12)))
        .accessibilityLabel("Risk: \(confirmation.risk.label)")
    }

    private func decide(approved: Bool) {
        guard !isProcessing else { return }   // press-time guard (no double-fire before re-render)
        let edited = approved ? buildEditedArguments() : nil
        logDecision(approved: approved, edited: edited)
        withAnimation { isProcessing = true }
        // A3: apply the user's inline edits on approval. Dismissal is driven by InteractionCenter.resolve.
        vm.submitToolApproval(operationID: pending.id, approved: approved, editedArguments: edited)
    }

    /// Logs the user's banner decision with full context — denial, plain approval, or approval with the
    /// specific old→new argument edits — so the run log shows what the user actually did.
    private func logDecision(approved: Bool, edited: [String: JSONValue]?) {
        let tool = confirmation.toolName
        guard approved else {
            bannerLogger.info("[HITL/UI] '\(tool)' DENIED by user [op \(pending.id)]")
            return
        }
        if let edited, case .object(let original)? = confirmation.arguments {
            // Log only WHICH args were edited — the executed values already appear at the dispatch log,
            // and argument values can hold secrets/paths/commands we don't want to duplicate into logs.
            let changedKeys = edited.keys.sorted().filter { original[$0]?.stringValue != edited[$0]?.stringValue }
            if !changedKeys.isEmpty {
                bannerLogger.info("[HITL/UI] '\(tool)' APPROVED with edits to [\(changedKeys.joined(separator: ", "))] [op \(pending.id)]")
                return
            }
        }
        bannerLogger.info("[HITL/UI] '\(tool)' APPROVED by user [op \(pending.id)]")
    }
}

// MARK: - Clarification Banner

private struct ClarificationInteractionBanner: View {
    let pending: PendingHITL
    let clarification: PendingClarification
    @Environment(MainApplicationViewModel.self) private var vm
    @Environment(\.appTheme) private var theme

    @State private var userInput: String = ""
    @State private var isSubmitting: Bool = false
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    private var hasOptions: Bool { !(clarification.options ?? []).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                InteractionHeader(pending: pending, accent: theme.streamingIndicator)
                Text("⎋ skip")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText.opacity(0.6))
            }

            Text(clarification.question)
                .font(theme.fontSubheadline.weight(.medium))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            if let options = clarification.options, !options.isEmpty {
                // A5: one-tap choice buttons — answering picks an option directly. Capped + scrollable
                // so a long option list can't push the chat input off-screen.
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            optionChip(option)
                        }
                    }
                }
                .frame(maxHeight: 150)
                HStack(spacing: 8) { Spacer(); skipButton }
            } else if clarification.multiline {
                // A5: multi-line answer.
                TextEditor(text: $userInput)
                    .font(theme.fontSubheadline)
                    .foregroundColor(theme.primaryText)
                    .focused($isFocused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 120)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceOverlay.opacity(0.6)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isFocused ? theme.streamingIndicator.opacity(0.45) : theme.dividerColor.opacity(0.4), lineWidth: 1)
                    )
                HStack(spacing: 8) { Spacer(); skipButton; sendButton }
            } else {
                HStack(spacing: 8) {
                    TextField("Type your answer...", text: $userInput)
                        .textFieldStyle(.plain)
                        .font(theme.fontSubheadline)
                        .foregroundColor(theme.primaryText)
                        .focused($isFocused)
                        .onSubmit { if canSend { submit() } }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceOverlay.opacity(0.6)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isFocused ? theme.streamingIndicator.opacity(0.45) : theme.dividerColor.opacity(0.4), lineWidth: 1)
                        )
                    skipButton
                    sendButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .onAppear { if !hasOptions { isFocused = true } }  // no field to focus in options mode
    }

    private var skipButton: some View {
        HITLActionButton(label: "Skip", icon: "arrow.uturn.left", style: .ghost, isDisabled: isSubmitting, keyboardShortcut: .cancelAction) {
            skip()   // B1: Esc — the "⎋ skip" hint is now real
        }
    }

    private var sendButton: some View {
        HITLActionButton(label: "Send", icon: "arrow.up", style: .primary(color: theme.streamingIndicator), isDisabled: !canSend) {
            submit()
        }
    }

    private func optionChip(_ option: String) -> some View {
        Button { send(option) } label: {
            Text(option)
                .font(.system(.caption, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceOverlay.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.streamingIndicator.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .help(option)                              // full text on hover when truncated
        .accessibilityLabel("Answer: \(option)")
    }

    private func submit() { send(userInput) }

    private func send(_ text: String) {
        guard !isSubmitting else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation { isSubmitting = true }
        bannerLogger.info("[ASK_USER/UI] answered (\(trimmed.count) chars) [op \(pending.id)]")
        vm.submitClarificationResponse(operationID: pending.id, response: trimmed)
    }

    private func skip() {
        guard !isSubmitting else { return }
        withAnimation { isSubmitting = true }
        bannerLogger.info("[ASK_USER/UI] SKIPPED by user [op \(pending.id)]")
        vm.submitClarificationResponse(operationID: pending.id, response: nil)
    }
}

// MARK: - Gate Banner (E1 — per-option routing)

/// Renders a workflow Gate HITL: the prompt, a live countdown to the auto-reject deadline, and one
/// button per configured option. Picking an option routes the workflow to that option's output port.
private struct GateInteractionBanner: View {
    let pending: PendingHITL
    let gate: PendingGate
    @Environment(MainApplicationViewModel.self) private var vm
    @Environment(\.appTheme) private var theme
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InteractionHeader(pending: pending, accent: theme.warningColor)

            Text(gate.prompt)
                .font(theme.fontSubheadline.weight(.medium))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            if gate.deadline != nil {
                // Live countdown to the configured auto-reject. WorkflowExecutor enforces the actual
                // timeout; this only displays it.
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    if let text = countdownText(now: context.date) {
                        Label(text, systemImage: "timer")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.warningColor)
                    }
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(gate.options.enumerated()), id: \.offset) { _, option in
                        gateButton(option)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func countdownText(now: Date) -> String? {
        guard let deadline = gate.deadline else { return nil }
        let remaining = max(0, deadline.timeIntervalSince(now))
        if remaining <= 0 { return "Timing out…" }
        let m = Int(remaining) / 60, s = Int(remaining) % 60
        return m > 0 ? String(format: "Auto-rejects in %d:%02d", m, s) : "Auto-rejects in \(s)s"
    }

    private func gateButton(_ option: String) -> some View {
        Button { choose(option) } label: {
            Text(option)
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceOverlay.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.warningColor.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .help(option)
        .accessibilityLabel("Choose: \(option)")
    }

    private func choose(_ option: String) {
        guard !isSubmitting else { return }
        withAnimation { isSubmitting = true }
        bannerLogger.info("[GATE/UI] chose '\(option)' [op \(pending.id)]")
        vm.submitGateChoice(operationID: pending.id, option: option)
    }
}

// MARK: - Plan Review Banner

private struct PlanReviewInteractionBanner: View {
    let pending: PendingHITL
    let planReview: PendingPlanReview
    @Environment(MainApplicationViewModel.self) private var vm
    @Environment(\.appTheme) private var theme

    @State private var editableSubtasks: [SubTask] = []
    @State private var isProcessing: Bool = false

    private var canApprove: Bool {
        !editableSubtasks.isEmpty &&
        !editableSubtasks.contains(where: { $0.description.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                InteractionHeader(pending: pending, accent: theme.streamingIndicator)
                Text("\(editableSubtasks.count) step\(editableSubtasks.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText.opacity(0.6))
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 6) {
                    ForEach($editableSubtasks) { $subtask in
                        let displayIndex = editableSubtasks.firstIndex(where: { $0.id == subtask.id })
                        PlanReviewInteractionSubtaskRow(
                            subtask: $subtask,
                            index: displayIndex ?? 0,
                            onDelete: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    editableSubtasks.removeAll { $0.id == subtask.id }
                                }
                            }
                        )
                    }
                }
            }
            .frame(maxHeight: 200)

            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        // Default init mints a UUID id. A count-derived id (step_N+1) collides with an
                        // existing id after a delete → duplicate ForEach identities (wrong-row edits /
                        // double-delete / corrupted submitted plan).
                        editableSubtasks.append(SubTask(description: ""))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle").font(.system(.caption2))
                        Text("Add Step").font(.system(.caption, weight: .medium))
                    }
                    .foregroundColor(theme.streamingIndicator.opacity(0.8))
                }
                .buttonStyle(.plain)

                Spacer()

                if editableSubtasks != planReview.subtasks {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { editableSubtasks = planReview.subtasks }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise").font(.system(.caption2))
                            Text("Reset").font(.system(.caption, weight: .medium))
                        }
                        .foregroundColor(theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                if isProcessing {
                    ProgressView().controlSize(.small).scaleEffect(0.8).frame(height: 28)
                } else {
                    HITLActionButton(label: "Reject", icon: "xmark", style: .ghost, isDisabled: false, keyboardShortcut: .cancelAction) {
                        reject()
                    }
                    HITLActionButton(label: "Approve & Run", icon: "play.fill", style: .primary(color: theme.successColor), isDisabled: !canApprove) {
                        approve()
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .onAppear { editableSubtasks = planReview.subtasks }
    }

    private func approve() {
        guard !isProcessing else { return }
        withAnimation { isProcessing = true }
        vm.submitPlanReview(operationID: pending.id, editedPlan: editableSubtasks)
    }

    private func reject() {
        guard !isProcessing else { return }
        withAnimation { isProcessing = true }
        vm.submitPlanReview(operationID: pending.id, editedPlan: nil)
    }
}

private struct PlanReviewInteractionSubtaskRow: View {
    @Binding var subtask: SubTask
    let index: Int
    let onDelete: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(theme.streamingIndicator.opacity(0.7))
                .frame(width: 18, alignment: .center)

            TextField("Subtask description", text: $subtask.description)
                .textFieldStyle(.plain)
                .font(.system(.caption))
                .foregroundColor(theme.primaryText)

            if let hints = subtask.toolHints, !hints.isEmpty {
                ForEach(hints, id: \.self) { hint in
                    Text(hint)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.surfaceOverlay.opacity(0.6)))
                }
            }

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(.caption))
                    .foregroundColor(theme.tertiaryText.opacity(0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete step")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.surfaceOverlay.opacity(0.4)))
    }
}

// MARK: - Shared Action Button

private enum HITLButtonStyle {
    case ghost
    case primary(color: Color)
}

private struct HITLActionButton: View {
    let label: String
    let icon: String
    let style: HITLButtonStyle
    let isDisabled: Bool
    var keyboardShortcut: KeyboardShortcut? = nil
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var bgColor: Color {
        switch style {
        case .ghost:
            return isHovering ? theme.surfaceOverlay : Color.clear
        case .primary(let color):
            return isDisabled ? color.opacity(0.25) : (isHovering ? color.opacity(0.9) : color)
        }
    }

    private var fgColor: Color {
        switch style {
        case .ghost:   return theme.secondaryText
        case .primary: return .white
        }
    }

    private var borderColor: Color {
        switch style {
        case .ghost:            return theme.dividerColor.opacity(0.4)
        case .primary(let color): return color.opacity(0.3)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(.caption2, weight: .semibold))
                Text(label).font(.system(.caption, weight: .medium))
            }
            .foregroundColor(isDisabled ? fgColor.opacity(0.4) : fgColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(bgColor))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(borderColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .keyboardShortcut(keyboardShortcut)   // B1: nil = no shortcut
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { isHovering = h } }
        .scaleEffect(isHovering && !isDisabled ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovering)
    }
}
