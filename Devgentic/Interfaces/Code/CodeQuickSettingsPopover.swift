// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeQuickSettingsPopover.swift
//  Devgentic
//
//  Per-project execution settings for the Code interface: iteration cap, compute budget,
//  and which tools ask before they act.
//

import SwiftUI
import AppKit

private let logger = DGLogger(category: "CodeQuickSettings")

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

    /// Logical ordering for confirmable tools
    private var confirmableTools: [Tool] {
        let order = ["edit_code_single", "edit_code_batch", "create_new_file", "overwrite_file", "batch_command"]
        return CodeToolPreset.defaultTools
            .filter { $0.requiresConfirmation }
            .sorted { a, b in
                let idxA = order.firstIndex(of: a.name) ?? 99
                let idxB = order.firstIndex(of: b.name) ?? 99
                return idxA < idxB
            }
    }

    private var projectName: String? {
        codeSessionManager.projectPath?.lastPathComponent
    }

    private var autoApprovedCount: Int {
        confirmableTools.filter { !(draft.toolConfirmations[$0.name] ?? $0.requiresConfirmation) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.35)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    executionSection
                    approvalsSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)

            Divider().opacity(0.35)

            footer
        }
        .frame(width: 430, height: 530)
        .background(theme.primaryBackground)
        .onAppear {
            draft = codeSessionManager.quickSettings
            hasHydrated = true
        }
        .onChange(of: draft) { _, newValue in
            guard hasHydrated else { return }
            codeSessionManager.updateQuickSettings(newValue)
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

                    Text(projectName.map { "Scoped to '\($0)'" } ?? "No project folder open")
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

                            if draft.maxIterations == nil {
                                Text("Default")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(theme.secondaryText.opacity(0.7))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(theme.surfaceOverlayStrong)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }

                        Text("Reasoning cycles before forced completion")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                    }

                    Spacer()

                    iterationsStepper
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
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.dividerColor.opacity(0.3), lineWidth: 0.8)
            )
        }
    }

    // MARK: - Iterations Stepper

    private var iterationsStepper: some View {
        HStack(spacing: 3) {
            Button(action: decrementIterations) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(currentIterations <= 3 ? theme.secondaryText.opacity(0.3) : theme.primaryText)
                    .frame(width: 22, height: 22)
                    .background(theme.surfaceOverlayStrong)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(currentIterations <= 3)

            Text("\(currentIterations)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .frame(minWidth: 26, alignment: .center)

            Button(action: incrementIterations) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(currentIterations >= 100 ? theme.secondaryText.opacity(0.3) : theme.primaryText)
                    .frame(width: 22, height: 22)
                    .background(theme.surfaceOverlayStrong)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(currentIterations >= 100)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(theme.surfaceOverlayStrong.opacity(0.6))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(theme.dividerColor.opacity(0.35), lineWidth: 0.8)
        )
    }

    private var currentIterations: Int {
        draft.maxIterations ?? 20
    }

    private func decrementIterations() {
        let current = currentIterations
        let next: Int
        if current > 20 {
            next = max(20, current - 5)
        } else if current > 10 {
            next = max(10, current - 5)
        } else {
            next = max(3, current - 1)
        }
        updateIterations(next)
    }

    private func incrementIterations() {
        let current = currentIterations
        let next: Int
        if current < 10 {
            next = current + 1
        } else {
            next = min(100, current + 5)
        }
        updateIterations(next)
    }

    private func updateIterations(_ value: Int) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        if value == 20 {
            draft.maxIterations = nil
        } else {
            draft.maxIterations = value
        }
    }

    // MARK: - Timeout Menu

    private var timeoutMenu: some View {
        Menu {
            Button(action: { setTimeout(nil) }) {
                HStack {
                    Text("5 minutes (Default)")
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
            return "5 min (Default)"
        }
    }

    private func setTimeout(_ value: TimeInterval?) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        draft.executionTimeout = value
    }

    // MARK: - Approvals Section

    private var approvalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("ASK BEFORE RUNNING")
                Spacer()
                if autoApprovedCount > 0 {
                    Text("\(autoApprovedCount) auto-acting")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.orange.opacity(0.9))
                }
            }

            Text("These tools modify files or execute shell commands. Turn off to grant auto-run permission without confirmation prompts in this project.")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(confirmableTools.enumerated()), id: \.element.name) { index, tool in
                    if index > 0 {
                        Divider().opacity(0.25).padding(.leading, 42)
                    }
                    toolApprovalRow(tool)
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
        }
    }

    private func toolApprovalRow(_ tool: Tool) -> some View {
        let isAskOn = binding(for: tool).wrappedValue

        return HStack(spacing: 11) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.surfaceOverlayStrong)
                    .frame(width: 26, height: 26)

                Image(systemName: toolIcon(for: tool.name))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }

            // Names & Description
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)

                    Text(toolDomain(for: tool.name))
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(theme.surfaceOverlayStrong)
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    if !isAskOn {
                        Text("AUTO-RUN")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                Text(toolConciseDescription(for: tool.name, original: tool.description))
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: binding(for: tool))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func toolIcon(for name: String) -> String {
        switch name {
        case "batch_command":
            return "terminal"
        case "create_new_file":
            return "doc.badge.plus"
        case "overwrite_file":
            return "doc.badge.arrow.up"
        case "edit_code_single":
            return "pencil.line"
        case "edit_code_batch":
            return "pencil.and.list.clipboard"
        default:
            return "wrench"
        }
    }

    private func toolDomain(for name: String) -> String {
        switch name {
        case "batch_command":
            return "SHELL"
        case "create_new_file", "overwrite_file":
            return "FILE"
        case "edit_code_single", "edit_code_batch":
            return "EDIT"
        default:
            return "TOOL"
        }
    }

    private func toolConciseDescription(for name: String, original: String) -> String {
        switch name {
        case "edit_code_single":
            return "Applies a verified single search-and-replace edit to a file."
        case "edit_code_batch":
            return "Applies multiple search-and-replace edits to a file atomically."
        case "create_new_file":
            return "Creates a brand-new file. Fails safely if the file already exists."
        case "overwrite_file":
            return "Replaces an existing file's contents entirely with new content."
        case "batch_command":
            return "Executes shell commands with timeout guarantees and scoping."
        default:
            return original
        }
    }

    /// `true` = ask first. Absent from the override map means "use what the preset declares",
    /// which for every tool in `confirmableTools` is `true` by definition.
    private func binding(for tool: Tool) -> Binding<Bool> {
        Binding(
            get: { draft.toolConfirmations[tool.name] ?? tool.requiresConfirmation },
            set: { newValue in
                if newValue == tool.requiresConfirmation {
                    // Back to the preset — drop the override rather than storing a value equal to
                    // the default, so `isDefault` stays honest and the entry can be reclaimed.
                    draft.toolConfirmations.removeValue(forKey: tool.name)
                } else {
                    draft.toolConfirmations[tool.name] = newValue
                    if !newValue {
                        logger.notice("[CODE_SETTINGS] '\(tool.name)' set to run WITHOUT confirmation in '\(projectName ?? "?")'. CONSEQUENCE: it acts on this project's files immediately, with no approval banner; the change is scoped to this folder and reverts if the folder is moved or renamed.")
                    }
                }
            }
        )
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
