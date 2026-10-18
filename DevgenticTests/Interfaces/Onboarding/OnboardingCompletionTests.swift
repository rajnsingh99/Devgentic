// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingCompletionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

private final class InMemoryProfileStore: BackendProfileStoreProtocol {
    var profiles: [BackendProfileSnapshot] = []

    func fetchProfiles() throws -> [BackendProfileSnapshot] { profiles }
    func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? { profiles.first { $0.id == id } }
    func saveProfile(_ snapshot: BackendProfileSnapshot,
                     callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError] {
        profiles.removeAll { $0.id == snapshot.id }
        profiles.append(snapshot)
        return []
    }
    func deleteProfile(withId id: UUID) throws { profiles.removeAll { $0.id == id } }
}

@MainActor
final class OnboardingCompletionTests: XCTestCase {

    private func makeBot(_ name: String) -> BackendProfileSnapshot {
        BackendProfileSnapshot(displayName: name,
                               details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .mlx, modelName: "m"))))
    }

    /// The root cause, pinned: a service built at launch does not see a profile saved straight to
    /// the store afterwards. If this ever fails, the service started observing the store and the
    /// explicit reload in `OnboardingCompletion` may no longer be needed.
    func testAServiceBuiltAtLaunchDoesNotSeeAProfileSavedStraightToTheStore() throws {
        let store = InMemoryProfileStore()
        let service = BackendProfileService(store: store)   // app launch: empty on a first run
        _ = try store.saveProfile(makeBot("Local Assistant"), callerFile: "", callerFunction: "", callerLine: 0)  // onboarding's save
        XCTAssertTrue(service.profiles.isEmpty, "the bug's precondition: the sidebar's list is stale")
    }

    /// The fix: completing onboarding shows the new profile in the sidebar list and selects it.
    func testCompletionShowsAndSelectsTheCreatedProfile() throws {
        let store = InMemoryProfileStore()
        let service = BackendProfileService(store: store)
        let configuration = BackendConfiguration()
        let created = makeBot("Local Assistant")
        _ = try store.saveProfile(created, callerFile: "", callerFunction: "", callerLine: 0)

        OnboardingCompletion.apply(createdProfileID: created.id, profileService: service, backendConfiguration: configuration)

        XCTAssertEqual(service.profiles.map(\.id), [created.id], "the sidebar list does not show the onboarding profile")
        XCTAssertEqual(configuration.selectedProfileID, created.id, "the first chat is not pointed at it")
    }

    /// A re-run: the service already holds the old profiles; the new one must join them.
    func testARerunAddsTheNewProfileToTheExistingList() throws {
        let store = InMemoryProfileStore()
        let existing = makeBot("Research")
        _ = try store.saveProfile(existing, callerFile: "", callerFunction: "", callerLine: 0)
        let service = BackendProfileService(store: store)
        let created = makeBot("Mac Helper")
        _ = try store.saveProfile(created, callerFile: "", callerFunction: "", callerLine: 0)

        OnboardingCompletion.apply(createdProfileID: created.id, profileService: service, backendConfiguration: BackendConfiguration())

        XCTAssertEqual(Set(service.profiles.map(\.id)), [existing.id, created.id])
    }

    /// Cancelling a re-run creates nothing, so the user's current selection is left alone.
    func testACancelledRerunKeepsTheCurrentSelection() throws {
        let store = InMemoryProfileStore()
        let existing = makeBot("Research")
        _ = try store.saveProfile(existing, callerFile: "", callerFunction: "", callerLine: 0)
        let service = BackendProfileService(store: store)
        let configuration = BackendConfiguration()
        configuration.selectedProfileID = existing.id

        OnboardingCompletion.apply(createdProfileID: nil, profileService: service, backendConfiguration: configuration)

        XCTAssertEqual(configuration.selectedProfileID, existing.id)
    }

    /// An id the store does not return is never selected — that would point the composer at nothing.
    func testAMissingProfileIsNotSelected() {
        let configuration = BackendConfiguration()
        OnboardingCompletion.apply(createdProfileID: UUID(), profileService: BackendProfileService(store: InMemoryProfileStore()),
                                   backendConfiguration: configuration)
        XCTAssertNil(configuration.selectedProfileID)
    }

    /// Wiring: the view model names the profile it saved; Cancel names none.
    func testTheViewModelReportsWhatItCreated() throws {
        let vm = OnboardingViewModel(physicalMemoryBytes: 16 * 1_073_741_824, checksInstallStatus: false,
                                     systemSettings: FakeOnboardingSystemSettings())
        vm.existingProfileNames = ["Research"]
        var reported: UUID?? = .none
        vm.cancelSetup(themeManager: ThemeManager()) { reported = .some($0) }
        XCTAssertEqual(reported, .some(nil), "Cancel must report that nothing was created")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent("Devgentic/Interfaces/Onboarding/OnboardingViewModel.swift"),
                                       encoding: .utf8) else { throw XCTSkip("source not reachable") }
        XCTAssertTrue(source.contains("onComplete(newProfile.id)"), "completion no longer reports the saved profile")
    }
}
