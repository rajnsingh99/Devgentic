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

    /// Conditional branch (IF/ELSE) — routes to different outputs based on upstream results.
    case condition(ConditionNodeConfig)

    /// Loop/iteration — re-enters a subgraph until an exit condition is met.
    case loop(LoopNodeConfig)

    /// Code/transform — deterministic non-LLM processing (regex, JSON, format).
    case code(CodeNodeConfig)

    /// HITL gate — suspends execution and waits for user approval.
    case gate(GateNodeConfig)

    /// Trigger — starts workflow execution (webhook, schedule, manual).
    case trigger(TriggerNodeConfig)
}

// MARK: - Node Kind Configs

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

    /// When true, downstream nodes receive the full upstream content.
    /// When false, they receive only the routing label (e.g. "Condition (pattern): route -> True").
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

    /// Label for the catch-all route. Must be one of the rule labels (enforced by picker).
    var fallbackLabel: String = "False"

    /// Default initializer — all properties use their declared defaults.
    init() {}

    // MARK: Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case rules, llmFallbackEnabled, llmPrompt, llmPortLabels, llmModelName
        case fallbackLabel, passthroughContent
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

        // Ensure fallbackLabel is one of the rule labels (fix legacy configs)
        if !rules.contains(where: { $0.label == fallbackLabel }) {
            fallbackLabel = rules.last?.label ?? "False"
        }
    }

    /// All output port labels — derived solely from pattern rule labels.
    /// The AI Classifier and static fallback route to these same ports.
    var outputPortLabels: [String] {
        var labels = rules.map(\.label)
        // Guard against legacy configs where fallback might not be in rules
        if !labels.contains(fallbackLabel) {
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
enum ConditionField: String, Codable, Hashable, Sendable, CaseIterable {
    case upstreamOutput     // Concatenated text output of upstream nodes
    case variable           // A shared workflow variable by name
}

/// How a condition rule evaluates its field.
enum ConditionOp: String, Codable, Hashable, Sendable, CaseIterable {
    case contains
    case notContains
    case equals
    case notEquals
    case isEmpty
    case isNotEmpty

    var displayName: String {
        switch self {
        case .contains: return "contains"
        case .notContains: return "does not contain"
        case .equals: return "equals"
        case .notEquals: return "does not equal"
        case .isEmpty: return "is empty"
        case .isNotEmpty: return "is not empty"
        }
    }
}
struct LoopNodeConfig: Codable, Hashable, Sendable {
    /// The workflow profile ID to execute as the loop body.
    var bodyWorkflowID: UUID? = nil

    /// Cached display name of the body workflow (for canvas subtitle).
    var bodyWorkflowName: String? = nil

    /// Maximum number of iterations (clamped 1–50 at execution time). Default: 3.
    var maxIterations: Int = 3

    /// Optional early-exit condition evaluated after each iteration.
    /// When the condition matches, the loop exits before reaching maxIterations.
    var exitCondition: ConditionRule? = nil

    /// Human-readable summary for the canvas subtitle.
    var subtitle: String {
        let bodyLabel = bodyWorkflowName ?? "No body set"
        if let exit = exitCondition {
            return "\(maxIterations) max | \(bodyLabel) | exit: \(exit.op.displayName)"
        }
        return "\(maxIterations) iters | \(bodyLabel)"
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
    /// Approval options displayed as buttons.
    var options: [String] = ["Approve", "Reject"]
    /// Timeout in seconds before auto-rejecting. Nil = default (300s).
    var timeout: TimeInterval? = nil
}

struct TriggerNodeConfig: Codable, Hashable, Sendable { }

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

    /// Per-node task description for workflow execution.
    /// Defines WHAT this node should do with upstream input — independent of the profile's persona.
    /// Empty string = no explicit task; the node relies solely on its profile system instructions.
    var taskDescription: String = ""
}

/// Cascade policy when a workflow node fails.
enum NodeFailurePolicy: String, Codable, Hashable, Sendable {
    /// Skip all downstream dependent nodes (default — current behavior).
    case skipDependents

    /// Halt the entire workflow immediately.
    case stopWorkflow

    /// Continue executing all remaining nodes regardless of this failure.
    case continueAll
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

        // Try new `kind` field first; fall back to legacy profileID + profileType
        if let decodedKind = try? container.decode(WorkflowNodeKind.self, forKey: .kind) {
            kind = decodedKind
        } else {
            let legacyProfileID = try container.decode(UUID.self, forKey: .profileID)
            let legacyProfileType = try container.decode(ProfileType.self, forKey: .profileType)
            kind = .profile(profileID: legacyProfileID, profileType: legacyProfileType)
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
        try container.encode(kind, forKey: .kind)
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

enum StickyNoteColor: String, Codable, Hashable, CaseIterable {
    case yellow, blue, green, pink, purple

    var swiftUIColor: Color {
        switch self {
        case .yellow: return .yellow
        case .blue:   return .blue
        case .green:  return .green
        case .pink:   return .pink
        case .purple: return .purple
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
