// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillCommandReachabilityTests.swift
//  devgenticTests
//
//  What a `/` command can reach — the one definition the picker and the send path both read.
//
//  ⚠️⚠️ THEY USED TO COMPUTE THIS SEPARATELY AND DISAGREED. The picker listed every runnable skill
//  in the library; the send-path rewrite accepted only names the profile had LINKED. So a user could
//  open `/`, see a skill, pick it, and have the literal text `/data-cleaner do the thing` delivered
//  to the model — the trigger looking, from the outside, simply broken.
//

import XCTest
import SwiftData
@testable import devgentic

final class SkillCommandReachabilityTests: XCTestCase {

    private func agent(_ selections: [SkillSelection]) -> ProfileDetails {
        .agent(AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                           tools: [], skillSelections: selections))
    }

    // MARK: - What counts as reachable

    func testALinkedEnabledSkillIsReachable() {
        let details = agent([.link(skillID: "skill_1", name: "code-review")])
        XCTAssertEqual(SkillCommandReachability.reachableNames(in: details), ["code-review"])
    }

    /// Differential: the same skill, switched off, must disappear from BOTH sides at once.
    func testADisabledSkillIsNotReachable() {
        let on = agent([.link(skillID: "skill_1", name: "code-review")])
        let off = agent([.link(skillID: "skill_1", name: "code-review", isEnabled: false)])

        XCTAssertEqual(SkillCommandReachability.reachableNames(in: on), ["code-review"],
                       "the control — without this the assertion below passes on an empty set")
        XCTAssertTrue(SkillCommandReachability.reachableNames(in: off).isEmpty)
    }

    func testNoProfileReachesNothing() {
        XCTAssertTrue(SkillCommandReachability.reachableNames(in: nil).isEmpty)
        XCTAssertFalse(SkillCommandReachability.pickerApplies(to: nil))
    }

    // MARK: - Profile kinds

    /// ⚠️ `.code` PERSISTS selections but the runtime gives Code profiles no skills. Reading the
    /// stored list would offer a directive naming something the run cannot load — the same lie in a
    /// different place.
    func testACodeProfileReachesNothingEvenThoughItStoresSelections() {
        let config = AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                                 tools: [], skillSelections: [.link(skillID: "skill_1", name: "code-review")])
        XCTAssertTrue(SkillCommandReachability.reachableNames(in: .code(config)).isEmpty)
        XCTAssertFalse(SkillCommandReachability.pickerApplies(to: .code(config)))
    }

    func testABotProfileGetsNoPickerAtAll() {
        let bot = ProfileDetails.bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        XCTAssertFalse(SkillCommandReachability.pickerApplies(to: bot))
        XCTAssertTrue(SkillCommandReachability.reachableNames(in: bot).isEmpty)
    }

    /// An agent with nothing linked still gets the picker — it has an empty state that says how to
    /// link one. That is a different thing from a profile that cannot use skills at all.
    func testAnAgentWithNothingLinkedStillGetsThePicker() {
        XCTAssertTrue(SkillCommandReachability.pickerApplies(to: agent([])))
        XCTAssertTrue(SkillCommandReachability.reachableNames(in: agent([])).isEmpty)
    }

    // MARK: - The property the split was breaking

    /// ⚠️⚠️ THE ANTI-DIVERGENCE TEST. Everything the picker offers must be something the send path
    /// actually rewrites. Both now read `reachableNames`, so this composes the two halves and
    /// asserts they agree for every offered name.
    ///
    /// **Mutation check:** widen the picker's source back to the whole library — i.e. render against
    /// a name NOT in `reachableNames` — and the raw-text arm below is what fires.
    func testEveryOfferedSkillActuallyExpandsOnSend() {
        let details = agent([
            .link(skillID: "skill_1", name: "code-review"),
            .link(skillID: "skill_2", name: "data-cleaner")
        ])
        let offered = SkillCommandReachability.reachableNames(in: details)
        XCTAssertEqual(offered.count, 2)

        for name in offered {
            let command = try! XCTUnwrap(SkillCommandParser.parse("/\(name) do the thing"))
            let rendered = SkillCommandParser.render(command, availableNames: offered)
            XCTAssertNotEqual(rendered, "/\(name) do the thing",
                              "'\(name)' was offered by the picker but the send path left it as raw text")
            XCTAssertTrue(rendered.contains("Load it with load_skill first."))
            XCTAssertTrue(rendered.hasSuffix("do the thing"), "the user's own words must survive verbatim")
        }
    }

    /// The control that makes the test above mean something: a name NOT reachable is left alone.
    /// This is the exact state the old split produced for an offered-but-unlinked skill.
    func testAnUnreachableNameIsLeftAsRawText() {
        let command = try! XCTUnwrap(SkillCommandParser.parse("/not-linked do the thing"))
        XCTAssertEqual(SkillCommandParser.render(command, availableNames: ["code-review"]),
                       "/not-linked do the thing")
    }
}

// MARK: - The wiring

/// ⚠️ The tests above pin the POLICY. This pins that the picker's filter actually applies it — a
/// policy-only suite goes green over a picker still listing the whole library, which is the exact
/// shape of the defect.
@MainActor
final class SkillCommandPickerScopeTests: XCTestCase {

    private var container: ModelContainer!
    private var store: SkillStore!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(for: DevgenticSchema.schema,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = SkillStore.shared
        store.setContainerForTesting(container)
    }

    override func tearDown() async throws {
        store?.setContainerForTesting(nil)
        store = nil
        container = nil
        try await super.tearDown()
    }

    /// **Mutation check:** drop the `reachableNames` filter in `refreshSkillSuggestions` and this
    /// goes red — the unlinked skill reappears in the picker, which is what sent raw `/name` text.
    func testThePickerOffersOnlyWhatTheProfileCanReach() throws {
        _ = try store.create(name: "linked", description: "d", body: "b").get()
        _ = try store.create(name: "not-linked", description: "d", body: "b").get()

        let vm = ChatInputViewModel()
        vm.skillSuggestionState.isShowing = true
        vm.skillSuggestionState.query = ""
        vm.refreshSkillSuggestions(reachableNames: ["linked"])

        XCTAssertEqual(vm.skillSuggestionState.filteredItems.map(\.name), ["linked"],
                       "a skill the send path would refuse must never be offered")
    }

    /// The control: with both reachable, both are offered — so the assertion above is about the
    /// filter and not about the library being empty.
    func testBothAreOfferedWhenBothAreReachable() throws {
        _ = try store.create(name: "alpha", description: "d", body: "b").get()
        _ = try store.create(name: "beta", description: "d", body: "b").get()

        let vm = ChatInputViewModel()
        vm.skillSuggestionState.isShowing = true
        vm.refreshSkillSuggestions(reachableNames: ["alpha", "beta"])

        XCTAssertEqual(vm.skillSuggestionState.filteredItems.map(\.name).sorted(), ["alpha", "beta"])
    }
}

// MARK: - The send-path orphan guard

/// ⚠️⚠️ EVERY OTHER TEST FOR `/skill` EXERCISES A PURE FUNCTION. This one asserts that the COMPOSER
/// STILL CALLS IT.
///
/// `SkillCommandParser.render` is well covered, and `ComposerSuggestionKeyRoutingTests` guards the
/// keyboard half. Nothing guarded the SEND half: delete the `expandSkillCommand(in:)` call from
/// `ChatInputAreaView`'s send path and every skill command silently degrades to plain text — the
/// model receives a literal `/code-review do the thing`, has no idea a skill was meant, and the
/// whole suite stays green. That is the same defect shape as the keyboard-dead picker, one layer
/// further down, and it is the reason the keyboard fix alone was not enough.
///
/// Asserted on the source because the send path runs inside a SwiftUI view with no reachable seam.
final class SkillCommandSendPathOrphanTests: XCTestCase {

    /// **Mutation check:** replace `expandSkillCommand(in: attributedString)` with
    /// `attributedString` at the send site and this goes red.
    func testTheComposerStillExpandsSkillCommandsOnSend() throws {
        let source = try Self.read("Devgentic/Interfaces/Shared/ChatInput/ChatInputAreaView.swift")

        XCTAssertTrue(source.contains("private func expandSkillCommand("),
                      "the rewrite must still exist")

        // ⚠️ Anchored on the CALL INSIDE THE SEND, not merely on the function existing. A private
        // method with no caller compiles, warns about nothing useful, and is exactly the state this
        // guard exists to catch.
        XCTAssertTrue(source.contains("onSendMessage(expandSkillCommand("),
                      "the send path must pass the message THROUGH the rewrite — without this call a `/skill` command is sent as literal text and the model never learns a skill was intended")
    }

    /// ⚠️ The rewrite must sit on the SUCCESS arm of profile resolution. Expanding a command for a
    /// profile that cannot be resolved would send a directive naming a skill the run never gets.
    func testTheExpansionHappensOnlyAfterTheProfileResolves() throws {
        let source = try Self.read("Devgentic/Interfaces/Shared/ChatInput/ChatInputAreaView.swift")
        let resolve = try XCTUnwrap(source.range(of: "switch backendConfiguration.resolveRequestConfig()"))
        let call = try XCTUnwrap(source.range(of: "onSendMessage(expandSkillCommand("))
        XCTAssertTrue(resolve.lowerBound < call.lowerBound,
                      "the command is expanded only once a config resolved — otherwise the directive names a skill this send will never have")
    }

    /// ⚠️ The send path and the picker must read the SAME reachable set. Computing it independently
    /// at each site is precisely how the two came to disagree once already.
    func testTheSendPathUsesTheSameReachableSetAsThePicker() throws {
        let source = try Self.read("Devgentic/Interfaces/Shared/ChatInput/ChatInputAreaView.swift")
        XCTAssertTrue(source.contains("SkillCommandParser.render(command, availableNames: reachableSkillNames)"),
                      "the send path must render against `reachableSkillNames` — the same value the picker filters by")
        XCTAssertTrue(source.contains("SkillCommandReachability.reachableNames("),
                      "and that value must come from the shared reachability rule, not a second derivation")
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath) from \(#filePath) — source-reading tests need the checkout present.")
    }
}
