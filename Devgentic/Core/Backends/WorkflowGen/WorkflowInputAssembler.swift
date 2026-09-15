// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  WorkflowInputAssembler.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26. Renamed from ContextCompressor.swift on 15/08/26.
//
//  Assembles a workflow node's INPUT from its upstream results: the compiled text block,
//  the artifact manifest, and inlined document text.
//
//  ⚠️ Renamed because the old name had become a lie. This file no longer compresses anything:
//  the per-upstream/total text budgets were retired 2026-08-13 (user decision — nothing is
//  truncated; fitting the input is the downstream model's context window, the author's call)
//  and the document-inlining budget followed on 2026-08-15 (same decision, WF-OB3). The legacy
//  `compile()` variant that still truncated — dead since the compaction overhaul, kept alive
//  only by tests of itself — was deleted in the rename, along with the boundary-truncation
//  helper and the two budget constants that existed only for it.
//

import Foundation
import os

private let assemblerLogger = DGLogger(category: "WorkflowInputAssembler")

/// Assembles upstream node results into the input a downstream workflow node receives:
/// compiled text (`compileForWorkflow`), the artifact manifest (`renderArtifactManifest`),
/// and inlined document text (`extractDocumentText`). Nothing here truncates.
enum WorkflowInputAssembler {

    // MARK: - Workflow Compilation

    /// Compiles upstream node outputs into a downstream node's input — the clean `<input>` block.
    ///
    /// Produces raw text a downstream node can process without knowing it's in a workflow:
    /// a single upstream arrives bare; multiple upstreams are separated by `\n\n---\n\n`. Only
    /// `.completed` results are included by default; `includeFailures: true` also surfaces
    /// error-routed FAILED upstreams, each annotated with its failure reason, so an error-handler
    /// node can see what failed and any partial output.
    ///
    /// ⚠️ This doc block replaced a stale one (2026-08-15) that still documented `budget:` /
    /// `perNodeBudget:` parameters retired on 2026-08-13 — the WF63 class: copy derived from a
    /// stale doc comment inherits its errors.
    ///
    /// ⚠️ **NOTHING IS TRUNCATED (2026-08-13, user decision).** A workflow passes upstream output
    /// through in full; fitting it is a matter of which model the downstream node runs, and that is
    /// the author's choice to make. The previous per-upstream and total character budgets — 2000 and
    /// 6000 by default — silently cut a three-paragraph answer on every run of every workflow, and
    /// the workflow-level sliders that tuned them could not know the downstream model's context
    /// window anyway.
    ///
    /// ⚠️ CONSEQUENCE, stated so nobody has to rediscover it: a node's input is now unbounded. A
    /// small local model downstream of several verbose upstreams can exceed its context window, and
    /// that surfaces as a provider-side error rather than a truncation marker. The size is logged
    /// per upstream and in total so a field report can see what was sent.
    static func compileForWorkflow(
        results: [NodeResultEnvelope],
        includeFailures: Bool = false
    ) -> String {
        // Normally only completed results contribute — failed/skipped are handled
        // by the executor's dependency logic. When `includeFailures` is set (the
        // consumer is an error handler wired to an upstream's `error` port), failed
        // results are included too and annotated below with their reason.
        let usableResults = results.filter { result in
            switch result.status {
            case .completed:            return true
            case .failed:               return includeFailures
            // A user-skipped upstream (D2.1) carries its INPUT as its output, and it counts as an
            // arrival everywhere — including fan-in joins (owner-ratified 2026-08-21): a join
            // requiring all inputs must never turn a skip into a silent run-killer. This is also
            // what makes CHAINED user skips compose: each pass-through feeds the next.
            case .skipped(reason: .byUser): return true
            case .canceled, .skipped:   return false
            }
        }

        guard !usableResults.isEmpty else {
            assemblerLogger.info("compileForWorkflow: no usable upstream results, returning empty")
            return ""
        }

        assemblerLogger.info("compileForWorkflow: \(usableResults.count)/\(results.count) usable results (includeFailures=\(includeFailures)), no truncation")

        var sections: [String] = []

        for (index, result) in usableResults.enumerated() {
            assemblerLogger.info("  [\(index)] '\(result.profileName)': \(result.output.count) chars (passed through in full)")
            assemblerLogger.debug("  [\(index)] '\(result.profileName)' preview: \(String(result.output.prefix(200)))")

            // Annotate an error-routed failed upstream so the downstream handler has
            // the failure reason alongside whatever partial output was produced.
            if case .failed(let reason) = result.status {
                let note = "[Upstream node \"\(result.profileName)\" failed: \(reason.localizedDescription)]"
                sections.append(result.output.isEmpty ? note : note + "\n\n" + result.output)
            } else {
                sections.append(result.output)
            }
        }

        // Join: single result = raw text, multiple = separated by ---
        let body = sections.count == 1
            ? sections[0]
            : sections.joined(separator: "\n\n---\n\n")

        // ⚠️ Not a cap — an observability floor. An oversized prompt now fails at the provider with
        // a message that says nothing about which workflow node built it, so the one place that
        // knows says it out loud.
        if body.count > 100_000 {
            assemblerLogger.warning("compileForWorkflow: compiled \(body.count) chars from \(usableResults.count) upstream(s) — NOT truncated (by design). CONSEQUENCE: if the downstream node's model has a smaller context window this request will fail at the provider. Reduce what the upstream nodes emit, or point that node at a larger-context model.")
        } else {
            assemblerLogger.info("compileForWorkflow: output \(body.count) chars")
        }
        return body
    }

    // MARK: - Untrusted-content escaping [WF-SE2 / WF-SE5]

    /// Escapes XML-significant characters so untrusted content — an upstream node's output, an
    /// artifact label, extracted document text, a ChatOps-remote attachment — cannot close the
    /// section it is embedded in and inject its own tags.
    ///
    /// ⚠️ `&` MUST run first: escaping `<`/`>` before it would double-escape the `&amp;` this
    /// call just introduced.
    ///
    /// Scoped to the concrete, EVIDENCED vector — a payload containing `</input><instruction>…`
    /// that hijacks the section it lands in — not a general sanitizer. Markdown wrapping has no
    /// closing delimiter to break out of (`## Input` opens no tag a payload could prematurely
    /// close), so this is a no-op there; escaping it anyway would just show literal `&lt;`/`&gt;`
    /// entities to a LOCAL model reading, say, pasted HTML, for no security benefit.
    ///
    /// Deliberately NOT applied to every `PromptWrapping.section` call — `task`,
    /// `system_instructions`, `knowledge_base`, `user_profile` and the rest are user- or
    /// profile-authored content under this app's local-trust model (see
    /// `Workflow_Production_Readiness.md`'s security-scoping note), and escaping angle brackets
    /// there would corrupt a legitimate `<T>` in a task description or a pasted code snippet for
    /// no one this fix is meant to defend against. Call this ONLY at a boundary where the content
    /// can plausibly be upstream node output, third-party (ChatOps) input, or content the user
    /// INSTALLED rather than wrote.
    ///
    /// ⚠️ That last category is why the caller list is no longer workflow-only.
    /// `<available_skills>` renders a skill's `name` and `description` straight off disk, and a
    /// skill folder routinely arrives as a zip or a cloned repo — so "the user put it there" is
    /// not the same claim as "the user wrote it", and the local-trust exemption above does not
    /// reach it. See `SkillDiscoveryRendering`, which owns that call and adds the newline
    /// collapse this function deliberately does not do (markdown wrapping has no closing tag to
    /// escape, but it does have headings to forge).
    /// Escapes a payload for embedding in `section` ONLY when it could actually forge the
    /// section's boundary (register EIO-4).
    ///
    /// ⚠️ The blanket escape corrupted VERBATIM work: a node whose job is to transform HTML/XML/
    /// code received `&lt;div&gt;` where its upstream emitted `<div>`, and consecutive LLM hops
    /// compounded it (`&` escapes first, so `&lt;` became `&amp;lt;`). But WF-SE5's actual threat
    /// is narrower than "any angle bracket": a payload can only break out of its section by
    /// containing the section's own CLOSING tag. So: payloads carrying `</tag` (case-insensitive)
    /// are escaped in full and the rewrite is LOGGED with its consequence; every other payload —
    /// the overwhelming majority, including all ordinary HTML/code — passes byte-exact.
    ///
    /// The trade is explicit: a legitimate payload that happens to contain the literal boundary
    /// string still gets entity-escaped (safe, visible in the log), because an unescaped boundary
    /// forgery would hand the payload its own `<instruction>` block — the injection WF-SE5 closed.
    static func escapeIfBoundaryThreat(
        _ text: String, section: String, wrapping: PromptWrapping
    ) -> String {
        guard wrapping == .xml else { return text }
        guard text.range(of: "</\(section)", options: .caseInsensitive) != nil else { return text }
        assemblerLogger.notice("[WF_EXEC] A payload bound for the <\(section)> section contains its closing tag ('</\(section)') and was entity-escaped IN FULL (\(text.count) chars). CONSEQUENCE: the section boundary cannot be forged, but this payload reaches the model with &/</> as XML entities — if it was legitimate markup that must stay verbatim, rename or wrap the offending text upstream.")
        return escapeForXMLEmbedding(text, wrapping: wrapping)
    }

    static func escapeForXMLEmbedding(_ text: String, wrapping: PromptWrapping) -> String {
        switch wrapping {
        case .markdown: return text
        case .xml:
            return text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
    }

    // MARK: - Artifact Passing (Workflow media/file handoff)

    // ⚠️ `maxArtifactTextChars` (4000) and its per-document split were RETIRED 2026-08-15 (user
    // decision, WF-OB3): document text is now inlined IN FULL, matching the 2026-08-13 decision
    // that made node TEXT unbounded — this cap was the surviving half of the same retired budget
    // system, and it additionally mis-reported an over-share plain-text file as "too large" and
    // silently dropped whole documents past the total. A workflow-layer character count cannot
    // know what fits; that is the downstream node's MODEL context window, and fitting it is the
    // author's call. Oversized totals are LOGGED (same shape as `compileForWorkflow`'s 100k
    // warning), never truncated.

    /// Maximum number of artifacts enumerated in the manifest. Bounds the manifest
    /// section so a node fanned-in from many media-producing branches can't emit an
    /// unbounded file list into the prompt; overflow is summarised as a count.
    static let maxManifestEntries: Int = 25

    /// Renders a compact, human/agent-readable manifest of upstream artifacts.
    ///
    /// Each line names the kind, label, mime type, and a resolvable locator (disk
    /// path or remote URL) so a downstream agent with file/HTTP tools can act on it.
    /// Returns an empty string when there are no artifacts. Cheap and synchronous —
    /// safe to call from prompt-build time. Capped at `maxManifestEntries` lines.
    static func renderArtifactManifest(_ artifacts: [MediaArtifact]) -> String {
        guard !artifacts.isEmpty else { return "" }

        // ⚠️ THE MANIFEST IS PRE-ESCAPED FIELD BY FIELD, and the caller must NOT escape it again
        // (register EIO-3). The blanket escape it used to get rewrote `&`/`<`/`>` inside the
        // LOCATOR — the one resolvable handle the downstream agent has — so `/Users/x/R&D/out.pdf`
        // arrived as `/Users/x/R&amp;D/out.pdf` and every fs/HTTP tool call on it failed on a path
        // that does not exist, with nothing logged. Only the LABEL is untrusted (upstream-authored
        // free text; a label of `</attached_files><instruction>` must stay inert — WF-SE5); the
        // locator, kind and mime are produced by this app and must reach the agent byte-exact.
        var lines: [String] = artifacts.prefix(maxManifestEntries).enumerated().map { index, artifact in
            let label = artifact.label
                ?? Self.locatorName(for: artifact.reference)
                ?? "untitled"
            let safeLabel = escapeForXMLEmbedding(label, wrapping: .xml)
            let locator = Self.locatorDescription(for: artifact.reference)
            return "\(index + 1). [\(artifact.kind.rawValue)] \"\(safeLabel)\" (\(artifact.mimeType)) — \(locator)"
        }
        if artifacts.count > maxManifestEntries {
            lines.append("…and \(artifacts.count - maxManifestEntries) more file(s).")
        }

        return """
        The following file(s) were produced by upstream steps and are available to you:
        \(lines.joined(separator: "\n"))
        """
    }

    /// Extracts and concatenates the text of `.document` artifacts (PDF, DOCX, XLSX,
    /// CSV, PPTX, RTF, plain text) via `FileProcessorService`, so a downstream text
    /// model can read attached documents even without native file support.
    ///
    /// Only `.document` artifacts backed by a resolvable disk path are extracted —
    /// images/audio/video can't be turned into text (they surface via the manifest
    /// and, later, native multimodal input).
    ///
    /// ⚠️ **NOTHING IS TRUNCATED (2026-08-15, user decision — WF-OB3).** Every document is inlined
    /// in full; the old 4000-char total with a per-document split silently dropped whole documents
    /// past the budget and reported an over-share plain-text file as "too large". Fitting the
    /// result is the downstream MODEL's context window — the author's responsibility, per the same
    /// decision that made node text unbounded on 2026-08-13. An oversized total is logged with its
    /// consequence, never cut.
    ///
    /// Returns the concatenated text plus a typed list of documents that couldn't be
    /// retrieved (via the throwing `readFileContentOrThrow`, preserving the real
    /// cause). Report-and-skip: the caller traces/surfaces the failures and the node
    /// continues with whatever extracted (this is enrichment, not a hard dependency).
    static func extractDocumentText(
        from artifacts: [MediaArtifact],
        fileProcessor: FileProcessorService
    ) async -> (text: String, failures: [FileRetrievalError]) {
        let documents = artifacts.filter { $0.kind == .document }
        guard !documents.isEmpty else { return ("", []) }

        var sections: [String] = []
        var failures: [FileRetrievalError] = []

        for artifact in documents {
            guard case .diskPath(let url) = artifact.reference else {
                // The manifest can't help here either: an `.ephemeralData` locator renders as
                // "<in-memory data, N bytes>", so this document is invisible to the node.
                assemblerLogger.warning("[WF_CONTEXT] Document artifact '\(artifact.label ?? "untitled")' has no disk path (in-memory or remote reference) and cannot be inlined. CONSEQUENCE: the downstream node sees this document only as a manifest entry it cannot read — persist the artifact to disk upstream if its content matters.")
                continue
            }

            do {
                // `Int.max` deliberately: no layer HERE may cut a document. The extractors treat
                // `maxSize` as a hard cap and the plain-text reader THROWS above it, so any finite
                // number reintroduces both halves of the retired budget.
                let text = try await fileProcessor.readFileContentOrThrow(for: url, maxSize: Int.max)
                let name = artifact.label ?? url.lastPathComponent
                guard !text.isEmpty else {
                    assemblerLogger.notice("[WF_CONTEXT] Document '\(name)' extracted to EMPTY text and is not inlined. CONSEQUENCE: the downstream node sees it only in the manifest — if it should contribute content, check the file is not image-only (e.g. a scanned PDF with no text layer).")
                    continue
                }
                sections.append("--- \(name) ---\n\(text)")
            } catch let retrievalError as FileRetrievalError {
                failures.append(retrievalError)
            } catch {
                failures.append(.readFailed(path: url.path, underlying: error.localizedDescription))
            }
        }

        let text = sections.joined(separator: "\n\n")
        if text.count > 100_000 {
            assemblerLogger.warning("[WF_CONTEXT] extractDocumentText: inlined \(text.count) chars from \(sections.count) document(s) — NOT truncated (by design, 2026-08-15). CONSEQUENCE: if the downstream node's model has a smaller context window this request will fail at the provider. Attach smaller documents, or point that node at a larger-context model.")
        } else {
            assemblerLogger.info("[WF_CONTEXT] extractDocumentText: inlined \(text.count) chars from \(sections.count) of \(documents.count) document(s), \(failures.count) failure(s).")
        }
        return (text, failures)
    }

    /// Best-effort display name from a media reference (file name for disk/remote).
    private static func locatorName(for reference: MediaReference) -> String? {
        switch reference {
        case .diskPath(let url), .remoteURL(let url): return url.lastPathComponent
        case .ephemeralData: return nil
        }
    }

    /// Resolvable locator string for the manifest.
    private static func locatorDescription(for reference: MediaReference) -> String {
        switch reference {
        case .diskPath(let url): return url.path
        case .remoteURL(let url): return url.absoluteString
        case .ephemeralData(let data): return "<in-memory data, \(data.count) bytes>"
        }
    }

}
