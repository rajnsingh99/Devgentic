// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPOAuthRefreshTests.swift
//  DevgenticTests
//
//  Registers KC-3 and KC-4 — the refresh-token pair.
//
//  ⚠️ KC-3. `MCPOAuthCoordinator.refresh` is a Keychain read-modify-write spanning two awaits, and
//  `@MainActor` does not serialize it. Two tool calls in one turn both read the same refresh token
//  and both POSTed it; a provider with reuse detection revokes the whole grant for the replay.
//  ⚠️ KC-4. The rotation was logged as persisted one line BEFORE the write that can fail; when it
//  failed, the new refresh token unwound with the frame while the old one was already dead.
//
//  Driven through `refresh(sourceID:)` itself — the function the two production callers invoke —
//  with the network and the Keychain replaced by the injected dependencies.
//

import XCTest
@testable import devgentic

@MainActor
final class MCPOAuthRefreshTests: XCTestCase {

    // MARK: - Harness

    private var stored: [UUID: MCPOAuthCredentialBundle] = [:]
    private var exchangeCount = 0
    private var persistCount = 0
    /// How many upcoming persist calls throw.
    private var persistFailures = 0
    /// What the exchange returns as the new refresh token; nil means "unchanged".
    private var rotateTo: String? = "RT2"
    /// When true, every exchange parks in `heldExchanges` until the test resumes them. An array,
    /// not a single slot: if the single-flight is broken, TWO exchanges arrive here, and a slot would
    /// leak the first continuation and hang the test instead of failing it.
    private var gateExchange = false
    private var heldExchanges: [CheckedContinuation<Void, Never>] = []
    private var exchangeError: Error?

    override func setUp() async throws {
        try await super.setUp()
        MCPOAuthCoordinator.setRefreshDependenciesForTesting(.init(
            loadBundle: { [unowned self] id in self.stored[id] },
            fetchMetadata: { [unowned self] _ in try self.metadata() },
            exchange: { [unowned self] bundle, _ in
                self.exchangeCount += 1
                if self.gateExchange {
                    await withCheckedContinuation { self.heldExchanges.append($0) }
                }
                if let error = self.exchangeError { throw error }
                return (accessToken: "AT\(self.exchangeCount)",
                        refreshToken: self.rotateTo,
                        expiresAt: Date().addingTimeInterval(3600),
                        grantedScopes: bundle.grantedScopes)
            },
            persist: { [unowned self] bundle, id in
                self.persistCount += 1
                if self.persistFailures > 0 {
                    self.persistFailures -= 1
                    throw MCPOAuthCoordinatorError.cannotPersist("Keychain write returned false.")
                }
                self.stored[id] = bundle
            }
        ))
    }

    override func tearDown() async throws {
        MCPOAuthCoordinator.setRefreshDependenciesForTesting(nil)
        try await super.tearDown()
    }

    private func bundle(refreshToken: String?, resource: URL? = nil) -> MCPOAuthCredentialBundle {
        MCPOAuthCredentialBundle(
            issuer: URL(string: "https://as.example.com")!,
            clientId: "client-1",
            grantedScopes: ["mcp"],
            redirectURI: URL(string: "http://127.0.0.1:1/cb")!,
            accessToken: "AT0",
            refreshToken: refreshToken,
            accessTokenExpiresAt: Date().addingTimeInterval(-60),
            registrationAccessToken: nil,
            registrationClientUri: nil,
            resource: resource
        )
    }

    private func metadata() throws -> MCPOAuthMetadata {
        let json = """
        {"issuer":"https://as.example.com",
         "authorization_endpoint":"https://as.example.com/authorize",
         "token_endpoint":"https://as.example.com/token"}
        """
        return try JSONDecoder().decode(MCPOAuthMetadata.self, from: Data(json.utf8))
    }

    // MARK: - KC-3: single flight

    /// ⚠️ THE KC-3 REGRESSION. Two callers, one exchange. The second must JOIN the first, not
    /// present the same refresh token a second time.
    func testConcurrentRefreshesForOneSourceShareASingleExchange() async throws {
        let id = UUID()
        stored[id] = bundle(refreshToken: "RT1")
        gateExchange = true

        let first = Task { try await MCPOAuthCoordinator.refresh(sourceID: id) }
        for _ in 0..<10_000 where heldExchanges.isEmpty { await Task.yield() }
        XCTAssertFalse(heldExchanges.isEmpty, "the first refresh never reached the token exchange")

        let second = Task { try await MCPOAuthCoordinator.refresh(sourceID: id) }
        for _ in 0..<50 { await Task.yield() }   // let `second` reach the in-flight check

        for waiter in heldExchanges { waiter.resume() }
        heldExchanges = []
        let a = try await first.value
        let b = try await second.value

        XCTAssertEqual(exchangeCount, 1, """
            the second caller presented the same refresh token again — that replay is what makes \
            providers with reuse detection revoke the entire grant
            """)
        XCTAssertEqual(a, b)
        XCTAssertEqual(persistCount, 1)
        XCTAssertEqual(stored[id]?.refreshToken, "RT2")
    }

    func testAfterARefreshCompletesTheNextOneRunsANewExchange() async throws {
        let id = UUID()
        stored[id] = bundle(refreshToken: "RT1")

        _ = try await MCPOAuthCoordinator.refresh(sourceID: id)
        rotateTo = "RT3"
        _ = try await MCPOAuthCoordinator.refresh(sourceID: id)

        XCTAssertEqual(exchangeCount, 2)
        XCTAssertEqual(stored[id]?.refreshToken, "RT3")
    }

    func testAFailedRefreshDoesNotPinTheSourceToTheFailedTask() async throws {
        let id = UUID()
        stored[id] = bundle(refreshToken: "RT1")
        exchangeError = URLError(.notConnectedToInternet)

        do {
            _ = try await MCPOAuthCoordinator.refresh(sourceID: id)
            XCTFail("expected the exchange error")
        } catch {}

        exchangeError = nil
        _ = try await MCPOAuthCoordinator.refresh(sourceID: id)
        XCTAssertEqual(exchangeCount, 2)
        XCTAssertEqual(stored[id]?.refreshToken, "RT2")
    }

    func testDifferentSourcesDoNotShareAFlight() async throws {
        let a = UUID(), b = UUID()
        stored[a] = bundle(refreshToken: "RT1")
        stored[b] = bundle(refreshToken: "RT1")

        async let first = MCPOAuthCoordinator.refresh(sourceID: a)
        async let second = MCPOAuthCoordinator.refresh(sourceID: b)
        _ = try await (first, second)

        XCTAssertEqual(exchangeCount, 2)
    }

    // MARK: - KC-4: rotation-safe persist

    /// ⚠️ THE KC-4 REGRESSION. The provider rotated; the write failed twice; the error must say the
    /// grant is lost — not "refresh failed" — and nothing may be written.
    func testARotatedTokenThatCannotBePersistedIsReportedAsALostGrant() async {
        let id = UUID()
        stored[id] = bundle(refreshToken: "RT1")
        persistFailures = 2

        do {
            _ = try await MCPOAuthCoordinator.refresh(sourceID: id)
            XCTFail("expected a throw")
        } catch MCPOAuthCoordinatorError.rotatedRefreshTokenLost(let sourceID, _) {
            XCTAssertEqual(sourceID, id)
        } catch {
            XCTFail("wrong error: \(error)")
        }

        XCTAssertEqual(persistCount, 2, "the write is retried exactly once")
        XCTAssertEqual(stored[id]?.refreshToken, "RT1", "nothing was written; the stored bundle is the old one")
    }

    func testATransientPersistFailureIsRetriedOnceAndSucceeds() async throws {
        let id = UUID()
        stored[id] = bundle(refreshToken: "RT1")
        persistFailures = 1

        let refreshed = try await MCPOAuthCoordinator.refresh(sourceID: id)

        XCTAssertEqual(persistCount, 2)
        XCTAssertEqual(refreshed.refreshToken, "RT2")
        XCTAssertEqual(stored[id]?.refreshToken, "RT2")
        XCTAssertEqual(stored[id]?.accessToken, "AT1")
    }

    /// Without a rotation the grant is intact — the old refresh token is still valid — so the error
    /// must be the plain persist failure, or a caller would tell the user to sign in again for nothing.
    func testAPersistFailureWithoutRotationIsNotReportedAsALostGrant() async {
        let id = UUID()
        stored[id] = bundle(refreshToken: "RT1")
        rotateTo = nil
        persistFailures = 2

        do {
            _ = try await MCPOAuthCoordinator.refresh(sourceID: id)
            XCTFail("expected a throw")
        } catch MCPOAuthCoordinatorError.rotatedRefreshTokenLost {
            XCTFail("the refresh token was not rotated — the grant is intact and the error must not say otherwise")
        } catch MCPOAuthCoordinatorError.cannotPersist {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(stored[id]?.refreshToken, "RT1")
    }

    func testAnUnrotatedRefreshKeepsTheStoredRefreshToken() async throws {
        let id = UUID()
        stored[id] = bundle(refreshToken: "RT1")
        rotateTo = nil

        _ = try await MCPOAuthCoordinator.refresh(sourceID: id)

        XCTAssertEqual(stored[id]?.refreshToken, "RT1", "nil from the exchange means unchanged, not revoked")
        XCTAssertEqual(stored[id]?.accessToken, "AT1")
    }

    /// The RFC 8707 audience binding must survive — the mutate-not-rebuild rule the coordinator
    /// already records.
    func testTheAudienceBindingSurvivesARefresh() async throws {
        let id = UUID()
        let resource = URL(string: "https://mcp.example.com")!
        stored[id] = bundle(refreshToken: "RT1", resource: resource)

        _ = try await MCPOAuthCoordinator.refresh(sourceID: id)

        XCTAssertEqual(stored[id]?.resource, resource)
    }

    func testAMissingBundleThrowsBundleNotFound() async {
        do {
            _ = try await MCPOAuthCoordinator.refresh(sourceID: UUID())
            XCTFail("expected a throw")
        } catch MCPOAuthCoordinatorError.bundleNotFound {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(exchangeCount, 0)
    }

    // MARK: - Live wiring

    /// The live exchange closure must keep repeating the audience binding; the seam makes that a
    /// one-line closure nobody would otherwise test.
    func testTheLiveExchangeRepeatsTheAudienceBinding() throws {
        let source = try TestRepositorySource.read("Devgentic/Interfaces/Main/Views/Tooling/Mcp/OAuth/MCPOAuthCoordinator.swift")
        XCTAssertTrue(source.contains("bundle: bundle, metadata: metadata, resource: bundle.resource"))
    }
}
