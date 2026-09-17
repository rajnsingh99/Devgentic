// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MCPSecretStoreClearTests.swift
//  devgenticTests
//
//  Registers KC-1 and KC-17 — the MCP edit round-trip that deleted a live credential.
//
//  ⚠️⚠️ THE FAILURE THESE PIN. `MCPSecretStore` exposed only `retrieve`, which collapses "no secret
//  stored" and "the Keychain read FAILED" into one nil. The edit sheet hydrated its field with
//  `retrieve(...) ?? ""`, so on a locked Keychain — or a denied ACL prompt after an update changed
//  the app's code signature — a live bearer token rendered as an EMPTY field. Pressing Save then ran
//  `persistSecrets`, which deleted both auth scopes unconditionally BEFORE the
//  `guard let header = ... else { return }` that returns when no secret was supplied. The token was
//  gone from the Keychain, which was the only copy, and the user had never touched the field.
//
//  ⚠️ EVERY TEST HERE DRIVES `.failed`, NOT `.notFound`. That is the whole point: a dev machine only
//  ever produces `errSecItemNotFound`, which is why this survived. If a test in this file passes
//  against a stub that cannot produce a FAILED read, it is testing nothing.
//

import XCTest
@testable import devgentic

@MainActor
final class MCPSecretStoreClearTests: XCTestCase {

    private var keychain: ProgrammableKeychain!
    private let sourceID = UUID()

    override func setUp() {
        super.setUp()
        keychain = ProgrammableKeychain()
        MCPSecretStore.setBackingForTesting(keychain)
    }

    override func tearDown() {
        MCPSecretStore.setBackingForTesting(nil)
        keychain = nil
        super.tearDown()
    }

    private func account(_ scope: MCPSecretScope) -> String { "\(sourceID.uuidString)::\(scope.rawScope)" }

    // MARK: - clear: the guarantee

    func testClearRefusesWhenTheCurrentValueCannotBeRead() {
        keychain.store[account(.bearerToken)] = "live-token"
        keychain.readStatusOverride = errSecAuthFailed   // the denied-ACL / locked-keychain case

        let outcome = MCPSecretStore.shared.clear(scope: .bearerToken, sourceID: sourceID)

        XCTAssertEqual(outcome, .refusedUnreadable(errSecAuthFailed))
        XCTAssertEqual(keychain.store[account(.bearerToken)], "live-token",
                       "a secret that merely could not be READ must survive a clear")
        XCTAssertEqual(keychain.deleteCount, 0, "no delete may even be attempted on an unreadable read")
    }

    func testClearDeletesWhenTheValueIsReadable() {
        keychain.store[account(.bearerToken)] = "live-token"

        let outcome = MCPSecretStore.shared.clear(scope: .bearerToken, sourceID: sourceID)

        XCTAssertEqual(outcome, .cleared)
        XCTAssertNil(keychain.store[account(.bearerToken)], "a readable secret the caller cleared must be removed")
    }

    /// The desired end state is "gone", not "we did the deleting".
    func testClearTreatsAGenuinelyAbsentSecretAsAlreadyCleared() {
        let outcome = MCPSecretStore.shared.clear(scope: .bearerToken, sourceID: sourceID)
        XCTAssertEqual(outcome, .cleared)
        XCTAssertEqual(keychain.deleteCount, 0, "nothing to delete means nothing should be attempted")
    }

    /// ⚠️ `refusedUnreadable` must NOT read as a failure. Callers carry on from it; if it were
    /// treated as an error they would fall back to exactly the destructive behaviour it prevents.
    func testRefusalIsNotAFailure() {
        XCTAssertFalse(MCPSecretClearOutcome.refusedUnreadable(errSecAuthFailed).isFailure)
        XCTAssertFalse(MCPSecretClearOutcome.cleared.isFailure)
        XCTAssertTrue(MCPSecretClearOutcome.failed(errSecIO).isFailure)
    }

    // MARK: - store("") is a clear, not a delete

    func testStoringAnEmptyValueOverAnUnreadableSecretDoesNotDestroyIt() {
        keychain.store[account(.envValue(key: "GITHUB_TOKEN"))] = "ghp_live"
        keychain.readStatusOverride = errSecInteractionNotAllowed

        MCPSecretStore.shared.store("", for: .envValue(key: "GITHUB_TOKEN"), sourceID: sourceID)

        XCTAssertEqual(keychain.store[account(.envValue(key: "GITHUB_TOKEN"))], "ghp_live",
                       "an empty form field during a Keychain outage must not delete the stored env secret")
    }

    // MARK: - read: the distinction itself

    func testReadDistinguishesAbsenceFromFailure() {
        XCTAssertEqual(MCPSecretStore.shared.read(.bearerToken, sourceID: sourceID), .notFound)

        keychain.store[account(.bearerToken)] = "tok"
        XCTAssertEqual(MCPSecretStore.shared.read(.bearerToken, sourceID: sourceID), .found("tok"))

        keychain.readStatusOverride = errSecAuthFailed
        XCTAssertEqual(MCPSecretStore.shared.read(.bearerToken, sourceID: sourceID), .failed(errSecAuthFailed))
    }

    /// `retrieve` is still allowed to collapse the two — but only for callers that merely send a
    /// value. Pinned so nobody "fixes" it into something that throws and breaks the runtime path.
    func testRetrieveStillCollapsesFailureIntoNil() {
        keychain.store[account(.bearerToken)] = "tok"
        keychain.readStatusOverride = errSecAuthFailed
        XCTAssertNil(MCPSecretStore.shared.retrieve(.bearerToken, sourceID: sourceID))
    }

    // MARK: - THE WIRING (registers KC-1 + KC-17)

    /// ⚠️⚠️ THIS IS THE TEST THAT MATTERS. `clear` refusing to delete is worth nothing if
    /// `persistSecrets` calls `delete` instead — and a test of `clear` alone cannot catch that.
    /// This drives the real save path with an unreadable Keychain and asserts the credential lives.
    func testSavingAnEditedServerDoesNotDestroyAnUnreadableBearerToken() {
        keychain.store[account(.bearerToken)] = "live-token"
        keychain.readStatusOverride = errSecAuthFailed

        // What the edit form produces when it could not read the secret: no authorization header,
        // because `buildRuntimeSecrets` only sets one for a non-empty field.
        let secrets = MCPRuntimeSecrets()
        let definition = ServerDefinition(
            command: nil, args: nil, envKeys: nil,
            url: "https://mcp.example.com", auth: .bearer)

        MCPToolStore.shared.persistSecrets(secrets, definition: definition, sourceID: sourceID)

        XCTAssertEqual(keychain.store[account(.bearerToken)], "live-token",
                       "renaming a server while the Keychain is unreadable must not delete its token")
    }

    /// The same save with a READABLE Keychain and a genuinely emptied field SHOULD clear it —
    /// otherwise the fix would have made the secret impossible to remove.
    func testSavingWithAnEmptiedFieldStillClearsAReadableToken() {
        keychain.store[account(.bearerToken)] = "live-token"

        let definition = ServerDefinition(
            command: nil, args: nil, envKeys: nil,
            url: "https://mcp.example.com", auth: .bearer)
        MCPToolStore.shared.persistSecrets(MCPRuntimeSecrets(), definition: definition, sourceID: sourceID)

        XCTAssertNil(keychain.store[account(.bearerToken)],
                     "clearing the field on a readable Keychain is real user intent and must take effect")
    }

    /// The target scope must never be cleared on the way to being written. Pins the
    /// reconcile-to-target ordering that replaced wipe-then-guard.
    func testTheScopeBeingWrittenIsNeverClearedFirst() {
        keychain.store[account(.bearerToken)] = "old-token"

        var secrets = MCPRuntimeSecrets()
        secrets.authorizationHeader = ("Authorization", "Bearer new-token")
        let definition = ServerDefinition(
            command: nil, args: nil, envKeys: nil,
            url: "https://mcp.example.com", auth: .bearer)

        MCPToolStore.shared.persistSecrets(secrets, definition: definition, sourceID: sourceID)

        XCTAssertEqual(keychain.store[account(.bearerToken)], "new-token", "the Bearer prefix must be stripped and the token stored")
        XCTAssertEqual(keychain.deleteCount, 0, "the target scope must not be deleted on its way to being written")
    }

    /// A scheme change must still orphan nothing.
    func testSwitchingSchemeClearsTheScopeNoLongerInUse() {
        keychain.store[account(.bearerToken)] = "old-bearer"

        var secrets = MCPRuntimeSecrets()
        secrets.authorizationHeader = ("X-API-Key", "api-key-value")
        let definition = ServerDefinition(
            command: nil, args: nil, envKeys: nil,
            url: "https://mcp.example.com", auth: .apiKeyHeader(headerName: "X-API-Key"))

        MCPToolStore.shared.persistSecrets(secrets, definition: definition, sourceID: sourceID)

        XCTAssertNil(keychain.store[account(.bearerToken)], "the abandoned scheme's secret must not be orphaned")
        XCTAssertEqual(keychain.store[account(.apiKeyHeaderValue)], "api-key-value")
    }
}

// MARK: - Stub

/// A Keychain whose READ can be made to fail on demand.
///
/// ⚠️ The `readStatusOverride` is the entire reason this exists. A stub that can only return
/// "found" and "not found" cannot express the state every defect in this file is about, and tests
/// written against one would pass against the unfixed code.
final class ProgrammableKeychain: KeychainAccessing, @unchecked Sendable {

    var store: [String: String] = [:]

    /// When set, every `read` returns `.failed(this)` regardless of what is stored.
    var readStatusOverride: OSStatus?

    /// When set, every `save` returns this instead of succeeding.
    var saveStatusOverride: OSStatus?

    /// When set, every `delete` returns this and the item is LEFT IN PLACE.
    var deleteStatusOverride: OSStatus?

    private(set) var deleteCount = 0
    private(set) var readCount = 0

    func save(value: String, service: String, account: String) -> OSStatus {
        if let saveStatusOverride { return saveStatusOverride }
        store[account] = value
        return errSecSuccess
    }

    func read(service: String, account: String) -> KeychainReadOutcome {
        readCount += 1
        if let readStatusOverride { return .failed(readStatusOverride) }
        guard let value = store[account] else { return .notFound }
        return .found(value)
    }

    func delete(service: String, account: String) -> OSStatus {
        deleteCount += 1
        if let deleteStatusOverride { return deleteStatusOverride }
        guard store.removeValue(forKey: account) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
}
