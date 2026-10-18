// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPOAuthDiscoveryWellKnownTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class MCPOAuthDiscoveryWellKnownTests: XCTestCase {

    /// (issuer, expected metadata URL) pairs. The path-bearing rows are the KC-44 defect; the
    /// first two pin that a pathless issuer — and one with only a trailing slash — is unchanged.
    func testTheMetadataURLIsBuiltByInsertingBetweenHostAndPath() throws {
        let cases: [(issuer: String, expected: String)] = [
            ("https://as.example.com",
             "https://as.example.com/.well-known/oauth-authorization-server"),
            ("https://as.example.com/",
             "https://as.example.com/.well-known/oauth-authorization-server"),
            ("https://as.example.com/realms/acme",
             "https://as.example.com/.well-known/oauth-authorization-server/realms/acme"),
            ("https://as.example.com/realms/acme/",
             "https://as.example.com/.well-known/oauth-authorization-server/realms/acme"),
            ("https://as.example.com/realms/acme/deep/path",
             "https://as.example.com/.well-known/oauth-authorization-server/realms/acme/deep/path"),
            ("http://127.0.0.1:8080/mcp",
             "http://127.0.0.1:8080/.well-known/oauth-authorization-server/mcp"),
        ]
        for (issuer, expected) in cases {
            let url = try XCTUnwrap(URL(string: issuer))
            XCTAssertEqual(
                MCPOAuthDiscovery.wellKnownURL(for: url)?.absoluteString, expected,
                "issuer \(issuer) must discover at \(expected)")
        }
    }

    /// States the defect in the negative: the appended shape no conforming server serves must
    /// never come back out of the builder.
    func testAnAppendedWellKnownSegmentIsNeverProduced() throws {
        let issuer = try XCTUnwrap(URL(string: "https://as.example.com/realms/acme"))
        let url = try XCTUnwrap(MCPOAuthDiscovery.wellKnownURL(for: issuer))
        XCTAssertFalse(url.absoluteString.contains("realms/acme/.well-known"),
                       "appending the well-known segment to the issuer's path 404s on every "
                       + "conforming server: \(url.absoluteString)")
    }

    /// ⚠️ THE WIRING. The builder must actually be what `probe` and `fetch` consult, the appended
    /// construction must be gone from the file, and the OIDC fallback must keep its append —
    /// removing THAT would break conforming OIDC providers, which is the opposite defect.
    func testProbeAndFetchBuildTheMetadataURLThroughTheRFC8414Builder() throws {
        let source = try TestRepositorySource.read(
            "Devgentic/Interfaces/Main/Views/Tooling/Mcp/OAuth/MCPOAuthDiscovery.swift")

        XCTAssertTrue(source.contains("wellKnownURL(for: issuer)"),
                      "probe/fetch must take the OAuth metadata URL from the RFC 8414 builder")
        XCTAssertFalse(
            source.contains("appendingPathComponent(\".well-known/oauth-authorization-server\")"),
            "the appended construction is the KC-44 defect and must not survive anywhere in the file")
        XCTAssertTrue(
            source.contains("appendingPathComponent(\".well-known/openid-configuration\")"),
            "the OIDC fallback must keep its append — that IS the OIDC Discovery construction")
    }
}
