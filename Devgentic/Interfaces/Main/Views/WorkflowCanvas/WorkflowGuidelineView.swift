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
                    "Runs a Bot or Agent profile. The card takes the profile's OWN colour — blue for a Bot, green for an Agent — so this swatch shows the Bot case. What it does is the profile's system instructions; what it acts on is its input — the message that started the run for entry nodes, upstream output below them. Supports per-node retries and its own Per-Node Timeout. An agent's tool confirmations pause the run just like a Gate.")
            nodeDoc("Sub-workflow", color: ProfileType.workflow.displayColor, icon: "point.3.connected.trianglepath.dotted",
                    "A Profile node bound to another Workflow profile — it runs that workflow's canvas as a child. Text-only handoff: the child gets this node's input as its message; variables and artifacts do not cross in (artifacts produced inside do flow out). Nesting is limited to 3 levels and cycles are blocked at design time. ⚠️ This node's Per-Node Timeout bounds the child's ENTIRE run — size it for the whole child, not one step.")
            nodeDoc("Router", color: theme.nodeIdentityColor(for: .router), icon: "arrow.triangle.branch",
                    "Matches the input against labelled rules, top to bottom; each rule's label is an output port. Exactly one match routes there. Anything else — SEVERAL rules matching, or NONE — is decided by one setting, 'When Routing Can't Decide': ask you to pick, route to a rule of your choosing, end the workflow here, or fail onto the error port. Unattended runs (scheduled or chat-bridge) never pause; an Ask uses its 'If nobody can answer' fallback instead. An optional AI Classifier (local MLX model) can name a branch when no pattern rule matched, and its answer follows the same rules — one label routes, none or several fall to the setting. ⚠️ A classifier that could not RUN fails the node regardless of that setting.")
            nodeDoc("Gate", color: theme.nodeIdentityColor(for: .gate), icon: "hand.raised",
                    // [CVV-7, cold-read] "without one the gate waits indefinitely" is true only on
                    // an ATTENDED run. Unattended with no timeout, the executor refuses up front
                    // and fails the node onto its error port rather than parking to an empty room.
                    "Pauses the run and asks you to choose. Each option is its own output port — the chosen option's branch runs. An optional timeout fails the node (onto its error port) if nobody answers; without one the gate waits indefinitely on an attended run. Parallel branches keep running while it waits, and the wait never counts against any timeout. ⚠️ A scheduled run can never answer a gate, so it ends on the error port either way — wire that port. A timeout does not rescue it; it only delays the same failure, and one longer than the run's overall budget cancels the whole run. See 'Attended vs unattended' below.")
            nodeDoc("Code", color: theme.nodeIdentityColor(for: .code), icon: "chevron.left.forwardslash.chevron.right",
                    "A deterministic text transform — no AI involved. Write a template using {{ input }}, {{ input.json.path }} for a field of JSON output, and {{ var.name }}; optionally store the result in a variable for later nodes. ⚠️ A placeholder that can't be resolved (e.g. a misspelled variable) is left in the output verbatim — check spelling; the validator does not lint Code templates. Never retries; failure routes to the error port.")
            nodeDoc("Action", color: theme.nodeIdentityColor(for: .action), icon: "bolt.horizontal.fill",
                    "Calls one tool directly — no AI, deterministic. Bind each argument to a literal or a placeholder. Supports Retries (a tool call that threw is retried; a tool that RETURNED an error is not, because its side effect may already have happened) and a per-attempt timeout. Tools marked as requiring confirmation pause the run for your approval.")
            // [CVV-7] ⚠️ The last clause was an instruction to do something the app does not offer:
            // no palette entry constructs a `.trigger` node, and `kind: .trigger` appears in zero
            // production files. The kind renders and executes correctly, so canvases built earlier
            // still work — the doc now says that instead of inviting the user to add one.
            nodeDoc("Trigger", color: theme.nodeIdentityColor(for: .trigger), icon: "bolt",
                    "An entry-point marker. It has no configuration and no error port, and passes its input straight through — as the first node it hands the run's message to whatever follows, so it makes a starting point explicit without changing what the next node receives. Canvases built in earlier versions may contain one; there is no palette entry for adding a new one.")
            nodeDoc("Sticky note", color: StickyNoteColor.yellow.swiftUIColor, icon: "note.text",
                    "Annotation only — invisible to execution. Document your graph for whoever opens it next.")
        }
    }

    private var unattendedSection: some View {
        section("Attended vs unattended runs", icon: "person.fill.questionmark", expanded: true) {
            para("A run is attended when you start it from the app; it is unattended when the scheduler or a chat bridge (Telegram / Discord / Slack) starts it. Anything that waits for a human behaves differently:")
            // ⚠️ [CVV-7, cold-read] Both rows described RETIRED engine behaviour and contradicted the
            // Router and Gate nodeDocs above. Verified line by line against the executor before
            // rewriting, per this file's header rule.
            //
            // Router: "first matching rule wins automatically" is the LEGACY arm only — the
            // executor gates it on `config.decisionPolicy == nil` and its own comment says "LEGACY
            // PATH ONLY (2026-08-17)". Any Router saved from today's inspector carries a policy
            // (the inspector's default is `.ask(fallback: .failNode)`), and unattended an Ask falls
            // through to that fallback, which FAILS the node.
            tableRow("Router — can't decide", "Follows 'When Routing Can't Decide' — with the default (Ask) a banner asks you to pick", "Never pauses — applies that setting's 'If nobody can answer' action, which by default fails the node onto its error port. A Router saved before this setting existed instead takes the first matching rule when SEVERAL match, and follows its own no-match behaviour when NONE does")
            // Gate: an unanswered scheduled gate no longer waits for the run deadline. When no gate
            // timeout is set and nobody can be reached, the executor refuses immediately and fails
            // the node onto its error port — deliberately, so a recovery branch can handle it.
            // A CONFIGURED timeout is left alone, and a chat bridge counts as reachable.
            // ⚠️ A gate timeout does NOT auto-decide — the executor's timeout arm sets
            // `output = "Gate not answered (timed out)"` and `status = .failed(...)` with
            // `activePorts` unset, so NO option branch is taken. Unattended, a gate therefore
            // always ends on its error port; the timeout only changes WHEN. Saying "which
            // auto-decides" would repeat the very defect register row INS-3 is filed against.
            tableRow("Gate", "Banner appears; waits for your choice", "Scheduled: no banner is shown, and the node ends up on its ERROR port either way — immediately if no gate timeout is set (nobody could answer), or when the timeout elapses if one is. No option branch is ever taken, so wire the error port. Chat bridge: answerable remotely via buttons, but there is no automatic deadline")
            tableRow("Tool confirmation", "Banner appears; waits", "Same as Gate — nothing on screen for scheduled runs")
            para("Scheduled runs have a fixed overall time budget, counted from the moment the run starts — a long-running workflow eats into it before any pause begins. Chat-bridge runs have no overall deadline.")
        }
    }

    private var timeoutsSection: some View {
        section("Timeouts and retries", icon: "clock.arrow.circlepath") {
            bullet("Each node gets a compute budget (default 120 seconds) — EXCEPT a Sub-workflow node, which has none by default (see below). Time spent waiting for a human — a gate, a confirmation, a routing question — never counts against it.")
            // [CVV-7] The control is labelled "Per-Node Timeout" on a Profile node and "Timeout" on
            // an Action node. "Hard Timeout" is the MODEL property name and appears on no screen.
            bullet("Profile and Action nodes can raise or lower that budget from their inspector — ‘Per-Node Timeout’ on a Profile node, ‘Timeout’ on an Action node. On expiry the node fails onto its error port and any partial result is discarded.")
            bullet("Only Profile and Action nodes retry; Router, Code and Gate never do. ⚠️ Retrying a Profile node re-runs its whole agent turn — including tool side effects it already performed.")
            bullet("A Sub-workflow node has NO outer budget by default — its child canvas is already bounded, node by node, on its own terms. Setting its Per-Node Timeout adds a ceiling over the child's ENTIRE run (not one step); with retries configured, every attempt shares that ONE ceiling rather than each getting its own.")
        }
    }

    private var dataSection: some View {
        section("Data, variables and files", icon: "shippingbox") {
            bullet("{{ input }} is the upstream text; if an upstream produced JSON, {{ input.json.path }} reads a field from it.")
            bullet("{{ input.parsed.path }} parses this node's OWN input as JSON — use it when the JSON arrived as text, including at an entry node reading what you typed in chat. {{ input.json }} needs a node upstream that actually produced JSON; {{ input.parsed }} needs only text that looks like it.")
            bullet("Variables are written ONLY by Code nodes (their Output Variable). Routers can test them; Code and Action nodes can substitute them.")
            bullet("Files and images produced by nodes flow downstream as attachments: later nodes see a manifest naming each file, and agents with file tools can read them.")
            bullet("Knowledge-base and attachment text from your message ride into the entry nodes as part of the input.")
        }
    }

    private var savingSection: some View {
        section("Saving and running", icon: "square.and.arrow.down") {
            // [CVV-7] "Save"/"Revert" named no control — the pills are "Save Changes" and "Discard
            // Changes", renamed precisely because "Revert" read as a sibling of Undo. And Discard
            // is itself undoable now (`revert()` re-arms the stack with the pre-revert graph).
            bullet("⚠️ There is no autosave. Save Changes writes the canvas; Discard Changes throws away everything since the last save — and is itself one Undo away. Unsaved edits survive switching screens and are offered for saving when you quit.")
            // [CVV-7] There is no button called "Run" — a run starts from the composer's send
            // button. The semantic claim was right; only the control name was invented.
            bullet("⚠️ A run executes the last SAVED graph, not your unsaved edits — save before you start one. If you start one anyway, the run says so in its own timeline, so a result that doesn't match your canvas is never a mystery.")
            // [CVV-7] Both halves of the old sentence were false. Moves ARE undoable (`moveNode`
            // and `moveStickyNote` each push one snapshot per completed drag, pinned by four tests),
            // and undo covers far more than "structural" edits — every inspector change goes
            // through `replaceNode`, which pushes too. The coalescing rule is the half users most
            // need and cannot infer.
            // ⚠️ SCOPED to what the undo stack actually holds (cold-read finding). `undo()` restores
            // `nodes`, `edges` and `annotations` and nothing else. A node's PROFILE fields — model,
            // instructions, tools, knowledge — are written straight to the profile row by
            // `profileService.saveProfile`, so they are on disk before Done returns and Undo cannot
            // touch them. "Editing anything in an inspector" over-claimed in the direction that
            // costs data: a user who overtyped their system prompt would press ⌘Z, get a layout
            // snapshot back, and find the prompt gone for good.
            bullet("Undo (⌘Z, or the Undo button) steps back through the last 25 canvas edits — adding, deleting, rewiring, moving a node or a note, a node's own name and workflow settings, and even Clear Canvas or Discard Changes.")
            bullet("⚠️ Undo does NOT cover a node's PROFILE — its model, instructions, tools or knowledge. Those are saved to the profile itself, and not only when you press Done: deleting the node, opening another node's inspector, or starting a run — which switches away from the canvas — all save them too. Cancel is the one way to throw them away. The canvas cannot take them back.")
            bullet("A run of typing in one inspector field counts as a single step, so that is 25 edits, not 25 keystrokes. Pause for a few seconds, switch to another node, or make any structural change, and the next edit starts its own step.")
            bullet("The validation panel lists everything that would block a run — a graph with errors refuses to start before spending any tokens.")
        }
    }

    // MARK: - Building blocks

    private func section(_ title: LocalizedStringKey, icon: String, expanded: Bool = false,
                         @ViewBuilder content: @escaping () -> some View) -> some View {
        GuidelineSection(title: title, icon: icon, initiallyExpanded: expanded, theme: theme, content: content)
    }

    private func para(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
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
    /// ⚠️ `String`, NOT `LocalizedStringKey`, and deliberately so: this is monospaced ASCII art whose
    /// alignment IS its meaning. Translating it would reflow the box drawing into nonsense, and the
    /// extractor would offer a translator a diagram they cannot safely touch. Every OTHER copy
    /// helper in this file takes a `LocalizedStringKey` (register CVV-8) — this is the one
    /// exception, recorded here so it does not read as an oversight.
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

    private func nodeDoc(_ name: LocalizedStringKey, color: Color, icon: String, _ text: LocalizedStringKey) -> some View {
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
    private func tableRow(_ situation: LocalizedStringKey, _ attended: LocalizedStringKey, _ unattended: LocalizedStringKey) -> some View {
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

    private func labeledCell(_ label: LocalizedStringKey, _ text: LocalizedStringKey, color: Color) -> some View {
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
    let title: LocalizedStringKey
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
