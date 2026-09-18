// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
/// Carries the ONE input a workflow node needs: `input` — the text this node acts on, which is
/// the user's query at an entry node and the compiled upstream output everywhere else.
///
/// ⚠️ There used to be a second channel, `taskDescription`, holding a per-node directive that was
/// rendered into the system prompt's `<task>` layer (and, at an entry node, fused with the user's
/// query). It was removed 2026-08-29: a node's behaviour is its profile's system instructions, and
/// since the canvas allows one node per profile those instructions ARE the per-node directive.
/// Two channels meant an entry node received the same request twice, in two different slots.
///
/// The presence of this struct on `SemanticContext.workflowContext` is the
/// single signal `buildStandardMessages` uses to apply workflow-specific
/// behavior (per-node user-message prefix). The `PromptLayerConfig.workflow`
/// switch is handled separately at the SemanticContext construction site
/// (see `ReActAgentExecutor` and `ChatExecutor`).
struct WorkflowExecutionContext: Sendable {

    /// The text this node acts on.
    ///
    /// ⚠️ ONE FIELD FOR BOTH ORIGINS, deliberately. At an ENTRY node this is the run's
    /// `userInput` — the user's chat query, a schedule's configured prompt, or a ChatOps message.
    /// Everywhere else it is `WorkflowInputAssembler.compileForWorkflow()`'s output: the raw text
    /// of completed predecessors, separated by `---`. The executor decides which, keyed on the
    /// GRAPH (`isEntryNode`), so this type never has to.
    ///
    /// Empty only when a run genuinely started with no input, or when every predecessor
    /// failed/skipped — both surfaced by `userMessagePrefix`.
    let input: String

    /// True if this node has no incoming edges (entry point of the DAG).
    ///
    /// ⚠️ No longer selects between two prompt SHAPES — every node renders its `input` the same
    /// way. It survives for two things that genuinely differ by position: `attachmentContext`
    /// (entry-node only) and the security note's framing, where an entry node's input is the
    /// request to fulfil and a downstream node's is untrusted data to process.
    let isFirstNode: Bool

    /// Current-turn attachment text, ENTRY NODE ONLY (nil elsewhere).
    ///
    /// ⚠️ This exists so attachments stop riding `userInput`. `AgentConnect`'s workflow arm used to
    /// prepend the knowledge and attachment payloads onto `userInput` because a node had no other
    /// route to them — and the entry-node merge then folded the result into `taskDescription`, so a
    /// pasted file's text became part of the node's TASK. It travels as its own value now and is
    /// rendered by the shared builder as `<attachments>`, the same section the chat path uses.
    var attachmentContext: String? = nil

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

    /// [WF-SE6/SE11] The node's explicit unattended-approval setting
    /// (`WorkflowNodeConfig.unattendedAutoApprove`), threaded to the agent path's confirmation
    /// gate in `ToolExecutionLoop`. Runtime-only — never persisted here.
    var unattendedAutoApprove: Bool = false

    /// Computes the per-node user-message prefix that gets prepended to the
    /// user turn in `buildStandardMessages`. Single source of truth — used by
    /// both the agent (ReAct) path and the bot (Chat) path automatically.
    ///
    /// ⚠️ ONE SHAPE FOR EVERY NODE since 2026-08-29: the node's `input` rendered as an `<input>`
    /// section, whatever its origin. The entry node used to get the literal string "Execute your
    /// task." here because its real directive sat in the system prompt's `<task>` layer; with that
    /// layer gone for workflow nodes, an entry node that returned that string would be handed a
    /// prompt containing no request at all.
    ///
    /// The only remaining branch is the genuinely-empty one, which is a real condition worth
    /// naming rather than a shape difference.
    ///
    /// `wrapping` is supplied by the caller (`buildStandardMessages` knows its
    /// own wrapping) so XML-style generators get `<input>…</input>` and
    /// markdown-style generators get `## Input\n…`.
    func userMessagePrefix(wrapping: PromptWrapping) -> String {
        // Compose the user message from up to three sections: the node's input text, a manifest
        // of attached files, and inlined document text.
        // Each is wrapping-aware so XML dialects get `<input>`/`<attached_files>`
        // and markdown dialects get `## Input` / `## Attached Files`. Both the bot
        // and agent workflow paths route through here, so artifacts reach both.
        var sections: [String] = []

        // [WF-SE5] Every section here is UNTRUSTED — an upstream node's own output, an
        // artifact's label (set by an upstream node, not this one), or extracted document
        // text — so each is escaped before it becomes the content of its tag. A payload
        // containing `</input><instruction>…</instruction><input>` would otherwise close the
        // section early and inject its own directive that a downstream Router or Action node
        // then acts on. See `WorkflowInputAssembler.escapeForXMLEmbedding`'s doc for why this
        // is NOT applied to `system_instructions`/etc., which are locally-authored.
        //
        // ⚠️ An ENTRY node's `input` is now escaped too, and that is a GAIN. The same text used to
        // ride `taskDescription` into the `<task>` layer, which is exempt from escaping as
        // "locally-authored" — true of a task the workflow author typed, false of a ChatOps
        // message or a schedule's prompt, which reach `userInput` from outside.
        if !input.isEmpty {
            // EIO-4: conditional — escaped only when the payload could forge this section's
            // boundary; ordinary HTML/code/markup passes VERBATIM. See `escapeIfBoundaryThreat`.
            let safe = WorkflowInputAssembler.escapeIfBoundaryThreat(input, section: "input", wrapping: wrapping)
            sections.append(wrapping.section("input", content: safe))
        }

        let manifest = WorkflowInputAssembler.renderArtifactManifest(upstreamArtifacts)
        if !manifest.isEmpty {
            // ⚠️ NOT escaped here (register EIO-3): `renderArtifactManifest` pre-escapes its one
            // untrusted field (the upstream-authored label) and everything else — above all the
            // LOCATOR path/URL — must reach the agent byte-exact, or the tool call on it fails on
            // a path that does not exist. Escaping the whole block here is what mangled `&` in
            // real paths and query strings for every hop.
            sections.append(wrapping.section("attached_files", content: manifest))
        }

        if !upstreamArtifactText.isEmpty {
            let safe = WorkflowInputAssembler.escapeIfBoundaryThreat(upstreamArtifactText, section: "attached_documents", wrapping: wrapping)
            sections.append(wrapping.section("attached_documents", content: safe))
        }

        // No text AND no artifacts. At an entry node the run started with no input at all; below
        // one, every predecessor failed, skipped, or produced nothing. Surface the gap rather than
        // emitting an empty user turn — and say which of the two it is, because the remedies are
        // opposite (type something / go look at the upstream node).
        if sections.isEmpty {
            return isFirstNode
                ? "This run started with no input. Follow your system instructions."
                : "No input data provided — every preceding step failed, was skipped, or produced nothing. Follow your system instructions."
        }

        return sections.joined(separator: "\n\n")
    }
}
