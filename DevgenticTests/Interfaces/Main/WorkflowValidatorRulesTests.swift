// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowValidatorRulesTests.swift
//  DevgenticTests
//
//  Register WF-VA6 — the run-blocking half of the validator was untested — plus regression cover
//  for the 2026-08-15 fixes: sub-workflow nesting (WF-VA1 ≡ WF-NS5 ≡ WF-SE4, originally found via
//  the since-retired Loop node's bodies), empty sub-workflow targets (WF-VA3), and the
//  variable-rule lints (WF-VA4, WF-VA5).
//
//  ⚠️ Why error-severity coverage matters more than warning coverage: an error BLOCKS the run at
//  the executor's pre-flight before any node executes. A refactor that makes an error rule fire
//  wrongly bricks every affected workflow, silently, with CI green — the inverse failure (a rule
//  that stops firing) is merely a run-time surprise. Each error rule therefore gets a positive AND
//  a negative case: the positive proves it fires, the negative proves it does not fire on a valid
//  graph (a rule that flags everything passes every positive-only test).
//
//  Pure sync — direct WorkflowNode/WorkflowLayout construction, no ML loads, no store.
//

import XCTest
@testable import devgentic

final class WorkflowValidatorRulesTests: XCTestCase {

    // MARK: - Fixtures

    private func rule(_ label: String, field: ConditionField = .upstreamOutput,
                      op: ConditionOp = .contains, value: String = "x",
                      variableName: String? = nil) -> ConditionRule {
        ConditionRule(label: label, field: field, op: op, value: value, variableName: variableName)
    }

    private func conditionNode(rules: [ConditionRule], name: String = "Router") -> WorkflowNode {
        var config = ConditionNodeConfig()
        config.rules = rules
        return WorkflowNode(kind: .condition(config), position: .zero, displayName: name)
    }

    private func codeNode(template: String = "{{ input }}", writes variable: String? = nil,
                          name: String = "Code") -> WorkflowNode {
        var config = CodeNodeConfig()
        config.template = template
        config.outputVariable = variable
        return WorkflowNode(kind: .code(config), position: .zero, displayName: name)
    }

    private func subWorkflowNode(_ workflowID: UUID, name: String = "Nested") -> WorkflowNode {
        WorkflowNode(kind: .profile(profileID: workflowID, profileType: .workflow),
                     position: .zero, displayName: name)
    }

    /// A chain layout: each listed node wired to the next, so no disconnected-node noise.
    private func layout(_ nodes: [WorkflowNode]) -> WorkflowLayout {
        var edges: [WorkflowEdge] = []
        for i in 0..<(max(nodes.count, 1) - 1) {
            edges.append(WorkflowEdge(sourceNodeID: nodes[i].id, targetNodeID: nodes[i + 1].id, sourcePortLabel: nil))
        }
        return WorkflowLayout(nodes: nodes, edges: edges, annotations: [])
    }

    private func validate(_ layout: WorkflowLayout,
                          subs: [UUID: WorkflowLayout] = [:],
                          profiles: [UUID: BackendProfileModel] = [:],
                          sources: [ToolSource] = [],
                          root: UUID? = nil) -> [WorkflowValidationIssue] {
        WorkflowValidator.validate(layout: layout, profileMap: profiles,
                                   availableToolSources: sources,
                                   subWorkflowLayouts: subs, rootProfileID: root)
    }

    /// A minimal workflow profile entry so a `.profile(_, .workflow)` node passes the
    /// profile-exists check. ⚠️ Needed since the nesting tests moved off the Loop node (which had
    /// no profileID and so never touched the map): a sub-workflow node without its profile in the
    /// map fails validation with "Profile not found" BEFORE any nesting rule is reached, which
    /// would mask the rule a control test exists to clear.
    private func workflowProfile(_ id: UUID, name: String = "Nested") -> (UUID, BackendProfileModel) {
        (id, BackendProfileSnapshot(id: id, displayName: name,
                                    details: .workflow(WorkflowConfig())))
    }

    private func errors(_ issues: [WorkflowValidationIssue], containing text: String) -> [WorkflowValidationIssue] {
        issues.filter { $0.severity == .error && $0.message.contains(text) }
    }

    private func warnings(_ issues: [WorkflowValidationIssue], containing text: String) -> [WorkflowValidationIssue] {
        issues.filter { $0.severity == .warning && $0.message.contains(text) }
    }

    /// A minimal body layout with one node, so a referenced workflow is non-empty.
    private var nonEmptyBody: WorkflowLayout {
        WorkflowLayout(nodes: [codeNode(name: "BodyStep")], edges: [], annotations: [])
    }

    // MARK: - Workflow-level error rules

    func testEmptyLayoutIsAnError() {
        let issues = validate(WorkflowLayout(nodes: [], edges: [], annotations: []))
        XCTAssertEqual(errors(issues, containing: "no nodes").count, 1)
    }

    func testSameLevelOutputVariableCollisionIsAnError() {
        // Two Code nodes on the SAME level (both entry nodes) writing one variable race.
        let a = codeNode(writes: "shared", name: "A")
        let b = codeNode(writes: "shared", name: "B")
        let sink = codeNode(name: "Sink")
        let l = WorkflowLayout(
            nodes: [a, b, sink],
            edges: [WorkflowEdge(sourceNodeID: a.id, targetNodeID: sink.id, sourcePortLabel: nil),
                    WorkflowEdge(sourceNodeID: b.id, targetNodeID: sink.id, sourcePortLabel: nil)],
            annotations: []
        )
        XCTAssertEqual(errors(validate(l), containing: "also written by").count, 2,
                       "both racing writers are named")
    }

    func testSequentialWritersOfOneVariableAreNotFlagged() {
        // Same variable on DIFFERENT levels is deterministic (last write wins predictably).
        let issues = validate(layout([codeNode(writes: "shared", name: "A"),
                                      codeNode(writes: "shared", name: "B")]))
        XCTAssertTrue(errors(issues, containing: "also written by").isEmpty,
                      "sequential writes are legal — got: \(issues.map(\.message))")
    }

    /// ⚠️ Matched on the ACTIONABLE half of the message, not on "may have been deleted". That
    /// wording was retired 2026-08-29: with node-owned configuration the remedy changed from a dead
    /// end into something the user can perform, and the message now says so.
    func testProfileNodeWithUnknownProfileIsAnError() {
        let orphan = WorkflowNode(profileID: UUID(), position: .zero,
                                  displayName: "Ghost", profileType: .agent)
        let issues = validate(layout([orphan, codeNode()]))
        XCTAssertEqual(errors(issues, containing: "add the node again").count, 1)
    }

    /// ⚠️ The message is SHARED with `ProfileNodeInspectorView`'s card, so the two surfaces cannot
    /// describe what looks like two different problems. Asserted against the constant rather than a
    /// literal — a test that restates the string would stay green through a reword that broke the
    /// sharing, which is the exact shape of weak test this repo's 2026-08-03 remediation pass was
    /// about.
    /// ⚠️ A dangling SUB-WORKFLOW node must NOT be told to delete and re-add itself. Its
    /// `profileID` is the only surviving record of which child workflow that step ran, and
    /// re-adding is impossible once the child is gone. The validator gave every kind the same
    /// advice until 2026-08-30, contradicting both its own doc and the node inspector.
    func testADanglingSubWorkflowNodeGetsItsOwnRemedy() {
        let sub = WorkflowNode(profileID: UUID(), position: .zero,
                               displayName: "Nested", profileType: .workflow)
        let issues = validate(layout([sub, codeNode()]))

        let issue = issues.first { $0.nodeID == sub.id && $0.severity == .error }
        XCTAssertEqual(issue?.message, WorkflowValidator.missingWorkflowMessage,
                       "got: \(String(describing: issue?.message))")
        XCTAssertFalse(issue?.message.contains("add the node again") ?? true,
                       "deleting and re-adding destroys the only record of which child ran")
    }

    /// The control: a bot/agent node still gets the re-add remedy, which genuinely repairs it.
    func testADanglingAgentNodeStillGetsTheReAddRemedy() {
        let agent = WorkflowNode(profileID: UUID(), position: .zero,
                                 displayName: "Ghost", profileType: .agent)
        let issues = validate(layout([agent, codeNode()]))

        XCTAssertEqual(issues.first { $0.nodeID == agent.id && $0.severity == .error }?.message,
                       WorkflowValidator.missingConfigurationMessage)
    }

    func testTheMissingConfigurationIssueUsesTheSharedMessage() {
        let orphan = WorkflowNode(profileID: UUID(), position: .zero,
                                  displayName: "Ghost", profileType: .agent)
        let issues = validate(layout([orphan, codeNode()]))

        XCTAssertTrue(issues.contains { $0.message == WorkflowValidator.missingConfigurationMessage },
                      "got: \(issues.map(\.message))")
        XCTAssertTrue(WorkflowValidator.missingConfigurationMessage.contains("add the node again"),
                      "the shared sentence must keep naming a remedy the user can perform")
    }

    // MARK: - Router (condition) error rules

    func testTooFewRulesIsAnError() {
        let issues = validate(layout([conditionNode(rules: [rule("Only")]), codeNode()]))
        XCTAssertFalse(errors(issues, containing: "at least").isEmpty)
    }

    func testInvalidRuleLabelIsAnError() {
        let issues = validate(layout([conditionNode(rules: [rule("has space"), rule("Fine")]), codeNode()]))
        XCTAssertEqual(errors(issues, containing: "invalid").count, 1)
    }

    func testDuplicateRuleLabelIsAnError() {
        let issues = validate(layout([conditionNode(rules: [rule("Same"), rule("Same")]), codeNode()]))
        XCTAssertEqual(errors(issues, containing: "Duplicate rule label").count, 1)
    }

    func testValueRequiringOperatorWithEmptyValueIsAnError() {
        let issues = validate(layout([conditionNode(rules: [rule("A", value: ""), rule("B")]), codeNode()]))
        XCTAssertEqual(errors(issues, containing: "requires a match value").count, 1)
    }

    func testValidRouterProducesNoRuleErrors() {
        let issues = validate(layout([conditionNode(rules: [rule("Bug"), rule("Feature")]), codeNode()]))
        XCTAssertTrue(issues.filter { $0.severity == .error }.isEmpty,
                      "a well-formed Router must not be blocked — got: \(issues.map(\.message))")
    }

    // MARK: - Variable lints (WF-VA5)

    func testVariableRuleWithBlankNameIsAnError() {
        let r = rule("V", field: .variable, op: .equals, value: "DONE", variableName: "  ")
        let issues = validate(layout([conditionNode(rules: [r, rule("B")]), codeNode()]))
        XCTAssertEqual(errors(issues, containing: "no variable name is set").count, 1)
    }

    func testVariableRuleOnAnUnwrittenVariableIsAWarning() {
        let r = rule("V", field: .variable, op: .equals, value: "DONE", variableName: "status")
        let issues = validate(layout([conditionNode(rules: [r, rule("B")]), codeNode()]))
        let hits = warnings(issues, containing: "no Code node on this canvas writes it")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(errors(issues, containing: "no Code node").isEmpty,
                      "unwritten is a WARNING — the graph still runs")
    }

    func testVariableRuleOnAWrittenVariableIsClean() {
        let writer = codeNode(writes: "status", name: "Writer")
        let r = rule("V", field: .variable, op: .equals, value: "DONE", variableName: "status")
        let issues = validate(layout([writer, conditionNode(rules: [r, rule("B")]), codeNode()]))
        XCTAssertTrue(issues.filter { $0.message.contains("status") && $0.nodeName == "Router" }.isEmpty,
                      "a written variable must not be flagged — got: \(issues.map(\.message))")
    }

    // MARK: - Gate / Code / Action rules

    func testGateWithFewerThanTwoOptionsIsAnError() {
        var config = GateNodeConfig()
        config.options = ["OnlyOne"]
        let gate = WorkflowNode(kind: .gate(config), position: .zero, displayName: "Gate")
        XCTAssertFalse(errors(validate(layout([gate, codeNode()])), containing: "at least 2").isEmpty)
    }

    func testGateDuplicateOptionsAreAWarningNotAnError() {
        var config = GateNodeConfig()
        config.options = ["Yes", "Yes"]
        let gate = WorkflowNode(kind: .gate(config), position: .zero, displayName: "Gate")
        let issues = validate(layout([gate, codeNode()]))
        XCTAssertEqual(warnings(issues, containing: "duplicate option labels").count, 1)
        XCTAssertTrue(errors(issues, containing: "duplicate option labels").isEmpty)
    }

    func testEmptyCodeTemplateIsAWarningNotAnError() {
        let issues = validate(layout([codeNode(template: "  "), codeNode(name: "Next")]))
        XCTAssertEqual(warnings(issues, containing: "template is empty").count, 1)
        XCTAssertTrue(errors(issues, containing: "template is empty").isEmpty,
                      "an empty template produces no output but must not block the run")
    }

    func testActionWithoutToolIsAnError() {
        let action = WorkflowNode(kind: .action(ActionNodeConfig()), position: .zero, displayName: "Call")
        XCTAssertEqual(errors(validate(layout([action, codeNode()])), containing: "no tool selected").count, 1)
    }

    // MARK: - Disabled MCP server (INS-1)

    private func mcpFixture(serverEnabled: Bool) -> (node: WorkflowNode, sources: [ToolSource]) {
        let sourceID = UUID()
        let tool = Tool(
            name: "post_message", description: "test tool", isEnabled: true,
            requiresConfirmation: true, sourceId: sourceID,
            parameters: ToolParameters(type: "object", properties: [:], required: [])
        )
        let source = ToolSource(
            id: sourceID, type: .mcp, serverName: "Slack",
            tools: [ToolDefinition(name: "post_message", description: "test tool",
                                   category: "mcp",
                                   parameters: ToolParameters(type: "object", properties: [:], required: []))],
            serverDefinition: nil, isEnabled: serverEnabled
        )
        let node = WorkflowNode(kind: .action(ActionNodeConfig(tool: tool)),
                                position: .zero, displayName: "Post")
        return (node, [source])
    }

    /// ⚠️ THE INS-1 PIN — the gap INSIDE the availability gap. A disabled server stays in the
    /// catalog WITH its tools (the Tool Library needs it visible to re-enable), so the membership
    /// test passed and no warning ever fired — while the executor's resolver refuses a disabled
    /// source by design and the node fails at run time, routed to its error port.
    func testActionToolOnDisabledServerWarns() {
        let (node, sources) = mcpFixture(serverEnabled: false)
        let issues = validate(layout([node, codeNode()]), sources: sources)
        XCTAssertEqual(warnings(issues, containing: "disabled MCP server").count, 1,
                       "a disabled server must surface at design time, not as a run-time node failure")
    }

    /// Control: the same tool on an ENABLED, present server raises nothing.
    func testActionToolOnEnabledServerDoesNotWarn() {
        let (node, sources) = mcpFixture(serverEnabled: true)
        let issues = validate(layout([node, codeNode()]), sources: sources)
        XCTAssertTrue(warnings(issues, containing: "disabled MCP server").isEmpty)
        XCTAssertTrue(warnings(issues, containing: "isn't currently available").isEmpty)
    }

    /// The pre-existing offline/absent arm must be unchanged by the disabled clause.
    func testActionToolOnAbsentServerStillWarnsUnavailable() {
        let (node, _) = mcpFixture(serverEnabled: true)
        let unrelated = ToolSource(id: UUID(), type: .mcp, serverName: "Other",
                                   tools: [], serverDefinition: nil, isEnabled: true)
        let issues = validate(layout([node, codeNode()]), sources: [unrelated])
        XCTAssertEqual(warnings(issues, containing: "isn't currently available").count, 1)
    }

    // MARK: - Built-in tool that needs setup (web_search)

    private func webSearchActionNode() -> WorkflowNode {
        let tool = Tool(
            name: "web_search", description: "test tool", isEnabled: true,
            requiresConfirmation: false, sourceId: ToolSource.builtInSourceID,
            parameters: ToolParameters(type: "object", properties: [:], required: [])
        )
        return WorkflowNode(kind: .action(ActionNodeConfig(tool: tool)), position: .zero, displayName: "Search")
    }

    /// An Action node embeds its own tool and never passes through a profile, so the Tool
    /// Library's block on enabling does not reach it. Unconfigured ⇒ a design-time warning; once
    /// configured ⇒ none. Uses the real `UserDefaults.standard` (the validator reads the live
    /// config), restored afterwards.
    func testActionToolThatNeedsSetupWarnsUntilConfigured() {
        let config = WebSearchConfig()
        let savedProvider = config.provider, savedURL = config.searxngURL
        addTeardownBlock { config.provider = savedProvider; config.searxngURL = savedURL }

        config.provider = .google
        WebSearchKeyStore.delete(for: .google)
        let node = webSearchActionNode()
        XCTAssertEqual(warnings(validate(layout([node, codeNode()])), containing: "needs setup").count, 1)

        config.provider = .searxng
        config.searxngURL = "http://localhost:8080"
        XCTAssertTrue(warnings(validate(layout([node, codeNode()])), containing: "needs setup").isEmpty)
    }

    // MARK: - Sub-workflow nesting (WF-VA1 ≡ WF-NS5 ≡ WF-SE4)
    // (Originally exercised through Loop bodies; rewritten onto sub-workflow nodes when the Loop
    //  was retired 2026-08-15. The RULES under test — the shared extractor, cycle detection, the
    //  depth limit, the legal-nesting control — are unchanged.)

    /// The one shared extractor is the fix's foundation — every workflow-referencing node kind
    /// must be collected here and only here.
    func testWorkflowReferencesCollectsSubWorkflowNodes() {
        let subID = UUID(), otherID = UUID()
        let l = WorkflowLayout(nodes: [subWorkflowNode(subID, name: "Sub"),
                                       subWorkflowNode(otherID, name: "Other"),
                                       codeNode()],
                               edges: [], annotations: [])

        let refs = WorkflowLayoutStore.workflowReferences(in: l)

        XCTAssertEqual(Set(refs.map(\.profileID)), [subID, otherID])
        XCTAssertEqual(Set(WorkflowLayoutStore.subWorkflowProfileIDs(in: l)), [subID, otherID],
                       "the legacy accessor must delegate, not re-implement")
    }

    /// A workflow that contains itself — the tightest recursion.
    func testSubWorkflowPointingAtOwnWorkflowIsACycleError() {
        let rootID = UUID()
        let l = layout([subWorkflowNode(rootID, name: "Self"), codeNode()])
        let issues = validate(l, subs: [rootID: l], root: rootID)
        XCTAssertFalse(errors(issues, containing: "Sub-workflow loop").isEmpty,
                       "self-recursion must be a design-time error — got: \(issues.map(\.message))")
    }

    /// Mutual recursion A⊂B⊂A — the WF-VA1 headline case.
    func testMutualRecursionThroughSubWorkflowsIsACycleError() {
        let aID = UUID(), bID = UUID()
        let aLayout = layout([subWorkflowNode(bID, name: "RunB"), codeNode()])
        let bLayout = layout([subWorkflowNode(aID, name: "RunA"), codeNode()])
        let issues = validate(aLayout, subs: [bID: bLayout, aID: aLayout], root: aID)
        XCTAssertFalse(errors(issues, containing: "Sub-workflow loop").isEmpty)
    }

    /// A 4-deep chain (limit is 3).
    func testOverDeepChainIsADepthError() {
        let aID = UUID(), bID = UUID(), cID = UUID()
        let root = layout([subWorkflowNode(aID, name: "RunA"), codeNode()])
        let aLayout = WorkflowLayout(nodes: [subWorkflowNode(bID, name: "B"), codeNode()], edges: [], annotations: [])
        let bLayout = WorkflowLayout(nodes: [subWorkflowNode(cID, name: "C"), codeNode()], edges: [], annotations: [])
        let issues = validate(root, subs: [aID: aLayout, bID: bLayout, cID: nonEmptyBody], root: UUID())
        XCTAssertFalse(errors(issues, containing: "levels deep").isEmpty,
                       "root→A→B→C is 4 levels against a limit of 3 — got: \(issues.map(\.message))")
    }

    /// The control: a legal one-level nesting must produce NO nesting errors, or the rule is just
    /// flagging every nested workflow.
    func testLegalNestingProducesNoNestingErrors() {
        let bodyID = UUID()
        let (pid, profile) = workflowProfile(bodyID)
        let issues = validate(layout([subWorkflowNode(bodyID), codeNode()]),
                              subs: [bodyID: nonEmptyBody], profiles: [pid: profile], root: UUID())
        XCTAssertTrue(issues.filter { $0.severity == .error }.isEmpty,
                      "legal nesting must not be blocked — got: \(issues.map(\.message))")
    }

    // MARK: - Empty sub-workflow targets (WF-VA3)

    func testSubWorkflowNodeWithEmptyCanvasIsAnError() {
        let subID = UUID()
        let subNode = WorkflowNode(kind: .profile(profileID: subID, profileType: .workflow),
                                   position: .zero, displayName: "Nested")
        let issues = validate(layout([subNode, codeNode()]),
                              subs: [subID: WorkflowLayout(nodes: [], edges: [], annotations: [])],
                              root: UUID())
        XCTAssertEqual(errors(issues, containing: "canvas is empty").count, 1)
    }

    func testNonEmptySubWorkflowIsNotFlaggedEmpty() {
        let subID = UUID()
        let subNode = WorkflowNode(kind: .profile(profileID: subID, profileType: .workflow),
                                   position: .zero, displayName: "Nested")
        let issues = validate(layout([subNode, codeNode()]), subs: [subID: nonEmptyBody], root: UUID())
        XCTAssertTrue(errors(issues, containing: "canvas is empty").isEmpty)
    }

    // MARK: - WF-CC2 / WF-CC5: same-level MLX model contention (design-time warning)
    //
    // ⚠️ `MLXService` keeps ONE model container resident and generates one request at a time
    // (decision D6), so ANY two same-level MLX nodes run one after another, same model or not.
    // `WorkflowExecutor.profileDispatchLanes` (WF-CC2) partitions the PROFILE group at
    // runtime; `WorkflowExecutor.structuralDispatchLanes` (WF-CC5) now does the same for the
    // STRUCTURAL group (Router `.condition` fallbacks + nested sub-workflow nodes). Both halves are
    // ACTUALLY FIXED at runtime now — these warnings are informational (this step runs slower, not
    // "this step is unsafe"), matching the profile pool's own long-standing framing.

    private static let mlxWarning = "Only one MLX model stays in memory"

    private func mlxBotProfile(_ model: String, name: String) -> BackendProfileModel {
        BackendProfileSnapshot(
            id: UUID(), displayName: name,
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .mlx, modelName: model)))
        )
    }

    private func cloudBotProfile(name: String) -> BackendProfileModel {
        BackendProfileSnapshot(
            id: UUID(), displayName: name,
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude")))
        )
    }

    private func botNode(_ profile: BackendProfileModel) -> WorkflowNode {
        WorkflowNode(kind: .profile(profileID: profile.id, profileType: .bot),
                     position: .zero, displayName: profile.displayName)
    }

    /// Two entry nodes feeding one sink — the fan-out shape that puts them on one level.
    private func fanOut(_ nodes: [WorkflowNode], into sink: WorkflowNode) -> WorkflowLayout {
        WorkflowLayout(
            nodes: nodes + [sink],
            edges: nodes.map { WorkflowEdge(sourceNodeID: $0.id, targetNodeID: sink.id, sourcePortLabel: nil) },
            annotations: []
        )
    }

    /// ⚠️ The severity pairing is the whole point, not decoration. A future refactor that promoted
    /// this to `.error` would BLOCK every affected workflow at pre-flight — violating the standing
    /// "a capability label describes, never enforces" directive. Asserting the warning count alone
    /// would not catch that; asserting zero errors is what does.
    func testSameLevelDifferentMLXModels_IsAWarningNotAnError() {
        let deep = mlxBotProfile("qwen3-8b", name: "Deep")
        let fast = mlxBotProfile("llama3-3b", name: "Fast")
        let sink = codeNode(name: "Merge")
        let l = fanOut([botNode(deep), botNode(fast)], into: sink)

        let issues = validate(l, profiles: [deep.id: deep, fast.id: fast])
        XCTAssertEqual(warnings(issues, containing: Self.mlxWarning).count, 2,
                       "both contending nodes must be flagged, so either one is clickable in the panel")
        XCTAssertTrue(errors(issues, containing: "MLX model").isEmpty,
                      "MUST stay a warning — the graph is legal and it runs; an error would block the run")
    }

    /// Decision D6: same-model siblings also run one after another at runtime, so the warning
    /// describes them too — the rule and `profileDispatchLanes` must agree.
    func testSameLevelSameMLXModel_IsFlagged() {
        let a = mlxBotProfile("qwen3-8b", name: "A")
        let b = mlxBotProfile("qwen3-8b", name: "B")
        let l = fanOut([botNode(a), botNode(b)], into: codeNode(name: "Merge"))

        let issues = validate(l, profiles: [a.id: a, b.id: b])
        XCTAssertEqual(warnings(issues, containing: Self.mlxWarning).count, 2)
        XCTAssertTrue(errors(issues, containing: "MLX model").isEmpty, "MUST stay a warning")
    }

    /// A cloud sibling never touches the MLX slot.
    func testOneMLXNodeBesideCloudNodes_IsNotFlagged() {
        let deep = mlxBotProfile("qwen3-8b", name: "Deep")
        let cloud = cloudBotProfile(name: "Cloud")
        let l = fanOut([botNode(deep), botNode(cloud)], into: codeNode(name: "Merge"))

        XCTAssertTrue(warnings(validate(l, profiles: [deep.id: deep, cloud.id: cloud]), containing: Self.mlxWarning).isEmpty)
    }

    /// Different LEVELS run sequentially, so there is nothing to contend for.
    func testDifferentLevelsAreNotFlagged() {
        let deep = mlxBotProfile("qwen3-8b", name: "Deep")
        let fast = mlxBotProfile("llama3-3b", name: "Fast")
        // A chain: Deep → Fast puts them on levels 0 and 1.
        let l = layout([botNode(deep), botNode(fast)])

        XCTAssertTrue(warnings(validate(l, profiles: [deep.id: deep, fast.id: fast]), containing: Self.mlxWarning).isEmpty,
                      "a chain is sequential by construction — the second model loads after the first is done with it")
    }

    /// ⚠️ WHY THE RULE KEEPS TWO POOLS. The executor fully awaits the STRUCTURAL task group before
    /// it opens the PROFILE group, so an AI-Classifier Router and a profile node on one level can
    /// never overlap in time. Merging the pools would flag this provably safe shape.
    func testClassifierAndProfileNodeOnOneLevel_DoNotWarn() {
        var config = ConditionNodeConfig()
        config.rules = [rule("A"), rule("B")]
        config.llmFallbackEnabled = true
        config.llmModelName = "llama3-3b"
        let router = WorkflowNode(kind: .condition(config), position: .zero, displayName: "Router")

        let deep = mlxBotProfile("qwen3-8b", name: "Deep")
        let l = fanOut([router, botNode(deep)], into: codeNode(name: "Merge"))

        XCTAssertTrue(warnings(validate(l, profiles: [deep.id: deep]), containing: Self.mlxWarning).isEmpty,
                      "structural and profile nodes are dispatched in separate, fully-awaited groups — they cannot contend")
    }

    /// ⚠️ Two same-level Routers on different models used to thrash unconditionally — the
    /// structural group was deliberately left unpartitioned until WF-CC5. Now the runtime lane
    /// split (`structuralDispatchLanes`) actually serializes them, so this warning is informational
    /// (a performance note) rather than a safety-critical "your run may fail" — but it must still
    /// fire, since the sequential lanes cost real wall-clock time the author should be told about.
    func testTwoSameLevelMLXRouters_DoWarn() {
        func router(_ model: String, _ name: String) -> WorkflowNode {
            var config = ConditionNodeConfig()
            config.rules = [rule("A"), rule("B")]
            config.llmFallbackEnabled = true
            config.llmModelName = model
            return WorkflowNode(kind: .condition(config), position: .zero, displayName: name)
        }
        let l = fanOut([router("qwen3-8b", "R1"), router("llama3-3b", "R2")], into: codeNode(name: "Merge"))

        let issues = validate(l)
        XCTAssertEqual(warnings(issues, containing: Self.mlxWarning).count, 2)
        XCTAssertTrue(errors(issues, containing: "MLX model").isEmpty)
    }

    /// A Router with the classifier switched OFF never loads a model.
    func testRoutersWithClassifierDisabled_AreNotFlagged() {
        func router(_ model: String, _ name: String) -> WorkflowNode {
            var config = ConditionNodeConfig()
            config.rules = [rule("A"), rule("B")]
            config.llmFallbackEnabled = false          // the classifier is off
            config.llmModelName = model
            return WorkflowNode(kind: .condition(config), position: .zero, displayName: name)
        }
        let l = fanOut([router("qwen3-8b", "R1"), router("llama3-3b", "R2")], into: codeNode(name: "Merge"))

        XCTAssertTrue(warnings(validate(l), containing: Self.mlxWarning).isEmpty)
    }

    // MARK: - WF-CC5: nested sub-workflows share the STRUCTURAL group too
    //
    // ⚠️ A sub-workflow's own MLX demand is invisible at design time — it lives in the CHILD
    // layout, which this rule cannot see (same reason `mlxProfileDemands` above skips `.workflow`
    // entirely). Unlike two same-model Routers, there is no model name to compare, so this check
    // cannot distinguish "these would never actually collide" from "these might" — it warns
    // unconditionally, deliberately mirroring the runtime's own unconditional exclusive-lane choice
    // in `WorkflowExecutor.structuralDispatchLanes`.

    /// Two same-level sub-workflows ALWAYS warn, even though this test gives neither of them any
    /// visible MLX demand at all.
    func testTwoSameLevelSubWorkflows_DoWarn() {
        let idA = UUID(), idB = UUID()
        let l = fanOut([subWorkflowNode(idA, name: "Nested A"), subWorkflowNode(idB, name: "Nested B")],
                       into: codeNode(name: "Merge"))
        let (pA, profA) = workflowProfile(idA, name: "Nested A")
        let (pB, profB) = workflowProfile(idB, name: "Nested B")
        let issues = validate(l, profiles: [pA: profA, pB: profB])
        XCTAssertEqual(warnings(issues, containing: Self.mlxWarning).count, 2)
        XCTAssertTrue(errors(issues, containing: "MLX model").isEmpty)
    }

    /// A sub-workflow beside an MLX-fallback Router also warns — they physically share the
    /// runtime's structural task group, unlike a sub-workflow beside a (separately-phased) regular
    /// profile node (see the negative case below).
    func testSubWorkflowBesideMLXRouter_DoesWarn() {
        var config = ConditionNodeConfig()
        config.rules = [rule("A"), rule("B")]
        config.llmFallbackEnabled = true
        config.llmModelName = "qwen3-8b"
        let router = WorkflowNode(kind: .condition(config), position: .zero, displayName: "Router")
        let nestedID = UUID()
        let l = fanOut([router, subWorkflowNode(nestedID, name: "Nested")], into: codeNode(name: "Merge"))
        let (p, prof) = workflowProfile(nestedID, name: "Nested")

        let issues = validate(l, profiles: [p: prof])
        XCTAssertEqual(warnings(issues, containing: Self.mlxWarning).count, 2)
    }

    /// A single sub-workflow with no other MLX-relevant sibling has nothing to contend with — full
    /// parallelism is preserved, matching `structuralDispatchLanes`'s own `slotOrder.count > 1` gate.
    func testSingleSubWorkflow_IsNotFlagged() {
        let nestedID = UUID()
        let l = fanOut([subWorkflowNode(nestedID, name: "Nested"), codeNode(name: "Sibling")], into: codeNode(name: "Merge"))
        let (p, prof) = workflowProfile(nestedID, name: "Nested")
        XCTAssertTrue(warnings(validate(l, profiles: [p: prof]), containing: Self.mlxWarning).isEmpty)
    }

    /// ⚠️ Same reason WF-CC2's own two-pool split exists. A sub-workflow node is dispatched
    /// STRUCTURALLY, but a regular (non-workflow) profile node is dispatched in the fully-separate,
    /// non-overlapping PROFILE phase — they cannot contend, so this must stay quiet.
    func testSubWorkflowBesideRegularProfileNode_DoesNotWarn() {
        let deep = mlxBotProfile("qwen3-8b", name: "Deep")
        let nestedID = UUID()
        let l = fanOut([subWorkflowNode(nestedID, name: "Nested"), botNode(deep)], into: codeNode(name: "Merge"))
        let (p, prof) = workflowProfile(nestedID, name: "Nested")
        XCTAssertTrue(warnings(validate(l, profiles: [deep.id: deep, p: prof]), containing: Self.mlxWarning).isEmpty,
                      "a sub-workflow (structural) and a regular profile node (profile phase) are dispatched in separate, fully-awaited groups")
    }

    /// ⚠️ THE REGRESSION TEST for the false-positive adversarial review caught: a `.condition`
    /// node with its AI Classifier fallback switched ON but a BLANK model name is genuinely
    /// unconstrained at runtime (`structuralDispatchLanes` gives it `slot = nil`, same as
    /// `mlxSlotKey` treats an empty model name), so it must never be blamed for MLX contention —
    /// even when 2+ OTHER genuinely-slotted siblings force `lanes.count > 1` and sweep it along
    /// into the same lane. The first version of this check gated a node's descriptor on
    /// `llmFallbackEnabled` alone (ignoring the model name) and filtered `contenders` by
    /// `lane.slot != nil` (a no-op once `lanes.count > 1`, since every RETURNED lane's slot is by
    /// construction non-nil) — so this exact Router got a warning quoting the local MLX model `''`.
    func testRouterWithFallbackEnabledButBlankModel_BesideTwoSubWorkflows_IsNotFlagged() {
        var config = ConditionNodeConfig()
        config.rules = [rule("A"), rule("B")]
        config.llmFallbackEnabled = true
        config.llmModelName = nil
        let router = WorkflowNode(kind: .condition(config), position: .zero, displayName: "BlankRouter")
        let idA = UUID(), idB = UUID()
        let l = fanOut(
            [router, subWorkflowNode(idA, name: "Nested A"), subWorkflowNode(idB, name: "Nested B")],
            into: codeNode(name: "Merge")
        )
        let (pA, profA) = workflowProfile(idA, name: "Nested A")
        let (pB, profB) = workflowProfile(idB, name: "Nested B")

        let issues = validate(l, profiles: [pA: profA, pB: profB])
        let mlxWarnings = warnings(issues, containing: Self.mlxWarning)

        XCTAssertTrue(mlxWarnings.allSatisfy { $0.nodeName != "BlankRouter" },
                      "BlankRouter never touches MLX and the runtime never gives it its own lane — it must not appear as a contender. Got: \(mlxWarnings.map(\.nodeName))")
        XCTAssertTrue(mlxWarnings.allSatisfy { !$0.message.contains("BlankRouter") },
                      "BlankRouter must not be named as a contending sibling in anyone else's warning either")
        // The two sub-workflows still genuinely contend with EACH OTHER and must still warn.
        XCTAssertEqual(mlxWarnings.count, 2)
    }

    // MARK: - Unified Router policy (2026-08-17)

    private func policyRouter(_ policy: RouterDecisionPolicy, rules rs: [ConditionRule],
                              name: String = "Router") -> WorkflowNode {
        var config = ConditionNodeConfig()
        config.rules = rs
        config.decisionPolicy = policy
        return WorkflowNode(kind: .condition(config), position: .zero, displayName: name)
    }

    /// The same stable-ID contract the legacy setting had, on the setting that replaced it.
    func testADeletedRouteTargetOnTheUnifiedPolicyIsAnError() {
        let kept = rule("Urgent")
        let node = policyRouter(.route(ruleID: UUID()), rules: [kept, rule("Billing")])
        XCTAssertEqual(errors(validate(layout([node])), containing: "Routing Can't Decide").count, 1)
    }

    /// …including when it hides inside an Ask fallback, which is the easier one to miss.
    func testADeletedRouteTargetInsideAnAskFallbackIsAlsoAnError() {
        let node = policyRouter(.ask(fallback: .route(ruleID: UUID())),
                                rules: [rule("Urgent"), rule("Billing")])
        XCTAssertEqual(errors(validate(layout([node])), containing: "Routing Can't Decide").count, 1)
    }

    func testAValidPolicyRouteIsNotFlagged() {
        let target = rule("Billing")
        let node = policyRouter(.route(ruleID: target.id), rules: [rule("Urgent"), target])
        XCTAssertTrue(errors(validate(layout([node])), containing: "Routing Can't Decide").isEmpty)
    }

    /// ⚠️ A WARNING, never an error — the graph is legal and runs. It names the unattended
    /// consequence the author cannot see from the canvas.
    func testAskWithFailFallbackAndNoErrorPortIsAWarningNotAnError() {
        let node = policyRouter(.ask(fallback: .failNode), rules: [rule("Urgent"), rule("Billing")])
        let issues = validate(layout([node]))
        XCTAssertEqual(warnings(issues, containing: "error port is not wired").count, 1)
        XCTAssertTrue(errors(issues, containing: "error port is not wired").isEmpty,
                      "must never block a run — the standing rule is that a capability describes, it does not gate")
    }

    /// Wiring the error port answers the warning.
    func testAskWithFailFallbackAndAWiredErrorPortIsQuiet() {
        let node = policyRouter(.ask(fallback: .failNode), rules: [rule("Urgent"), rule("Billing")])
        let sink = codeNode(name: "Handler")
        let l = WorkflowLayout(
            nodes: [node, sink],
            edges: [WorkflowEdge(sourceNodeID: node.id, targetNodeID: sink.id,
                                 sourcePortLabel: WorkflowEdge.errorPortLabel)],
            annotations: []
        )
        XCTAssertTrue(warnings(validate(l), containing: "error port is not wired").isEmpty)
    }
}
