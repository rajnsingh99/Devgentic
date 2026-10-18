// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillCommandReachabilityTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class SkillCommandReachabilityTests: XCTestCase {

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

    private func agentConfig(_ selections: [SkillSelection]) -> AgentConfig {
        AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                    tools: [], skillSelections: selections)
    }

    private func agent(_ selections: [SkillSelection]) -> ProfileDetails { .agent(agentConfig(selections)) }

    private func skill(_ name: String, display: String? = nil, description: String = "d") throws -> SkillSD {
        try store.create(name: name, displayName: display, description: description, body: "b").get()
    }

    // MARK: - What counts as reachable

    func testALinkedEnabledSkillIsOffered() throws {
        let review = try skill("code-review")
        let offer = SkillCommandReachability.offer(in: agent([.link(skillID: review.id, name: "code-review")]), store: store)
        XCTAssertEqual(offer.skills.map(\.skillID), [review.id])
        XCTAssertEqual(offer.names, ["code-review"])
    }

    /// Differential: the same skill, switched off, must disappear from BOTH sides at once.
    func testADisabledSkillIsNotOffered() throws {
        let review = try skill("code-review")
        let on = agent([.link(skillID: review.id, name: "code-review")])
        let off = agent([.link(skillID: review.id, name: "code-review", isEnabled: false)])

        XCTAssertEqual(SkillCommandReachability.offer(in: on, store: store).names, ["code-review"],
                       "the control — without this the assertion below passes on an empty set")
        XCTAssertTrue(SkillCommandReachability.offer(in: off, store: store).names.isEmpty)
    }

    /// A link to a skill that is still a DRAFT reaches no run, so it must not be offered or expanded.
    /// The old name-only rule offered it: the selection was enabled, whatever the library said.
    func testALinkedDraftIsNotOffered() throws {
        let draft = try store.create(name: "half-done", description: "d", body: "b", isDraft: true).get()
        let offer = SkillCommandReachability.offer(in: agent([.link(skillID: draft.id, name: "half-done")]), store: store)
        XCTAssertTrue(offer.skills.isEmpty)
    }

    /// A profile pinned to an older version is shown THAT version's description — the sentence the
    /// model will route on in this profile's runs, not `latest`'s.
    func testAPinnedProfileIsShownItsPinnedDescription() throws {
        let tutor = try skill("tutor", description: "v1 description")
        let v1 = try XCTUnwrap(tutor.latestVersion?.id)
        _ = try store.addVersion(toSkillWithID: tutor.id, description: "v2 description", body: "b2",
                                 allowedTools: nil, files: [], note: "v2").get()

        let pinned = SkillCommandReachability.offer(
            in: agent([.link(skillID: tutor.id, name: "tutor", pinnedVersionID: v1)]), store: store)
        let following = SkillCommandReachability.offer(
            in: agent([.link(skillID: tutor.id, name: "tutor")]), store: store)

        XCTAssertEqual(pinned.skills.map(\.description), ["v1 description"])
        XCTAssertEqual(following.skills.map(\.description), ["v2 description"], "the control")
    }

    func testNoProfileReachesNothing() {
        XCTAssertTrue(SkillCommandReachability.offer(in: nil, store: store).skills.isEmpty)
        XCTAssertFalse(SkillCommandReachability.pickerApplies(to: nil))
    }

    // MARK: - Profile kinds

    /// ⚠️ `.code` PERSISTS selections but the runtime gives Code profiles no skills. Reading the
    /// stored list would offer a directive naming something the run cannot load — the same lie in a
    /// different place.
    func testACodeProfileReachesNothingEvenThoughItStoresSelections() throws {
        let review = try skill("code-review")
        let config = agentConfig([.link(skillID: review.id, name: "code-review")])
        XCTAssertEqual(SkillCommandReachability.offer(in: .agent(config), store: store).names, ["code-review"],
                       "the control — the same selections DO reach an agent")
        XCTAssertTrue(SkillCommandReachability.offer(in: .code(config), store: store).skills.isEmpty)
        XCTAssertFalse(SkillCommandReachability.pickerApplies(to: .code(config)))
    }

    func testABotProfileGetsNoPickerAtAll() {
        let bot = ProfileDetails.bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        XCTAssertFalse(SkillCommandReachability.pickerApplies(to: bot))
        XCTAssertTrue(SkillCommandReachability.offer(in: bot, store: store).skills.isEmpty)
    }

    /// An agent with nothing linked still gets the picker — it has an empty state that says how to
    /// link one. That is a different thing from a profile that cannot use skills at all.
    func testAnAgentWithNothingLinkedStillGetsThePicker() {
        XCTAssertTrue(SkillCommandReachability.pickerApplies(to: agent([])))
        XCTAssertTrue(SkillCommandReachability.offer(in: agent([]), store: store).skills.isEmpty)
    }

    // MARK: - The property the split was breaking

    /// ⚠️⚠️ THE ANTI-DIVERGENCE TEST. Everything the picker offers must be something the send path
    /// actually rewrites. Both read `SkillCommandOffer`, so this composes the two halves and asserts
    /// they agree for every offered name.
    func testEveryOfferedSkillActuallyExpandsOnSend() throws {
        let review = try skill("code-review")
        let cleaner = try skill("data-cleaner")
        let offer = SkillCommandReachability.offer(in: agent([
            .link(skillID: review.id, name: "code-review"),
            .link(skillID: cleaner.id, name: "data-cleaner")
        ]), store: store)
        XCTAssertEqual(offer.skills.count, 2)

        for name in offer.names {
            let command = try XCTUnwrap(SkillCommandParser.parse("/\(name) do the thing"))
            let rendered = SkillCommandParser.render(command, availableNames: offer.names)
            XCTAssertNotEqual(rendered, "/\(name) do the thing",
                              "'\(name)' was offered by the picker but the send path left it as raw text")
            XCTAssertTrue(rendered.contains("Load it with load_skill first."))
            XCTAssertTrue(rendered.hasSuffix("do the thing"), "the user's own words must survive verbatim")
        }
    }

    /// The control that makes the test above mean something: a name NOT reachable is left alone.
    func testAnUnreachableNameIsLeftAsRawText() throws {
        let command = try XCTUnwrap(SkillCommandParser.parse("/not-linked do the thing"))
        XCTAssertEqual(SkillCommandParser.render(command, availableNames: ["code-review"]),
                       "/not-linked do the thing")
    }

    /// ⚠️⚠️ THE PICKER MUST OFFER EXACTLY WHAT THE RUN LOADS. Same selections, two readers: the offer
    /// and the resolution `AgentConnect` uses. Any filter added to one and not the other fails here.
    func testTheOfferIsExactlyWhatTheRunResolves() throws {
        let a = try skill("learn", display: "Spanish tutor")
        let b = try skill("learn", display: "Swift coach")
        let c = try skill("code-review")
        let d = try skill("off")
        let config = agentConfig([
            .link(skillID: a.id, name: "learn"), .link(skillID: b.id, name: "learn"),
            .link(skillID: c.id, name: "code-review"), .link(skillID: d.id, name: "off", isEnabled: false)
        ])
        let run = try XCTUnwrap(SkillResolution.resolve(for: config, profileName: "test", store: store))
        let offer = SkillCommandReachability.offer(in: .agent(config), store: store)

        XCTAssertEqual(offer.skills.map(\.skillID), run.manifests.map(\.folderPath))
        XCTAssertEqual(offer.collisions, run.nameCollisions)
    }
}

// MARK: - Overlapping verbs (two skills with one name)

/// ⚠️⚠️ THE `/learn` DEFECT, PINNED. Skills are addressed by NAME at run time, so two library skills
/// called `learn` are one command. The picker filtered the library by name and showed a row for
/// each — including an UNLINKED or DISABLED copy — while every row inserted the identical `/learn`
/// and the run loaded the copy whose id sorted first. Picking "Spanish tutor" ran "Swift coach".
///
/// **Mutation checks:** revert the picker to `fetchRunnableSkills().filter { names.contains($0.name) }`
/// and all three case tests go red (two rows instead of one).
@MainActor
final class SkillCommandOverlappingVerbTests: XCTestCase {

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

    private func agent(_ selections: [SkillSelection]) -> ProfileDetails {
        .agent(AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                           tools: [], skillSelections: selections))
    }

    private func twoLearns() throws -> (spanish: SkillSD, swift: SkillSD) {
        (try store.create(name: "learn", displayName: "Spanish tutor", description: "Learn Spanish", body: "A").get(),
         try store.create(name: "learn", displayName: "Swift coach", description: "Learn Swift", body: "B").get())
    }

    private func picker(_ details: ProfileDetails, query: String = "learn") -> ChatInputViewModel {
        let vm = ChatInputViewModel()
        vm.skillSuggestionState.isShowing = true
        vm.skillSuggestionState.query = query
        vm.refreshSkillSuggestions(offer: SkillCommandReachability.offer(in: details, store: store))
        return vm
    }

    /// Case 1 — both linked. ONE row, and it is the copy the run will load; the collision is said.
    func testBothLinkedOffersOnlyTheCopyTheRunLoads() throws {
        let (spanish, swift) = try twoLearns()
        let details = agent([.link(skillID: spanish.id, name: "learn"), .link(skillID: swift.id, name: "learn")])
        guard case .agent(let config) = details else { return XCTFail() }
        let winner = try XCTUnwrap(SkillResolution.resolve(for: config, profileName: "t", store: store)?.manifests.first)

        let vm = picker(details)
        XCTAssertEqual(vm.skillSuggestionState.filteredItems.map(\.id), [winner.folderPath],
                       "the only row must be the copy `load_skill` will actually return")
        let note = try XCTUnwrap(vm.skillSuggestionState.collisionNotes.first)
        XCTAssertTrue(note.contains("/learn"))
        XCTAssertTrue(note.contains(winner.folderPath == spanish.id ? "Spanish tutor" : "Swift coach"),
                      "the note must name the reachable copy: \(note)")
    }

    /// Case 2 — only Spanish linked. The unlinked Swift coach must not be offered, and nothing collides.
    func testAnUnlinkedSameNameSkillIsNotOffered() throws {
        let (spanish, _) = try twoLearns()
        let vm = picker(agent([.link(skillID: spanish.id, name: "learn")]))
        XCTAssertEqual(vm.skillSuggestionState.filteredItems.map(\.id), [spanish.id])
        XCTAssertEqual(vm.skillSuggestionState.filteredItems.map(\.description), ["Learn Spanish"])
        XCTAssertTrue(vm.skillSuggestionState.collisionNotes.isEmpty)
    }

    /// Case 3 — Swift coach linked but switched off. Only the enabled copy is offered.
    func testADisabledSameNameSkillIsNotOffered() throws {
        let (spanish, swift) = try twoLearns()
        let vm = picker(agent([.link(skillID: spanish.id, name: "learn"),
                               .link(skillID: swift.id, name: "learn", isEnabled: false)]))
        XCTAssertEqual(vm.skillSuggestionState.filteredItems.map(\.id), [spanish.id])
        XCTAssertTrue(vm.skillSuggestionState.collisionNotes.isEmpty)
    }

    /// A note about a name the query filtered away explains nothing and must not show.
    func testACollisionNoteHidesWithItsRow() throws {
        let (spanish, swift) = try twoLearns()
        let review = try store.create(name: "code-review", description: "d", body: "b").get()
        let vm = picker(agent([.link(skillID: spanish.id, name: "learn"), .link(skillID: swift.id, name: "learn"),
                               .link(skillID: review.id, name: "code-review")]), query: "code")
        XCTAssertEqual(vm.skillSuggestionState.filteredItems.map(\.name), ["code-review"])
        XCTAssertTrue(vm.skillSuggestionState.collisionNotes.isEmpty)
    }
}

// MARK: - The wiring

/// ⚠️ The tests above pin the POLICY. This pins that the picker builds its rows from the offer it is
/// given — a policy-only suite goes green over a picker still listing the whole library.
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

    private func agent(_ selections: [SkillSelection]) -> ProfileDetails {
        .agent(AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                           tools: [], skillSelections: selections))
    }

    /// **Mutation check:** make `refreshSkillSuggestions` read the library instead of the offer and
    /// this goes red — the unlinked skill reappears in the picker, which is what sent raw `/name` text.
    func testThePickerOffersOnlyWhatTheProfileCanReach() throws {
        let linked = try store.create(name: "linked", description: "d", body: "b").get()
        _ = try store.create(name: "not-linked", description: "d", body: "b").get()

        let vm = ChatInputViewModel()
        vm.skillSuggestionState.isShowing = true
        vm.skillSuggestionState.query = ""
        vm.refreshSkillSuggestions(offer: SkillCommandReachability.offer(
            in: agent([.link(skillID: linked.id, name: "linked")]), store: store))

        XCTAssertEqual(vm.skillSuggestionState.filteredItems.map(\.name), ["linked"],
                       "a skill the send path would refuse must never be offered")
    }

    /// The control: with both reachable, both are offered — so the assertion above is about the
    /// filter and not about the library being empty.
    func testBothAreOfferedWhenBothAreReachable() throws {
        let alpha = try store.create(name: "alpha", description: "d", body: "b").get()
        let beta = try store.create(name: "beta", description: "d", body: "b").get()

        let vm = ChatInputViewModel()
        vm.skillSuggestionState.isShowing = true
        vm.refreshSkillSuggestions(offer: SkillCommandReachability.offer(
            in: agent([.link(skillID: alpha.id, name: "alpha"), .link(skillID: beta.id, name: "beta")]), store: store))

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
        XCTAssertTrue(source.contains("SkillCommandParser.render(command, availableNames: skillCommandOffer.names)"),
                      "the send path must render against `skillCommandOffer` — the same value the picker is built from")
        XCTAssertTrue(source.contains("inputViewModel.refreshSkillSuggestions(offer: skillCommandOffer)"),
                      "and the picker must be built from that same value")
        XCTAssertTrue(source.contains("SkillCommandReachability.offer("),
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
