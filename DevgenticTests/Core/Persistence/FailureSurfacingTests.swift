// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FailureSurfacingTests.swift
//  DevgenticTests
//
//  Created on 07/08/26.
//
//  Regression tests for the silent-failure cluster (register A10, A13, A14, A15).
//
//  ⚠️ Every one of these failed by looking like nothing had happened: a delete that left the row
//  in place, a destructive confirmation whose button did nothing, a picker that raced itself. None
//  raised, none logged, and three of the four had no UI surface at all — so the user's only signal
//  was that the app appeared broken.
//

import XCTest
@testable import devgentic

// MARK: - A14: a failed delete must not navigate away

@MainActor
final class ProfileDeleteFailureTests: XCTestCase {

    private final class ThrowingDeleteStore: BackendProfileStoreProtocol {
        var profiles: [BackendProfileSnapshot] = []
        var shouldThrowOnDelete = false
        private(set) var deleteAttempts = 0

        func fetchProfiles() throws -> [BackendProfileSnapshot] { profiles }
        func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? {
            profiles.first { $0.id == id }
        }
        func saveProfile(_ snapshot: BackendProfileSnapshot,
                         callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError] {
            if let i = profiles.firstIndex(where: { $0.id == snapshot.id }) { profiles[i] = snapshot }
            else { profiles.append(snapshot) }
            return []  // A34: a double has no advisories to report.
        }
        func deleteProfile(withId id: UUID) throws {
            deleteAttempts += 1
            if shouldThrowOnDelete {
                throw ProfileStoreError.deleteFailed(underlying: NSError(domain: "test", code: 1))
            }
            profiles.removeAll { $0.id == id }
        }
    }

    private func makeBot(_ name: String) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: name,
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        )
    }

    private var store: ThrowingDeleteStore!
    private var service: BackendProfileService!

    override func setUp() {
        store = ThrowingDeleteStore()
        store.profiles = [makeBot("Alpha"), makeBot("Beta")]
        service = BackendProfileService(store: store)
    }

    /// ⚠️ The defect was `try?` plus an UNCONDITIONAL `returnToChat()`. The service throws, so the
    /// row must survive — and the caller must be able to see that it threw in order not to
    /// navigate. This pins the throw reaching the caller at all.
    func testAFailedDeletePropagatesAndLeavesTheProfileInPlace() {
        store.shouldThrowOnDelete = true
        let target = service.profiles[0]

        XCTAssertThrowsError(try service.deleteProfile(withId: target.id)) { error in
            XCTAssertTrue(error is ProfileStoreError)
        }
        XCTAssertEqual(store.deleteAttempts, 1)
        XCTAssertTrue(store.profiles.contains { $0.id == target.id },
                      "a failed delete must not remove the row")
        XCTAssertEqual(service.profiles.count, 2,
                       "the sidebar array must still show the profile that was not deleted")
    }

    func testASuccessfulDeleteRemovesTheProfile() throws {
        let target = service.profiles[0]
        try service.deleteProfile(withId: target.id)

        XCTAssertFalse(store.profiles.contains { $0.id == target.id })
        XCTAssertEqual(service.profiles.count, 1)
    }

    /// The edit buffer must be released with the profile — otherwise the editor keeps a draft for
    /// a row that no longer exists.
    func testDeletingTheOpenProfileClearsItsEditBuffer() throws {
        let target = service.profiles[0]
        service.activateEditBuffer(for: target.id)
        XCTAssertNotNil(service.editBuffer)

        try service.deleteProfile(withId: target.id)
        XCTAssertNil(service.editBuffer)
    }

    /// A failed delete must leave the buffer alone — the user is still editing that profile.
    func testAFailedDeleteKeepsTheEditBuffer() {
        store.shouldThrowOnDelete = true
        let target = service.profiles[0]
        service.activateEditBuffer(for: target.id)

        XCTAssertThrowsError(try service.deleteProfile(withId: target.id))
        XCTAssertEqual(service.editBuffer?.draft.id, target.id)
    }
}

// MARK: - A15: the discard path must report every refusal

@MainActor
final class DiscardUnreadableRefusalTests: XCTestCase {

    /// ⚠️ Every refusal arm returns the same `false`, and each used to do so without a log while
    /// the caller's comment asserted "store logged it". This exercises the reachable one — a row
    /// that is not there — and pins that the call refuses rather than trapping or silently
    /// reporting success.
    ///
    /// (The container-unconfigured arm is not reachable from here: the shared store is configured
    /// by the app under test, so `modelContainer` is non-nil in this process. It is covered by
    /// inspection at the call site rather than by a test that would have to un-configure a
    /// singleton other suites depend on.)
    func testDiscardingAProfileThatDoesNotExistRefuses() {
        XCTAssertFalse(
            BackendProfileStore.shared.discardUnreadableConfiguration(
                for: UUID(), reason: "unit test"),
            "a missing row must refuse, not report a successful discard"
        )
    }

    /// A readable profile is not a candidate for the destructive reset — the guard must hold even
    /// when the row genuinely exists.
    func testDiscardingAReadableProfileRefuses() throws {
        let store = BackendProfileStore.shared
        try XCTSkipIf(store.modelContainer == nil, "requires the app's configured container")

        let profile = BackendProfileSnapshot(
            displayName: "Readable",
            details: .bot(BotConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        )
        try store.saveProfile(profile)
        defer { try? store.deleteProfile(withId: profile.id) }

        XCTAssertFalse(
            store.discardUnreadableConfiguration(for: profile.id, reason: "unit test"),
            "a profile whose blob decodes fine has nothing to discard"
        )
    }

    /// The two read-only queries fail OPEN on the same path, which is why a fetch failure used to
    /// read as "this profile is fine" and silently retire the corruption warning.
    func testUnreadableQueriesFailSafelyWithoutAContainer() {
        let store = BackendProfileStore.shared
        XCTAssertTrue(store.unreadableProfiles().isEmpty)
        XCTAssertFalse(store.isConfigurationUnreadable(for: UUID()))
    }
}

// MARK: - A13: the Ollama store must expose its failures

@MainActor
final class OllamaStoreFailureSurfacingTests: XCTestCase {

    /// ⚠️ `downloadErrorMessage` had exactly two references in the whole repo — its declaration and
    /// its assignment — and `modelRemoveError` had none outside the service that writes it. The
    /// view model must now hold BOTH so the store view has something to render.
    func testTheViewModelExposesBothFailureChannels() {
        let vm = OllamaModelStoreViewModel()

        vm.downloadErrorMessage = "pull failed"
        vm.deleteErrorMessage = "cannot remove the active model"

        XCTAssertEqual(vm.downloadErrorMessage, "pull failed")
        XCTAssertEqual(vm.deleteErrorMessage, "cannot remove the active model")
    }

    /// The banner is dismissible, and dismissing must clear the mirrored state so it does not
    /// immediately reappear on the next observation tick.
    func testDismissClearsBothChannels() {
        let vm = OllamaModelStoreViewModel()
        vm.downloadErrorMessage = "pull failed"
        vm.deleteErrorMessage = "delete refused"

        vm.dismissErrors()

        XCTAssertNil(vm.downloadErrorMessage)
        XCTAssertNil(vm.deleteErrorMessage)
    }

    /// A delete in flight has to be observable too — the card's spinner state came from nowhere.
    func testDeletionProgressIsExposed() {
        let vm = OllamaModelStoreViewModel()
        XCTAssertFalse(vm.isDeleting, "a fresh view model is not mid-delete")
    }
}
