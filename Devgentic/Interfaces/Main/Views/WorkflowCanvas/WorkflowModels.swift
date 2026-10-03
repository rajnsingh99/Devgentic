// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    /// name written by a different build: a rollback after a node-kind addition, or a deleted
    /// kind). `raw` is the kind's ORIGINAL JSON, and `WorkflowNode.encode(to:)`
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

    /// Dedicated branch colors for multi-port routing nodes (e.g. Router/Condition rules 1...5, Gate options).
    /// Assigned by slot index (0...4) so user-renamed branches stay distinct and consistently colored.
    static func branchColor(forIndex index: Int) -> Color {
        switch index {
        case 0:
            // Branch 1: Emerald Green (default True / affirmative / first branch)
            return Color(red: 0.20, green: 0.78, blue: 0.42)
        case 1:
            // Branch 2: Warm Amber (default False / alternative / second branch)
            return Color(red: 1.00, green: 0.60, blue: 0.15)
        case 2:
            // Branch 3: Electric Violet
            return Color(red: 0.68, green: 0.42, blue: 0.98)
        case 3:
            // Branch 4: Sky Cyan
            return Color(red: 0.18, green: 0.75, blue: 0.96)
        case 4:
            // Branch 5: Rose Pink
            return Color(red: 0.98, green: 0.35, blue: 0.58)
        default:
            return Color(red: 0.55, green: 0.60, blue: 0.68)
        }
    }

    /// Resolves the output port / branch color for a node given the port label.
    /// Error ports take precedence with theme.errorColor; multi-port nodes resolve
    /// their rules/options by slot index; single-port nodes use kind identity color.
    func portColor(forLabel portLabel: String?, in theme: any Theme) -> Color {
        if portLabel == WorkflowEdge.errorPortLabel {
            return theme.errorColor
        }
        switch self {
        case .condition(let config):
            if let index = config.rules.firstIndex(where: { $0.label == portLabel }) {
                return Self.branchColor(forIndex: index)
            }
        case .gate(let config):
            if let index = config.options.firstIndex(of: portLabel ?? "") {
                return Self.branchColor(forIndex: index)
            }
        default:
            break
        }
        return identityColor(in: theme)
    }

    /// The node inspector window's minimum content size for this kind (register INS-4).
    ///
    /// ⚠️ SINGLE SOURCE, and it must stay one: the inspector view's own root `.frame(minHeight:)`
    /// and the AppKit host's `minSize` are the same quantity stated twice. They disagreed by up to
    /// 160pt — the host passed one 800×520 for EVERY kind while Router declares 680, Action 620,
    /// Gate 560 and Profile 540 — so the content was laid out taller than the window hosting it,
    /// and the strip that gets clipped is the header carrying Cancel and Save.
    ///
    /// ⚠️ Total, with NO `default:`. Adding a node kind must be a compile error here rather than a
    /// silently-wrong window. `.trigger` and `.unsupported` never reach an inspector — both writers
    /// of `targetConfigNode` gate them out — but they still need an answer.
    nonisolated var inspectorMinimumSize: CGSize {
        switch self {
        case .condition:   return CGSize(width: 800, height: 680)
        case .action:      return CGSize(width: 800, height: 620)
        case .gate:        return CGSize(width: 800, height: 560)
        case .profile:     return CGSize(width: 800, height: 540)
        case .code:        return CGSize(width: 800, height: 520)
        case .trigger, .unsupported: return CGSize(width: 800, height: 520)
        }
    }
}

// MARK: - Node Kind Configs

/// What a Router does when its evidence yields anything but exactly ONE winner — zero rules matched
/// (EMPTY) or several matched (AMBIGUOUS). One setting, both triggers (user decision 2026-08-17).
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

    /// Fail the node so its `error` port activates and a wired branch can recover — the reason the
    /// error port is reachable at all: the guide promises "a failure (and only a failure) activates
    /// the error port".
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

    /// The rule-label length contract. THE one definition — `isValidLabel` below, the inspector's
    /// keystroke sanitizer, `WorkflowCanvasState.portBadgeCharacterCap` and `deduplicatedLabel` all
    /// read it, so the four cannot drift apart (register INS-6). Do not restate the number.
    static let maxLabelLength = 10

    /// Validates a label: single word, alphanumeric only, max `maxLabelLength` characters.
    static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= maxLabelLength else { return false }
        return label.range(of: "^[a-zA-Z0-9]+$", options: .regularExpression) != nil
    }

    /// `label` if it is free, else the first `<base><n>` (n = 2…99) not already in `taken`.
    ///
    /// ⚠️ The numeric suffix REPLACES the tail; it never extends it. The de-dup used to build
    /// `String("\(label)\(n)".prefix(10))`, which for an already-10-character label truncates
    /// straight back to the SAME ten characters — so every one of the 98 candidates was already in
    /// `taken`, the loop fell through, and the duplicate was written unchanged. That is a blocking
    /// validator error the user then has to find and fix by hand. Replacing the tail also stops
    /// suffixes 10…99 collapsing onto nine distinct candidates for a 9-character base.
    ///
    /// ⚠️ The result always ends in a digit, so it can never collide with
    /// `WorkflowEdge.errorPortLabel` ("error"), which is a reserved port name.
    ///
    /// Returns `label` unchanged if all 98 candidates are taken — the caller cannot have 98 rules
    /// (`maxRules` is 5), so that arm is unreachable in production and is a safe identity.
    nonisolated static func deduplicatedLabel(_ label: String, taken: Set<String>) -> String {
        guard taken.contains(label) else { return label }
        let base = String(label.filter { $0.isLetter || $0.isNumber })
        for n in 2...99 {
            let tail = String(n)
            let head = String(base.prefix(max(0, maxLabelLength - tail.count)))
            let candidate = head + tail
            if !taken.contains(candidate) { return candidate }
        }
        return label
    }

    // --- Pattern Match (always evaluated first) ---

    /// Condition rules — every rule is evaluated; exactly one match activates that output port.
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
    /// MLX model display name used for classification.
    var llmModelName: String? = nil

    /// What this Router does when its evidence yields anything but exactly ONE winner.
    ///
    /// ⚠️ ONE setting, TWO triggers (user decision 2026-08-17): zero rules matched (EMPTY) and
    /// several matched (AMBIGUOUS). They are mutually exclusive by construction, so a single
    /// setting is coherent rather than a false merge.
    ///
    /// ⚠️ The AI Classifier INHERITS it: exactly one recognised token routes, zero is EMPTY, two or
    /// more is AMBIGUOUS. That is what retires WF-OB2 — a multi-token reply used to resolve by
    /// unordered `Dictionary` iteration, so the same input could take a different branch after an
    /// app restart.
    ///
    /// ⚠️ TWO OUTCOMES STAY OUTSIDE THIS SETTING, deliberately. A classifier that CRASHED produced
    /// no verdict, so it fails the node regardless of the policy (WF-CC10); a Stop settles the node
    /// `.canceled` and routes nowhere (WF-CC13). This setting answers "the rules did not single out
    /// one branch" — a statement about CONTENT — and neither of those is content.
    ///
    /// Defaults to asking, with "fail the node" when nobody can answer — the strict choice: an
    /// undecided input never silently takes a branch nobody chose.
    var decisionPolicy: RouterDecisionPolicy = .ask(fallback: .failNode)

    /// Default initializer — all properties use their declared defaults.
    init() {}

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case rules, llmFallbackEnabled, llmPrompt, llmModelName, decisionPolicy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // A Router needs at least two rules (two ports); a blob carrying fewer is topped up rather
        // than failing the whole layout.
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
        llmModelName = try c.decodeIfPresent(String.self, forKey: .llmModelName)
        // `try?` deliberately: a policy shape from a NEWER build degrades to the default instead of
        // taking the whole layout unreadable (WF24 — the blob has no per-element resilience). The
        // `layoutBlobVersion` stamp refuses that build's save, so the degraded read is never written
        // back over the newer value.
        decisionPolicy = (try? c.decodeIfPresent(RouterDecisionPolicy.self, forKey: .decisionPolicy))
            ?? .ask(fallback: .failNode)
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
    /// The AI Classifier routes to these same ports.
    var outputPortLabels: [String] {
        rules.map(\.label)
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

    // ⚠️ There is deliberately no "always matches" operator. A catch-all rule matches everything,
    // so any input matching a real rule matches TWO rules and ambiguity arbitration fires on every
    // ordinary input. Unmatched input is `ConditionNodeConfig.decisionPolicy`'s job.

    /// An operator this build cannot evaluate — a newer build's operator (WF-PE3). Preserved
    /// verbatim, never matches.
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
        case .other(let raw): return "\(raw) (unavailable)"
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
/// Controls retry and hard timeout at the graph level.
struct WorkflowNodeConfig: Codable, Hashable, Sendable {
    /// Re-invoke entire node on failure (default: 0 = no retry).
    var maxNodeRetries: Int = 0

    /// Delay in seconds between node-level retries.
    var retryDelay: TimeInterval = 0

    /// Hard timeout override for this node.
    /// If nil (or 0 / negative — `TimeLimit.usable`), the node uses its profile's `executionTimeout`,
    /// then the workflow's node timeout (`WorkflowConfig.nodeTimeout`); an enclosing scheduled run
    /// can shorten it further (`ExecutionBudget`).
    var hardTimeout: TimeInterval? = nil

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
    /// nil = false.
    var unattendedAutoApprove: Bool? = nil
}

// MARK: - WorkflowNodeConfig Codable
//
// `decodeIfPresent` with the property defaults, so a config written with only some keys (a node
// whose user touched one control) loads with the rest at their defaults. Declared in an extension
// so the memberwise initializer (`WorkflowNodeConfig()`) is preserved; `encode(to:)` stays
// synthesized from these same keys.
extension WorkflowNodeConfig {
    private enum CodingKeys: String, CodingKey {
        case maxNodeRetries, retryDelay, hardTimeout, unattendedAutoApprove
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxNodeRetries: try c.decodeIfPresent(Int.self, forKey: .maxNodeRetries) ?? 0,
            retryDelay: try c.decodeIfPresent(TimeInterval.self, forKey: .retryDelay) ?? 0,
            hardTimeout: try c.decodeIfPresent(TimeInterval.self, forKey: .hardTimeout),
            unattendedAutoApprove: try c.decodeIfPresent(Bool.self, forKey: .unattendedAutoApprove)
        )
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

    /// Per-node execution configuration (retry, timeout).
    /// Nil uses defaults: 0 retries, agent-level timeout.
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

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, kind, positionX, positionY, displayName, nodeConfig
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)

        do {
            kind = try container.decode(WorkflowNodeKind.self, forKey: .kind)
        } catch let kindError {
            if let raw = try? container.decode(JSONValue.self, forKey: .kind),
               case .object(let fields) = raw,
               let discriminator = fields.keys.first, fields.count == 1,
               !WorkflowNodeKind.knownKindCaseNames.contains(discriminator) {
                // [WF-PE4] Per-element resilience: an UNRECOGNIZED case name (a kind a newer build
                // added, read here after a rollback) becomes a
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

    /// The one size a sticky note may shrink to, in canvas points (register CVC-8).
    ///
    /// ⚠️ SINGLE SOURCE. The resize handle's live preview and `WorkflowCanvasState.resizeStickyNote`'s
    /// clamp MUST both read this. They used to carry independent literals — 100×60 in the view,
    /// 120×80 in the model — so every release in that band previewed a size the model refused and
    /// the note visibly snapped back out from under the cursor.
    ///
    /// 120 is not arbitrary: the note header's colour-swatch row is ~114pt intrinsically wide, so a
    /// 100pt card clips its own chrome. The committed size is unchanged by unifying on the higher
    /// floor — `max(120, max(100, x)) == max(120, x)` — so only the preview stops lying.
    static let minimumSize = CGSize(width: 120, height: 80)

    /// The size a resize drag of `translation` from `base` resolves to — the ONLY resize arithmetic.
    ///
    /// Pure and nonisolated so the floor can be truth-tabled (WF-UI5): the two `DragGesture`
    /// closures that used to hold this expression are unreachable from a test.
    static func resizedSize(from base: CGSize, translation: CGSize) -> CGSize {
        CGSize(
            width: max(minimumSize.width, base.width + translation.width),
            height: max(minimumSize.height, base.height + translation.height)
        )
    }

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
