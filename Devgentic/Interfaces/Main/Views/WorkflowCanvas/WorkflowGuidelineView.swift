//
//  WorkflowGuidelineView.swift
//  Devgentic
//
//  Created on 16/08/26.
//
//  The in-app workflow manual, opened from the canvas's "Guide" button. One place that explains
//  every node kind and the execution model — including the behaviours a user cannot infer from the
//  canvas: unattended (scheduled / chat-bridge) differences, failure routing, timeouts, and what
//  becomes the final output.
//
//  ⚠️ EVERY CLAIM IN HERE MUST MATCH THE ENGINE. This file is user-facing documentation of
//  `WorkflowExecutor` behaviour, and the register has a filed lesson (WF63) about inspector copy
//  derived from stale facts shipping wrong advice. When engine behaviour changes, this file changes
//  in the SAME commit — treat it like `architecture_readme.md`, but for users.
//

import SwiftUI

struct WorkflowGuidelineView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    overviewSection
                    executionSection
                    failureSection
                    mergeSection
                    finalOutputSection
                    nodesSection
                    unattendedSection
                    timeoutsSection
                    dataSection
                    savingSection
                }
                .padding(24)
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 600, idealHeight: 760)
        .background(theme.primaryBackground)
    }

    private var header: some View {
        HStack {
            Image(systemName: "book.closed.fill")
                .foregroundColor(theme.accentColor)
            Text("Workflow Guide")
                .font(theme.fontTitle3.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Sections

    private var overviewSection: some View {
        section("What a workflow is", icon: "point.3.connected.trianglepath.dotted", expanded: true) {
            para("A workflow is a graph of nodes connected by wires. Each node does one job — run an AI profile, route by rules, transform text, call a tool, or wait for your approval — and passes its output to whatever is wired after it. You draw the graph on this canvas; running it executes the graph from its entry nodes to its ends.")
            diagram("""
            your message ──▶ [Researcher] ──▶ ⟨Router⟩ ──Urgent──▶ [Escalate] ──▶ answer
                              profile          rules  └─Billing──▶ [Invoice bot] ─┘
            """)
            para("Nodes with no incoming wires are entry nodes — they receive your message. Nodes whose outgoing wires never fired are the workflow's terminals — their output becomes the final answer.")
        }
    }

    private var executionSection: some View {
        section("How execution works", icon: "play.circle") {
            bullet("Independent nodes run in parallel. The engine groups nodes into levels by their dependencies; everything on one level that doesn't depend on a sibling runs at the same time.")
            bullet("A node's input is the joined output of the upstream nodes whose wires actually fired. One upstream arrives as-is; several arrive separated by a divider line.")
            bullet("Nothing is ever truncated. Upstream text and inlined documents pass through in full — if a downstream node's model has a small context window, pick a larger model or make upstreams less verbose. That trade is yours by design.")
            bullet("The workflow does not see your chat history or RAG context. Only the message that started the run (plus any knowledge-base and attachment text) reaches the entry nodes.")
        }
    }

    private var failureSection: some View {
        section("Failure and the error port", icon: "exclamationmark.triangle") {
            para("Every node that can fail — Profile, Router, Code, Gate, Action — has a dedicated error output port beside its normal ones.")
            diagram("""
            [Fetcher] ──default──▶ [Summarizer]
                └──error────▶ [Notify on-call]     ← runs ONLY if Fetcher fails
            """)
            bullet("Wire the error port to handle a failure: the handler receives the failed node's partial output, annotated with the reason.")
            bullet("Leave it unwired and that branch simply stops there — the failure reason appears in the run's final output.")
            bullet("A failure never cancels parallel branches and never stops the whole run. Work that succeeded elsewhere keeps its results.")
            bullet("Pressing Stop is not a failure: cancelled nodes do not trigger error branches.")
        }
    }

    private var mergeSection: some View {
        section("Merging branches (fan-in)", icon: "arrow.triangle.merge") {
            para("A node with several incoming wires waits for all of them — except a branch that could never fire because a Router or Gate chose a different way. The engine works that out from the graph; there is nothing to configure.")
            diagram("""
            ⟨Router⟩ ──A──▶ [Draft A] ──┐
                    └─B──▶ [Draft B] ──┴──▶ [Polish]   ← runs when the CHOSEN side finishes
            """)
            bullet("If genuinely independent branches merge and one of them failed with its error port unwired, the merge is skipped rather than run on partial input.")
        }
    }

    private var finalOutputSection: some View {
        section("What becomes the final answer", icon: "flag.checkered") {
            bullet("Terminals — nodes whose outgoing wires never fired, or that have none — produce the final output.")
            bullet("One terminal: its output is the answer, verbatim. Several: each appears under a heading with its node's name.")
            bullet("A branch the Router didn't take is quietly omitted; it is not an error and is not listed.")
            bullet("A terminal can succeed with empty text — for example an Action node whose job was a side effect. That's a valid outcome, not a failure.")
        }
    }

    private var nodesSection: some View {
        section("The nodes", icon: "square.grid.2x2", expanded: true) {
            nodeDoc("Profile", color: ProfileType.bot.displayColor, icon: "person.crop.circle",
                    "Runs a Bot or Agent profile. The card takes the profile's OWN colour — blue for a Bot, green for an Agent — so this swatch shows the Bot case. The Task Description is this node's standing instruction; the workflow's input message reaches entry nodes only, appended to their task. Supports per-node Retries and a Hard Timeout. An agent's tool confirmations pause the run just like a Gate.")
            nodeDoc("Sub-workflow", color: ProfileType.workflow.displayColor, icon: "point.3.connected.trianglepath.dotted",
                    "A Profile node bound to another Workflow profile — it runs that workflow's canvas as a child. Text-only handoff: the child gets this node's input as its message; variables and artifacts do not cross in (artifacts produced inside do flow out). Nesting is limited to 3 levels and cycles are blocked at design time. ⚠️ This node's Hard Timeout bounds the child's ENTIRE run — size it for the whole child, not one step.")
            nodeDoc("Router", color: theme.nodeIdentityColor(for: .router), icon: "arrow.triangle.branch",
                    "Matches the input against labelled rules, top to bottom; each rule's label is an output port. Exactly one match routes there. Anything else — SEVERAL rules matching, or NONE — is decided by one setting, 'When Routing Can't Decide': ask you to pick, route to a rule of your choosing, end the workflow here, or fail onto the error port. Unattended runs (scheduled or chat-bridge) never pause; an Ask uses its 'If nobody can answer' fallback instead. An optional AI Classifier (local MLX model) can name a branch when no pattern rule matched, and its answer follows the same rules — one label routes, none or several fall to the setting. ⚠️ A classifier that could not RUN fails the node regardless of that setting.")
            nodeDoc("Gate", color: theme.nodeIdentityColor(for: .gate), icon: "hand.raised",
                    "Pauses the run and asks you to choose. Each option is its own output port — the chosen option's branch runs. An optional timeout fails the node (onto its error port) if nobody answers; without one the gate waits indefinitely. Parallel branches keep running while it waits, and the wait never counts against any timeout. ⚠️ In scheduled workflows always set a timeout — see 'Attended vs unattended' below.")
            nodeDoc("Code", color: theme.nodeIdentityColor(for: .code), icon: "chevron.left.forwardslash.chevron.right",
                    "A deterministic text transform — no AI involved. Write a template using {{ input }}, {{ input.json.path }} for a field of JSON output, and {{ var.name }}; optionally store the result in a variable for later nodes. ⚠️ A placeholder that can't be resolved (e.g. a misspelled variable) is left in the output verbatim — check spelling; the validator does not lint Code templates. Never retries; failure routes to the error port.")
            nodeDoc("Action", color: theme.nodeIdentityColor(for: .action), icon: "bolt.horizontal.fill",
                    "Calls one tool directly — no AI, deterministic. Bind each argument to a literal or a placeholder. Supports Retries (a tool call that threw is retried; a tool that RETURNED an error is not, because its side effect may already have happened) and a per-attempt timeout. Tools marked as requiring confirmation pause the run for your approval.")
            nodeDoc("Trigger", color: theme.nodeIdentityColor(for: .trigger), icon: "bolt",
                    "An entry-point marker only. It never executes, has no configuration and no error port — use it to make a workflow's starting point explicit.")
            nodeDoc("Sticky note", color: StickyNoteColor.yellow.swiftUIColor, icon: "note.text",
                    "Annotation only — invisible to execution. Document your graph for whoever opens it next.")
        }
    }

    private var unattendedSection: some View {
        section("Attended vs unattended runs", icon: "person.fill.questionmark", expanded: true) {
            para("A run is attended when you start it from the app; it is unattended when the scheduler or a chat bridge (Telegram / Discord / Slack) starts it. Anything that waits for a human behaves differently:")
            tableRow("Router — several rules match", "Pauses and asks you", "Never pauses — first matching rule wins automatically")
            tableRow("Gate", "Banner appears; waits for your choice", "Scheduled: no banner is shown — an unanswered gate waits until the run's deadline cancels the WHOLE run, so always set a gate timeout. Chat bridge: answerable remotely via buttons, but there is no automatic deadline")
            tableRow("Tool confirmation", "Banner appears; waits", "Same as Gate — nothing on screen for scheduled runs")
            para("Scheduled runs have a fixed overall time budget, counted from the moment the run starts — a long-running workflow eats into it before any pause begins. Chat-bridge runs have no overall deadline.")
        }
    }

    private var timeoutsSection: some View {
        section("Timeouts and retries", icon: "clock.arrow.circlepath") {
            bullet("Each node gets a compute budget (default 120 seconds). Time spent waiting for a human — a gate, a confirmation, a routing question — never counts against it.")
            bullet("Profile and Action nodes expose a per-node Hard Timeout to raise or lower their own budget. On expiry the node fails onto its error port and any partial result is discarded.")
            bullet("Only Profile and Action nodes retry; Router, Code and Gate never do. ⚠️ Retrying a Profile node re-runs its whole agent turn — including tool side effects it already performed.")
            bullet("A Sub-workflow node's single budget covers its child's entire run — raise its Hard Timeout for long children.")
        }
    }

    private var dataSection: some View {
        section("Data, variables and files", icon: "shippingbox") {
            bullet("{{ input }} is the upstream text; if an upstream produced JSON, {{ input.json.path }} reads a field from it.")
            bullet("Variables are written ONLY by Code nodes (their Output Variable). Routers can test them; Code and Action nodes can substitute them.")
            bullet("Files and images produced by nodes flow downstream as attachments: later nodes see a manifest naming each file, and agents with file tools can read them.")
            bullet("Knowledge-base and attachment text from your message ride into the entry nodes as part of the input.")
        }
    }

    private var savingSection: some View {
        section("Saving and running", icon: "square.and.arrow.down") {
            bullet("⚠️ There is no autosave. Save writes the canvas; Revert returns to the last save. Unsaved edits survive switching screens and are offered for saving when you quit.")
            bullet("⚠️ Run executes the last SAVED graph, not your unsaved edits — save before running.")
            bullet("Undo covers the last 25 structural edits (add / delete / rewire). Node moves are not undoable.")
            bullet("The validation panel lists everything that would block a run — a graph with errors refuses to start before spending any tokens.")
        }
    }

    // MARK: - Building blocks

    private func section(_ title: String, icon: String, expanded: Bool = false,
                         @ViewBuilder content: @escaping () -> some View) -> some View {
        GuidelineSection(title: title, icon: icon, initiallyExpanded: expanded, theme: theme, content: content)
    }

    private func para(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(theme.accentColor)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A monospaced mini-diagram. Horizontal scroll keeps long lines intact instead of wrapping
    /// them into nonsense; the box makes it read as an illustration, not body text.
    private func diagram(_ art: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(art)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.primaryText.opacity(0.85))
                .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.accentColor.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func nodeDoc(_ name: String, color: Color, icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(color)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Attended-vs-unattended comparison row.
    private func tableRow(_ situation: String, _ attended: String, _ unattended: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(situation)
                .font(theme.fontCaption.weight(.semibold))
                .foregroundColor(theme.primaryText)
            HStack(alignment: .top, spacing: 12) {
                labeledCell("Attended", attended, color: .green)
                labeledCell("Unattended", unattended, color: .orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.controlBackground.opacity(0.6)))
    }

    private func labeledCell(_ label: String, _ text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One collapsible section of the guide. A separate view so each keeps its own disclosure state.
private struct GuidelineSection<Content: View>: View {
    let title: String
    let icon: String
    let initiallyExpanded: Bool
    let theme: any Theme
    @ViewBuilder let content: () -> Content

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.accentColor)
                    Text(title)
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                }
            }
        }
        .padding(16)
        .background(theme.surfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { if initiallyExpanded { isExpanded = true } }
    }
}
