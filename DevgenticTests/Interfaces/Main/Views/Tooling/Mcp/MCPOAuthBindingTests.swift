// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPOAuthBindingTests.swift
//  DevgenticTests
//
//  Register KC-14. An MCP OAuth access token used to be attached by sourceID alone, so editing
//  a server's URL — or repurposing the row for a different vendor — replayed the old host's
//  token at the new one. The invariant the fix enforces, from three independent call sites that
//  all delegate to `MCPOAuthBinding`:
//
//      an OAuth credential bundle is attached only to the server URL it was issued for.
//
//  The three points disagree DELIBERATELY about what to do when the binding is unknown:
//    - ATTACH  (`shouldAttach`)          — legacy bundles attach (compatibility);
//    - PERSIST (`isProvablyMisbound`)    — only a PROVEN misbinding is cleared (never destroy
//                                          what cannot be read);
//    - SAVE    (`editDecision`)          — fail closed: a save whose effective bundle is not
//                                          provably bound to the new URL demands a re-auth.
//  A mutation that homogenises any two of those answers must go red.
//

import XCTest
@testable import devgentic

@MainActor
final class MCPOAuthBindingTests: XCTestCase {

    private var keychain: ProgrammableKeychain!
    private let sourceID = UUID()

    override func setUp() {
        super.setUp()
        keychain = ProgrammableKeychain()
        MCPSecretStore.setBackingForTesting(keychain)
    }

    override func tearDown() {
        MCPSecretStore.setBackingForTesting(nil)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeBundle(
        accessToken: String = "token-1",
        serverURL: URL? = URL(string: "https://mcp.vendor-a.com")
    ) -> MCPOAuthCredentialBundle {
        MCPOAuthCredentialBundle(
            issuer: URL(string: "https://auth.vendor-a.com")!,
            clientId: "client-1",
            grantedScopes: ["mcp"],
            redirectURI: URL(string: "http://127.0.0.1:0/callback")!,
            accessToken: accessToken,
            refreshToken: "rt-1",
            accessTokenExpiresAt: Date().addingTimeInterval(3600),
            registrationAccessToken: nil,
            registrationClientUri: nil,
            resource: serverURL,
            serverURL: serverURL
        )
    }

    private func seedStoredBundle(_ bundle: MCPOAuthCredentialBundle) {
        let json = String(data: try! JSONEncoder().encode(bundle), encoding: .utf8)!
        XCTAssertTrue(MCPSecretStore.shared.store(json, for: .oauthBundle, sourceID: sourceID))
    }

    private func storedOAuthBundleJSON() -> String? {
        MCPSecretStore.shared.retrieve(.oauthBundle, sourceID: sourceID)
    }

    // MARK: - The binding key

    func testTheKeyIsInsensitiveToCaseAndTrailingSlash() {
        let a = MCPOAuthBinding.normalizedServerKey(URL(string: "https://MCP.Vendor-A.com/")!)
        let b = MCPOAuthBinding.normalizedServerKey(URL(string: "https://mcp.vendor-a.com")!)
        XCTAssertEqual(a, b)
    }

    func testTheKeyKeepsThePathAndAnExplicitPort() {
        XCTAssertEqual(
            MCPOAuthBinding.normalizedServerKey(URL(string: "https://mcp.a.com/tenant1")!),
            MCPOAuthBinding.normalizedServerKey(URL(string: "https://mcp.a.com/tenant1")!))
        XCTAssertNotEqual(
            MCPOAuthBinding.normalizedServerKey(URL(string: "https://mcp.a.com")!),
            MCPOAuthBinding.normalizedServerKey(URL(string: "https://mcp.a.com/tenant1")!),
            "different paths on one host are different servers")
        XCTAssertNotEqual(
            MCPOAuthBinding.normalizedServerKey(URL(string: "https://mcp.a.com:8443")!),
            MCPOAuthBinding.normalizedServerKey(URL(string: "https://mcp.a.com:8080")!),
            "different ports on one host are different services — a token must not cross them")
    }

    // MARK: - ATTACH: shouldAttach (the runtime enforcement)

    func testABoundBundleAttachesOnlyToItsOwnURL() {
        let bundle = makeBundle()
        XCTAssertTrue(MCPOAuthBinding.shouldAttach(bundle, to: "https://mcp.vendor-a.com"))
        XCTAssertTrue(MCPOAuthBinding.shouldAttach(bundle, to: "https://MCP.VENDOR-A.com/"),
                      "case and trailing slash are the same server")
        XCTAssertFalse(MCPOAuthBinding.shouldAttach(bundle, to: "https://mcp.vendor-b.com"),
                       "the replay this register exists to prevent")
        XCTAssertFalse(MCPOAuthBinding.shouldAttach(bundle, to: "https://mcp.vendor-a.com:8443"))
    }

    func testALegacyUnboundBundleAttachesForCompatibility() {
        let bundle = makeBundle(serverURL: nil)
        XCTAssertTrue(MCPOAuthBinding.shouldAttach(bundle, to: "https://any.host.example"),
                      "pre-register bundles carry no binding; refusing them breaks every existing server on first connect")
    }

    func testAnUnparseableTargetRefusesABoundBundle() {
        let bundle = makeBundle()
        XCTAssertFalse(MCPOAuthBinding.shouldAttach(bundle, to: nil))
        XCTAssertFalse(MCPOAuthBinding.shouldAttach(bundle, to: "not a url at all"),
                       "cannot confirm the one thing this check exists to confirm")
    }

    /// The wiring: `materialize` must refuse to build an Authorization header for a misbound
    /// bundle, and must still build one for the matching URL.
    func testMaterializeRefusesToAttachAMisboundToken() {
        seedStoredBundle(makeBundle()) // bound to vendor-a

        let vendorA = ServerDefinition(command: nil, args: nil, envKeys: nil,
                                       url: "https://mcp.vendor-a.com", auth: .oauth(issuer: URL(string: "https://auth.vendor-a.com")!))
        XCTAssertEqual(MCPRuntimeSecrets.materialize(for: sourceID, definition: vendorA)
            .authorizationHeader?.value, "Bearer token-1")

        let vendorB = ServerDefinition(command: nil, args: nil, envKeys: nil,
                                       url: "https://mcp.vendor-b.com", auth: .oauth(issuer: URL(string: "https://auth.vendor-a.com")!))
        XCTAssertNil(MCPRuntimeSecrets.materialize(for: sourceID, definition: vendorB)
            .authorizationHeader,
            "vendor B must never receive vendor A's token")

        let legacy = makeBundle(serverURL: nil)
        seedStoredBundle(legacy)
        XCTAssertNotNil(MCPRuntimeSecrets.materialize(for: sourceID, definition: vendorB)
            .authorizationHeader,
            "a legacy bundle attaches until the edit gate retires it")
    }

    // MARK: - PERSIST: isProvablyMisbound (the reconcile)

    func testTheReconcileClearsOnlyAProvenMisbinding() {
        // Proven: decodes, carries a binding, target parses, keys differ.
        XCTAssertTrue(MCPOAuthBinding.isProvablyMisbound(
            storedJSON: String(data: try! JSONEncoder().encode(makeBundle()), encoding: .utf8)!,
            serverURLString: "https://mcp.vendor-b.com"))
        XCTAssertFalse(MCPOAuthBinding.isProvablyMisbound(
            storedJSON: String(data: try! JSONEncoder().encode(makeBundle()), encoding: .utf8)!,
            serverURLString: "https://mcp.vendor-a.com"))

        // Everything unprovable is KEPT — never destroy what cannot be read.
        XCTAssertFalse(MCPOAuthBinding.isProvablyMisbound(
            storedJSON: String(data: try! JSONEncoder().encode(makeBundle(serverURL: nil)), encoding: .utf8)!,
            serverURLString: "https://mcp.vendor-b.com"),
            "a legacy bundle cannot be proven misbound")
        XCTAssertFalse(MCPOAuthBinding.isProvablyMisbound(
            storedJSON: "not json", serverURLString: "https://mcp.vendor-b.com"))
        XCTAssertFalse(MCPOAuthBinding.isProvablyMisbound(
            storedJSON: String(data: try! JSONEncoder().encode(makeBundle()), encoding: .utf8)!,
            serverURLString: nil))
    }

    /// The wiring: `persistSecrets` must clear a provably misbound bundle and must leave
    /// legacy and correctly-bound bundles alone.
    func testPersistSecretsReconcilesTheBinding() {
        // Proven misbinding → cleared.
        seedStoredBundle(makeBundle()) // vendor-a
        let vendorB = ServerDefinition(command: nil, args: nil, envKeys: nil,
                                       url: "https://mcp.vendor-b.com", auth: .oauth(issuer: URL(string: "https://auth.vendor-a.com")!))
        MCPToolStore.shared.persistSecrets(MCPRuntimeSecrets(), definition: vendorB, sourceID: sourceID)
        XCTAssertNil(storedOAuthBundleJSON(),
                     "a bundle bound to vendor A must not survive a save of vendor B")

        // Correct binding → kept.
        seedStoredBundle(makeBundle())
        let vendorA = ServerDefinition(command: nil, args: nil, envKeys: nil,
                                       url: "https://mcp.vendor-a.com", auth: .oauth(issuer: URL(string: "https://auth.vendor-a.com")!))
        MCPToolStore.shared.persistSecrets(MCPRuntimeSecrets(), definition: vendorA, sourceID: sourceID)
        XCTAssertNotNil(storedOAuthBundleJSON())

        // Legacy bundle → kept (a guarded world: hygiene never destroys the unprovable).
        seedStoredBundle(makeBundle(serverURL: nil))
        MCPToolStore.shared.persistSecrets(MCPRuntimeSecrets(), definition: vendorB, sourceID: sourceID)
        XCTAssertNotNil(storedOAuthBundleJSON())
    }

    // MARK: - SAVE: editDecision (the fail-closed form gate)

    private func proceed(_ decision: MCPOAuthBinding.EditDecision,
                         _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .proceed = decision else {
            XCTFail("expected .proceed — \(message)", file: file, line: line)
            return
        }
    }

    private func refused(_ decision: MCPOAuthBinding.EditDecision,
                         _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .requiresReAuth = decision else {
            XCTFail("expected .requiresReAuth — \(message)", file: file, line: line)
            return
        }
    }

    func testANonOAuthSaveNeverNeedsTheGate() {
        proceed(MCPOAuthBinding.editDecision(
            isOAuth: false, newURL: "https://b.com", previousURL: "https://a.com",
            freshBundle: nil, storedRead: .failed(errSecAuthFailed)), "a bearer server may edit its URL freely")
    }

    func testAFreshSignInBoundToTheSavedURLProceeds() {
        proceed(MCPOAuthBinding.editDecision(
            isOAuth: true, newURL: "https://mcp.vendor-a.com", previousURL: nil,
            freshBundle: makeBundle(), storedRead: .notFound),
            "the add path: nothing stored, fresh bundle bound to the form URL")
    }

    func testTheURLEditedAfterTheSignInIsARefusal() {
        // The user signed in, THEN edited the URL field. The fresh bundle is bound to the
        // old URL — it must not ride along to the new one.
        refused(MCPOAuthBinding.editDecision(
            isOAuth: true, newURL: "https://mcp.vendor-b.com", previousURL: nil,
            freshBundle: makeBundle(), storedRead: .notFound),
            "a fresh bundle bound elsewhere is exactly the replay")
    }

    func testNothingStoredProceedsAndAnUnreadableStoreRefuses() {
        proceed(MCPOAuthBinding.editDecision(
            isOAuth: true, newURL: "https://b.com", previousURL: "https://a.com",
            freshBundle: nil, storedRead: .notFound),
            "nothing stored means nothing can be replayed")
        refused(MCPOAuthBinding.editDecision(
            isOAuth: true, newURL: "https://b.com", previousURL: "https://a.com",
            freshBundle: nil, storedRead: .failed(errSecAuthFailed)),
            "a locked Keychain must fail closed")
        refused(MCPOAuthBinding.editDecision(
            isOAuth: true, newURL: "https://b.com", previousURL: "https://a.com",
            freshBundle: nil, storedRead: .found("not json")),
            "an undecodable bundle must fail closed")
    }

    func testALegacyStoredBundleMayStayOnlyWhileTheURLIsProvablyUntouched() {
        let legacyJSON = String(data: try! JSONEncoder().encode(makeBundle(serverURL: nil)), encoding: .utf8)!
        proceed(MCPOAuthBinding.editDecision(
            isOAuth: true, newURL: "https://mcp.a.com", previousURL: "https://mcp.a.com",
            freshBundle: nil, storedRead: .found(legacyJSON)),
            "a rename on a pre-register server must not be refused over a binding it does not touch")
        proceed(MCPOAuthBinding.editDecision(
            isOAuth: true, newURL: "https://MCP.A.com/", previousURL: "https://mcp.a.com",
            freshBundle: nil, storedRead: .found(legacyJSON)),
            "case/slash differences are the same URL")
        refused(MCPOAuthBinding.editDecision(
            isOAuth: true, newURL: "https://mcp.b.com", previousURL: "https://mcp.a.com",
            freshBundle: nil, storedRead: .found(legacyJSON)),
            "a legacy bundle whose URL changed cannot prove where its token belongs")
        refused(MCPOAuthBinding.editDecision(
            isOAuth: true, newURL: "https://mcp.b.com", previousURL: nil,
            freshBundle: nil, storedRead: .found(legacyJSON)),
            "an unknown previous URL cannot prove 'unchanged'")
    }

    func testABoundStoredBundleMustMatchTheSavedURL() {
        let boundJSON = String(data: try! JSONEncoder().encode(makeBundle()), encoding: .utf8)!
        proceed(MCPOAuthBinding.editDecision(
            isOAuth: true, newURL: "https://mcp.vendor-a.com", previousURL: "https://mcp.vendor-a.com",
            freshBundle: nil, storedRead: .found(boundJSON)),
            "a bound bundle may keep serving its own URL")
        refused(MCPOAuthBinding.editDecision(
            isOAuth: true, newURL: "https://mcp.vendor-b.com", previousURL: "https://mcp.vendor-a.com",
            freshBundle: nil, storedRead: .found(boundJSON)),
            "the KC-14 save itself")
    }

    // MARK: - The bundle field itself

    func testLegacyBundleJSONWithoutServerURLStillDecodes() {
        // Shape of a bundle persisted before 2026-09-27: no serverURL key at all.
        let legacy = """
        {"issuer":"https://auth.vendor-a.com","clientId":"c","grantedScopes":["mcp"],\
        "redirectURI":"http://127.0.0.1:0/callback","accessToken":"t","refreshToken":"r",\
        "accessTokenExpiresAt":1000000000,"registrationAccessToken":null,\
        "registrationClientUri":null}
        """
        let bundle = try! JSONDecoder().decode(MCPOAuthCredentialBundle.self, from: Data(legacy.utf8))
        XCTAssertNil(bundle.serverURL, "old bundles decode with no local binding")
        XCTAssertNil(bundle.resource)
    }

    func testServerURLRoundTripsAndParticipatesInEquality() throws {
        let data = try JSONEncoder().encode(makeBundle())
        let decoded = try JSONDecoder().decode(MCPOAuthCredentialBundle.self, from: data)
        XCTAssertEqual(decoded.serverURL, URL(string: "https://mcp.vendor-a.com"))

        var unbound = makeBundle()
        unbound.serverURL = nil
        XCTAssertNotEqual(unbound, makeBundle(),
                          "two bundles differing only in binding are different credentials")
    }
}
