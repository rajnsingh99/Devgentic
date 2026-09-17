// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ProfileFreshReadBeforeWriteTests.swift
//  devgenticTests
//
//  ⚠️⚠️ THE CLOBBER. `BackendProfileService.profiles` is an array of VALUE-TYPE snapshots taken when
//  it last loaded. Several things write profile ROWS out of band and never refresh it:
//  `BackendOrchestrationService` auto-healing a thinking flag, `MLXContextWindowHealer` backfilling a
//  context window, and — since V6 — `SkillLibraryImportSweep`, which re-links every pre-V6 skill
//  reference at launch by assigning `details` on the SwiftData row directly.
//
//  A writer that starts from the stale array, changes one facet and calls `saveProfile` writes the
//  WHOLE stale snapshot back, because `BackendProfileStore.saveProfile` does
//  `existing.details = snapshot.details`. The sweep is the worst case of the class: it is the one
//  pass that carries a pre-V6 user's skills into the library, so reverting it loses the migration
//  rather than one setting — and the trigger is an ordinary skill-link toggle.
//
//  `activateEditBuffer` already learned this for the editor path. `freshProfile(id:)` is that rule
//  extracted and named, so the next whole-profile writer reaches for it instead of rediscovering it.
//

import XCTest
@testable import devgentic

@MainActor
final class ProfileFreshReadBeforeWriteTests: XCTestCase {

    private final class InMemoryStore: BackendProfileStoreProtocol {
        var profiles: [BackendProfileSnapshot] = []
        var fetchByIdCount = 0
        func fetchProfiles() throws -> [BackendProfileSnapshot] { profiles }
        func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? {
            fetchByIdCount += 1
            return profiles.first { $0.id == id }
        }
        func fetchProfiles(ids: Set<UUID>) throws -> [BackendProfileSnapshot] {
            profiles.filter { ids.contains($0.id) }
        }
        func saveProfile(_ snapshot: BackendProfileSnapshot,
                         callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError] {
            if let i = profiles.firstIndex(where: { $0.id == snapshot.id }) { profiles[i] = snapshot }
            else { profiles.append(snapshot) }
            return []
        }
        func deleteProfile(withId id: UUID) throws { profiles.removeAll { $0.id == id } }
    }

    private func agent(selections: [SkillSelection]) -> BackendProfileSnapshot {
        var config = AgentConfig(llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "m"))
        config.skillSelections = selections
        return BackendProfileSnapshot(displayName: "Researcher", details: .agent(config))
    }

    private func selections(of profile: BackendProfileSnapshot?) -> [SkillSelection] {
        guard case .agent(let config) = profile?.details else { return [] }
        return config.skillSelections ?? []
    }

    /// ⚠️ THE DEFECT, as the sweep actually produces it: the service loads, the sweep rewrites the
    /// ROW underneath it, and the in-memory copy still holds the pre-sweep selections.
    ///
    /// **Mutation check:** have `freshProfile` return `profiles.first(where:)` instead of reading the
    /// store and this goes red.
    func testFreshProfileSeesAnOutOfBandRowWriteThatTheSnapshotArrayMissed() throws {
        let store = InMemoryStore()
        let pending = SkillSelection(skillID: nil, legacyFolderPath: "/tmp/skills/code-review",
                                     name: "code-review", isEnabled: true)
        store.profiles = [agent(selections: [pending])]
        let service = BackendProfileService(store: store)
        let id = try XCTUnwrap(service.profiles.first?.id)

        XCTAssertTrue(selections(of: service.profiles.first).allSatisfy { $0.skillID == nil },
                      "precondition: the loaded snapshot holds an unlinked selection")

        // The sweep: the ROW is re-linked, the service is never told.
        let relinked = SkillSelection(skillID: "skill_abc", legacyFolderPath: nil,
                                      name: "code-review", isEnabled: true)
        store.profiles = [agent(selections: [relinked])].map {
            BackendProfileSnapshot(id: id, displayName: $0.displayName, details: $0.details)
        }

        XCTAssertEqual(selections(of: service.profiles.first).first?.skillID, nil,
                       "the in-memory array is STALE — this is the state every whole-profile writer starts from")
        XCTAssertEqual(selections(of: service.freshProfile(id: id)).first?.skillID, "skill_abc",
                       "freshProfile must see what the sweep actually wrote")
    }

    /// The control: with the store unreachable, the cached copy is still returned rather than nil.
    /// A `freshProfile` that failed closed would break every writer whenever a read hiccupped.
    func testFreshProfileFallsBackToTheCachedCopyWhenTheStoreCannotBeRead() throws {
        final class FailingStore: BackendProfileStoreProtocol {
            var seed: [BackendProfileSnapshot] = []
            var failReads = false
            func fetchProfiles() throws -> [BackendProfileSnapshot] { seed }
            func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? {
                if failReads { throw ProfileStoreError.containerNotConfigured }
                return seed.first { $0.id == id }
            }
            func fetchProfiles(ids: Set<UUID>) throws -> [BackendProfileSnapshot] { seed.filter { ids.contains($0.id) } }
            func saveProfile(_ s: BackendProfileSnapshot, callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError] { [] }
            func deleteProfile(withId id: UUID) throws {}
        }
        let store = FailingStore()
        store.seed = [agent(selections: [])]
        let service = BackendProfileService(store: store)
        let id = try XCTUnwrap(service.profiles.first?.id)

        store.failReads = true
        XCTAssertNotNil(service.freshProfile(id: id),
                        "a failed read must fall back to the cached copy — failing closed would break every writer on a transient error")
    }

    /// ⚠️ And it must actually CONSULT the store, not merely happen to agree with it. A cached-only
    /// implementation satisfies the fallback test above and reintroduces the entire defect.
    func testFreshProfileActuallyReadsTheStore() throws {
        let store = InMemoryStore()
        store.profiles = [agent(selections: [])]
        let service = BackendProfileService(store: store)
        let id = try XCTUnwrap(service.profiles.first?.id)

        let before = store.fetchByIdCount
        _ = service.freshProfile(id: id)
        XCTAssertEqual(store.fetchByIdCount, before + 1,
                       "freshProfile must hit the store — that read IS the fix")
    }
}
