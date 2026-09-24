// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeSystemPromptTests.swift
//  devgenticTests
//
//  The Code system prompt had NO test coverage at all, despite being the largest behavioural
//  surface in Code mode.
//
//  ⚠️ These deliberately assert almost nothing about WORDING. A test that pinned the prose would
//  be the drift test this project has been burned by before — red on a correct rewrite, useless
//  against a real regression. What they guard is the handful of things that must hold however the
//  text is phrased:
//
//    1. The project root reaches the model. A prompt without it is what let a Code session walk
//       the user's home directory (field-observed 2026-09-20).
//    2. The prompt does not CONTRADICT the runtime. Until 2026-09-20 it told the model that
//       cross-folder reads were legitimate — then `WorkspaceBoundary` started interrupting the
//       user to approve them. Prompt and enforcement have to describe the same product.
//

import XCTest
@testable import devgentic

final class CodeSystemPromptTests: XCTestCase {

    private let projectPath = "/Users/someone/Projects/guest-service"
    private let projectName = "guest-service"

    private func prompt(for provider: ApiProvider, context: String? = nil) -> String {
        CodeSystemPrompt.production(
            projectPath: projectPath,
            projectName: projectName,
            currentDate: "20/9/2026",
            apiProvider: provider,
            projectContext: context
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

    // MARK: - Project memory

    func testProjectContextIsInjectedWhenPresentAndAbsentOtherwise() {
        let marker = "ZZ_PROJECT_MEMORY_MARKER_ZZ"

        for provider in [ApiProvider.anthropic, .ollama] {
            let withContext = prompt(for: provider, context: marker)
            let without = prompt(for: provider, context: nil)

            XCTAssertTrue(withContext.contains(marker),
                          "\(provider) variant dropped .devgentic/context.md from the prompt.")
            XCTAssertFalse(without.contains(marker),
                           "\(provider) variant leaked project memory when there was none.")
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
}
