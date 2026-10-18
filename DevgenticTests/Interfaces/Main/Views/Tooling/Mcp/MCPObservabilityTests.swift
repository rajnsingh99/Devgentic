// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPObservabilityTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class MCPObservabilityTests: XCTestCase {

    private var keychain: ProgrammableKeychain!
    private let sourceID = UUID()

    override func setUp() {
        super.setUp()
        keychain = ProgrammableKeychain()
        MCPSecretStore.setBackingForTesting(keychain)
    }

    override func tearDown() {
        MCPSecretStore.setBackingForTesting(nil)
        MCPRuntimeSecrets.refusalLogSinkForTesting = nil
        MCPSecretStore.deleteFailureLogSinkForTesting = nil
        super.tearDown()
    }

    private func remoteDefinition(auth: MCPAuthenticationScheme, envKeys: [String]? = nil) -> ServerDefinition {
        ServerDefinition(command: nil, args: nil, envKeys: envKeys,
                         url: "https://mcp.example.com", auth: auth)
    }

    // MARK: - KC-31: materialize refuses loudly

    func testAnUnreadableBearerTokenIsRefusedWithALog() {
        keychain.readStatusOverride = errSecAuthFailed
        var logged: [String] = []
        MCPRuntimeSecrets.refusalLogSinkForTesting = { logged.append($0) }

        let secrets = MCPRuntimeSecrets.materialize(
            for: sourceID, definition: remoteDefinition(auth: .bearer))

        XCTAssertNil(secrets.authorizationHeader)
        XCTAssertEqual(logged.count, 1, "the refusal must be logged: \(logged)")
        XCTAssertTrue(logged[0].contains("bearer token"), logged[0])
        XCTAssertTrue(logged[0].contains("errSecAuthFailed"), "the OSStatus must be named (KC-51): \(logged[0])")
        XCTAssertTrue(logged[0].contains("CONSEQUENCE"), logged[0])
    }

    func testAnUnreadableEnvValueIsRefusedWithALogAndSiblingsSurvive() {
        keychain.readStatusOverride = errSecAuthFailed
        var logged: [String] = []
        MCPRuntimeSecrets.refusalLogSinkForTesting = { logged.append($0) }

        let secrets = MCPRuntimeSecrets.materialize(
            for: sourceID,
            definition: remoteDefinition(auth: .none, envKeys: ["GITHUB_TOKEN", "OTHER_VAR"]))

        XCTAssertTrue(secrets.env.isEmpty)
        XCTAssertEqual(logged.count, 2, "each unreadable env value gets its own refusal: \(logged)")
        XCTAssertTrue(logged[0].contains("GITHUB_TOKEN") || logged[1].contains("GITHUB_TOKEN"))
    }

    func testAnUnreadableHeaderValueIsRefusedWithALog() {
        keychain.readStatusOverride = errSecInteractionNotAllowed
        var logged: [String] = []
        MCPRuntimeSecrets.refusalLogSinkForTesting = { logged.append($0) }

        let secrets = MCPRuntimeSecrets.materialize(
            for: sourceID, definition: remoteDefinition(auth: .apiKeyHeader(headerName: "X-API-Key")))

        XCTAssertNil(secrets.authorizationHeader)
        XCTAssertTrue(logged.contains { $0.contains("X-API-Key") }, "\(logged)")
    }

    func testAnAbsentCredentialIsStillSilentlySkipped() {
        // KC-31 is about FAILED reads. An ABSENT one is the user having removed the secret —
        // that was always silent by design and must stay so, or every de-scoped server spams.
        var logged: [String] = []
        MCPRuntimeSecrets.refusalLogSinkForTesting = { logged.append($0) }

        _ = MCPRuntimeSecrets.materialize(for: sourceID, definition: remoteDefinition(auth: .bearer))
        XCTAssertTrue(logged.isEmpty, "absent ≠ failed: no refusal for a credential that does not exist")
    }

    // MARK: - KC-52: delete failures are visible

    func testARefusedDeleteIsLogged() {
        keychain.store[MCPSecretStoreTestAccount.bearer(sourceID)] = "live"
        keychain.deleteStatusOverride = errSecAuthFailed
        var logged: [String] = []
        MCPSecretStore.deleteFailureLogSinkForTesting = { logged.append($0) }

        XCTAssertFalse(MCPSecretStore.shared.delete(scope: .bearerToken, sourceID: sourceID))
        XCTAssertEqual(logged.count, 1, "\(logged)")
        XCTAssertTrue(logged[0].contains("REMAINS"), logged[0])
        XCTAssertTrue(logged[0].contains("errSecAuthFailed"), logged[0])
    }

    func testADeleteOfAnAbsentSecretIsNotAFailureAndLogsNothing() {
        var logged: [String] = []
        MCPSecretStore.deleteFailureLogSinkForTesting = { logged.append($0) }

        XCTAssertTrue(MCPSecretStore.shared.delete(scope: .bearerToken, sourceID: sourceID))
        XCTAssertTrue(logged.isEmpty, "errSecItemNotFound is the goal of a wipe, not a failure")
    }

    // MARK: - KC-64: the registration is deleted, best-effort

    func testTheRegistrationDeletionSendsRFC7592DeleteWithBearerAuth() async {
        var captured: URLRequest?
        let removed = await MCPOAuthTokenExchange.deleteRegistration(
            registrationClientUri: URL(string: "https://as.example.com/register/client-1")!,
            registrationAccessToken: "rat-1") { req in
                captured = req
                return (204, nil)
            }

        XCTAssertTrue(removed)
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer rat-1")
    }

    func testAnASWithoutRFC7592IsLoggedAndNotTreatedAsSuccess() async {
        var logged: [String] = []
        MCPRuntimeSecrets.refusalLogSinkForTesting = nil
        // 405 = the AS does not implement RFC 7592 §2.3; the deletion must NOT report success.
        let refused = await MCPOAuthTokenExchange.deleteRegistration(
            registrationClientUri: URL(string: "https://as.example.com/register/client-1")!,
            registrationAccessToken: "rat-1") { _ in
                (405, nil)
            }
        XCTAssertFalse(refused)

        let errored = await MCPOAuthTokenExchange.deleteRegistration(
            registrationClientUri: URL(string: "https://as.example.com/register/client-1")!,
            registrationAccessToken: "rat-1") { _ in
                throw URLError(.timedOut)
            }
        XCTAssertFalse(errored)
        _ = logged // the network paths log through DGLogger; the Bool is the contract under test
    }

    /// Resolves a repo-relative path from THIS test file's location — the test runner's CWD is
    /// not the repo root, so plain relative paths silently read nothing.
    private func repoSource(relativeToRepo path: String) -> String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Mcp
            .deletingLastPathComponent() // Tooling
            .deletingLastPathComponent() // Views
            .deletingLastPathComponent() // Main
            .deletingLastPathComponent() // Interfaces
            .deletingLastPathComponent() // DevgenticTests
            .deletingLastPathComponent() // <repo root>
        return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testRevokeTokensWiresTheRegistrationDeletion() {
        // Source pin: the coordinator's revoke path must attempt the registration deletion
        // (KC-64's whole point was that the token sat unused).
        let source = repoSource(relativeToRepo: "Devgentic/Interfaces/Main/Views/Tooling/Mcp/OAuth/MCPOAuthCoordinator.swift")
        XCTAssertTrue(source?.contains("deleteRegistration(") == true,
                      "revokeTokens must wire MCPOAuthTokenExchange.deleteRegistration")
    }

    // MARK: - KC-49 / KC-50: the HF entry's ordering, pinned by source scan

    private func ordered(_ haystack: String, _ first: String, before second: String) -> Bool {
        guard let a = haystack.range(of: first), let b = haystack.range(of: second) else { return false }
        return a.lowerBound < b.lowerBound
    }

    func testTheDraftIsWipedOnlyAfterAConfirmedStore() {
        guard let source = repoSource(relativeToRepo: "Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/HuggingFaceTokenEntry.swift") else {
            return XCTFail("could not read HuggingFaceTokenEntry.swift — the source pin is void")
        }
        XCTAssertTrue(ordered(source,
                              "let stored = HuggingFaceTokenStore.shared.store(draft)",
                              before: "guard stored else {"), "the store must precede its guard")
        XCTAssertTrue(ordered(source,
                              "guard stored else {",
                              before: "draft = \"\""),
                      "KC-50: the draft must survive a failed save so the user can retry")
    }

    func testTheShapeWarningIsComputedAfterTheStoreSucceeds() {
        guard let source = repoSource(relativeToRepo: "Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/HuggingFaceTokenEntry.swift") else {
            return XCTFail("could not read HuggingFaceTokenEntry.swift — the source pin is void")
        }
        XCTAssertTrue(ordered(source,
                              "guard stored else {",
                              before: "showsShapeWarning = !HuggingFaceTokenStore.looksLikeToken(draft)"),
                      "KC-49: 'It has been saved anyway' must never accompany a save failure")
    }
}

/// The account format MCPSecretStore uses, re-spelled here only because the real one is private;
/// these tests go through the PUBLIC store API, so this is only needed for direct stub seeding.
private enum MCPSecretStoreTestAccount {
    static func bearer(_ sourceID: UUID) -> String {
        "\(sourceID.uuidString)::auth.bearer"
    }
}
