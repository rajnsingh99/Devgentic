//
//  ProviderKeyStorageTests.swift
//  DevgenticTests
//
//  Created on 07/08/26.
//
//  Regression tests for the credential-at-rest cluster (register A16, A17, A18).
//
//  ⚠️ The invariant these exist to hold: a cloud API key must not appear in `configData`. That blob
//  lives in an unsandboxed Application Support directory, so anything written there is readable by
//  any process running as the user and is swept into every backup.
//

import XCTest
@testable import devgentic

// MARK: - A16: keys must not reach the stored blob

@MainActor
final class ProviderKeyStorageTests: XCTestCase {

    private let sentinel = "sk-ant-TESTKEY-do-not-persist-0123456789"
    private var createdProfileIDs: [UUID] = []

    override func tearDown() {
        for id in createdProfileIDs { ProviderKeyStore.delete(for: id) }
        createdProfileIDs = []
        super.tearDown()
    }

    private func agentDetails(key: String?) -> ProfileDetails {
        .agent(AgentConfig(llmConfig: ProviderConfig(
            apiProvider: .anthropic, modelName: "claude-opus-5", apiKey: key)))
    }

    private func makeRow(key: String?) -> BackendProfile {
        let row = BackendProfile(displayName: "Keyed", details: agentDetails(key: key))
        createdProfileIDs.append(row.id)
        return row
    }

    /// ⚠️ The defect, stated as an assertion: `strings DevgenticSD.store | grep sk-ant` used to
    /// return the live key. The blob must not contain it in any form.
    func testAFreshlyCreatedProfileDoesNotPutItsKeyInTheBlob() {
        let row = makeRow(key: sentinel)
        let blob = String(data: row.configData, encoding: .utf8) ?? ""

        XCTAssertFalse(blob.contains(sentinel),
                       "the API key must never be encoded into configData")
        XCTAssertFalse(row.hasInlineAPIKeyInStoredBlob)
    }

    /// The key must still be USABLE — stripping it from the blob is only correct if reads reinject
    /// it, otherwise every cloud request loses its credential.
    func testTheKeyIsStillReadableThroughDetails() {
        let row = makeRow(key: sentinel)
        XCTAssertEqual(row.details.providerAPIKey, sentinel,
                       "in-memory readers must still see the key")
    }

    func testUpdatingTheKeyKeepsItOutOfTheBlobAndReadable() {
        let row = makeRow(key: sentinel)
        let replacement = sentinel + "-rotated"

        row.details = agentDetails(key: replacement)

        let blob = String(data: row.configData, encoding: .utf8) ?? ""
        XCTAssertFalse(blob.contains(replacement))
        XCTAssertFalse(blob.contains(sentinel), "the previous key must not linger either")
        XCTAssertEqual(row.details.providerAPIKey, replacement)
    }

    /// Clearing the key must clear the Keychain entry, not leave the old one to be re-injected.
    func testClearingTheKeyRemovesItFromTheKeychain() {
        let row = makeRow(key: sentinel)
        row.details = agentDetails(key: nil)

        XCTAssertNil(ProviderKeyStore.load(for: row.id))
        XCTAssertNil(row.details.providerAPIKey)
    }

    /// ⚠️ Per-profile scoping. Two profiles on the same provider legitimately hold different
    /// credentials; a provider-keyed store would have collapsed them into one.
    func testTwoProfilesOnTheSameProviderKeepSeparateKeys() {
        let a = makeRow(key: sentinel + "-A")
        let b = makeRow(key: sentinel + "-B")

        XCTAssertEqual(a.details.providerAPIKey, sentinel + "-A")
        XCTAssertEqual(b.details.providerAPIKey, sentinel + "-B")
    }

    func testProfilesWithoutAnLLMConfigAreUnaffected() {
        let row = BackendProfile(
            displayName: "Flow", details: .workflow(WorkflowConfig(agentProfileIDs: [])))
        createdProfileIDs.append(row.id)

        XCTAssertNil(row.details.providerAPIKey)
        XCTAssertFalse(row.hasInlineAPIKeyInStoredBlob)
    }

    // MARK: Migration

    /// ⚠️ The pre-migration shape: a blob written by an older build still carries its key inline.
    /// It must keep working — the read path falls back to the blob when the Keychain is empty —
    /// and `hasInlineAPIKeyInStoredBlob` must report it so the launch sweep can find it.
    func testALegacyBlobWithAnInlineKeyStillResolvesAndIsDetected() throws {
        let row = makeRow(key: nil)
        // Write the legacy shape directly, bypassing the stripping setter.
        row.configData = try JSONEncoder().encode(agentDetails(key: sentinel))
        row.resetDecodeCacheForTesting()

        XCTAssertTrue(row.hasInlineAPIKeyInStoredBlob,
                      "the sweep must be able to identify an un-migrated row")
        XCTAssertEqual(row.details.providerAPIKey, sentinel,
                       "a legacy profile must keep working before the sweep runs")
    }

    /// What the sweep does to such a row: assigning `details` back through the setter strips it.
    func testRewritingALegacyRowStripsTheKeyFromTheBlob() throws {
        let row = makeRow(key: nil)
        row.configData = try JSONEncoder().encode(agentDetails(key: sentinel))
        row.resetDecodeCacheForTesting()

        row.details = row.details   // the sweep's operation

        XCTAssertFalse(row.hasInlineAPIKeyInStoredBlob)
        XCTAssertEqual(row.details.providerAPIKey, sentinel, "the key survives the move")
        XCTAssertEqual(ProviderKeyStore.load(for: row.id), sentinel)
    }

    /// ⚠️ Keychain wins when both exist — it is the newer of the two by construction (a rotated
    /// key is written there while the stale blob copy has not been rewritten yet).
    func testTheKeychainValueWinsOverAStaleInlineOne() throws {
        let row = makeRow(key: nil)
        ProviderKeyStore.save("current-key", for: row.id)
        row.configData = try JSONEncoder().encode(agentDetails(key: "stale-inline-key"))
        row.resetDecodeCacheForTesting()

        XCTAssertEqual(row.details.providerAPIKey, "current-key")
    }

    // MARK: - A53: legacy plaintext credentials in UserDefaults

    /// A throwaway suite so the developer's real preferences are never touched.
    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "devgentic.tests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    /// ⚠️ Deleting the write in `GeminiService` protects only future fetches. Every install that
    /// ever validated a Gemini key already has the plaintext value on disk, unreachable from any
    /// UI and surviving profile deletion — so the purge is the half that actually closes A53.
    func testThePurgeRemovesTheLegacyGeminiKey() {
        let defaults = makeDefaults()
        defaults.set("AIzaSy-live-secret", forKey: "gemini_api_key")

        ProviderKeyStore.purgeLegacyPlaintextKeys(defaults: defaults)

        XCTAssertNil(defaults.string(forKey: "gemini_api_key"))
    }

    /// ⚠️ THE GUARD THAT MATTERS. `webSearchAPIKey` is also a cleartext credential in
    /// UserDefaults, but unlike the Gemini one it has a live reader — purging it would silently
    /// disable web search. The purge list is membership-by-"has no reader", not by "looks like a
    /// secret", and this pins that distinction so a later addition cannot quietly break a feature.
    func testThePurgeLeavesCredentialsThatAreStillReadBack() {
        let defaults = makeDefaults()
        defaults.set("still-in-use", forKey: "webSearchAPIKey")

        ProviderKeyStore.purgeLegacyPlaintextKeys(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "webSearchAPIKey"), "still-in-use")
    }

    /// Runs on every launch, so it has to be safe to repeat and quiet when there is nothing to do.
    func testThePurgeIsIdempotent() {
        let defaults = makeDefaults()
        defaults.set("AIzaSy-live-secret", forKey: "gemini_api_key")

        ProviderKeyStore.purgeLegacyPlaintextKeys(defaults: defaults)
        ProviderKeyStore.purgeLegacyPlaintextKeys(defaults: defaults)

        XCTAssertNil(defaults.string(forKey: "gemini_api_key"))
    }
}

// MARK: - ProfileDetails key accessors

final class ProfileDetailsKeyAccessorTests: XCTestCase {

    private func llm(_ key: String?) -> ProviderConfig {
        ProviderConfig(apiProvider: .openAI, modelName: "gpt-4o", apiKey: key)
    }

    /// Every case that carries an `llmConfig` must be handled — a missed case would silently leave
    /// that profile type's key in the blob.
    func testEveryProfileTypeWithAnLLMConfigRoundTrips() {
        let cases: [ProfileDetails] = [
            .bot(BotConfig(llmConfig: llm("k"))),
            .agent(AgentConfig(llmConfig: llm("k"))),
            .code(AgentConfig(llmConfig: llm("k"))),
            .imageGen(ImageGenConfig(llmConfig: llm("k"))),
        ]
        for details in cases {
            XCTAssertEqual(details.providerAPIKey, "k")
            XCTAssertNil(details.settingProviderAPIKey(nil).providerAPIKey)
            XCTAssertEqual(details.settingProviderAPIKey("z").providerAPIKey, "z")
        }
    }

    /// `.workflow` has no `llmConfig` — it composes other profiles, each with their own key.
    func testWorkflowHasNoKeyAndIsUnchangedBySetting() {
        let workflow = ProfileDetails.workflow(WorkflowConfig(agentProfileIDs: []))
        XCTAssertNil(workflow.providerAPIKey)
        XCTAssertEqual(workflow.settingProviderAPIKey("k"), workflow)
    }

    /// Stripping must leave everything else intact — this runs on the value that gets persisted.
    func testStrippingPreservesEveryOtherField() {
        let original = ProfileDetails.agent(AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude-opus-5",
                                      apiKey: "k", baseURL: "https://gw.internal/v1"),
            instructions: "be brief"
        ))
        guard case .agent(let stripped) = original.settingProviderAPIKey(nil) else {
            return XCTFail("case changed during strip")
        }
        XCTAssertNil(stripped.llmConfig.apiKey)
        XCTAssertEqual(stripped.llmConfig.modelName, "claude-opus-5")
        XCTAssertEqual(stripped.llmConfig.baseURL, "https://gw.internal/v1")
        XCTAssertEqual(stripped.instructions, "be brief")
    }
}
