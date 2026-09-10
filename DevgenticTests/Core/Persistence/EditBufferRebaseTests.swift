// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  EditBufferRebaseTests.swift
//  DevgenticTests
//
//  Created on 07/08/26.
//
//  Regression tests for the edit-buffer bypass cluster (register A1–A6).
//
//  ⚠️ The shared root of all six: several surfaces persist ONE facet of a profile while a detail
//  editor is open on it, and none of them re-baselined the buffer. The symptoms looked unrelated —
//  a Revert that restores the wrong thing, a just-saved workflow that stays dirty, a chat chip that
//  reverts editor work — but they are one missing operation, so they are pinned in one file.
//

import XCTest
@testable import devgentic

// MARK: - Mock Store

private final class RebaseMockStore: BackendProfileStoreProtocol {
    var profiles: [BackendProfileSnapshot] = []
    var fetchByIdCallCount = 0
    var shouldThrowOnFetchById = false

    func fetchProfiles() throws -> [BackendProfileSnapshot] { profiles }

    func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? {
        fetchByIdCallCount += 1
        if shouldThrowOnFetchById {
            throw ProfileStoreError.fetchFailed(underlying: NSError(domain: "test", code: 1))
        }
        return profiles.first { $0.id == id }
    }

    func saveProfile(_ snapshot: BackendProfileSnapshot,
                     callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError] {
        if let idx = profiles.firstIndex(where: { $0.id == snapshot.id }) {
            profiles[idx] = snapshot
        } else {
            profiles.append(snapshot)
        }
        return []  // A34: a double has no advisories to report.
    }

    func deleteProfile(withId id: UUID) throws {
        profiles.removeAll { $0.id == id }
    }
}

// MARK: - Buffer semantics

@MainActor
final class ProfileEditBufferRebaseTests: XCTestCase {

    private func makeAgent(name: String, instructions: String? = nil) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: name,
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                instructions: instructions
            ))
        )
    }

    /// The clean case: an out-of-band write with no other pending edits leaves the editor clean,
    /// so the phantom Save/Revert pills go away.
    func testRebaseClearsDirtyWhenTheDraftMatchesWhatWasPersisted() {
        let original = makeAgent(name: "Agent", instructions: "v1")
        let buffer = ProfileEditBuffer(profile: original)

        // Someone else persisted a change and pushed it into the draft (Tool Library shape).
        var persisted = original
        persisted.displayName = "Agent Renamed"
        buffer.draft = persisted

        XCTAssertTrue(buffer.isDirty, "before rebase the editor believes this is an unsaved edit")
        buffer.rebase(onto: persisted)
        XCTAssertFalse(buffer.isDirty)
    }

    /// ⚠️ The reason this is `rebase` and not `markSaved`. The user has unsaved instructions in the
    /// editor; a Tool Library save must not declare those saved too.
    func testRebasePreservesUnrelatedPendingEdits() {
        let original = makeAgent(name: "Agent", instructions: "v1")
        let buffer = ProfileEditBuffer(profile: original)

        // What the OTHER surface wrote to disk.
        var persisted = original
        persisted.displayName = "Renamed elsewhere"

        // The user's own in-flight edit, plus that same out-of-band change.
        var draft = persisted
        draft.details = .agent(AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
            instructions: "user is still typing"
        ))
        buffer.draft = draft

        buffer.rebase(onto: persisted)

        XCTAssertTrue(buffer.isDirty, "the user's instructions are still unsaved")
        if case .agent(let cfg) = buffer.draft.details {
            XCTAssertEqual(cfg.instructions, "user is still typing", "draft must not be touched")
        } else {
            XCTFail("draft details were replaced")
        }
    }

    /// ⚠️ The defect this cluster is named for. Revert must restore what is ON DISK; before the
    /// rebase it restored a superseded snapshot while disk kept the newer one.
    func testRevertAfterRebaseRestoresThePersistedStateNotTheSupersededOne() {
        let original = makeAgent(name: "Agent", instructions: "v1")
        let buffer = ProfileEditBuffer(profile: original)

        var persisted = original
        persisted.displayName = "Saved by the Tool Library"
        buffer.draft = persisted
        buffer.rebase(onto: persisted)

        // User then types something and changes their mind.
        buffer.draft.displayName = "half-typed"
        buffer.revert()

        XCTAssertEqual(buffer.draft.displayName, "Saved by the Tool Library",
                       "Revert must not resurrect the pre-save name")
    }

    /// `markSaved` is still the right call when the buffer's OWN draft was what got persisted —
    /// this pins the distinction so the two do not get merged later.
    func testMarkSavedStillPromotesTheWholeDraft() {
        let buffer = ProfileEditBuffer(profile: makeAgent(name: "Agent"))
        buffer.draft.displayName = "edited"
        buffer.markSaved()
        XCTAssertFalse(buffer.isDirty)
        XCTAssertEqual(buffer.original.displayName, "edited")
    }
}

// MARK: - Service wiring

@MainActor
final class BackendProfileServiceRebaseTests: XCTestCase {

    private var store: RebaseMockStore!
    private var service: BackendProfileService!

    private func makeBot(name: String) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: name,
            details: .bot(BotConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")
            ))
        )
    }

    override func setUp() {
        store = RebaseMockStore()
        store.profiles = [makeBot(name: "Alpha"), makeBot(name: "Beta")]
        service = BackendProfileService(store: store)
    }

    // MARK: - A2: the editor must read the store, not the cached array

    /// ⚠️ The auto-heal regression. `BackendOrchestrationService.disableThinkingOnProfile` and
    /// `MLXContextWindowHealer` write straight to the store without refreshing `profiles`; opening
    /// the editor from that stale array showed the pre-heal value, and saving any unrelated field
    /// wrote it back — so the provider 400 the healer had just fixed returned on the next send.
    func testActivateEditBufferReadsThroughToTheStore() {
        let target = store.profiles[0]

        // Simulate an out-of-band write that the service's cached array never saw.
        var healed = target
        healed.displayName = "Healed out of band"
        store.profiles[0] = healed
        XCTAssertEqual(service.profiles[0].displayName, "Alpha", "precondition: cache is stale")

        service.activateEditBuffer(for: target.id)

        XCTAssertEqual(service.editBuffer?.draft.displayName, "Healed out of band")
        XCTAssertFalse(service.editBuffer?.isDirty ?? true,
                       "a freshly opened editor is never dirty")
        XCTAssertEqual(service.profiles[0].displayName, "Healed out of band",
                       "the sidebar row must not disagree with the editor")
    }

    /// A store read can fail; that must degrade to the cached copy rather than refusing to open.
    func testActivateEditBufferFallsBackToCacheWhenTheStoreThrows() {
        store.shouldThrowOnFetchById = true
        let target = service.profiles[0]

        service.activateEditBuffer(for: target.id)

        XCTAssertEqual(service.editBuffer?.draft.id, target.id)
        XCTAssertEqual(service.editBuffer?.draft.displayName, "Alpha")
    }

    /// ⚠️ Previously an unknown id left the PREVIOUS buffer active — so the editor kept showing,
    /// and could save, a profile the router had already navigated away from (⌘⇧P on a first run
    /// with an empty store did exactly this).
    func testActivateEditBufferClearsTheBufferForAnUnknownProfile() {
        service.activateEditBuffer(for: service.profiles[0].id)
        XCTAssertNotNil(service.editBuffer)

        service.activateEditBuffer(for: UUID())
        XCTAssertNil(service.editBuffer)
    }

    // MARK: - A1 / A5: re-baselining through the service

    func testRebaseEditBufferUpdatesTheOpenBuffer() {
        let target = service.profiles[0]
        service.activateEditBuffer(for: target.id)

        var persisted = target
        persisted.displayName = "Persisted elsewhere"
        service.editBuffer?.draft = persisted
        XCTAssertTrue(service.editBuffer?.isDirty ?? false)

        service.rebaseEditBuffer(to: persisted)
        XCTAssertFalse(service.editBuffer?.isDirty ?? true)
    }

    /// The Tool Library and the canvas both call this unconditionally after a save; it must be
    /// inert when the editor is open on a different profile.
    func testRebaseEditBufferIgnoresADifferentProfile() {
        let opened = service.profiles[0]
        service.activateEditBuffer(for: opened.id)
        service.editBuffer?.draft.displayName = "user is editing this"

        var other = service.profiles[1]
        other.displayName = "unrelated save"
        service.rebaseEditBuffer(to: other)

        XCTAssertTrue(service.editBuffer?.isDirty ?? false,
                      "an unrelated profile's save must not clear this editor's dirty state")
        XCTAssertEqual(service.editBuffer?.draft.displayName, "user is editing this")
    }

    func testRebaseEditBufferIsSafeWithNoOpenBuffer() {
        service.deactivateEditBuffer()
        service.rebaseEditBuffer(to: service.profiles[0])   // must not trap
        XCTAssertNil(service.editBuffer)
    }

    // MARK: - A4: canvas dirt reaches the navigation guard

    /// ⚠️ Canvas geometry lives in `WorkflowCanvasState`/`WorkflowLayoutSD`, never in
    /// `editBuffer.draft` — so the sidebar's old `editBuffer?.isDirty` check reported "clean" for a
    /// canvas full of unsaved nodes and switched profiles without prompting.
    func testHasUnsavedEditorChangesSeesCanvasDirtThatTheBufferCannot() {
        service.activateEditBuffer(for: service.profiles[0].id)
        XCTAssertFalse(service.hasUnsavedEditorChanges, "clean editor, clean canvas")

        service.canvasEditGuard.hasUnsavedChanges = true
        XCTAssertFalse(service.editBuffer?.isDirty ?? true,
                       "precondition: the buffer genuinely cannot see canvas dirt")
        XCTAssertTrue(service.hasUnsavedEditorChanges,
                      "the guard the sidebar consults must still fire")
    }

    func testHasUnsavedEditorChangesStillSeesPlainFieldEdits() {
        service.activateEditBuffer(for: service.profiles[0].id)
        service.editBuffer?.draft.displayName = "edited"
        XCTAssertTrue(service.hasUnsavedEditorChanges)
    }

    // MARK: - B3: the floating prompt editor is a THIRD source of unsaved work

    /// ⚠️ `AdvancedPromptEditorView` keeps typing in its own `@State localText` and writes back
    /// only on an explicit commit, so the buffer AND the canvas both report clean while the
    /// floating window holds thousands of characters. Navigation commits on teardown (A27); ⌘Q
    /// has no teardown, so `handleUnsavedProfileEditsBeforeQuit` returned `.proceed` and the text
    /// was discarded silently — the loss the guard exists to prevent.
    func testFlushCommitsFloatingEditorTextSoTheQuitGuardCanSeeIt() {
        service.activateEditBuffer(for: service.profiles[0].id)
        XCTAssertFalse(service.hasUnsavedEditorChanges, "precondition: nothing dirty yet")

        // Stand in for the floating editor holding text it has not committed yet — the same
        // unwrap/re-wrap the detail view's `instructionsBinding` performs. In production the hook
        // is registered by `AgentConfigDetailView`; the seam itself is profile-type agnostic, and
        // this suite's fixture happens to be a bot.
        guard case .bot = service.profiles[0].details else {
            return XCTFail("fixture precondition: profiles[0] must carry an instructions field")
        }
        service.commitPendingPromptEdits = { [weak service] in
            guard case .bot(var config)? = service?.editBuffer?.draft.details else { return }
            config.instructions = "a long system prompt typed into the floating window"
            service?.editBuffer?.draft.details = .bot(config)
        }

        XCTAssertFalse(service.hasUnsavedEditorChanges,
                       "the guard genuinely cannot see pending text before the flush")

        service.flushPendingEditorText()
        XCTAssertTrue(service.hasUnsavedEditorChanges,
                      "after the flush the quit prompt must fire and offer to save")
    }

    /// The hook is nil whenever no editor owns it, and flushing must be a safe no-op then —
    /// `handleUnsavedProfileEditsBeforeQuit` calls it unconditionally.
    func testFlushIsANoOpWithNoEditorRegistered() {
        service.activateEditBuffer(for: service.profiles[0].id)
        service.commitPendingPromptEdits = nil
        service.flushPendingEditorText()
        XCTAssertFalse(service.hasUnsavedEditorChanges)
    }

    // MARK: - WF-LC1: the delete cascade must reach per-profile caches

    /// ⚠️ Pins the SEAM, which is the half that was missing. `MainApplicationViewModel` caches a
    /// `WorkflowCanvasState` per profile and nothing pruned it, so deleting a workflow whose canvas
    /// was dirty left a live state behind — and the quit-time drain then RE-INSERTED a
    /// `WorkflowLayoutSD` row for a profile that no longer exists, resurrecting the layout the
    /// delete had just removed as a permanently orphaned row.
    ///
    /// ⚠️ The view model's own `discardWorkflowCanvasState` body is NOT covered here: constructing a
    /// `MainApplicationViewModel` claims `HITLPresenter` globally and loads settings, so building one
    /// in a unit test leaks state across the suite (this file's header documents the same
    /// constraint). What is covered is that the delete path FIRES the cascade — the part a future
    /// delete path could forget.
    func testDeletingAProfileFiresTheCacheEvictionCascade() throws {
        let victim = service.profiles[0].id
        var evicted: [UUID] = []
        service.onProfileDeleted = { evicted.append($0) }

        try service.deleteProfile(withId: victim)

        XCTAssertEqual(evicted, [victim],
                       "a per-profile cache owner must be told, or the quit drain can resurrect the deleted layout")
    }

    /// The cascade is unconditional — a non-workflow profile has no cached canvas, and the owner is
    /// responsible for ignoring it. Keeping the call site free of type tests means a future profile
    /// kind cannot be forgotten here.
    func testTheCascadeFiresRegardlessOfProfileType() throws {
        let victim = service.profiles[1].id   // a .bot
        var fired = false
        service.onProfileDeleted = { _ in fired = true }

        try service.deleteProfile(withId: victim)

        XCTAssertTrue(fired)
    }
}
