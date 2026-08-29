//
//  WorkflowTestBuilders.swift
//  DevgenticTests
//
//  Fluent builder for constructing WorkflowLayout + profile maps
//  for integration tests. Avoids verbose manual construction.
//

import Foundation
@testable import devgentic

/// Builds a complete test scenario: layout (nodes + edges) and profile map.
final class WorkflowTestScenario {

    private(set) var nodes: [WorkflowNode] = []
    private(set) var edges: [WorkflowEdge] = []
    var profileMap: [UUID: BackendProfileModel] = [:]

    /// The assembled layout (call after building all nodes/edges).
    var layout: WorkflowLayout {
        WorkflowLayout(nodes: nodes, edges: edges, annotations: [])
    }

    // MARK: - Profile Node Builders

    /// Adds a bot node and returns its node UUID.
    ///
    /// ⚠️ WF-CC2: `apiProvider`/`modelName` are INERT for execution — `MockWorkflowStreamProvider`
    /// keys on `profile.id` and never reads `details`, so an `.mlx` profile here reaches the
    /// WF-CC2 dispatch decision (`WorkflowExecutor.profileDispatchLanes`) and NOTHING else: no
    /// MLXService, no MLXModelService, no model load, no disk. That is what lets the lane tests
    /// stay hermetic. Do not "simplify" these back to a hardcoded `.ollama`.
    @discardableResult
    func addBotNode(name: String,
                    apiProvider: ApiProvider = .ollama,
                    modelName: String = "test-model",
                    position: CGPoint = .zero) -> UUID {
        let profileID = UUID()
        let nodeID = UUID()

        let profile = BackendProfileSnapshot(
            id: profileID,
            displayName: name,
            details: .bot(BotConfig(
                llmConfig: ProviderConfig(apiProvider: apiProvider, modelName: modelName)
            ))
        )
        profileMap[profileID] = profile

        var node = WorkflowNode(
            id: nodeID,
            kind: .profile(profileID: profileID, profileType: .bot),
            position: position,
            displayName: name
        )
        // Profile nodes require a non-empty task description, or workflow pre-flight
        // validation fails the run with `.validationFailed`. Tests don't assert on
        // it (mock streams are scripted by profile ID), so a generic default keeps
        // `executeWorkflow` from throwing before any node runs.
        node.nodeConfig = WorkflowNodeConfig(taskDescription: "Respond to the input.")
        nodes.append(node)
        return nodeID
    }

    /// Adds a node backed by a *workflow* profile — a nested sub-workflow step.
    ///
    /// Deliberately leaves `nodeConfig` nil (no task description): a sub-workflow node takes its
    /// directive from upstream output, and `WorkflowValidator` exempts it for that reason. Tests
    /// that pass a description explicitly can still do so; the default is the shape that used to
    /// brick the whole workflow.
    @discardableResult
    func addSubWorkflowNode(
        name: String,
        workflowProfileID: UUID,
        taskDescription: String? = nil,
        position: CGPoint = .zero
    ) -> UUID {
        let nodeID = UUID()

        // The dispatch loop resolves every profile node against the profile map before it can
        // run, sub-workflow nodes included, so the child workflow's own profile must be present.
        profileMap[workflowProfileID] = BackendProfileSnapshot(
            id: workflowProfileID,
            displayName: name,
            details: .workflow(WorkflowConfig(agentProfileIDs: []))
        )

        var node = WorkflowNode(
            id: nodeID,
            kind: .profile(profileID: workflowProfileID, profileType: .workflow),
            position: position,
            displayName: name
        )
        if let taskDescription {
            node.nodeConfig = WorkflowNodeConfig(taskDescription: taskDescription)
        }
        nodes.append(node)
        return nodeID
    }

    /// Adds an Action node bound to a tool by name — the deterministic, no-LLM node kind.
    ///
    /// Pair with `MockWorkflowStreamProvider.scriptTool(name:output:)`, which the executor
    /// resolves through `resolveWorkflowTool`.
    @discardableResult
    func addActionNode(
        name: String,
        toolName: String,
        argumentBindings: [String: String] = [:],
        requiresConfirmation: Bool = false,
        sourceId: UUID = ToolSource.builtInSourceID,
        onFailure: NodeFailurePolicy? = nil,
        unattendedAutoApprove: Bool? = nil,
        position: CGPoint = .zero
    ) -> UUID {
        let nodeID = UUID()
        let tool = Tool(
            name: toolName,
            description: "Tool bound to Action node \(name)",
            isEnabled: true,
            requiresConfirmation: requiresConfirmation,
            sourceId: sourceId,
            parameters: ToolParameters(type: "object", properties: [:], required: [])
        )
        var node = WorkflowNode(
            id: nodeID,
            kind: .action(ActionNodeConfig(tool: tool, argumentBindings: argumentBindings)),
            position: position,
            displayName: name
        )
        if let onFailure {
            node.nodeConfig = WorkflowNodeConfig(onFailure: onFailure)
        }
        if let unattendedAutoApprove {
            if node.nodeConfig == nil { node.nodeConfig = WorkflowNodeConfig() }
            node.nodeConfig?.unattendedAutoApprove = unattendedAutoApprove
        }
        nodes.append(node)
        return nodeID
    }

    /// Returns the profile UUID for a node (for scripting mock streams).
    func profileID(for nodeID: UUID) -> UUID? {
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return nil }
        return node.profileID
    }

    // MARK: - Structural Node Builders

    /// Full-config overload — for tests that need to set classifier fields, which the
    /// convenience builder below deliberately does not expose.
    @discardableResult
    func addConditionNode(name: String, config: ConditionNodeConfig, position: CGPoint = .zero) -> UUID {
        let nodeID = UUID()
        nodes.append(WorkflowNode(id: nodeID, kind: .condition(config), position: position, displayName: name))
        return nodeID
    }

    /// Adds a condition node with pattern-matching rules.
    @discardableResult
    func addConditionNode(
        name: String,
        rules: [ConditionRule] = [
            ConditionRule(label: "True", field: .upstreamOutput, op: .isNotEmpty, value: ""),
            ConditionRule(label: "False", field: .upstreamOutput, op: .isEmpty, value: "")
        ],
        fallbackLabel: String = "False",
        position: CGPoint = .zero
    ) -> UUID {
        let nodeID = UUID()
        var config = ConditionNodeConfig()
        // Production validation requires ≥2 rules and that `fallbackLabel` names a
        // real rule (the canvas exposes one output port per rule). When a test models
        // a "match → A, else → B" router as a single rule + a distinct fallback,
        // materialize the else-branch as a real never-matching rule so the layout is
        // valid. Runtime routing is unchanged — the executor still activates the
        // fallback port when no user rule matches (`matchedLabel ?? fallbackLabel`).
        var effectiveRules = rules
        if !fallbackLabel.isEmpty, !effectiveRules.contains(where: { $0.label == fallbackLabel }) {
            effectiveRules.append(ConditionRule(
                label: fallbackLabel,
                field: .upstreamOutput,
                op: .equals,
                value: "__wf_test_fallback_never_matches__"
            ))
        }
        config.rules = effectiveRules
        config.fallbackLabel = fallbackLabel

        let node = WorkflowNode(
            id: nodeID,
            kind: .condition(config),
            position: position,
            displayName: name
        )
        nodes.append(node)
        return nodeID
    }

    /// Adds a code transform node.
    @discardableResult
    func addCodeNode(
        name: String,
        template: String = "{{ input }}",
        outputVariable: String? = nil,
        position: CGPoint = .zero
    ) -> UUID {
        let nodeID = UUID()
        let config = CodeNodeConfig(template: template, outputVariable: outputVariable)

        let node = WorkflowNode(
            id: nodeID,
            kind: .code(config),
            position: position,
            displayName: name
        )
        nodes.append(node)
        return nodeID
    }

    /// Adds a HITL gate node.
    @discardableResult
    func addGateNode(
        name: String,
        prompt: String = "Approve?",
        options: [String] = ["Approve", "Reject"],
        timeout: TimeInterval? = nil,
        position: CGPoint = .zero
    ) -> UUID {
        let nodeID = UUID()
        let config = GateNodeConfig(prompt: prompt, options: options, timeout: timeout)

        let node = WorkflowNode(
            id: nodeID,
            kind: .gate(config),
            position: position,
            displayName: name
        )
        nodes.append(node)
        return nodeID
    }

    /// Adds a trigger (entry-point) node.
    @discardableResult
    func addTriggerNode(name: String = "Trigger", position: CGPoint = .zero) -> UUID {
        let nodeID = UUID()
        let node = WorkflowNode(
            id: nodeID,
            kind: .trigger(TriggerNodeConfig()),
            position: position,
            displayName: name
        )
        nodes.append(node)
        return nodeID
    }

    // MARK: - Edges

    /// Connects two nodes. Use `portLabel` for condition/error routing.
    func connect(from sourceID: UUID, to targetID: UUID, portLabel: String? = nil) {
        let edge = WorkflowEdge(
            sourceNodeID: sourceID,
            targetNodeID: targetID,
            sourcePortLabel: portLabel
        )
        edges.append(edge)
    }

    // MARK: - Node Configuration

    /// Sets per-node execution config (failure policy, retries, timeout).
    func setNodeConfig(_ config: WorkflowNodeConfig, for nodeID: UUID) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var cfg = config
        // Preserve the node's existing task description when the override doesn't
        // set one. Profile nodes require a non-empty taskDescription for pre-flight
        // validation, and most callers only mean to tweak failure/retry policy.
        if cfg.taskDescription.isEmpty,
           let existing = nodes[index].nodeConfig?.taskDescription, !existing.isEmpty {
            cfg.taskDescription = existing
        }
        nodes[index].nodeConfig = cfg
    }

    /// Sets the per-node task description for workflow execution.
    func setTaskDescription(_ description: String, for nodeID: UUID) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        if nodes[index].nodeConfig == nil {
            nodes[index].nodeConfig = WorkflowNodeConfig()
        }
        nodes[index].nodeConfig?.taskDescription = description
    }
}

// MARK: - Inner Workflow Builder (for sub-workflow bodies)

/// Builds an inner workflow layout for sub-workflow testing.
/// Saves to WorkflowLayoutStore and cleans up on deinit.
final class InnerWorkflowBuilder {
    let workflowProfileID: UUID
    private var scenario: WorkflowTestScenario

    init(workflowProfileID: UUID = UUID()) {
        self.workflowProfileID = workflowProfileID
        self.scenario = WorkflowTestScenario()
    }

    /// Adds a bot node to the inner workflow. Returns the node UUID.
    @discardableResult
    func addBotNode(name: String) -> UUID {
        scenario.addBotNode(name: name)
    }

    /// Adds a code node to the inner workflow.
    @discardableResult
    func addCodeNode(name: String, template: String = "{{ input }}", outputVariable: String? = nil) -> UUID {
        scenario.addCodeNode(name: name, template: template, outputVariable: outputVariable)
    }

    /// Adds a Gate node to the inner workflow.
    ///
    /// ⚠️ Added when the Loop node was retired (2026-08-15): `LoopHITLForwardingTests` was the only
    /// pin on child-stream HITL forwarding, and without an inner-gate builder no test could put a
    /// suspending node inside a sub-workflow body at all — a swallowed suspending event is a
    /// PERMANENT hang (no banner, nobody to answer, and the compute clock excludes parked time so
    /// not even the node timeout fires).
    @discardableResult
    func addGateNode(name: String, options: [String] = ["Approve", "Reject"], timeout: TimeInterval? = nil) -> UUID {
        scenario.addGateNode(name: name, options: options, timeout: timeout)
    }

    /// Connects two nodes in the inner workflow.
    func connect(from sourceID: UUID, to targetID: UUID, portLabel: String? = nil) {
        scenario.connect(from: sourceID, to: targetID, portLabel: portLabel)
    }

    /// Returns the profile UUID for a node (for scripting mock streams).
    func profileID(for nodeID: UUID) -> UUID? {
        scenario.profileID(for: nodeID)
    }

    /// All profiles from the inner workflow (merge into outer scenario's profileMap).
    var profileMap: [UUID: BackendProfileModel] { scenario.profileMap }

    /// Saves the inner layout to WorkflowLayoutStore and returns the layout.
    /// `@MainActor` because `WorkflowLayoutStore` is main-actor isolated; the test
    /// class is `@MainActor` too, so callers invoke this synchronously.
    @MainActor
    @discardableResult
    func save() -> WorkflowLayout {
        let layout = scenario.layout
        WorkflowLayoutStore.shared.save(layout, for: workflowProfileID)
        return layout
    }

    /// Removes the inner layout from WorkflowLayoutStore.
    @MainActor
    func cleanup() {
        WorkflowLayoutStore.shared.delete(for: workflowProfileID)
    }
}
