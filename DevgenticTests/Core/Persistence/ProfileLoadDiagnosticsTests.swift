// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileLoadDiagnosticsTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

// MARK: - A47: "couldn't read" must be distinguishable from "you have none"

@MainActor
final class ProfileLoadDiagnosticsTests: XCTestCase {

    private final class FlakyStore: BackendProfileStoreProtocol {
        var profiles: [BackendProfileSnapshot] = []
        var shouldThrowOnFetch = false

        func fetchProfiles() throws -> [BackendProfileSnapshot] {
            if shouldThrowOnFetch {
                throw ProfileStoreError.fetchFailed(underlying: NSError(domain: "test", code: 1))
            }
            return profiles
        }
        func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? {
            if shouldThrowOnFetch {
                throw ProfileStoreError.fetchFailed(underlying: NSError(domain: "test", code: 1))
            }
            return profiles.first { $0.id == id }
        }
        func saveProfile(_ snapshot: BackendProfileSnapshot,
                         callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError] {
            if let i = profiles.firstIndex(where: { $0.id == snapshot.id }) { profiles[i] = snapshot }
            else { profiles.append(snapshot) }
            return []  // A34: a double has no advisories to report.
        }
        func deleteProfile(withId id: UUID) throws { profiles.removeAll { $0.id == id } }
    }

    private func makeBot(_ name: String) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: name,
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"))))
    }

    /// ⚠️ The defect: at launch `loadProfiles()` runs from `init`, where there is no prior list to
    /// keep — so a fetch failure produced an EMPTY sidebar that reads as a first run, complete with
    /// a "New Profile" button. The user's profiles were not gone; they were not read.
    func testAFailedInitialLoadIsDistinguishableFromAnEmptyStore() {
        let failing = FlakyStore()
        failing.shouldThrowOnFetch = true
        let service = BackendProfileService(store: failing)

        XCTAssertTrue(service.profiles.isEmpty)
        XCTAssertNotNil(service.lastLoadError,
                        "an empty list after a FAILURE must be distinguishable from a genuine first run")
    }

    func testAGenuinelyEmptyStoreReportsNoError() {
        let service = BackendProfileService(store: FlakyStore())
        XCTAssertTrue(service.profiles.isEmpty)
        XCTAssertNil(service.lastLoadError, "a real first run must not show an error state")
    }

    /// The error state must clear on a successful retry — otherwise the sidebar keeps offering
    /// "Retry" after the problem is gone.
    func testASuccessfulRetryClearsTheErrorState() {
        let store = FlakyStore()
        store.shouldThrowOnFetch = true
        let service = BackendProfileService(store: store)
        XCTAssertNotNil(service.lastLoadError)

        store.shouldThrowOnFetch = false
        store.profiles = [makeBot("Alpha")]
        service.loadProfiles()

        XCTAssertNil(service.lastLoadError)
        XCTAssertEqual(service.profiles.count, 1)
    }

    /// A later failure must not clear a list already in memory — the comment on that branch says
    /// so, and the log line distinguishes the two cases by count.
    func testALaterFailureKeepsTheProfilesAlreadyLoaded() {
        let store = FlakyStore()
        store.profiles = [makeBot("Alpha"), makeBot("Beta")]
        let service = BackendProfileService(store: store)
        XCTAssertEqual(service.profiles.count, 2)

        store.shouldThrowOnFetch = true
        service.loadProfiles()

        XCTAssertEqual(service.profiles.count, 2, "a transient failure must not empty the sidebar")
        XCTAssertNotNil(service.lastLoadError)
    }
}

// MARK: - A50: the configuration dump is reachable AND says the right things

@MainActor
final class ProfileSelectionSummaryTests: XCTestCase {

    private final class InMemoryStore: BackendProfileStoreProtocol {
        var profiles: [BackendProfileSnapshot] = []
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
        func deleteProfile(withId id: UUID) throws { profiles.removeAll { $0.id == id } }
    }

    private func service(seeding snapshots: [BackendProfileSnapshot]) -> BackendProfileService {
        let store = InMemoryStore()
        store.profiles = snapshots
        return BackendProfileService(store: store)
    }

    private func tool(_ name: String, enabled: Bool) -> Tool {
        Tool(name: name,
             description: "test",
             isEnabled: enabled,
             sourceId: UUID(),
             parameters: ToolParameters(type: "object", properties: [:], required: []))
    }

    private func agentSnapshot(
        name: String = "Researcher",
        apiKey: String? = nil,
        tools: [Tool] = [],
        knowledge: [KnowledgeSource]? = nil
    ) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: name,
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .anthropic,
                                          modelName: "claude-opus-5",
                                          apiKey: apiKey),
                tools: tools,
                knowledgeSources: knowledge)))
    }

    /// A50's actual defect: 70 lines of diagnostic with ZERO callers, so no run ever recorded which
    /// settings it used. The dump is now built from `activateEditBuffer` — this asserts the profile
    /// the user opened is the one described.
    func testActivatingAProfileProducesADumpForThatProfile() {
        let profile = agentSnapshot(name: "Researcher")
        let service = self.service(seeding: [profile])

        let summary = service.profileSelectionSummary(profileID: profile.id)

        let unwrapped = try? XCTUnwrap(summary)
        XCTAssertNotNil(unwrapped)
        XCTAssertTrue(summary?.contains("PROFILE SELECTED: Researcher") == true)
        XCTAssertTrue(summary?.contains(profile.id.uuidString) == true,
                      "the ID is what correlates this dump with the rest of the log")
    }

    func testAnUnknownProfileProducesNoDump() {
        let service = self.service(seeding: [])
        XCTAssertNil(service.profileSelectionSummary(profileID: UUID()),
                     "the caller logs a [PROFILE] notice for this case instead")
    }

    /// ⚠️ The dump is written to the log file. A key that leaks here leaks into every support
    /// bundle the user sends.
    func testTheAPIKeyIsMaskedInTheDump() {
        let secret = "sk-ant-SUPERSECRETVALUE1234"
        let profile = agentSnapshot(apiKey: secret)
        let service = self.service(seeding: [profile])

        let summary = service.profileSelectionSummary(profileID: profile.id) ?? ""

        XCTAssertFalse(summary.contains(secret), "the raw key must never reach the log")
        XCTAssertTrue(summary.contains("Masked for Security"))
    }

    func testAMissingAPIKeyIsReportedRatherThanOmitted() {
        let profile = agentSnapshot(apiKey: nil)
        let service = self.service(seeding: [profile])

        let summary = service.profileSelectionSummary(profileID: profile.id) ?? ""

        XCTAssertTrue(summary.contains("API Key: None"),
                      "\"no key configured\" is the single most common cause of a dead cloud profile "
                      + "— it has to be visible, not absent")
    }

    /// Per-tool ON/OFF state is the answer to "my agent stopped calling tools", which is exactly the
    /// question this dump exists to answer.
    func testPerToolEnabledStateIsRecorded() {
        let profile = agentSnapshot(tools: [
            tool("read_file", enabled: true),
            tool("execute_shell", enabled: false)
        ])
        let service = self.service(seeding: [profile])

        let summary = service.profileSelectionSummary(profileID: profile.id) ?? ""

        XCTAssertTrue(summary.contains("[ON] read_file"))
        XCTAssertTrue(summary.contains("[OFF] execute_shell"))
        XCTAssertTrue(summary.contains("[TOOLS (1 Active)]"))
    }

    func testAProfileWithNoToolsSaysSoExplicitly() {
        let profile = agentSnapshot(tools: [])
        let service = self.service(seeding: [profile])

        let summary = service.profileSelectionSummary(profileID: profile.id) ?? ""

        XCTAssertTrue(summary.contains("No tools configured."),
                      "silence is ambiguous between \"none\" and \"not recorded\"")
    }
}
