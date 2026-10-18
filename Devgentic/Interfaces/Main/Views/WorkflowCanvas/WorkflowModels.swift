// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowModels.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI

// MARK: - Port Type

/// The kind of data a workflow node port carries (part of the canvas data models: nodes, edges, ports and the DAG
/// definition).
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

    // Why: the case name stays `condition`: `WorkflowNodeKind` uses synthesized Codable, which persists the case name, so
    // renaming it would degrade every saved Router to `.unsupported`.
    /// The Router node: matches the upstream text against labelled rules and routes to the matching output port.
    case condition(ConditionNodeConfig)

    /// Code/transform — deterministic non-LLM processing (regex, JSON, format).
    case code(CodeNodeConfig)

    /// HITL gate — suspends execution and waits for user approval.
    case gate(GateNodeConfig)

    /// Trigger — starts workflow execution (webhook, schedule, manual).
    case trigger(TriggerNodeConfig)

    /// Action/integration — invokes a tool directly and deterministically (no LLM).
    case action(ActionNodeConfig)

    // Why: the case name `unsupported` is reserved: encode unwraps this case, so a blob must never contain
    // `{"unsupported":{...}}`.
    /// A node this build cannot understand, preserved rather than lost. Produced only by `WorkflowNode.init(from:)` when
    /// the stored kind's case name is unknown; `raw` is the original JSON and `encode(to:)` writes it back verbatim. Such
    /// a node renders as a degraded placeholder and blocks the run (`WorkflowError.unsupportedNodes`).
    case unsupported(raw: JSONValue)

    // Why: update it whenever a case is added, renamed or removed, or corrupted nodes are misclassified as version skew.
    /// The persisted discriminator (case name) of every real, persistable case, i.e. all cases except `.unsupported`.
    /// Distinguishes an unknown case name (version skew, kept as a placeholder) from a known case whose payload failed to
    /// decode (corruption).
    fileprivate static let knownKindCaseNames: Set<String> = [
        "profile", "condition", "code", "gate", "trigger", "action",
    ]
}

// MARK: - Node Identity Colour (WF-CU10)

/// The structural node kinds that carry an identity colour on the canvas. Profile-backed nodes are excluded: their
/// colour comes from `ProfileType.displayColor`, which has other consumers.
enum WorkflowNodeRole: String, CaseIterable, Sendable {
    case router      // `.condition` — the Swift case name is frozen for Codable reasons
    case code
    case gate
    case trigger
    case action
}

extension WorkflowNodeKind {
    /// The card, port, edge, palette and legend colour for this node kind. Single source for the canvas, edge gradients,
    /// add-node palette and legend, so they cannot drift.
    func identityColor(in theme: any Theme) -> Color {
        switch self {
        case .profile(_, let pType): return pType.displayColor
        case .condition: return theme.nodeIdentityColor(for: .router)
        case .code:      return theme.nodeIdentityColor(for: .code)
        case .gate:      return theme.nodeIdentityColor(for: .gate)
        case .trigger:   return theme.nodeIdentityColor(for: .trigger)
        case .action:    return theme.nodeIdentityColor(for: .action)
        // Colourless, so the placeholder reads as not one of ours.
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

    // Why: single source: the inspector's root `.frame(minHeight:)` and the AppKit host's `minSize` state the same quantity,
    // and a mismatch clips the header with Cancel and Save.
    /// The node inspector window's minimum content size for this kind. Total, with no `default:`, so a new node kind is a
    /// compile error here; `.trigger` and `.unsupported` never reach an inspector but still need an answer.
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

// Why: every case must mean the same thing for empty and ambiguous; do not add an implicit "first match wins" case, which
// would make rule order silently change unattended routing.
/// What a Router does when its evidence yields anything but exactly one winner: zero rules matched (empty) or several
/// matched (ambiguous). One setting covers both triggers.
enum RouterDecisionPolicy: Codable, Hashable, Sendable {
    /// Route to this rule's port, as if it had matched. On ambiguous input this overrides the matched rules, so the
    /// branches that did match do not run.
    case route(ruleID: UUID)

    /// Pause and ask a human to pick. Attended runs only: an unattended run (scheduled, or started from a chat bridge)
    /// takes `fallback` immediately, as does an attended run nobody answers.
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

    /// Returns `label` if it is free, else the first `<base><n>` (n = 2…99) not in `taken`; returns `label` unchanged if
    /// all candidates are taken. The suffix replaces the tail of the label, so the result fits the length limit and
    /// always ends in a digit, never colliding with `WorkflowEdge.errorPortLabel`.
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

    /// What this Router does when its evidence yields anything but exactly one winner (zero matched or several matched).
    /// The AI Classifier inherits it; a classifier crash fails the node and a Stop cancels it regardless of this setting.
    /// Defaults to asking, with "fail the node" when nobody can answer.
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
        // `try?` on purpose: a policy shape from a newer build degrades to the default instead of making the whole layout
        // unreadable; `layoutBlobVersion` stops that build's save being overwritten.
        decisionPolicy = (try? c.decodeIfPresent(RouterDecisionPolicy.self, forKey: .decisionPolicy))
            ?? .ask(fallback: .failNode)
    }

    // MARK: - AI Classifier prompt

    // Why: a placeholder, not baked text: materialising the rules into the stored prompt would clobber user edits or go stale
    // as rules change.
    /// The placeholder that expands to this Router's rule labels at run time.
    static let rulesPlaceholder = "{{rules}}"

    /// The prompt a Router starts with when its AI Classifier is switched on. Fully editable — the
    /// user owns this text; only `{{rules}}` is substituted.
    static let defaultRoutingPrompt = """
        You are an intelligent router. Read the input and decide which ONE of these categories best         describes it:
        \(rulesPlaceholder)
        Answer with exactly one category.
        """

    /// The instruction actually sent to the model: the stored prompt with `{{rules}}` expanded. Uses rule labels only,
    /// never the opaque per-invocation tokens, which live in the system-owned `<labels>` block.
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

/// What a condition rule evaluates against. Raw-preserving: `.other(raw)` decodes any value and re-encodes it
/// verbatim, so an unknown value from a newer build survives a round trip. Consumers treat `.other` as inert: the
/// validator flags it, the engine never matches it, and `allCases` excludes it.
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

    // There is deliberately no "always matches" operator: a catch-all would match alongside every real rule and trigger
    // ambiguity on every input. Unmatched input is `decisionPolicy`'s job.

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

/// A deterministic action node that invokes a tool directly, with no LLM. It resolves each `argumentBindings`
/// template against upstream data (`{{ input }}`, `{{ input.json.x }}`, `{{ var.y }}`), invokes the tool and emits
/// its output and artifacts.
struct ActionNodeConfig: Codable, Hashable, Sendable {
    /// The selected tool reference (native or MCP), or nil when unconfigured. Uses the same `Tool` type profiles persist,
    /// including a snapshot of its `parameters` schema for the inspector.
    var tool: Tool? = nil

    /// Maps each tool-argument name to a template string resolved at run time, e.g. `["url": "https://hooks.example.com",
    /// "body": "{{ input }}"]`. Only bound arguments are sent; an unbound required argument surfaces as a tool-decode
    /// failure.
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

    /// Hard timeout override for this node. If nil (or 0 / negative), the node uses its profile's `executionTimeout`,
    /// then the workflow's `nodeTimeout`; an enclosing scheduled run can shorten it (`ExecutionBudget`).
    var hardTimeout: TimeInterval? = nil

    /// Explicit unattended approval: when true, tool confirmations raised by this node in a run nobody can answer (a
    /// scheduled fire) are auto-approved; nil = false. A ChatOps run is not covered because a human is reachable there.
    /// Read only on the profile-node and Action-node paths; sub-workflow nodes never read it.
    var unattendedAutoApprove: Bool? = nil
}

// MARK: - WorkflowNodeConfig Codable
// `decodeIfPresent` with the property defaults, so a config with only some keys loads with the rest at defaults.
// Declared in an extension so the memberwise initializer is preserved.
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
                // An unrecognized case name (from a newer build) becomes a preserved placeholder instead of failing the node array.
                // A known case whose payload fails to decode is corruption, not version skew, and rethrows.
                kind = .unsupported(raw: raw)
            } else {
                // Either not valid JSON under the key, or a known case whose payload failed to decode: real corruption, surfaced by
                // the unreadable-layout machinery.
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
        // An unsupported node re-encodes its original kind JSON, not the placeholder wrapper, so the literal case name
        // `unsupported` never reaches a blob.
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

    // Why: one definition shared by `WorkflowCanvasState.outputPortLabels` and `WorkflowState.edgeIsLive`: a port the engine
    // activates but the canvas never renders is unwireable.
    /// The reserved failure port label; also a reserved user-facing label (a rule or Gate option named "error" collides,
    /// and the validator warns).
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

    /// The one size a sticky note may shrink to, in canvas points. The resize preview and
    /// `WorkflowCanvasState.resizeStickyNote`'s clamp both read it; 120 fits the header's ~114pt colour-swatch row.
    static let minimumSize = CGSize(width: 120, height: 80)

    /// The size a resize drag of `translation` from `base` resolves to; the only resize arithmetic. Pure and nonisolated
    /// so the floor can be tested.
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

    /// Groups nodes into dependency levels for parallel execution: level 0 is entry nodes, level N has all upstream
    /// dependencies in levels 0..N-1. Returns `nil` if the graph has a cycle.
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
