// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowExecutionContext.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Workflow-specific execution context passed from `WorkflowExecutor` through `AgentConnect` to the generator via
/// `SemanticContext`. Carries `input`, the text this node acts on. Its presence on `SemanticContext.workflowContext` is
/// the single signal `buildStandardMessages` uses to apply the per-node user-message prefix.
struct WorkflowExecutionContext: Sendable {

    /// The text this node acts on: at an entry node the run's `userInput` (chat query, schedule prompt or ChatOps message),
    /// elsewhere `WorkflowInputAssembler.compileForWorkflow()`'s output. Empty when a run started with no input or every
    /// predecessor failed/skipped.
    let input: String

    /// True if this node has no incoming edges (entry point of the DAG). It decides only `attachmentContext` (entry node
    /// only) and the security note's framing: an entry node's input is the request to fulfil, a downstream node's is
    /// untrusted data to process.
    let isFirstNode: Bool

    /// Current-turn attachment text, entry node only (nil elsewhere); travels as its own value and is rendered by the shared
    /// builder as `<attachments>`, the same section the chat path uses.
    var attachmentContext: String? = nil

    /// Node display name for logging and tracing.
    let nodeName: String

    /// Identity of the node this run belongs to, carried for the HITL approval scope: every node of a run shares one
    /// conversationID, so an 'Allow for this chat' in one node must not auto-approve the same tool in another. See
    /// `SessionToolApprovals.Scope`.
    let nodeID: UUID

    /// Media/file artifacts produced by completed upstream nodes (images, audio, video, documents), surfaced to the node as
    /// a text manifest by `userMessagePrefix` so an agent with file/HTTP tools can act on them. Empty when there are none.
    var upstreamArtifacts: [MediaArtifact] = []

    /// Pre-extracted text of `.document` upstream artifacts (PDF/DOCX/XLSX/...), computed asynchronously by the executor and
    /// inlined into the prompt so a text-only model can read them. Empty when there are no extractable documents.
    var upstreamArtifactText: String = ""

    /// [WF-SE6/SE11] The node's explicit unattended-approval setting
    /// (`WorkflowNodeConfig.unattendedAutoApprove`), threaded to the agent path's confirmation
    /// gate in `ToolExecutionLoop`. Runtime-only — never persisted here.
    var unattendedAutoApprove: Bool = false

    /// Computes the per-node user-message prefix prepended to the user turn in `buildStandardMessages`, for both the agent
    /// (ReAct) and bot (Chat) paths. Every node renders its `input` as an `<input>` section; the only other branch is the
    /// genuinely empty case. `wrapping` is supplied by the caller (XML tags or markdown headings).
    func userMessagePrefix(wrapping: PromptWrapping) -> String {
        // Composes the user message from up to three wrapping-aware sections: the node's input text, a manifest of attached
        // files, and inlined document text. Both the bot and agent workflow paths route through here, so artifacts reach both.
        var sections: [String] = []

        // Every section is untrusted (upstream output, artifact labels, document text), so each is escaped before it becomes
        // the content of its tag; an entry node's `input` too, since ChatOps and schedule prompts arrive from outside.
        if !input.isEmpty {
            // EIO-4: conditional — escaped only when the payload could forge this section's
            // boundary; ordinary HTML/code/markup passes VERBATIM. See `escapeIfBoundaryThreat`.
            let safe = WorkflowInputAssembler.escapeIfBoundaryThreat(input, section: "input", wrapping: wrapping)
            sections.append(wrapping.section("input", content: safe))
        }

        let manifest = WorkflowInputAssembler.renderArtifactManifest(upstreamArtifacts)
        if !manifest.isEmpty {
            // Not escaped here: `renderArtifactManifest` pre-escapes its one untrusted field (the label), and the locator path/URL
            // must reach the agent byte-exact.
            sections.append(wrapping.section("attached_files", content: manifest))
        }

        if !upstreamArtifactText.isEmpty {
            let safe = WorkflowInputAssembler.escapeIfBoundaryThreat(upstreamArtifactText, section: "attached_documents", wrapping: wrapping)
            sections.append(wrapping.section("attached_documents", content: safe))
        }

        // No text and no artifacts: an entry node got no input, or every predecessor failed, skipped or produced nothing. The
        // gap is surfaced, saying which case it is, rather than emitting an empty user turn.
        if sections.isEmpty {
            return isFirstNode
                ? "This run started with no input. Follow your system instructions."
                : "No input data provided — every preceding step failed, was skipped, or produced nothing. Follow your system instructions."
        }

        return sections.joined(separator: "\n\n")
    }
}
