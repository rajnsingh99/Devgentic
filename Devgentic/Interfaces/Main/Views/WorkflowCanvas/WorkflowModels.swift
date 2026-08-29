//
//  WorkflowModels.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  Data models for the visual workflow canvas: nodes, edges, ports, and DAG definition.
//

import Foundation
import SwiftUI

// MARK: - Port Type

enum PortType: String, Codable, Hashable {
    case input
    case output
}

// MARK: - Workflow Node Kind

/// Discriminated union identifying what a workflow node represents.
/// Profile-backed nodes reference a BackendProfileModel; structural nodes carry their own config.
enum WorkflowNodeKind: Codable, Hashable, Sendable {
    /// A Bot, Agent, Workflow, or ImageGen profile node.
    case profile(profileID: UUID, profileType: ProfileType)

    /// The **Router** node — matches the upstream text against labelled rules and routes to the
    /// matching output port. Renamed from "Condition" in the UI on 2026-08-13: with N labelled rules
    /// and one port each it is a switch/router, not a boolean condition.
    ///
    /// ⚠️ THE SWIFT CASE NAME IS DELIBERATELY STILL `condition`, and must stay that way.
    /// `WorkflowNodeKind` uses Swift's SYNTHESIZED enum `Codable`, which writes the case name as the
    /// discriminator into every persisted layout blob. Renaming the case would turn every saved
    /// Router into an `.unsupported` placeholder (per-element resilience, WF-PE4) — no longer a
    /// lost layout, but still every workflow ever saved degrading to unrunnable in one rename.
    ///
    /// ⚠️ `ConditionRule` / `ConditionOp` / `ConditionField` also keep their names, and that is
    /// correct rather than merely safe: the NODE is a Router; the RULES are conditions. It routes
    /// by conditions.
    case condition(ConditionNodeConfig)

    // ⚠️ `case loop(LoopNodeConfig)` was RETIRED AND DELETED 2026-08-15 (user decision). The node
    // conflated retry (already served by per-node `maxNodeRetries`) with chained re-execution, and
    // its one legitimate pattern (evaluator–optimizer refinement) was judged not worth the node.
    // DELIBERATELY no decode shim — a Loop node never becomes a runnable something-else. Since
    // 2026-08-24 (WF-PE4) an old blob's `{"loop":{...}}` decodes as `.unsupported(raw:)`: the graph
    // opens with a visible placeholder instead of the all-or-nothing unreadable-layout refusal the
    // 2026-08-15 decision accepted, the RUN stays blocked, and the raw bytes survive re-save.
    // Do NOT reuse the name `loop` for a future case: an old blob's `{"loop":{...}}` would decode
    // into it instead of the placeholder.

    /// Code/transform — deterministic non-LLM processing (regex, JSON, format).
    case code(CodeNodeConfig)

    /// HITL gate — suspends execution and waits for user approval.
    case gate(GateNodeConfig)

    /// Trigger — starts workflow execution (webhook, schedule, manual).
    case trigger(TriggerNodeConfig)

    /// Action/integration — invokes a tool directly and deterministically (no LLM).
    case action(ActionNodeConfig)

    /// A node this build cannot understand — preserved, never lost. [WF-PE4]
    ///
    /// Produced ONLY by `WorkflowNode.init(from:)` when the stored `kind` fails to decode (a case
    /// name written by a different build: a rollback after a node-kind addition, or a deleted kind
    /// like the retired Loop). `raw` is the kind's ORIGINAL JSON, and `WorkflowNode.encode(to:)`
    /// writes it back verbatim — so re-saving the layout is lossless and the build that understands
    /// the node reads it again untouched.
    ///
    /// Before this case existed, ONE unknown case name failed the whole `[WorkflowNode]` array
    /// decode, which made the layout simultaneously unreadable (empty canvas + overlay), unrunnable
    /// (executor refusal) and permanently unsaveable (the `WorkflowLayoutSD` setter refuses every
    /// write while unreadable) — with the destructive `repairUnreadableLayout` as the only exit.
    /// Now the graph opens with a visibly degraded placeholder card; everything else stays editable
    /// and saveable, and only the RUN is refused (`WorkflowError.unsupportedNodes`, plus a blocking
    /// validation issue) because an unknown node cannot be executed or honestly skipped.
    ///
    /// ⚠️ The case name `unsupported` is effectively reserved the same way `loop` is: a blob must
    /// never legitimately contain `{"unsupported":{...}}`, because `WorkflowNode.encode` unwraps
    /// this case to the RAW original — the wrapper itself is never persisted.
    case unsupported(raw: JSONValue)

    /// The persisted discriminator (case name) of every REAL, persistable case — i.e. every case
    /// above except `.unsupported` itself, which is never written to a blob (its `encode(to:)`
    /// unwraps to `raw` instead). [WF-PE4, corrected on audit] Used only to distinguish "this
    /// build has never heard of this case name" (true version skew — preserve as a placeholder)
    /// from "this build knows the case but its payload failed to decode" (real corruption of a
    /// fully-understood node — must NOT be silently reclassified as version skew; see
    /// `WorkflowNode.init(from:)`).
    ///
    /// ⚠️ MUST be updated whenever a case is added, renamed, or removed here — a name missing
    /// from this set would misclassify a genuinely corrupted node of that kind as version skew.
    fileprivate static let knownKindCaseNames: Set<String> = [
        "profile", "condition", "code", "gate", "trigger", "action",
    ]
}

// MARK: - Node Identity Colour (WF-CU10)

/// The structural node kinds that carry an identity colour on the canvas.
///
/// ⚠️ Profile-backed nodes are NOT here. Their colour comes from `ProfileType.displayColor`, which
/// is already a single shared source with several non-canvas consumers (chat input, QuickAccess,
/// profile detail, pickers). Folding it in here would drag those surfaces into a canvas change.
enum WorkflowNodeRole: String, CaseIterable, Sendable {
    case router      // `.condition` — the Swift case name is frozen for Codable reasons
    case code
    case gate
    case trigger
    case action
}

extension WorkflowNodeKind {
    /// The card / port / edge / palette / legend colour for this node kind.
    ///
    /// ⚠️ SINGLE SOURCE. This mapping was open-coded in several places — `WorkflowNodeView`'s
    /// `profileColor`, `WorkflowCanvasState.nodeColor(for:)` (which fed the EDGE gradient, so the
    /// two had to agree for an edge to match the node it leaves), the Add-node palette and the
    /// in-app legend. `ProfileType+Display.swift`'s own header records the last time this exact
    /// class of duplication drifted.
    func identityColor(in theme: any Theme) -> Color {
        switch self {
        case .profile(_, let pType): return pType.displayColor
        case .condition: return theme.nodeIdentityColor(for: .router)
        case .code:      return theme.nodeIdentityColor(for: .code)
        case .gate:      return theme.nodeIdentityColor(for: .gate)
        case .trigger:   return theme.nodeIdentityColor(for: .trigger)
        case .action:    return theme.nodeIdentityColor(for: .action)
        // [WF-PE4] Deliberately colourless — the placeholder must read as "not one of ours".
        case .unsupported: return theme.secondaryText
        }
    }
}

// MARK: - Node Kind Configs

/// What a Router does when NO rule matches the input (2026-08-16, user decision).
///
/// Replaces the `always` catch-all-rule idiom, which was HARD-DELETED the same day: an `always`
/// rule matched everything, so any input matching a real rule matched TWO rules and ambiguity
/// arbitration fired on every ordinary routing decision (the "amplifier" defect). This setting is
/// ORTHOGONAL to `askOnAmbiguity` — that answers "several rules matched", this answers "none did".
///
/// ⚠️ `.route` stores the target rule's stable `id`, NEVER its label. A stored label is the
/// stale-`fallbackLabel` maintenance class that got the old Static Fallback picker retired (WF64):
/// renames silently strand it and deletions silently re-point it. An id survives renames, and a
/// deleted target becomes a design-time validation ERROR instead of a silent misroute.
enum RouterNoMatchBehavior: Codable, Hashable, Sendable {
    /// Fail the node — `error` port activates, wireable recovery. Today's behaviour; the pre-filled
    /// default, so existing Routers change nothing.
    case failNode
    /// Route unmatched input to this rule's port, as if that rule had matched.
    case route(ruleID: UUID)
    /// End this BRANCH gracefully: the Router completes with NO active ports, everything downstream
    /// skips as "not chosen", and — because terminality is computed over LIVE edges — the Router
    /// becomes a terminal whose passthrough content lands in the run's final output.
    /// ⚠️ Ends the BRANCH, not the run: parallel siblings are untouched (invariant W28). In a
    /// linear workflow the two are the same thing.
    case endWorkflow
}

/// What a Router does when its evidence yields anything but exactly ONE winner — zero rules matched
/// (EMPTY) or several matched (AMBIGUOUS). One setting, both triggers (user decision 2026-08-17),
/// superseding the `askOnAmbiguity` + `noMatchBehavior` pair.
///
/// ⚠️ EVERY CASE IS TOTAL — it means the same thing for EMPTY and for AMBIGUOUS. That property is
/// load-bearing, not tidiness: it is what keeps the decision table free of per-situation footnotes.
/// An earlier draft carried a `firstMatch` case ("take the first matching rule"), which was the one
/// option that was NOT total — meaningful for ambiguity, undefined when nothing matched, requiring
/// a special rule so it could not reinvent the WF-OB1 arbitrary-branch defect. **Dropped by user
/// decision 2026-08-17. Do NOT reintroduce it**; an explicit default chosen from the dropdown is
/// what replaced it, and the implicit "rule order is priority" behaviour it encoded was itself the
/// kind of hidden coupling this redesign exists to remove (reordering rules on the canvas silently
/// changed unattended routing).
enum RouterDecisionPolicy: Codable, Hashable, Sendable {
    /// Route to this rule's port, as if it had matched. ⚠️ On AMBIGUOUS this OVERRIDES the matched
    /// rules — the branches that did match will not run.
    case route(ruleID: UUID)

    /// Pause and ask a human to pick. ⚠️ Attended runs only: an unattended run (scheduled, or
    /// started from a chat bridge) renders no banner anyone can see, so it never parks — it takes
    /// `fallback` immediately. The same `fallback` also covers an attended run nobody answers
    /// (Stop, conversation closed), which must stay identical to the unattended path.
    case ask(fallback: AskFallback)

    /// End this BRANCH gracefully — no active ports, downstream skips as "not chosen", and the
    /// Router's passthrough content becomes (part of) the final answer. Parallel siblings are
    /// untouched (invariant W28).
    case endBranch

    /// Fail the node so its `error` port activates and a wired branch can recover. The stored
    /// default of every pre-redesign Router, and the reason the error port is reachable at all —
    /// the guide promises "a failure (and only a failure) activates the error port".
    case failNode

    /// What an `ask` does when nobody can answer. Mirrors the outer policy minus `ask` itself.
    enum AskFallback: Codable, Hashable, Sendable {
        /// Fail the node — the default. Strict and honest: the run stops with the reason on the
        /// error port rather than guessing a branch nobody chose.
        case failNode
        case route(ruleID: UUID)
        case endBranch
    }
}

struct ConditionNodeConfig: Codable, Hashable, Sendable {

    // MARK: - Constraints

    static let minRules = 2
    static let maxRules = 5

    /// Validates a label: single word, alphanumeric only, max 10 characters.
    static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 10 else { return false }
        return label.range(of: "^[a-zA-Z0-9]+$", options: .regularExpression) != nil
    }

    // --- Output Behavior ---

    /// ⚠️ RETIRED 2026-08-13 — decode/encode-only, never read at runtime. A Router always passes the
    /// upstream content through.
    ///
    /// This was the "Pass Through Content" toggle. Switched OFF it emitted the literal string
    /// `Condition (pattern): route → <Label>` in place of the payload — a debug line, not data, and
    /// nothing downstream could consume it except a rule matching that exact text. It was also
    /// LEAKY: artifacts were forwarded from every live upstream regardless of the toggle, so it
    /// suppressed text only. The one real motivation (not spending context on a payload the
    /// downstream does not need) is what the per-node context budget already handles.
    ///
    /// ⚠️ Deliberately NOT deleted, same reasoning as `onFailure` and `joinMode`: the layout blob
    /// has no per-element resilience (WF24), so dropping a Codable key is not free. A stored `false`
    /// is logged once per run and ignored — never rewritten, so a downgrade still reads the file.
    var passthroughContent: Bool = true

    // --- Pattern Match (always evaluated first) ---

    /// Condition rules — evaluated top-to-bottom, first match activates that output port.
    /// Minimum 2, maximum 5. Labels define all output ports.
    var rules: [ConditionRule] = [
        ConditionRule(label: "True", field: .upstreamOutput, op: .isNotEmpty, value: ""),
        ConditionRule(label: "False", field: .upstreamOutput, op: .isEmpty, value: "")
    ]

    // --- AI Classifier (fires only when no pattern rule matches) ---

    /// When true, delegates to a local MLX model (AI Classifier) if no pattern rule matches.
    /// The classifier chooses from the same labels defined by pattern rules.
    var llmFallbackEnabled: Bool = false
    /// Routing instruction for the AI Classifier (max 500 chars). e.g., "Is this positive or negative?"
    var llmPrompt: String = ""
    /// [Deprecated] Separate LLM labels — kept for backward decoding only. Runtime uses rules.map(\.label).
    var llmPortLabels: [String] = []
    /// MLX model display name used for classification.
    var llmModelName: String? = nil

    // --- Static Fallback ---

    /// ⚠️ RETIRED FROM THE UI 2026-08-13 — the "Static Fallback / Catch-All Route" picker is gone.
    /// A default branch is now an ordinary last rule with the `always` operator, which has a visible,
    /// wireable port like every other rule instead of invisibly aliasing one.
    ///
    /// ⚠️ STILL HONOURED AT RUNTIME when non-empty, and that is deliberate. Every workflow saved
    /// before today carries a `fallbackLabel`, and silently converting it on load would change where
    /// unmatched input goes in every one of them. There is no safe automatic migration: the
    /// equivalent rule must keep the SAME label (the label is the port, and edges are already wired
    /// to it), which would duplicate an existing rule label; and moving the pointed-at rule to the
    /// end to make it `always` would reorder precedence for inputs matching several rules.
    ///
    /// So: legacy configs keep their exact behaviour and log that they are doing so. NEW nodes
    /// default to `""` and fail on no-match, which is the point of the redesign.
    var fallbackLabel: String = ""

    /// Ask a human which branch to take when MORE THAN ONE rule matches the same input.
    ///
    /// ⚠️ ON by default (user decision 2026-08-13). An overlapping-rule input is a decision the
    /// author never actually made — rule order is an authoring artefact — so the default is to ask
    /// rather than to guess silently.
    ///
    /// ⚠️ The DECODER also defaults to `true`, so layouts written before this field existed turn it
    /// on. An absent key means "saved before the feature existed", not "the user switched it off";
    /// once the user actually toggles it off, `false` is written explicitly and honoured.
    ///
    /// ⚠️ CONSEQUENCE for unattended runs, stated plainly because it is not obvious: the arbitration
    /// now waits INDEFINITELY (no per-node timeout), and a scheduled run renders no banner at all —
    /// `InteractionBannerStack` shows only the selected conversation and `SchedulerCoordinator`
    /// deliberately creates its conversation without selecting it, with no remote mirror registered.
    /// Such a run parks invisibly until the container's 600s deadline fires, which cancels the WHOLE
    /// run rather than just this node. Switch this off on nodes used in scheduled workflows.
    ///
    /// ⚠️ This is NOT the same class of control as the retired `onFailure` and `joinMode` pickers.
    /// Those asked the AUTHOR, at edit time, for something the graph already determined. This asks
    /// the OPERATOR, at run time, about a data-dependent ambiguity the graph cannot answer: rule
    /// order is an arbitrary authoring artefact being used as a tiebreak, and nothing in the graph
    /// encodes which of two genuinely-matching rules the user meant.
    ///
    /// ⚠️ When nobody answers (Stop, conversation closed, or the arbitration timeout) the node falls
    /// back to the FIRST match — today's deterministic winner — never to `fallbackLabel`. That keeps
    /// the unattended path byte-identical to the setting being off.
    var askOnAmbiguity: Bool = true

    /// What to do when NO rule matches. See `RouterNoMatchBehavior`; `.failNode` preserves the
    /// pre-2026-08-16 behaviour, so absent keys and untouched Routers behave identically.
    ///
    /// ⚠️ SUPERSEDED by `decisionPolicy` (2026-08-17). Still declared, still decoded, and still the
    /// governing setting for any node whose `decisionPolicy` is nil — same retirement pattern as
    /// `passthroughContent` and `fallbackLabel`. A node saved from the redesigned inspector carries
    /// a policy, and then THIS FIELD IS IGNORED at runtime.
    var noMatchBehavior: RouterNoMatchBehavior = .failNode

    /// What this Router does when its evidence yields anything but exactly ONE winner.
    ///
    /// ⚠️ ONE setting, TWO triggers (user decision 2026-08-17): zero rules matched (EMPTY) and
    /// several matched (AMBIGUOUS). They are mutually exclusive by construction, so a single
    /// setting is coherent rather than a false merge — and it replaces two adjacent controls of
    /// inconsistent shape (`askOnAmbiguity`, a Bool, and `noMatchBehavior`, an enum).
    ///
    /// ⚠️ The AI Classifier INHERITS it: exactly one recognised token routes, zero is EMPTY, two or
    /// more is AMBIGUOUS. That is what retires WF-OB2 — a multi-token reply used to resolve by
    /// unordered `Dictionary` iteration, so the same input could take a different branch after an
    /// app restart.
    ///
    /// ⚠️ TWO OUTCOMES STAY OUTSIDE THIS SETTING, deliberately. A classifier that CRASHED produced
    /// no verdict, so it fails the node regardless of the policy (WF-CC10); a Stop settles the node
    /// `.canceled` and routes nowhere (WF-CC13). `noMatchBehavior` answers "no rule described this
    /// input" — a statement about CONTENT — and neither of those is content.
    ///
    /// ⚠️ `nil` means "saved before the redesign": the legacy
    /// `askOnAmbiguity` / `noMatchBehavior` / `fallbackLabel` trio governs, byte-identically. No
    /// stored workflow changes behaviour until its author opens the node and saves it. Same refusal
    /// to auto-migrate that `fallbackLabel` itself documents above — and here the merge is provably
    /// lossy (a 2×3 legacy matrix onto one axis), so a decode-time collapse would silently change
    /// untouched workflows.
    var decisionPolicy: RouterDecisionPolicy?

    /// Default initializer — all properties use their declared defaults.
    init() {}

    // MARK: Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case rules, llmFallbackEnabled, llmPrompt, llmPortLabels, llmModelName
        case fallbackLabel, passthroughContent, askOnAmbiguity, noMatchBehavior
        case decisionPolicy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Decode rules with min-2 enforcement for legacy configs
        var decodedRules = try c.decodeIfPresent([ConditionRule].self, forKey: .rules)
            ?? [ConditionRule(label: "True", field: .upstreamOutput, op: .isNotEmpty, value: ""),
                ConditionRule(label: "False", field: .upstreamOutput, op: .isEmpty, value: "")]
        if decodedRules.count < Self.minRules {
            if decodedRules.isEmpty {
                decodedRules.append(ConditionRule(label: "True", field: .upstreamOutput, op: .isNotEmpty, value: ""))
            }
            if decodedRules.count < Self.minRules {
                decodedRules.append(ConditionRule(label: "False", field: .upstreamOutput, op: .isEmpty, value: ""))
            }
        }
        rules = decodedRules

        llmFallbackEnabled = try c.decodeIfPresent(Bool.self, forKey: .llmFallbackEnabled) ?? false
        llmPrompt = try c.decodeIfPresent(String.self, forKey: .llmPrompt) ?? ""
        // Still decode for backward compat — ignored at runtime (AI Classifier uses rules.map(\.label))
        llmPortLabels = try c.decodeIfPresent([String].self, forKey: .llmPortLabels) ?? []
        llmModelName = try c.decodeIfPresent(String.self, forKey: .llmModelName)
        fallbackLabel = try c.decodeIfPresent(String.self, forKey: .fallbackLabel) ?? "False"
        passthroughContent = try c.decodeIfPresent(Bool.self, forKey: .passthroughContent) ?? true
        askOnAmbiguity = try c.decodeIfPresent(Bool.self, forKey: .askOnAmbiguity) ?? true
        // `try?` deliberately: a shape from a NEWER build must degrade to the safe default, not
        // take the whole layout unreadable (WF24 — the blob has no per-element resilience).
        noMatchBehavior = (try? c.decodeIfPresent(RouterNoMatchBehavior.self, forKey: .noMatchBehavior)) ?? .failNode

        // ⚠️ `try?` for the same WF24 reason as the line above, and `nil` is a MEANINGFUL result
        // here, not a failure: it says "saved before the redesign", and the legacy trio then
        // governs byte-identically. Decode must NEVER invent a policy — the legacy 2×3 matrix does
        // not collapse onto this axis losslessly (see the migration table in
        // `Router_Unified_Decision_Design.md` §3), so synthesising one at decode time would
        // silently change stored workflows the user never opened. Seeding happens in the inspector,
        // on an explicit Save, exactly as `fallbackLabel`'s retirement note above demands.
        decisionPolicy = (try? c.decodeIfPresent(RouterDecisionPolicy.self, forKey: .decisionPolicy)) ?? nil

        // Repair a legacy fallback that points at a rule which no longer exists. ⚠️ Guarded on
        // NON-EMPTY: an empty `fallbackLabel` means "this node has no catch-all", which is the new
        // default — without the guard the repair would invent one for every new node and quietly
        // reinstate the retired behaviour.
        if !fallbackLabel.isEmpty, !rules.contains(where: { $0.label == fallbackLabel }) {
            fallbackLabel = rules.last?.label ?? ""
        }
    }

    /// ⚠️ HAND-WRITTEN so a node carrying a `decisionPolicy` ALSO mirror-writes the legacy keys it
    /// supersedes. Without this, an older build reading a new blob would find `askOnAmbiguity` and
    /// `noMatchBehavior` absent, fall back to their raw decode defaults (`true` / `.failNode`), and
    /// route unmatched input somewhere the author never chose. Mirroring gives it the closest
    /// legacy approximation of the policy instead.
    ///
    /// ⚠️ It is an APPROXIMATION and cannot be otherwise — the legacy pair has no way to express
    /// "ask, and if nobody answers route to R", so the fallback is what survives for the no-match
    /// axis. That is the whole reason `layoutBlobVersion` bumps alongside this: an old build gets a
    /// sane read but is REFUSED the save, so it can never round-trip a policy back into a lossy
    /// pair (WF-TS5's protection, doing exactly what it exists for).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rules, forKey: .rules)
        try c.encode(llmFallbackEnabled, forKey: .llmFallbackEnabled)
        try c.encode(llmPrompt, forKey: .llmPrompt)
        try c.encode(llmPortLabels, forKey: .llmPortLabels)
        try c.encodeIfPresent(llmModelName, forKey: .llmModelName)
        try c.encode(fallbackLabel, forKey: .fallbackLabel)
        try c.encode(passthroughContent, forKey: .passthroughContent)
        try c.encodeIfPresent(decisionPolicy, forKey: .decisionPolicy)

        guard let policy = decisionPolicy else {
            // No policy: this node is still governed by the legacy pair, so write it verbatim.
            try c.encode(askOnAmbiguity, forKey: .askOnAmbiguity)
            try c.encode(noMatchBehavior, forKey: .noMatchBehavior)
            return
        }

        // Mirror. `ask` is the only case an old build can represent as "pause on ambiguity"; every
        // other case resolves without asking, so `askOnAmbiguity` is false for them.
        switch policy {
        case .ask(let fallback):
            try c.encode(true, forKey: .askOnAmbiguity)
            switch fallback {
            case .failNode:            try c.encode(RouterNoMatchBehavior.failNode, forKey: .noMatchBehavior)
            case .route(let ruleID):   try c.encode(RouterNoMatchBehavior.route(ruleID: ruleID), forKey: .noMatchBehavior)
            case .endBranch:           try c.encode(RouterNoMatchBehavior.endWorkflow, forKey: .noMatchBehavior)
            }
        case .route(let ruleID):
            try c.encode(false, forKey: .askOnAmbiguity)
            try c.encode(RouterNoMatchBehavior.route(ruleID: ruleID), forKey: .noMatchBehavior)
        case .endBranch:
            try c.encode(false, forKey: .askOnAmbiguity)
            try c.encode(RouterNoMatchBehavior.endWorkflow, forKey: .noMatchBehavior)
        case .failNode:
            try c.encode(false, forKey: .askOnAmbiguity)
            try c.encode(RouterNoMatchBehavior.failNode, forKey: .noMatchBehavior)
        }
    }

    // MARK: - AI Classifier prompt (2026-08-17)

    /// The placeholder that expands to this Router's rule labels at RUN TIME.
    ///
    /// ⚠️ A placeholder, not baked text, and that is the whole mechanism. Materialising the rule
    /// list into the stored prompt would force a choice between two bad options: rewrite the user's
    /// prompt whenever a rule is added or renamed (clobbering their edits), or leave it alone and
    /// let it go stale (the model told about categories that no longer exist). Expanding at run
    /// time means the prompt is always current AND never overwritten.
    static let rulesPlaceholder = "{{rules}}"

    /// The prompt a Router starts with when its AI Classifier is switched on. Fully editable — the
    /// user owns this text; only `{{rules}}` is substituted.
    static let defaultRoutingPrompt = """
        You are an intelligent router. Read the input and decide which ONE of these categories best         describes it:
        \(rulesPlaceholder)
        Answer with exactly one category.
        """

    /// The instruction actually sent to the model: the stored prompt with `{{rules}}` expanded.
    ///
    /// ⚠️ Labels only — never the opaque 4-char tokens. Those are assigned per invocation and live
    /// in the system-owned `<labels>` block; letting a user-editable field name them would break the
    /// parse protocol, and letting the model answer in readable rule names would let unescaped
    /// upstream text name a route into being (the open WF-SE2 interpolation).
    func resolvedRoutingPrompt() -> String {
        guard llmPrompt.contains(Self.rulesPlaceholder) else { return llmPrompt }
        var seen = Set<String>()
        let list = rules
            .map(\.label)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { "- \($0)" }
            .joined(separator: "\n")
        return llmPrompt.replacingOccurrences(of: Self.rulesPlaceholder, with: list)
    }

    /// All output port labels — derived solely from pattern rule labels.
    /// The AI Classifier and static fallback route to these same ports.
    var outputPortLabels: [String] {
        var labels = rules.map(\.label)
        // A legacy `fallbackLabel` that names no rule still needs its port, or the edges already
        // wired to it would dangle. Empty = no catch-all (the post-2026-08-13 default).
        if !fallbackLabel.isEmpty, !labels.contains(fallbackLabel) {
            labels.append(fallbackLabel)
        }
        return labels
    }
}

/// A single condition rule: evaluates a field with an operator against a value.
struct ConditionRule: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var label: String
    var field: ConditionField
    var op: ConditionOp
    var value: String

    /// When `field == .variable`, the name of the workflow variable to read.
    /// The variable's value is then compared against `value` using `op`.
    var variableName: String?

    init(id: UUID = UUID(), label: String, field: ConditionField, op: ConditionOp, value: String, variableName: String? = nil) {
        self.id = id
        self.label = label
        self.field = field
        self.op = op
        self.value = value
        self.variableName = variableName
    }
}

/// What a condition rule evaluates against.
/// ⚠️ RAW-PRESERVING catch-all (WF-PE3), the pattern `WorkflowRunRecord.RunStatus` established.
///
/// These layout enums used to be plain `String, Codable`: ONE unknown rawValue — written by a newer
/// build, read after a rollback — threw at decode, which failed the node, which failed the array,
/// which failed the WHOLE layout. A 15-node graph became unreadable and unsaveable over a single
/// string, and the only in-app escape was the total-loss Discard. `.other(raw)` decodes ANY value
/// and re-encodes it VERBATIM — lossless by construction, so a round-trip through an older build
/// preserves the newer build's data byte-for-byte. Consumers treat `.other` as inert-and-visible:
/// the validator flags it, the engine never matches on it, and no picker offers it
/// (`allCases` excludes it by hand — the synthesized one would).
enum ConditionField: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    case upstreamOutput     // Concatenated text output of upstream nodes
    case variable           // A shared workflow variable by name
    /// A field written by a newer build — preserved verbatim, never evaluated.
    case other(String)

    static var allCases: [ConditionField] { [.upstreamOutput, .variable] }

    init?(rawValue: String) {
        switch rawValue {
        case "upstreamOutput": self = .upstreamOutput
        case "variable":       self = .variable
        default:               self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .upstreamOutput:  return "upstreamOutput"
        case .variable:        return "variable"
        case .other(let raw):  return raw
        }
    }
}

/// How a condition rule evaluates its field.
enum ConditionOp: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    case contains
    case notContains
    case equals
    case notEquals
    case isEmpty
    case isNotEmpty

    // ⚠️ `case always` was HARD-DELETED 2026-08-16 (user decision). It was the recommended
    // catch-all idiom after the Static Fallback picker retired (2026-08-13), but it AMPLIFIED
    // ambiguity arbitration: an `always` rule matches everything, so any input matching a real
    // rule matched TWO rules and the Router asked "which branch?" on every ordinary input. The
    // catch-all's job moved to `ConditionNodeConfig.noMatchBehavior`. A stored `"always"` now
    // decodes to `.other("always")` below — which NEVER MATCHES — so old catch-all rules become
    // dead rules (flagged by the validator), and unmatched input follows `noMatchBehavior`.

    /// An operator this build cannot evaluate — a newer build's operator (WF-PE3), or the retired
    /// `always`. Preserved verbatim, never matches.
    case other(String)

    static var allCases: [ConditionOp] { [.contains, .notContains, .equals, .notEquals, .isEmpty, .isNotEmpty] }

    init?(rawValue: String) {
        switch rawValue {
        case "contains":    self = .contains
        case "notContains": self = .notContains
        case "equals":      self = .equals
        case "notEquals":   self = .notEquals
        case "isEmpty":     self = .isEmpty
        case "isNotEmpty":  self = .isNotEmpty
        default:            self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .contains:     return "contains"
        case .notContains:  return "notContains"
        case .equals:       return "equals"
        case .notEquals:    return "notEquals"
        case .isEmpty:      return "isEmpty"
        case .isNotEmpty:   return "isNotEmpty"
        case .other(let raw): return raw
        }
    }

    var displayName: String {
        switch self {
        case .contains: return "contains"
        case .notContains: return "does not contain"
        case .equals: return "equals"
        case .notEquals: return "does not equal"
        case .isEmpty: return "is empty"
        case .isNotEmpty: return "is not empty"
        // The raw value IS the most useful display for an op this build cannot evaluate.
        case .other(let raw): return "\(raw) (newer version)"
        }
    }
}
/// Code/transform node — deterministic non-LLM processing via Mustache-like templates.
/// Supports `{{ input }}` (upstream text) and `{{ var.name }}` (workflow variables).
struct CodeNodeConfig: Codable, Hashable, Sendable {
    /// Template string with placeholders: `{{ input }}`, `{{ var.name }}`.
    var template: String = "{{ input }}"
    /// If set, writes the transform result to this shared workflow variable name.
    var outputVariable: String? = nil
}

/// HITL gate node — suspends workflow execution and waits for user approval.
struct GateNodeConfig: Codable, Hashable, Sendable {
    /// Prompt displayed to the user when the gate suspends.
    var prompt: String = "Approve this workflow step?"
    /// Choice options, each rendered as a button and exposed as a same-named output port — the user's
    /// choice routes the workflow to that port (E1 per-option branching).
    var options: [String] = ["Approve", "Reject"]
    /// Seconds before the gate auto-rejects (fails, no branch taken). Nil = no per-gate timeout: the gate
    /// waits indefinitely and the execution container owns the deadline — Stop, the scheduled-run
    /// deadline, or stopWorkflow (HITL D3). The banner shows a live countdown only when this is set.
    var timeout: TimeInterval? = nil
}

struct TriggerNodeConfig: Codable, Hashable, Sendable { }

/// Deterministic action/integration node — invokes a tool directly, with NO LLM.
///
/// At run time the node resolves `tool` to an executable tool, builds the tool's
/// JSON arguments by resolving each `argumentBindings` template against the
/// upstream data (`{{ input }}`, `{{ input.json.x }}`, `{{ var.y }}`), invokes it,
/// and emits the tool's output + artifacts. This is the "do things" node:
/// HTTP calls, file writes, notifications, MCP tool invocations — instant,
/// free (no tokens), and deterministic, versus puppeteering an agent to do it.
struct ActionNodeConfig: Codable, Hashable, Sendable {
    /// The selected tool reference (native or MCP), or nil when unconfigured.
    /// Reuses the same `Tool` type profiles persist — carries the tool `name`,
    /// `sourceId` (native vs MCP routing), and a snapshot of its `parameters`
    /// schema (so the inspector can render one binding field per argument).
    var tool: Tool? = nil

    /// Maps each tool-argument name → a template string resolved at run time.
    /// e.g. `["url": "https://hooks.example.com", "body": "{{ input }}"]`.
    /// Only bound arguments are sent; unbound optional args are omitted (and an
    /// unbound *required* arg surfaces as a clear tool-decode failure at run time).
    var argumentBindings: [String: String] = [:]

    init(tool: Tool? = nil, argumentBindings: [String: String] = [:]) {
        self.tool = tool
        self.argumentBindings = argumentBindings
    }
}

// MARK: - Per-Node Execution Config

/// Per-node execution configuration owned by the workflow layer (not the agent layer).
/// Controls retry, cascade policy, and hard timeout at the graph level.
struct WorkflowNodeConfig: Codable, Hashable, Sendable {
    /// Re-invoke entire node on failure (default: 0 = no retry).
    var maxNodeRetries: Int = 0

    /// Delay in seconds between node-level retries.
    var retryDelay: TimeInterval = 0

    /// Behavior when this node fails — controls downstream cascade.
    var onFailure: NodeFailurePolicy = .skipDependents

    /// Hard timeout override — `Task.cancel()` safety net.
    /// If nil, uses the agent's own `executionTimeout` or `ExecutionConstraints.default.maxDuration`.
    var hardTimeout: TimeInterval? = nil

    /// RETIRED 2026-08-29 — read and written by NOTHING. No UI edits it, no validation requires
    /// it, and `WorkflowExecutor` no longer reads it: a node's behaviour is its profile's system
    /// instructions, and its input is the run's query (entry node) or its upstream's output.
    ///
    /// ⚠️ THE PROPERTY AND ITS CODING KEY STAY, and must. `WorkflowNodeConfig` decodes out of the
    /// persisted layout blob; every workflow saved before this date carries a `taskDescription`,
    /// and while `decodeIfPresent` means dropping the key would not fail the decode, re-encoding
    /// without it would strip those bytes from disk on the next save — silently discarding text
    /// users wrote, with no UI left to show them what was lost. Keeping the field round-trips it
    /// untouched, so a future build could surface or migrate it.
    ///
    /// ⚠️ Do NOT reintroduce a reader. If per-node direction is ever wanted again it should be a
    /// new, deliberately-named field, not this one silently coming back to life with old content.
    var taskDescription: String = ""

    /// [WF-SE6/SE11] EXPLICIT unattended approval: when true, tool confirmations raised by this
    /// node during a run NOBODY CAN ANSWER (a scheduled fire) are auto-approved. This — never a
    /// banner click — is the sanctioned way to let a scheduled workflow run a confirming tool:
    /// interactive "Allow for this chat" grants are not served to such runs, and a confirmation
    /// with no standing config is refused fast instead of parking to nobody until a deadline
    /// kills the whole run.
    ///
    /// ⚠️ A CHATOPS run is NOT covered by this: a human is reachable there (the confirmation is
    /// mirrored to Telegram/Slack/Discord with working Approve/Deny), so it still asks. See
    /// `WorkflowRunAttendance.canReachAHuman`.
    ///
    /// ⚠️ Read only on the PROFILE-node path (via `WorkflowExecutionContext`) and the Action-node
    /// arm. A sub-workflow node dispatches structurally and never reads it — the child graph's own
    /// nodes carry their own settings, which is why the inspector hides the row there.
    ///
    /// nil = false; the field is additive, which is why `layoutBlobVersion` bumped 2 → 3 (the TS5
    /// rule: an old build re-saving would silently strip it, so it must be refused the save).
    var unattendedAutoApprove: Bool? = nil

    /// ⚠️ RETIRED 2026-08-13 — decode/encode-only, never read at runtime.
    ///
    /// This was the "Fan-in Behavior" picker (Wait for all / Any one). It asked the user a question
    /// the graph already answers, and its two values could not express the correct behaviour for a
    /// node with BOTH independent and mutually-exclusive upstreams — `.all` never ran, `.any` ran on
    /// too little. `WorkflowState.shouldExecuteNode` now DERIVES the join: every incoming branch is
    /// required except a dead one whose live sibling depends on a different port of a common
    /// ancestor. See that method for the full rule.
    ///
    /// ⚠️ Deliberately NOT deleted, same reasoning as `onFailure`: the layout blob has no
    /// per-element resilience (WF24), so dropping a Codable key is not free. A stored value is
    /// logged once per run and ignored — never rewritten, so a downgrade still reads the file.
    var joinMode: JoinMode = .all
}

// MARK: - WorkflowNodeConfig Codable (backward-compatible)
//
// `joinMode` was added after the original schema shipped. Swift's *synthesized*
// `init(from:)` would `throw` on any layout serialized before this field
// existed (synthesized decoding ignores property defaults for missing keys).
// A hand-rolled decoder using `decodeIfPresent` lets old layouts load cleanly
// and also hardens every other field against partially-written configs.
// Declared in an extension so the memberwise initializer (`WorkflowNodeConfig()`)
// is preserved; `encode(to:)` stays synthesized from these same keys.
extension WorkflowNodeConfig {
    private enum CodingKeys: String, CodingKey {
        case maxNodeRetries, retryDelay, onFailure, hardTimeout, taskDescription, unattendedAutoApprove, joinMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxNodeRetries: try c.decodeIfPresent(Int.self, forKey: .maxNodeRetries) ?? 0,
            retryDelay: try c.decodeIfPresent(TimeInterval.self, forKey: .retryDelay) ?? 0,
            onFailure: try c.decodeIfPresent(NodeFailurePolicy.self, forKey: .onFailure) ?? .skipDependents,
            hardTimeout: try c.decodeIfPresent(TimeInterval.self, forKey: .hardTimeout),
            taskDescription: try c.decodeIfPresent(String.self, forKey: .taskDescription) ?? "",
            unattendedAutoApprove: try c.decodeIfPresent(Bool.self, forKey: .unattendedAutoApprove),
            joinMode: try c.decodeIfPresent(JoinMode.self, forKey: .joinMode) ?? .all
        )
    }
}

/// Cascade policy when a workflow node fails.
/// ⚠️ RETIRED 2026-08-12 — decode-only. Nothing reads this at run time.
///
/// Failure routing is now expressed on the CANVAS, via the `error` port:
///   • error port unwired  → the branch stops (what `skipDependents` always was — it had ZERO
///     runtime reads even before this; it was the fall-through)
///   • error port wired    → the downstream node runs and receives the failure reason + partial
///     output (what `continueAll` was trying to be)
///   • `stopWorkflow` is GONE by design: a failure no longer cancels PARALLEL branches. Parallel
///     branches are independent by construction — nothing connects them — so aborting them
///     destroyed usable, already-finished work to save tokens. A real dependency is an edge, and
///     the skip cascade already enforces those.
///
/// The cases and their rawValues MUST stay: they are persisted inside `WorkflowNodeConfig` in the
/// layout blob, and there is no per-element decode resilience yet (WF24) — an unknown rawValue
/// takes the ENTIRE layout unreadable, not just one node. `WorkflowExecutor` logs once per run
/// when a stored policy is encountered and ignored.
enum NodeFailurePolicy: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    case skipDependents
    case stopWorkflow
    case continueAll
    /// Unrecognised stored value — preserved verbatim (WF-PE3). Safe here by construction: the
    /// whole policy is RETIRED and never consulted at runtime.
    case other(String)

    static var allCases: [NodeFailurePolicy] { [.skipDependents, .stopWorkflow, .continueAll] }

    init?(rawValue: String) {
        switch rawValue {
        case "skipDependents": self = .skipDependents
        case "stopWorkflow":   self = .stopWorkflow
        case "continueAll":    self = .continueAll
        default:               self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .skipDependents:  return "skipDependents"
        case .stopWorkflow:    return "stopWorkflow"
        case .continueAll:     return "continueAll"
        case .other(let raw):  return raw
        }
    }
}

/// ⚠️ RETIRED 2026-08-13 — kept for blob compatibility only. See `WorkflowNodeConfig.joinMode`.
///
/// The join is now derived from the graph, so neither case is consulted at runtime. The old doc
/// comment described `.all` as "if any branch failed or was skipped, this node is skipped too" and
/// `.any` as "consuming only the successful branches' outputs" — **both were wrong** (an activated
/// `error` route makes a failed branch live, and data was never filtered by success), and the UI
/// copy was written from this comment. Left here as a warning: help text derived from a doc comment
/// inherits its errors.
///
/// ⚠️ rawValues are pinned — they appear in persisted layout blobs.
enum JoinMode: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    case all
    case any
    /// Unrecognised stored value — preserved verbatim (WF-PE3). Retired setting; never consulted.
    case other(String)

    static var allCases: [JoinMode] { [.all, .any] }

    init?(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "any": self = .any
        default:    self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .all: return "all"
        case .any: return "any"
        case .other(let raw): return raw
        }
    }

    /// Retained for log lines only — there is no UI control any more.
    var displayName: String {
        switch self {
        case .all: return "Wait for all"
        case .any: return "Any one"
        case .other(let raw): return raw
        }
    }
}

// MARK: - Workflow Node

/// A single node on the canvas. The `kind` discriminated union determines what
/// the node represents — a profile-backed executor, a logic node, or a structural node.
struct WorkflowNode: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: WorkflowNodeKind
    var position: CGPoint
    var displayName: String

    /// Per-node execution configuration (retry, cascade, timeout).
    /// Nil uses defaults: 0 retries, skipDependents, agent-level timeout.
    var nodeConfig: WorkflowNodeConfig?

    /// Convenience: returns the profile UUID if this is a profile-backed node.
    var profileID: UUID? {
        if case .profile(let id, _) = kind { return id }
        return nil
    }

    /// Convenience: returns the profile type if this is a profile-backed node.
    var profileType: ProfileType? {
        if case .profile(_, let type) = kind { return type }
        return nil
    }

    init(id: UUID = UUID(), kind: WorkflowNodeKind, position: CGPoint, displayName: String) {
        self.id = id
        self.kind = kind
        self.position = position
        self.displayName = displayName
    }

    /// Convenience initializer for profile-backed nodes (most common case).
    init(id: UUID = UUID(), profileID: UUID, position: CGPoint, displayName: String, profileType: ProfileType) {
        self.id = id
        self.kind = .profile(profileID: profileID, profileType: profileType)
        self.position = position
        self.displayName = displayName
    }

    // MARK: Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case id, kind, positionX, positionY, displayName, nodeConfig
        // Legacy keys for backward compatibility
        case profileID, profileType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)

        // Try new `kind` field first; fall back to legacy profileID + profileType.
        //
        // ⚠️ The fallback is GATED on the legacy key being present (WF-PE4). This was `try?`, which
        // swallowed the REAL kind-decode error unconditionally: any modern non-profile node whose
        // `kind` failed to decode (an unknown case name after a rollback — PE3's dominant path)
        // fell through here, failed on the absent `profileID`, and the one log line a field
        // engineer got named `keyNotFound(profileID)` — a key that has nothing to do with the
        // failure. Every legacy blob HAS `profileID` (it was mandatory then); every modern
        // non-profile node does NOT — so the key's presence is exactly the "is this a legacy row"
        // question, and when it is absent the true error is rethrown with its full coding path.
        do {
            kind = try container.decode(WorkflowNodeKind.self, forKey: .kind)
        } catch let kindError {
            if container.contains(.profileID) {
                let legacyProfileID = try container.decode(UUID.self, forKey: .profileID)
                let legacyProfileType = try container.decode(ProfileType.self, forKey: .profileType)
                kind = .profile(profileID: legacyProfileID, profileType: legacyProfileType)
            } else if let raw = try? container.decode(JSONValue.self, forKey: .kind),
                      case .object(let fields) = raw,
                      let discriminator = fields.keys.first, fields.count == 1,
                      !WorkflowNodeKind.knownKindCaseNames.contains(discriminator) {
                // [WF-PE4] Per-element resilience: an UNRECOGNIZED case name (a build this old has
                // never heard of — rollback, or a deleted kind like the retired Loop) becomes a
                // PRESERVED placeholder instead of failing the whole [WorkflowNode] array — which
                // used to make the layout unreadable, unrunnable AND permanently unsaveable in one
                // throw. The raw JSON round-trips through encode(to:), so nothing is lost on re-save.
                //
                // ⚠️ Found on adversarial audit: the ORIGINAL version of this arm fired on ANY
                // undecodable `kind`, which conflated true version skew (an unknown case name) with
                // real CORRUPTION of a case this build fully understands — a node-kind config with
                // a synthesized `Codable` and a non-optional field (e.g. `ActionNodeConfig.
                // argumentBindings`) throws the identical `kindError` shape on a missing/malformed
                // key as an unknown case name does. Silently reclassifying that as "saved by a
                // different version, update Devgentic" is actively misleading — updating changes
                // nothing, and the corruption is never surfaced. The discriminator-name check above
                // is the fix: only a case name THIS BUILD DOES NOT KNOW is version skew.
                kind = .unsupported(raw: raw)
            } else {
                // Either not valid JSON under the key, or the discriminator names a case this
                // build DOES understand whose payload still failed to decode — real corruption,
                // not version skew. The unreadable-layout machinery is the honest surface for it.
                throw kindError
            }
        }

        let x = try container.decode(CGFloat.self, forKey: .positionX)
        let y = try container.decode(CGFloat.self, forKey: .positionY)
        position = CGPoint(x: x, y: y)
        displayName = try container.decode(String.self, forKey: .displayName)
        nodeConfig = try container.decodeIfPresent(WorkflowNodeConfig.self, forKey: .nodeConfig)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        // [WF-PE4] An unsupported node re-encodes its ORIGINAL kind JSON, not the placeholder
        // wrapper — so the build that understands this node reads it back untouched, and the
        // literal case name `unsupported` never reaches a persisted blob.
        if case .unsupported(let raw) = kind {
            try container.encode(raw, forKey: .kind)
        } else {
            try container.encode(kind, forKey: .kind)
        }
        try container.encode(position.x, forKey: .positionX)
        try container.encode(position.y, forKey: .positionY)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(nodeConfig, forKey: .nodeConfig)

        // Dual-write legacy fields for backward compatibility
        if case .profile(let pid, let ptype) = kind {
            try container.encode(pid, forKey: .profileID)
            try container.encode(ptype, forKey: .profileType)
        }
    }
}

// MARK: - Workflow Edge

/// A directed connection between two nodes (source output port → target input port).
/// For multi-port nodes (e.g., Condition), `sourcePortLabel` identifies which output port.
struct WorkflowEdge: Identifiable, Codable, Hashable {

    /// The reserved failure port label.
    ///
    /// ⚠️ ONE definition, deliberately. This string is load-bearing in two places that MUST agree —
    /// `WorkflowCanvasState.outputPortLabels` (which port the canvas draws and the validator accepts)
    /// and `WorkflowState.edgeIsLive` (which edge the engine follows on failure). A port the engine
    /// activates but the canvas never renders is unwireable, which is exactly the defect WF61
    /// recorded; a port the canvas draws but the engine never activates is a dead branch. Both are
    /// invisible to pre-flight validation, because the validator checks edges against the canvas
    /// list and can never see a runtime activation.
    ///
    /// ⚠️ It is also a RESERVED user-facing label: a Condition rule or Gate option named "error"
    /// collides with it. `outputPortLabels` de-duplicates so no duplicate port renders, and the
    /// validator warns — it does not block, since an existing workflow may already carry one.
    static let errorPortLabel = "error"

    let id: UUID
    let sourceNodeID: UUID
    let targetNodeID: UUID

    /// Which output port this edge originates from.
    /// `nil` = default single output port (profile nodes, most structural nodes).
    /// For condition nodes: "True", "False", or custom rule labels.
    let sourcePortLabel: String?

    init(id: UUID = UUID(), sourceNodeID: UUID, targetNodeID: UUID, sourcePortLabel: String? = nil) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        self.sourcePortLabel = sourcePortLabel
    }

    // Backward-compatible Codable
    private enum CodingKeys: String, CodingKey {
        case id, sourceNodeID, targetNodeID, sourcePortLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceNodeID = try container.decode(UUID.self, forKey: .sourceNodeID)
        targetNodeID = try container.decode(UUID.self, forKey: .targetNodeID)
        sourcePortLabel = try container.decodeIfPresent(String.self, forKey: .sourcePortLabel)
    }
}

// MARK: - Sticky Note

/// A canvas annotation — draggable, resizable, no ports, no execution.
struct StickyNote: Identifiable, Codable, Hashable {
    let id: UUID
    var position: CGPoint
    var size: CGSize
    var text: String
    var color: StickyNoteColor

    init(id: UUID = UUID(), position: CGPoint, size: CGSize = CGSize(width: 180, height: 120), text: String = "", color: StickyNoteColor = .yellow) {
        self.id = id
        self.position = position
        self.size = size
        self.text = text
        self.color = color
    }

    private enum CodingKeys: String, CodingKey {
        case id, positionX, positionY, width, height, text, color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let x = try c.decode(CGFloat.self, forKey: .positionX)
        let y = try c.decode(CGFloat.self, forKey: .positionY)
        position = CGPoint(x: x, y: y)
        let w = try c.decode(CGFloat.self, forKey: .width)
        let h = try c.decode(CGFloat.self, forKey: .height)
        size = CGSize(width: w, height: h)
        text = try c.decode(String.self, forKey: .text)
        color = try c.decodeIfPresent(StickyNoteColor.self, forKey: .color) ?? .yellow
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(position.x, forKey: .positionX)
        try c.encode(position.y, forKey: .positionY)
        try c.encode(size.width, forKey: .width)
        try c.encode(size.height, forKey: .height)
        try c.encode(text, forKey: .text)
        try c.encode(color, forKey: .color)
    }
}

enum StickyNoteColor: RawRepresentable, Codable, Hashable, CaseIterable {
    case yellow, blue, green, pink, purple
    /// A colour written by a newer build — preserved verbatim, DRAWN as yellow (WF-PE3). The note's
    /// text is the data; the tint is cosmetic and must never brick a graph.
    case other(String)

    static var allCases: [StickyNoteColor] { [.yellow, .blue, .green, .pink, .purple] }

    init?(rawValue: String) {
        switch rawValue {
        case "yellow": self = .yellow
        case "blue":   self = .blue
        case "green":  self = .green
        case "pink":   self = .pink
        case "purple": self = .purple
        default:       self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .yellow: return "yellow"
        case .blue:   return "blue"
        case .green:  return "green"
        case .pink:   return "pink"
        case .purple: return "purple"
        case .other(let raw): return raw
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .yellow: return .yellow
        case .blue:   return .blue
        case .green:  return .green
        case .pink:   return .pink
        case .purple: return .purple
        // Cosmetic fallback — the note's TEXT is the data; an unknown tint draws as the default.
        case .other:  return .yellow
        }
    }
}

// MARK: - Workflow Layout

/// Persistable canvas layout — stored as a sidecar alongside the profile.
/// Keeps node positions, edge connections, and annotations.
struct WorkflowLayout: Codable {
    var nodes: [WorkflowNode]
    var edges: [WorkflowEdge]
    var annotations: [StickyNote]

    static let empty = WorkflowLayout(nodes: [], edges: [], annotations: [])

    /// Nodes this build cannot understand ([WF-PE4] placeholders). Non-empty blocks the RUN —
    /// the executor's choke point and the validator both consult this — while the canvas stays
    /// open, editable and saveable.
    var unsupportedNodes: [WorkflowNode] {
        nodes.filter { if case .unsupported = $0.kind { return true }; return false }
    }

    // Backward-compatible decoding — old layouts have no annotations
    private enum CodingKeys: String, CodingKey {
        case nodes, edges, annotations
    }

    init(nodes: [WorkflowNode] = [], edges: [WorkflowEdge] = [], annotations: [StickyNote] = []) {
        self.nodes = nodes
        self.edges = edges
        self.annotations = annotations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decode([WorkflowNode].self, forKey: .nodes)
        edges = try c.decode([WorkflowEdge].self, forKey: .edges)
        annotations = try c.decodeIfPresent([StickyNote].self, forKey: .annotations) ?? []
    }

    // MARK: - Cycle Detection (DFS)

    /// Returns `true` if adding an edge from `source` to `target` would create a cycle.
    func wouldCreateCycle(source: UUID, target: UUID) -> Bool {
        // Build adjacency list including the proposed new edge
        var adjacency: [UUID: [UUID]] = [:]
        for edge in edges {
            adjacency[edge.sourceNodeID, default: []].append(edge.targetNodeID)
        }
        adjacency[source, default: []].append(target)

        // DFS from target to see if we can reach source (cycle)
        var visited: Set<UUID> = []
        var stack: [UUID] = [target]

        while let current = stack.popLast() {
            if current == source { return true }
            if visited.contains(current) { continue }
            visited.insert(current)

            if let neighbors = adjacency[current] {
                stack.append(contentsOf: neighbors)
            }
        }
        return false
    }

    /// Returns nodes in topological order, or nil if the graph has a cycle.
    func topologicalSort() -> [UUID]? {
        var inDegree: [UUID: Int] = [:]
        var adjacency: [UUID: [UUID]] = [:]

        for node in nodes {
            inDegree[node.id] = 0
            adjacency[node.id] = []
        }

        for edge in edges {
            adjacency[edge.sourceNodeID, default: []].append(edge.targetNodeID)
            inDegree[edge.targetNodeID, default: 0] += 1
        }

        var queue = nodes.map(\.id).filter { (inDegree[$0] ?? 0) == 0 }
        var result: [UUID] = []

        while !queue.isEmpty {
            let current = queue.removeFirst()
            result.append(current)

            for neighbor in adjacency[current] ?? [] {
                inDegree[neighbor, default: 0] -= 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                }
            }
        }

        return result.count == nodes.count ? result : nil
    }

    /// Groups nodes into dependency levels for parallel execution.
    /// Level 0 = entry nodes (no incoming edges).
    /// Level N = nodes whose ALL upstream dependencies are in levels 0..N-1.
    /// Returns `nil` if the graph has a cycle.
    ///
    /// Adapted from `PlanningCapability.computeExecutionLevels()`.
    func computeExecutionLevels() -> [[UUID]]? {
        let nodeIDs = Set(nodes.map(\.id))
        var inDegree: [UUID: Int] = [:]
        var adjacency: [UUID: [UUID]] = [:]

        for node in nodes {
            inDegree[node.id] = 0
            adjacency[node.id] = []
        }

        for edge in edges {
            guard nodeIDs.contains(edge.sourceNodeID), nodeIDs.contains(edge.targetNodeID) else { continue }
            adjacency[edge.sourceNodeID, default: []].append(edge.targetNodeID)
            inDegree[edge.targetNodeID, default: 0] += 1
        }

        var levels: [[UUID]] = []
        var placed: Set<UUID> = []

        while placed.count < nodes.count {
            // Collect nodes whose all dependencies are already placed
            let currentLevel = nodes
                .map(\.id)
                .filter { !placed.contains($0) && (inDegree[$0] ?? 0) == 0 }

            guard !currentLevel.isEmpty else {
                // No progress — cycle detected
                return nil
            }

            levels.append(currentLevel)
            placed.formUnion(currentLevel)

            // Decrement in-degree for downstream nodes
            for nodeID in currentLevel {
                for neighbor in adjacency[nodeID] ?? [] {
                    inDegree[neighbor, default: 0] -= 1
                }
            }
        }

        return levels
    }
}

// MARK: - Drag State

/// Tracks an in-progress edge being drawn from an output port.
struct EdgeDragState {
    let sourceNodeID: UUID
    let sourcePortLabel: String?  // Which output port is being dragged from (nil = default)
    var currentPoint: CGPoint
}
