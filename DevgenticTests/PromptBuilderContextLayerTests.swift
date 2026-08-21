//
//  PromptBuilderContextLayerTests.swift
//  devgenticTests
//
//  Created on 11/07/26.
//
//  Covers the 2026-07 file-context redesign contract in PromptBuilder:
//  - <knowledge_base> renders as a system layer iff a payload is present
//  - attachmentContext leads the USER message, never the system <task>
//  - the native path can exclude attachments (kickoff turn delivers them)
//

import XCTest
@testable import devgentic

final class PromptBuilderContextLayerTests: XCTestCase {

    // MARK: - Helpers

    private func makeContext(
        query: String = "What does this code do?",
        attachmentContext: String? = nil,
        knowledgeBaseContext: String? = nil,
        ragContext: String = "",
        userProfile: String? = nil,
        layerConfig: PromptLayerConfig = .bot
    ) -> SemanticContext {
        SemanticContext(
            instructions: "You are a helpful assistant.",
            environmentFacts: EnvironmentFacts(
                osVersion: "macOS 26",
                shellType: "Zsh",
                userName: "tester",
                homeDirectory: "/Users/tester",
                currentDate: "01/01/2026"
            ),
            longTermMemory: StaticGroundingMemory(ragContext: ragContext),
            recentHistory: nil,
            nativeHistoryTurns: nil,
            originalQuery: query,
            currentIteration: 0,
            compiledScratchpad: "",
            latestClarification: nil,
            negativeConstraints: [],
            hallucinatedTools: [],
            availableTools: [],
            userProfile: userProfile,
            skillManifests: nil,
            taskDescription: nil,
            promptLayerConfig: layerConfig,
            workflowContext: nil,
            attachmentContext: attachmentContext,
            knowledgeBaseContext: knowledgeBaseContext
        )
    }

    private func systemContent(of messages: [[String: String]]) -> String {
        messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
    }

    private func userContents(of messages: [[String: String]]) -> [String] {
        messages.filter { $0["role"] == "user" }.compactMap { $0["content"] }
    }

    // MARK: - User profile in WORKFLOW mode (owner decision, 2026-08-20)

    /// THE DECISION, pinned. A workflow node must not inherit conversation memory — it has no
    /// conversation — but it DOES run the user's own profile, so their skills and guardrails apply.
    /// Before this, `.workflow` set all three layer flags to false together, and the personal layer
    /// was collateral damage of "a node has no conversation history".
    ///
    /// ⚠️ This asserts the ASYMMETRY, not just the one flag. A future cleanup that "tidies" the
    /// three flags back into agreement is exactly the regression this exists to catch.
    func testWorkflowLayerConfig_KeepsUserProfileButNotConversationMemory() {
        XCTAssertTrue(PromptLayerConfig.workflow.includeUserProfile,
                      "a node runs the user's profile on their behalf — skills and guardrails still apply")
        XCTAssertFalse(PromptLayerConfig.workflow.includeRAG,
                       "a node has no conversation to retrieve from")
        XCTAssertFalse(PromptLayerConfig.workflow.includeEpisodicMemory,
                       "a node has no episodic history")
    }

    func testUserProfile_RendersOnTheWorkflowPath() {
        let context = makeContext(userProfile: "Prefers metric units. Never run destructive shell commands.",
                                  layerConfig: .workflow)
        let system = systemContent(of: PromptBuilder.buildStandardMessages(context: context, layerConfig: .workflow))

        XCTAssertTrue(system.contains("Never run destructive shell commands."),
                      "the personal layer must reach a workflow node's system prompt")
    }

    /// ⚠️ THE TWIN GATE. `PromptLayerConfig` only PERMITS the layer; the value itself is read in
    /// `ReActAgentExecutor` / `PlanningCapability`, which used to nil it out whenever
    /// `workflowContext != nil`. Flipping one and not the other renders nothing, silently — which is
    /// indistinguishable from the feature being off. This pins the assembly half: permitted plus
    /// absent must stay absent, so a green flag alone is never mistaken for a working layer.
    func testWorkflowUserProfile_AbsentWhenTheExecutorSuppliedNone() {
        let context = makeContext(userProfile: nil, layerConfig: .workflow)
        let system = systemContent(of: PromptBuilder.buildStandardMessages(context: context, layerConfig: .workflow))

        XCTAssertFalse(system.contains("<user_profile>"),
                       "permitting the layer must not invent one when the executor passed nil")
    }

    // MARK: - <knowledge_base> layer

    func testKnowledgeBase_RendersAsSystemLayer() {
        let context = makeContext(knowledgeBaseContext: "--- Knowledge: StyleGuide.md ---\nUse tabs.")
        let messages = PromptBuilder.buildStandardMessages(context: context, layerConfig: .bot)

        let system = systemContent(of: messages)
        XCTAssertTrue(system.contains("<knowledge_base>"), "KB payload must render as a system layer")
        XCTAssertTrue(system.contains("Use tabs."), "KB content must be inside the system prompt")
        XCTAssertFalse(
            userContents(of: messages).joined().contains("StyleGuide.md"),
            "KB content must never ride the user message"
        )
    }

    func testKnowledgeBase_AbsentWhenNil() {
        let context = makeContext(knowledgeBaseContext: nil)
        let system = systemContent(of: PromptBuilder.buildStandardMessages(context: context, layerConfig: .bot))
        XCTAssertFalse(system.contains("<knowledge_base>"), "no KB → no layer, not an empty placeholder")
    }

    func testKnowledgeBase_AbsentWhenEmpty() {
        let context = makeContext(knowledgeBaseContext: "")
        let system = systemContent(of: PromptBuilder.buildStandardMessages(context: context, layerConfig: .bot))
        XCTAssertFalse(system.contains("<knowledge_base>"))
    }

    // MARK: - Attachment placement

    func testAttachments_LeadUserMessage_NotTask() {
        let fileBlob = "--- Start of file: AppDelegate.swift ---\nimport Cocoa\n--- End of file: AppDelegate.swift ---"
        let context = makeContext(attachmentContext: fileBlob)
        // Bot flow: the typed query arrives as userMessagePrefix (ChatExecutor behavior).
        let messages = PromptBuilder.buildStandardMessages(
            context: context,
            layerConfig: .bot,
            userMessagePrefix: context.originalQuery
        )

        let system = systemContent(of: messages)
        XCTAssertFalse(system.contains("import Cocoa"), "file text must NOT land in the system <task> block")
        XCTAssertTrue(system.contains("<task>\nWhat does this code do?"), "task carries only the typed query")

        let users = userContents(of: messages)
        XCTAssertEqual(users.count, 1)
        let user = users[0]
        XCTAssertTrue(user.contains("import Cocoa"), "file text rides the user message")
        XCTAssertLessThan(
            user.range(of: "import Cocoa")!.lowerBound,
            user.range(of: "What does this code do?")!.lowerBound,
            "attachments lead, query follows"
        )
    }

    func testAttachments_StatelessPathNote_RidesUserMessage() {
        let note = "The user has attached the following files. Use the read_file tool to access them when needed:\n/tmp/a.swift"
        let context = makeContext(attachmentContext: note, layerConfig: .agent)
        let messages = PromptBuilder.buildStandardMessages(context: context, layerConfig: .agent)

        XCTAssertTrue(
            userContents(of: messages).joined().contains("read_file"),
            "stateless note must reach the user message even with no prefix (legacy agent path)"
        )
        XCTAssertFalse(systemContent(of: messages).contains("read_file tool to access"), "note must not land in system")
    }

    func testAttachments_ExcludedWhenNativeExecutorOwnsDelivery() {
        let context = makeContext(attachmentContext: "FILE PAYLOAD", layerConfig: .agent)
        // Mirrors NativeStructuredGenerator.compileMessages: kickoff turn delivers attachments.
        let messages = PromptBuilder.buildStandardMessages(
            context: context,
            isNativeFlow: true,
            layerConfig: .agent,
            includeWorkingMemory: false,
            includeAttachmentContext: false
        )

        XCTAssertTrue(
            userContents(of: messages).isEmpty,
            "native seed messages must not emit an attachment-only user turn (kickoff owns it)"
        )
        XCTAssertFalse(systemContent(of: messages).contains("FILE PAYLOAD"))
    }

    // MARK: - <semantic_context> conditional rendering (standard RAG, Phase 3)

    func testSemanticContext_AbsentWhenGroundingEmpty() {
        // Post-sentinel-removal: no retrieval → empty grounding → no hollow layer.
        let context = makeContext(ragContext: "")
        let system = systemContent(of: PromptBuilder.buildStandardMessages(context: context, layerConfig: .bot))
        XCTAssertFalse(system.contains("<semantic_context>"), "empty grounding must not emit a placeholder block")
    }

    func testSemanticContext_RendersWhenRetrievalReturnedContent() {
        let context = makeContext(ragContext: "PRIOR TURN: we discussed the parser rewrite.")
        let system = systemContent(of: PromptBuilder.buildStandardMessages(context: context, layerConfig: .bot))
        XCTAssertTrue(system.contains("<semantic_context>"))
        XCTAssertTrue(system.contains("parser rewrite"))
    }

    // MARK: - Combined

    func testKnowledgeAndAttachments_LandInSeparateVehicles() {
        let context = makeContext(
            attachmentContext: "ATTACHED FILE TEXT",
            knowledgeBaseContext: "KB REFERENCE TEXT"
        )
        let messages = PromptBuilder.buildStandardMessages(
            context: context,
            layerConfig: .bot,
            userMessagePrefix: context.originalQuery
        )

        let system = systemContent(of: messages)
        let user = userContents(of: messages).joined()
        XCTAssertTrue(system.contains("KB REFERENCE TEXT"), "KB → system")
        XCTAssertFalse(system.contains("ATTACHED FILE TEXT"), "attachments not in system")
        XCTAssertTrue(user.contains("ATTACHED FILE TEXT"), "attachments → user message")
        XCTAssertFalse(user.contains("KB REFERENCE TEXT"), "KB not in user message")
    }
}
