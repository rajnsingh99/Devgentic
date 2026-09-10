// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  GateNodeInspectorView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Configuration sheet for Gate (HITL) nodes — card-based layout.
//  Allows the user to edit the approval prompt, customize option labels,
//  and set an optional timeout.
//  Uses SettingsCard components for visual consistency with other inspector views.
//

import SwiftUI

struct GateNodeInspectorView: View {
    @Binding var node: WorkflowNode
    @Environment(\.closeNodeInspector) private var closeInspector
    @Environment(\.appTheme) private var theme

    @State private var prompt: String = "Approve this workflow step?"
    /// [INS-5] Option rows carry a STABLE identity, so `ForEach` keys on the option rather than on
    /// its screen slot. With `ForEach(options.indices, id: \.self)` the identity WAS the slot:
    /// deleting the first of three rows destroyed slot 2's view and shifted every surviving row's
    /// text up a slot, taking keyboard focus, text selection and any in-flight IME composition with
    /// it — the user's caret silently vanished and every visible field changed under them. The
    /// Router's rules have used stable ids since they were written.
    ///
    /// ⚠️ The MODEL stays `[String]`. `GateNodeConfig.options` are PORT LABELS matched by exact
    /// string, and `WorkflowCanvasState.gateRenameMap` recovers renames POSITIONALLY — its
    /// documented precondition is that the inspector edits text in place and appends adds at the
    /// end. `saveAndDismiss` therefore flattens these rows back in row order, which preserves that
    /// precondition exactly; the ids never reach the model and cannot affect edge re-pointing.
    @State private var options: [OptionRow] = [OptionRow("Approve"), OptionRow("Reject")]

    struct OptionRow: Identifiable, Equatable {
        let id = UUID()
        var text: String
        init(_ text: String) { self.text = text }
    }
    @State private var hasTimeout: Bool = false
    @State private var timeoutSeconds: Double = 300
    @State private var showGuide: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    guideCard
                    approvalPromptCard
                    optionsCard
                    timeoutCard
                }
                .padding(24)
            }
        }
        .frame(
            minWidth: 800,
            idealWidth: 950,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 700,
            maxHeight: .infinity
        )
        .background(theme.primaryBackground)
        .onAppear { loadFromNode() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.red)
            Text("HITL Gate")
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Text("\u{00B7}")
                .foregroundColor(theme.tertiaryText)
            // Inline-editable node label — same pattern as the agent profile
            // editor's identity-header rename.
            TextField("Node Name", text: $node.displayName)
                .font(theme.fontCaption)
                .textFieldStyle(.plain)
                .foregroundColor(theme.secondaryText)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showGuide.toggle() }
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(theme.fontBody)
                    .foregroundColor(theme.secondaryText)
            }
            GlassActionButton(title: "Cancel", icon: "xmark", isAccent: false) { closeInspector() }
            GlassActionButton(title: "Save", icon: "checkmark", isAccent: true) { saveAndDismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.secondaryBackground.opacity(0.5))
    }

    // MARK: - 1. Guide Card (Collapsible)

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $showGuide) {
                VStack(alignment: .leading, spacing: 12) {
                    guideStep(
                        number: "1",
                        title: "Approval Prompt",
                        subtitle: "user-facing",
                        description: "The question shown when the workflow pauses here for your decision.",
                        color: .red
                    )
                    guideStep(
                        number: "2",
                        title: "Options",
                        subtitle: "one port each",
                        description: "Every option is its own output port — the branch wired to the option you choose is the one that runs. Wire each option to what should happen next.",
                        color: .blue
                    )
                    guideStep(
                        number: "3",
                        title: "Timeout",
                        subtitle: "optional",
                        description: "If nobody answers in time, the node FAILS onto its error port (wire it to handle the no-answer case). Without a timeout the gate waits indefinitely on an attended run.",
                        color: .orange
                    )
                    guideStep(
                        number: "4",
                        title: "Unattended Runs",
                        subtitle: "scheduled / bridge",
                        // ⚠️ WF-SE11 retired the "waits until the run deadline" behaviour: with no
                        // timeout and nobody reachable, the executor refuses UP FRONT and fails the
                        // node onto its error port. Either way the gate ends on the error port —
                        // the timeout only changes when. This sentence was byte-identical to the
                        // one the Workflow Guide carried, and both were stale (register CVV-7).
                        description: "A scheduled run shows no banner, and nobody can answer — so the node ends on its ERROR port either way: immediately if no timeout is set, or when the timeout elapses if one is. No option branch is ever taken, so wire the error port. Chat-bridge runs can be answered remotely via buttons but have no automatic deadline.",
                        color: .purple
                    )

                    guideTip("Only this branch pauses — parallel branches keep running, and time spent waiting never counts against any node timeout. Pressing Stop cancels the gate without firing its error branch.")
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(.red)
                    Text("How Gate Nodes Work")
                        .font(theme.fontCaption.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                }
            }
            .disclosureGroupStyle(.automatic)
        }
        .padding(16)
        .background(theme.surfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func guideStep(number: String, title: String, subtitle: String, description: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(color))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(theme.fontCaption.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .italic()
                }
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func guideTip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .font(theme.fontCaption)
                .foregroundColor(.yellow)
                .padding(.top, 2)
            Text(text)
                .font(.system(.caption))
                .foregroundColor(theme.secondaryText)
                .italic()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.yellow.opacity(0.15), lineWidth: 0.5)
        )
    }

    // MARK: - 2. Approval Prompt Card

    private var approvalPromptCard: some View {
        SettingsCard(title: "Approval Prompt", icon: "text.bubble", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                            .fill(theme.controlBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                            .stroke(theme.surfaceOverlayStrong.opacity(0.3), lineWidth: 0.5)
                    )
                Text("Shown to the user when the gate pauses execution.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - 3. Options Card

    private var optionsCard: some View {
        SettingsCard(title: "Options", icon: "list.bullet", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach($options) { $row in
                    // The index is still needed for the leading affordance and the placeholder, but
                    // it is derived per render and never captured into a binding or a delete.
                    let index = options.firstIndex(where: { $0.id == row.id }) ?? 0
                    HStack(spacing: 8) {
                        // Neutral per-row port glyph. The green-check / red-X pair encoded the same
                        // false approve/reject claim as the footer did.
                        Image(systemName: "arrow.right.circle")
                            .foregroundColor(theme.secondaryText)
                            .font(.system(size: 14))
                        TextField("Option \(index + 1)", text: $row.text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                                .fill(theme.controlBackground)
                        )

                        if options.count > 2 {
                            Button {
                                // Delete BY ID, never by a captured index.
                                options.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.tertiaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if options.count < 4 {
                    GlassActionButton(title: "Add Option", icon: "plus", isAccent: true) {
                        options.append(OptionRow("Option \(options.count + 1)"))
                    }
                }

                // ⚠️ The old sentence here — "First option is treated as approval, others as
                // rejection" — was false and contradicted guide step 2 in this same view. The engine
                // gives index 0 no meaning: `if let chosen = chosenOption { activePorts = [chosen] }`,
                // so EVERY option activates its own same-named port. A user who believed it wired one
                // "reject" branch and silently got nothing from the other options.
                Text("Every option becomes its own output port — wire each one to what should happen when it is chosen.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - 4. Timeout Card

    private var timeoutCard: some View {
        SettingsCard(title: "Timeout", icon: "clock", theme: theme) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Timeout")
                            .font(theme.fontBody.weight(.medium))
                            .foregroundColor(theme.primaryText)
                        // [INS-3] "Auto-rejects" was a promise the engine does not keep. The
                        // timeout arm sets `output = "Gate not answered (timed out)"` and
                        // `status = .failed(...)` and leaves `activePorts` UNSET — only the
                        // `if let chosen` arm ever activates an option port. A user who wired only
                        // the Reject branch, exactly as this copy invited, got nothing at all.
                        // The truthful description already existed in the collapsed guide above,
                        // which defaults to hidden.
                        Text("If nobody answers in time the node FAILS and its error port activates — no option branch is taken. Wire the error port to handle it.")
                            .font(.system(.caption))
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 24)
                    Toggle("", isOn: $hasTimeout)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                if hasTimeout {
                    Divider()
                        .padding(.vertical, 12)

                    HStack {
                        Slider(value: $timeoutSeconds, in: 30...900, step: 30)
                        Text("\(Int(timeoutSeconds))s")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Helpers

    private func loadFromNode() {
        guard case .gate(let config) = node.kind else { return }
        prompt = config.prompt
        // Flatten in row order — see the `options` note: `gateRenameMap` is positional.
        options = config.options.map(OptionRow.init)
        if let t = config.timeout {
            hasTimeout = true
            timeoutSeconds = t
        }
    }

    private func saveAndDismiss() {
        let config = GateNodeConfig(
            prompt: prompt.isEmpty ? "Approve this workflow step?" : prompt,
            options: options.map(\.text).filter { !$0.isEmpty },
            timeout: hasTimeout ? timeoutSeconds : nil
        )
        node.kind = .gate(config)

        // [INS-11] The `if node.nodeConfig == nil { node.nodeConfig = WorkflowNodeConfig() }` that
        // stood here is GONE — same reason as the Router's. `joinMode` was retired 2026-08-13 and a
        // Gate has no other per-node config this panel edits, so the line's only effect was turning
        // `nil` into `.some(defaults)`, which `replaceNode`'s equality guard cannot absorb: a Save
        // that changed nothing still dirtied the canvas and burned an undo slot.

        closeInspector()
    }
}
