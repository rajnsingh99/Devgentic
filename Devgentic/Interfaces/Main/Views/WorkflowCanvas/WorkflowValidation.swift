//
//  WorkflowValidation.swift
//  Devgentic
//
//  Created by Raj Singh on 13/04/26.
//
//  Pure validation system for workflow configurations.
//  Scans all nodes for configuration issues and returns actionable results.
//  The validator is a stateless pure function — O(n+e) on layout size, safe to
//  call on every canvas change without debouncing.
//

import Foundation

// MARK: - Validation Issue

/// A single configuration issue found during workflow validation.
struct WorkflowValidationIssue: Identifiable, Hashable, Sendable {
    let id: UUID
    /// The node that has the issue. Nil for workflow-level issues.
    let nodeID: UUID?
    /// Display name of the node (or "Workflow" for workflow-level).
    let nodeName: String
    /// Error = blocks execution. Warning = informational, execution allowed.
    let severity: Severity
    /// Human-readable description of the issue.
    let message: String

    enum Severity: String, Sendable, Comparable, Hashable {
        case error
        case warning

        // Errors sort before warnings
        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs == .error && rhs == .warning
        }
    }

    init(nodeID: UUID? = nil, nodeName: String, severity: Severity, message: String) {
        self.id = UUID()
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.severity = severity
        self.message = message
    }
}

// MARK: - Validator

/// Pure validation function for workflow layouts.
/// No side effects, no singletons, no async — fully testable in isolation.
enum WorkflowValidator {

    /// Validates a workflow layout and returns all configuration issues.
    /// - Parameters:
    ///   - layout: The workflow's node/edge graph.
    ///   - profileMap: Available profiles keyed by UUID (for checking profile existence).
    /// - Returns: Issues sorted by severity (errors first), then by layout order.
    static func validate(
        layout: WorkflowLayout,
        profileMap: [UUID: BackendProfileModel]
    ) -> [WorkflowValidationIssue] {
        var issues: [WorkflowValidationIssue] = []

        // --- Workflow-Level Checks ---

        if layout.nodes.isEmpty {
            issues.append(WorkflowValidationIssue(
                nodeName: "Workflow",
                severity: .error,
                message: "Workflow has no nodes. Add profiles to the canvas."
            ))
            return issues // No point checking nodes if there are none
        }

        // Disconnected nodes (no incoming or outgoing edges)
        let connectedNodeIDs = Set(layout.edges.map(\.sourceNodeID)).union(Set(layout.edges.map(\.targetNodeID)))
        for node in layout.nodes {
            if !connectedNodeIDs.contains(node.id) && layout.nodes.count > 1 {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .warning,
                    message: "Node is disconnected — no edges to or from other nodes."
                ))
            }
        }

        // --- Per-Node Checks ---

        for node in layout.nodes {
            switch node.kind {
            case .profile(let profileID, _):
                validateProfileNode(node: node, profileID: profileID, profileMap: profileMap, issues: &issues)

            case .condition(let config):
                validateConditionNode(node: node, config: config, issues: &issues)

            case .loop(let config):
                validateLoopNode(node: node, config: config, issues: &issues)

            case .gate(let config):
                validateGateNode(node: node, config: config, issues: &issues)

            case .code(let config):
                validateCodeNode(node: node, config: config, issues: &issues)

            case .trigger:
                break // Trigger nodes have no user-configurable fields to validate
            }
        }

        // Sort: errors first, then warnings, preserving layout order within each group
        return issues.sorted { $0.severity < $1.severity }
    }

    // MARK: - Profile Node

    private static func validateProfileNode(
        node: WorkflowNode,
        profileID: UUID,
        profileMap: [UUID: BackendProfileModel],
        issues: inout [WorkflowValidationIssue]
    ) {
        // Profile existence check
        if profileMap[profileID] == nil {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "Profile not found — it may have been deleted."
            ))
        }

        // Task description is mandatory for workflow execution
        let taskDescription = node.nodeConfig?.taskDescription ?? ""
        if taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "Task description is required. Double-click to configure."
            ))
        }
    }

    // MARK: - Condition Node

    private static func validateConditionNode(
        node: WorkflowNode,
        config: ConditionNodeConfig,
        issues: inout [WorkflowValidationIssue]
    ) {
        // Rule count
        if config.rules.count < ConditionNodeConfig.minRules {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "Requires at least \(ConditionNodeConfig.minRules) pattern rules."
            ))
        }

        // Per-rule validation
        var seenLabels = Set<String>()
        for rule in config.rules {
            // Label validity
            if !ConditionNodeConfig.isValidLabel(rule.label) {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .error,
                    message: "Rule label '\(rule.label)' is invalid (alphanumeric, max 10 chars)."
                ))
            }

            // Duplicate labels
            if seenLabels.contains(rule.label) {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .error,
                    message: "Duplicate rule label '\(rule.label)'."
                ))
            }
            seenLabels.insert(rule.label)

            // Empty match value for value-requiring operators
            let requiresValue: Bool = {
                switch rule.op {
                case .contains, .notContains, .equals, .notEquals: return true
                case .isEmpty, .isNotEmpty: return false
                }
            }()
            if requiresValue && rule.value.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .error,
                    message: "Rule '\(rule.label)' requires a match value for '\(rule.op.displayName)'."
                ))
            }
        }

        // AI Classifier checks
        if config.llmFallbackEnabled {
            if config.llmModelName == nil || config.llmModelName?.isEmpty == true {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .error,
                    message: "AI Classifier enabled but no MLX model selected."
                ))
            }
            if config.llmPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .warning,
                    message: "AI Classifier enabled but routing prompt is empty."
                ))
            }
        }
    }

    // MARK: - Loop Node

    private static func validateLoopNode(
        node: WorkflowNode,
        config: LoopNodeConfig,
        issues: inout [WorkflowValidationIssue]
    ) {
        if config.bodyWorkflowID == nil {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "No body workflow selected. Double-click to configure."
            ))
        }
    }

    // MARK: - Gate Node

    private static func validateGateNode(
        node: WorkflowNode,
        config: GateNodeConfig,
        issues: inout [WorkflowValidationIssue]
    ) {
        if config.options.filter({ !$0.isEmpty }).count < 2 {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "Gate requires at least 2 options."
            ))
        }
        if config.prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .warning,
                message: "Gate prompt is empty — users won't know what to approve."
            ))
        }
    }

    // MARK: - Code Node

    private static func validateCodeNode(
        node: WorkflowNode,
        config: CodeNodeConfig,
        issues: inout [WorkflowValidationIssue]
    ) {
        if config.template.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .warning,
                message: "Code template is empty — node will produce no output."
            ))
        }
    }
}
