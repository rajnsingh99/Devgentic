// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// ⚠️ An OpenAI-COMPATIBLE profile, deliberately: since 2026-10-03 it is the one cloud provider
    /// whose key is still stored per profile (`ProviderKeyStore`) — OpenAI, Anthropic, Google and
    /// OpenRouter share one key per provider (`GlobalProviderKeys`, covered by
    /// `SharedProviderKeyTests`). Every guard below protects the per-profile path.
    private func agentDetails(key: String?) -> ProfileDetails {
        .agent(AgentConfig(llmConfig: ProviderConfig(
            apiProvider: .openAICompatible, modelName: "local-model", apiKey: key,
            baseURL: "https://llm.example.test/v1")))
    }

    /// Whether the STORED BYTES carry the key — decoded directly, because `details` injects the
    /// Keychain value and would report a key either way.
    private func hasInlineKey(_ row: BackendProfile) -> Bool {
        let decoded = try? JSONDecoder().decode(ProfileDetails.self, from: row.configData)
        return !(decoded?.providerAPIKey ?? "").isEmpty
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
        XCTAssertFalse(hasInlineKey(row))
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
            displayName: "Flow", details: .workflow(WorkflowConfig()))
        createdProfileIDs.append(row.id)

        XCTAssertNil(row.details.providerAPIKey)
        XCTAssertFalse(hasInlineKey(row))
    }

    // MARK: Inline key (left there by a Keychain write that failed)

    /// A key the setter had to leave inline must keep working — the read path falls back to the
    /// blob when the Keychain is empty.
    func testAnInlineKeyStillResolves() throws {
        let row = makeRow(key: nil)
        // Write the legacy shape directly, bypassing the stripping setter.
        row.configData = try JSONEncoder().encode(agentDetails(key: sentinel))
        row.resetDecodeCacheForTesting()

        XCTAssertTrue(hasInlineKey(row), "precondition: the key is inline")
        XCTAssertEqual(row.details.providerAPIKey, sentinel,
                       "an inline key must keep working until a later save moves it")
    }

    /// The next save moves it: assigning `details` back through the setter strips it.
    func testTheNextSaveMovesAnInlineKeyIntoTheKeychain() throws {
        let row = makeRow(key: nil)
        row.configData = try JSONEncoder().encode(agentDetails(key: sentinel))
        row.resetDecodeCacheForTesting()

        row.details = row.details

        XCTAssertFalse(hasInlineKey(row))
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

    // MARK: - B2 / B19: a failed Keychain read or delete must not destroy a credential

    /// Programmable Keychain so the failure branches can actually run. Before this seam existed
    /// they never had — which is why "strip only if the write succeeded" and "never delete on a
    /// failed read" were asserted by comment rather than by test.
    private final class StubKeychain: KeychainAccessing, @unchecked Sendable {
        var stored: [String: String] = [:]
        var readOutcome: KeychainReadOutcome?      // when set, overrides `stored`
        var deleteStatus: OSStatus = errSecSuccess
        /// Register B25: a Keychain that refuses WRITES — a login-item launch before first unlock
        /// is the ordinary way this happens.
        var saveStatus: OSStatus = errSecSuccess
        private(set) var deleteCallCount = 0

        func save(value: String, service: String, account: String) -> OSStatus {
            guard saveStatus == errSecSuccess else { return saveStatus }
            stored[account] = value
            return errSecSuccess
        }

        func read(service: String, account: String) -> KeychainReadOutcome {
            if let readOutcome { return readOutcome }
            if let v = stored[account] { return .found(v) }
            return .notFound
        }

        func delete(service: String, account: String) -> OSStatus {
            deleteCallCount += 1
            if deleteStatus == errSecSuccess { stored[account] = nil }
            return deleteStatus
        }
    }

    private func withStub(_ stub: StubKeychain, _ body: () -> Void) {
        ProviderKeyStore.setStorageForTesting(stub)
        defer { ProviderKeyStore.setStorageForTesting(nil) }
        body()
    }

    /// ⚠️ THE B2 REGRESSION. A locked Keychain (or a denied ACL prompt after a re-sign) made
    /// `read` fail; the row then decoded with no key; and the next opportunistic save — a rename,
    /// a capability chip, the thinking auto-heal — called `save(nil)` and DELETED the credential.
    /// No user action was involved at any point.
    func testAFailedKeychainReadDoesNotDeleteTheStoredKey() {
        let stub = StubKeychain()
        withStub(stub) {
            let row = makeRow(key: sentinel)
            XCTAssertEqual(stub.stored[row.id.uuidString], sentinel, "precondition: key is stored")

            // The Keychain goes unreadable, and the row is re-materialized on a fresh launch —
            // the process key cache starts empty.
            stub.readOutcome = .failed(errSecAuthFailed)
            ProviderKeyStore.discardCache()
            row.resetDecodeCacheForTesting()
            XCTAssertNil(row.details.providerAPIKey, "precondition: the read failure hides the key")

            // An unrelated save — the shape every opportunistic writer takes.
            row.details = row.details

            XCTAssertEqual(stub.deleteCallCount, 0, "a failed read must never trigger a delete")
            XCTAssertEqual(stub.stored[row.id.uuidString], sentinel,
                           "the credential must survive a save made while the Keychain was unreadable")
        }
    }

    // MARK: - KC-20 / KC-22: recovery after a failed read

    /// Makes a stored row whose first read failed — the post-update "ACL prompt denied" state.
    private func rowWithUnreadableKey(_ stub: StubKeychain) -> BackendProfile {
        let row = makeRow(key: sentinel)
        stub.readOutcome = .failed(errSecAuthFailed)
        ProviderKeyStore.discardCache()   // a fresh launch: the process key cache starts empty
        row.resetDecodeCacheForTesting()
        XCTAssertNil(row.details.providerAPIKey, "precondition: the read failure hides the key")
        XCTAssertTrue(row.hasUnreadableProviderKey, "precondition: KC-22's flag reports it")
        return row
    }

    /// ⚠️ KC-20. The failure used to be cached for the instance's lifetime: the key never came
    /// back, however long ago the user clicked Always Allow.
    func testTheKeyComesBackOnceTheKeychainIsReadableAgain() {
        let stub = StubKeychain()
        withStub(stub) {
            let row = rowWithUnreadableKey(stub)

            stub.readOutcome = nil
            row.expireProviderKeyRetryThrottleForTesting()

            XCTAssertEqual(row.details.providerAPIKey, sentinel, "the recovered key must be re-injected")
            XCTAssertFalse(row.hasUnreadableProviderKey)
        }
    }

    /// Every render reads `details`; an unthrottled re-read would re-raise a Keychain prompt
    /// continuously.
    func testTheAutomaticRereadIsThrottled() {
        let stub = StubKeychain()
        withStub(stub) {
            let row = rowWithUnreadableKey(stub)
            stub.readOutcome = nil  // readable again — but the throttle window has not elapsed

            XCTAssertNil(row.details.providerAPIKey, "a re-read inside the throttle window must not happen")
            XCTAssertTrue(row.hasUnreadableProviderKey)
        }
    }

    /// The Try Again button bypasses the throttle.
    func testAnExplicitRetryIgnoresTheThrottle() {
        let stub = StubKeychain()
        withStub(stub) {
            let row = rowWithUnreadableKey(stub)
            XCTAssertFalse(row.retryProviderKeyRead(), "still failing → reports unreadable")

            stub.readOutcome = nil
            XCTAssertTrue(row.retryProviderKeyRead())
            XCTAssertEqual(row.details.providerAPIKey, sentinel)
        }
    }

    /// ⚠️ THE REASON THE SUPPRESSION IS STICKY. The editor snapshotted its draft while the key was
    /// unreadable, so the draft carries no key. After a recovery, saving that stale draft must NOT
    /// read as "the user cleared the key" — that would be B2's credential destruction again, just
    /// one step later.
    func testAStaleDraftSavedAfterRecoveryDoesNotDeleteTheKey() {
        let stub = StubKeychain()
        withStub(stub) {
            let row = rowWithUnreadableKey(stub)
            let staleDraft = row.details  // key-less snapshot, as the editor holds it

            stub.readOutcome = nil
            XCTAssertTrue(row.retryProviderKeyRead(), "precondition: recovered")

            row.details = staleDraft

            XCTAssertEqual(stub.deleteCallCount, 0, "a draft taken during the failure must never delete the key")
            XCTAssertEqual(stub.stored[row.id.uuidString], sentinel)
            XCTAssertEqual(row.details.providerAPIKey, sentinel,
                           "memory must agree with the Keychain — a key-less cache sends requests unauthenticated")
        }
    }

    /// Typing a NEW key while unreadable writes it — and the banner must not keep claiming the key
    /// is unreadable until the next throttled re-read.
    func testWritingANewKeyClearsTheUnreadableBanner() {
        let stub = StubKeychain()
        withStub(stub) {
            let row = rowWithUnreadableKey(stub)

            row.details = agentDetails(key: "sk-ant-NEW-0123456789")

            XCTAssertEqual(stub.stored[row.id.uuidString], "sk-ant-NEW-0123456789")
            XCTAssertFalse(row.hasUnreadableProviderKey)
        }
    }

    /// The asymmetry that keeps the fix honest: when the Keychain is READABLE, clearing the field
    /// must still clear the key. Suppressing in both cases would remove the user's ability to
    /// remove a credential at all.
    func testClearingTheKeyStillWorksWhenTheKeychainIsReadable() {
        let stub = StubKeychain()
        withStub(stub) {
            let row = makeRow(key: sentinel)
            row.details = agentDetails(key: nil)

            XCTAssertEqual(stub.deleteCallCount, 1)
            XCTAssertNil(stub.stored[row.id.uuidString])
        }
    }

    /// ⚠️ B19. `save(nil)` returned `true` unconditionally because `delete` was `Void` and
    /// swallowed its status — so a FAILED delete was reported as a successful clear, and
    /// `primeDecodeState` re-injected the "removed" key on the next read.
    func testSaveNilReportsFailureWhenTheDeleteFails() {
        let stub = StubKeychain()
        withStub(stub) {
            let id = UUID()
            _ = ProviderKeyStore.save(sentinel, for: id)
            stub.deleteStatus = errSecInteractionNotAllowed

            XCTAssertFalse(ProviderKeyStore.save(nil, for: id),
                           "a failed delete must not be reported as a successful clear")
            XCTAssertEqual(stub.stored[id.uuidString], sentinel,
                           "precondition: the item really did survive, which is why it must be reported")
        }
    }

    func testSaveNilReportsSuccessWhenTheItemWasAlreadyAbsent() {
        let stub = StubKeychain()
        withStub(stub) {
            stub.deleteStatus = errSecItemNotFound
            XCTAssertTrue(ProviderKeyStore.save(nil, for: UUID()),
                          "the desired end state is 'gone', so an absent item is success")
        }
    }

    /// `read` must separate the two outcomes that `load` flattens — the whole point of B2.
    func testReadDistinguishesMissingFromFailed() {
        let stub = StubKeychain()
        withStub(stub) {
            let id = UUID()
            XCTAssertEqual(ProviderKeyStore.read(for: id), .notFound)

            stub.readOutcome = .failed(errSecAuthFailed)
            ProviderKeyStore.discardCache()   // a fresh launch, so the Keychain is actually asked
            XCTAssertEqual(ProviderKeyStore.read(for: id), .failed(errSecAuthFailed))

            // ⚠️ And `load` still flattens both to nil — which is why callers that WRITE based on
            // the answer must not use it. Pinned so the distinction cannot quietly be lost again.
            XCTAssertNil(ProviderKeyStore.load(for: id))
        }
    }

    // MARK: - A failed Keychain write keeps the key inline rather than losing it

    /// The assignment SUCCEEDS even when the Keychain write inside it failed — by design, since the
    /// setter keeps the key inline rather than destroying it.
    func testAFailedKeychainWriteLeavesTheKeyInline() throws {
        let stub = StubKeychain()
        ProviderKeyStore.setStorageForTesting(stub)
        defer { ProviderKeyStore.setStorageForTesting(nil) }

        let row = makeRow(key: nil)
        row.configData = try JSONEncoder().encode(agentDetails(key: sentinel))
        row.resetDecodeCacheForTesting()
        XCTAssertTrue(hasInlineKey(row), "precondition: the key is inline")

        stub.saveStatus = errSecInteractionNotAllowed
        row.details = row.details

        XCTAssertTrue(hasInlineKey(row),
                      "the key must stay in the blob when the Keychain write failed — losing it "
                      + "would be worse")
        XCTAssertEqual(row.details.providerAPIKey, sentinel, "the profile keeps working")
        XCTAssertNil(stub.stored[row.id.uuidString], "precondition: nothing reached the Keychain")
    }

    /// The other half: a row that really did move no longer carries the key inline.
    func testASuccessfulWriteClearsTheInlineKey() throws {
        let stub = StubKeychain()
        ProviderKeyStore.setStorageForTesting(stub)
        defer { ProviderKeyStore.setStorageForTesting(nil) }

        let row = makeRow(key: nil)
        row.configData = try JSONEncoder().encode(agentDetails(key: sentinel))
        row.resetDecodeCacheForTesting()

        row.details = row.details

        XCTAssertFalse(hasInlineKey(row))
        XCTAssertEqual(stub.stored[row.id.uuidString], sentinel)
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
        let workflow = ProfileDetails.workflow(WorkflowConfig())
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
