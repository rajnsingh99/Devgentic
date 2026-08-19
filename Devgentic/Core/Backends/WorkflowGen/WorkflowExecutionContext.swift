//
//  WorkflowExecutionContext.swift
//  Devgentic
//
//  Created by Claude on 13/04/26.
//
//  In-memory value type carrying workflow-specific execution metadata through
//  the AgentConnect → Executor → Generator pipeline. Enables the agent flow
//  to distinguish workflow node execution from normal chat, allowing targeted
//  prompt construction that eliminates RAG, history, and competing directives.
//
//  Never serialized — exists only during a single node's execution lifetime.
//

import Foundation

/// Workflow-specific execution context passed from `WorkflowExecutor` through
/// `AgentConnect` to the underlying agent/bot generator via `SemanticContext`.
///
/// Carries the two inputs a workflow node needs:
/// - `taskDescription`: WHAT to do (per-node directive, merged with user query for first nodes)
/// - `upstreamInput`: WITH what data (clean text from upstream nodes)
///
/// The presence of this struct on `SemanticContext.workflowContext` is the
/// single signal `buildStandardMessages` uses to apply workflow-specific
/// behavior (per-node user-message prefix). The `PromptLayerConfig.workflow`
/// switch is handled separately at the SemanticContext construction site
/// (see `ReActAgentExecutor` and `ChatExecutor`).
struct WorkflowExecutionContext: Sendable {

    /// Per-node task description from `WorkflowNodeConfig.taskDescription`.
    /// For first nodes, the original user query (if any) is merged into this field
    /// by `WorkflowExecutor.executeNode()` so there is a single directive.
    let taskDescription: String

    /// Clean compiled upstream text from `WorkflowInputAssembler.compileForWorkflow()`.
    /// Contains raw output from completed predecessor nodes, separated by `---`.
    /// Empty string when there are no upstream results (first node).
    let upstreamInput: String

    /// True if this node has no incoming edges (entry point of the DAG).
    /// First nodes receive "Execute your task." as user message.
    /// Downstream nodes receive `<input>[upstreamInput]</input>`.
    let isFirstNode: Bool

    /// Node display name for logging and tracing.
    let nodeName: String

    /// Identity of the node this run belongs to.
    ///
    /// Carried for the HITL approval SCOPE: every node of a run shares one conversationID, so
    /// without this an "Allow for this chat" granted in one node would silently auto-approve the
    /// same tool in every other node. Nodes configure their tools independently, so an approval
    /// given to one is not an answer for another. See `SessionToolApprovals.Scope`.
    let nodeID: UUID

    /// Media/file artifacts produced by completed upstream nodes (images, audio,
    /// video, documents). Surfaced to the node as a text *manifest* (kind, label,
    /// mime, resolvable path) by `userMessagePrefix`, so an agent with file/HTTP
    /// tools can act on them. Native image-into-vision injection is a later phase;
    /// this field is the carrier for it. Empty when no upstream artifacts.
    var upstreamArtifacts: [MediaArtifact] = []

    /// Pre-extracted text of `.document` upstream artifacts (PDF/DOCX/XLSX/…),
    /// computed asynchronously by the executor and budget-limited. Inlined into the
    /// prompt so a text-only model can still read attached documents. Empty when
    /// there are no extractable documents.
    var upstreamArtifactText: String = ""

    /// Computes the per-node user-message prefix that gets prepended to the
    /// user turn in `buildStandardMessages`. Single source of truth — used by
    /// both the agent (ReAct) path and the bot (Chat) path automatically.
    ///
    /// Three branches:
    ///   - `.isFirstNode == true` → "Execute your task." (the task description
    ///     already lives in the system prompt's `<task>` layer)
    ///   - `.upstreamInput.isEmpty` → "No input data provided. …" (downstream
    ///     node where every predecessor failed/skipped — surface the gap)
    ///   - else → wrapping-appropriate `<input>upstreamInput</input>` block
    ///
    /// `wrapping` is supplied by the caller (`buildStandardMessages` knows its
    /// own wrapping) so XML-style generators get `<input>…</input>` and
    /// markdown-style generators get `## Input\n…`.
    func userMessagePrefix(wrapping: PromptWrapping) -> String {
        if isFirstNode {
            return "Execute your task."
        }

        // Compose the downstream user message from up to three sections: the
        // upstream text, a manifest of attached files, and inlined document text.
        // Each is wrapping-aware so XML dialects get `<input>`/`<attached_files>`
        // and markdown dialects get `## Input` / `## Attached Files`. Both the bot
        // and agent workflow paths route through here, so artifacts reach both.
        var sections: [String] = []

        if !upstreamInput.isEmpty {
            sections.append(wrapping.section("input", content: upstreamInput))
        }

        let manifest = WorkflowInputAssembler.renderArtifactManifest(upstreamArtifacts)
        if !manifest.isEmpty {
            sections.append(wrapping.section("attached_files", content: manifest))
        }

        if !upstreamArtifactText.isEmpty {
            sections.append(wrapping.section("attached_documents", content: upstreamArtifactText))
        }

        // No text AND no artifacts — every predecessor failed/skipped or produced
        // nothing. Surface the gap rather than emitting an empty user turn.
        if sections.isEmpty {
            return "No input data provided. Execute your task based on the task description."
        }

        return sections.joined(separator: "\n\n")
    }
}
