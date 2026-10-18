// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeSystemPromptTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class CodeSystemPromptTests: XCTestCase {

    private let projectPath = "/Users/someone/Projects/guest-service"
    private let projectName = "guest-service"

    private func prompt(for provider: ApiProvider, _ wording: CodeSystemPrompt.Wording = .full) -> String {
        CodeSystemPrompt.production(
            projectPath: projectPath,
            projectName: projectName,
            currentDate: "20/9/2026",
            apiProvider: provider,
            wording: wording
        )
    }

    /// Anthropic gets the XML variant; everything else gets markdown. Both must satisfy the same
    /// invariants — a rule that holds in one dialect and not the other is a rule the user cannot
    /// rely on after switching provider.
    private var everyVariant: [(name: String, text: String)] {
        [
            ("anthropic/XML", prompt(for: .anthropic)),
            ("ollama/markdown", prompt(for: .ollama)),
            ("openAI/markdown", prompt(for: .openAI)),
            ("mlx/markdown", prompt(for: .mlx)),
            ("anthropic/XML compact", prompt(for: .anthropic, .compact)),
            ("mlx/markdown compact", prompt(for: .mlx, .compact)),
        ]
    }

    // MARK: - The root must reach the model

    func testEveryVariantNamesTheProjectRoot() {
        for variant in everyVariant {
            XCTAssertTrue(
                variant.text.contains(projectPath),
                "\(variant.name) does not name the project root. Without it the model has no idea "
                + "which folder it is working in — the exact state in which a Code session called "
                + "list_directory on the user's home directory."
            )
        }
    }

    func testEveryVariantIsSubstantial() {
        // Guards the failure MODE rather than the content: an empty or near-empty prompt means the
        // model fell back to "You are a helpful AI assistant.", which is what actually shipped.
        for variant in everyVariant {
            XCTAssertGreaterThan(
                variant.text.count, 1_000,
                "\(variant.name) is suspiciously short — the Code prompt carries the tool workflow, "
                + "path rules and safety sections; a stub here means the model is running unguided."
            )
        }
    }

    // MARK: - Prompt must not contradict the runtime

    func testNoVariantSanctionsUnpromptedCrossFolderWork() {
        // ⚠️ Asserts the ABSENCE of a retired instruction, not the presence of a new one — so
        // rewording the replacement freely is fine, and only REINTRODUCING the contradiction fails.
        //
        // The retired line read: "For legitimate cross-folder work (reading a shared header, a
        // config in another repo), pass an explicit absolute path. Prefer read-only tools in that
        // case." `WorkspaceBoundary` now parks the run on a confirmation banner for exactly that,
        // so telling the model it is routine sets the user up to be interrupted by design.
        for variant in everyVariant {
            XCTAssertFalse(
                variant.text.lowercased().contains("cross-folder"),
                "\(variant.name) still tells the model cross-folder work is legitimate, but the "
                + "runtime now asks the user to approve every out-of-project read. Prompt and "
                + "enforcement must describe the same product."
            )
        }
    }

    func testEveryVariantSaysWritesOutsideTheProjectAreRefused() {
        // The one positive claim worth pinning, because getting it wrong wastes the user's turns:
        // a model that believes an outside write MIGHT work will try one and burn an iteration on
        // a refusal. Matched loosely — any of these words satisfies it.
        for variant in everyVariant {
            let lower = variant.text.lowercased()
            let statesTheRule = lower.contains("refus") || lower.contains("never modify files outside")
            XCTAssertTrue(
                statesTheRule,
                "\(variant.name) does not tell the model that writing outside the project is refused."
            )
        }
    }

    func testNoVariantSaysAPlainReplyIsDiscarded() {
        // ⚠️ Absence of the retired claim, plus the runtime fact — not the wording around it.
        //
        // The retired line read: "Do NOT end a turn by emitting plain assistant text — that output
        // is discarded. You MUST use `final_answer`." Since the answer-vs-call verdict (2026-10-05)
        // a reply with no tool call IS the final answer (`.genuineCompletion` → `.completed`). The
        // false claim kept small models exploring the project on questions that needed no tools,
        // even when the user said "Don't use any tools".
        for variant in everyVariant {
            let lower = variant.text.lowercased()
            XCTAssertFalse(lower.contains("discarded"),
                           "\(variant.name) still says a plain reply is discarded; it is the final answer.")
            XCTAssertFalse(lower.contains("only way to deliver"),
                           "\(variant.name) still says `final_answer` is the only way to answer.")
            XCTAssertTrue(lower.contains("plain text") && lower.contains("no tool call"),
                          "\(variant.name) does not tell the model a plain reply with no tool call is an answer.")
        }
    }

    // MARK: - Project memory

    /// The stored prompt never carries project content: `AGENTS.md` and memory are appended per run.
    func testTheStoredPromptCarriesNoProjectContent() {
        for variant in everyVariant {
            XCTAssertFalse(variant.text.contains("context.md"), "\(variant.name) still names the retired context.md.")
            XCTAssertTrue(variant.text.contains("AGENTS.md"), "\(variant.name) does not tell the model about AGENTS.md.")
            for tool in ["remember", "forget", "recall"] {
                XCTAssertTrue(variant.text.contains("`\(tool)`"), "\(variant.name) does not explain `\(tool)`.")
            }
        }
    }

    func testProjectKnowledgeSectionCarriesBothPartsAndNothingWhenEmpty() {
        for provider in [ApiProvider.anthropic, .ollama] {
            let both = CodeSystemPrompt.projectKnowledgeSection(
                agentsInstructions: "ZZ_AGENTS_ZZ", memoryListing: "- [command] test — ZZ_MEMORY_ZZ", apiProvider: provider)
            XCTAssertTrue(both?.contains("ZZ_AGENTS_ZZ") == true, "\(provider) dropped AGENTS.md")
            XCTAssertTrue(both?.contains("ZZ_MEMORY_ZZ") == true, "\(provider) dropped the memory listing")
            XCTAssertNil(CodeSystemPrompt.projectKnowledgeSection(agentsInstructions: nil, memoryListing: nil, apiProvider: provider))
        }
    }

    // MARK: - Dialect routing

    func testAnthropicGetsXmlAndOthersDoNot() {
        // Not a wording assertion — the dialect split is a routing decision with a stated reason
        // (Claude's trained preference), and silently collapsing it would change every Code run.
        XCTAssertTrue(prompt(for: .anthropic).contains("<project_root>"),
                      "Anthropic must receive the XML variant.")
        XCTAssertFalse(prompt(for: .ollama).contains("<project_root>"),
                       "Non-Anthropic providers must receive the markdown variant.")
    }

    // MARK: - Phase 4: one source, SDLC phases, compact wording

    /// The rules the device runs earned, in EVERY wording — compact is fewer words, not fewer rules.
    func testEveryWordingCarriesTheSameRules() {
        let rules: [(String, String)] = [
            ("never edit a file you have not seen", "T2/T7 edited files that did not exist instead of creating them"),
            ("create_new_file", "the tool for a file that does not exist yet"),
            ("same arguments", "T3/T4 repeated the same call 3-5 times"),
            ("state only what a tool showed you", "T5 reported line counts for files it never read"),
            ("answer now in plain text with no tool call", "a question that needs no project files is answered at once"),
            ("run_command", "verify with the build or tests"),
            ("ask_user", "how to ask the user"),
            ("remember", "project memory"),
            ("recall", "project memory"),
        ]
        for variant in everyVariant {
            let lower = variant.text.lowercased()
            for (rule, why) in rules {
                XCTAssertTrue(lower.contains(rule.lowercased()), "\(variant.name) lost '\(rule)' — \(why)")
            }
        }
    }

    func testThePhasesComeInOrder() {
        for provider in [ApiProvider.anthropic, .mlx] {
            let text = prompt(for: provider)
            let marks = ["1. Decide first", "2. Understand", "3. Plan", "4. Change", "5. Verify", "6. Report"]
            let positions = marks.compactMap { text.range(of: $0)?.lowerBound }
            XCTAssertEqual(positions.count, marks.count, "\(provider) is missing a phase")
            XCTAssertEqual(positions, positions.sorted(), "\(provider) has the phases out of order")
        }
    }

    /// The drift this rewrite ends: the XML copy never got the background-task guidance.
    func testMarkdownAndXMLNameTheSameTools() {
        func toolNames(_ text: String) -> Set<String> {
            Set(text.components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
                .filter { $0.contains("_") && !$0.contains(" ") })
        }
        for wording in [CodeSystemPrompt.Wording.full, .compact] {
            XCTAssertEqual(toolNames(prompt(for: .anthropic, wording)), toolNames(prompt(for: .mlx, wording)),
                           "the \(wording) wording names different tools in XML and markdown")
        }
        XCTAssertTrue(prompt(for: .anthropic).contains("start_background_task"),
                      "the XML prompt still lacks the background-task guidance")
    }

    func testTheCompactWordingIsMateriallyShorter() {
        for provider in [ApiProvider.anthropic, .mlx] {
            let full = prompt(for: provider).count
            let compact = prompt(for: provider, .compact).count
            XCTAssertLessThan(Double(compact), Double(full) * 0.6, "\(provider): compact \(compact) vs full \(full) chars")
        }
    }

    @MainActor func testTierPicksTheWordingOnly() {
        XCTAssertEqual(CodeSystemPrompt.Wording.forTier(.tiny), .compact)
        XCTAssertEqual(CodeSystemPrompt.Wording.forTier(.small), .compact)
        XCTAssertEqual(CodeSystemPrompt.Wording.forTier(.medium), .full)
        XCTAssertEqual(CodeSystemPrompt.Wording.forTier(nil), .full, "an unknown size gets the full wording")

        let tiny = CodeSessionManager.instructions(forProject: projectPath, apiProvider: .mlx, tier: .tiny)
        let large = CodeSessionManager.instructions(forProject: projectPath, apiProvider: .mlx, tier: .large)
        XCTAssertTrue(tiny.contains("You are a coding assistant working directly"), "a tiny model did not get the compact wording")
        XCTAssertTrue(large.contains("You work in phases"), "a large model did not get the full wording")
    }

    /// The background-run path (a wake or resume for another project) builds the prompt itself; it
    /// must honour the model's size too.
    @MainActor func testARunBoundToAnotherProjectGetsItsModelsWording() throws {
        let suite = "CodePromptWording.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("wording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }

        var llm = ProviderConfig(apiProvider: .mlx, modelName: "tiny-model")
        llm.modelMetadata = ModelMetadata(tier: .tiny)
        var config = AgentConfig(llmConfig: llm, tools: CodeToolPreset.defaultTools, historyStrategy: .pointer)
        config.projectPath = "/somewhere/else"
        config.instructions = "PROMPT FOR THE OPEN PROJECT"
        let bound = CodeSessionManager.profile(BackendProfileSnapshot(displayName: "Code Session", details: .code(config)),
                                               forConversationProject: target.path, defaults: defaults)
        guard case .code(let boundConfig) = bound.details else { return XCTFail("not code") }
        XCTAssertTrue(boundConfig.instructions?.contains("You are a coding assistant working directly") == true,
                      "a tiny model's background run got the full wording")
    }
}
