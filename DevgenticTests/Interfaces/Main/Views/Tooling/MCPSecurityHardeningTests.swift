//
//  MCPSecurityHardeningTests.swift
//  DevgenticTests
//
//  P2 security fixes, 2026-08-01. Covers the pure units that need no live server:
//  redaction (URL paths + free text), the icon-fetch SSRF allowlist, and the PKCE
//  advertisement check whose default was inverted.
//

import XCTest
@testable import devgentic

final class MCPSecurityHardeningTests: XCTestCase {

    // MARK: - #27 URL path redaction

    /// The shape hosted MCP providers actually use: the key sits in the PATH.
    func testRedactURL_PathEmbeddedKey_IsRedacted() {
        let redacted = MCPRedaction.redact(url: "https://mcp.example.com/v1/sk-live-abc123def456ghi789/sse")
        XCTAssertFalse(redacted.contains("sk-live-abc123def456ghi789"), "Path-embedded key must not survive: \(redacted)")
        XCTAssertTrue(redacted.contains("mcp.example.com"), "Host must stay readable for diagnostics")
    }

    func testRedactURL_HighEntropyPathSegment_IsRedacted() {
        let redacted = MCPRedaction.redact(url: "https://api.example.com/mcp/a1b2c3d4e5f6a7b8c9d0e1f2a3b4/messages")
        XCTAssertFalse(redacted.contains("a1b2c3d4e5f6a7b8c9d0e1f2a3b4"))
    }

    /// A URL redacted into uselessness defeats the point of logging it.
    func testRedactURL_OrdinaryPathSegments_StayReadable() {
        let redacted = MCPRedaction.redact(url: "https://mcp.example.com/v1/messages/sse")
        XCTAssertEqual(redacted, "https://mcp.example.com/v1/messages/sse")
    }

    func testRedactURL_StillStripsUserinfoAndQuerySecrets() {
        let redacted = MCPRedaction.redact(url: "https://user:pass@example.com/path?api_key=secret123&page=2")
        XCTAssertFalse(redacted.contains("pass"))
        XCTAssertFalse(redacted.contains("secret123"))
        XCTAssertTrue(redacted.contains("page=2"), "Non-secret params must survive")
    }

    // MARK: - #26 free-text redaction

    /// `redact(url:)` was used for this and silently returned prose unchanged,
    /// because `URLComponents(string:)` fails to parse a line of stderr.
    func testRedactText_EnvAssignment_IsRedacted() {
        let redacted = MCPRedaction.redact(text: "Starting with GITHUB_TOKEN=ghp_abcdefghijklmnop1234 and DEBUG=1")
        XCTAssertFalse(redacted.contains("ghp_abcdefghijklmnop1234"), "Got: \(redacted)")
        XCTAssertTrue(redacted.contains("GITHUB_TOKEN"), "The NAME stays — it is the diagnostic value")
        XCTAssertTrue(redacted.contains("DEBUG=1"), "Non-secret assignments must survive")
    }

    func testRedactText_AuthorizationHeader_IsRedacted() {
        let redacted = MCPRedaction.redact(text: "sending Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig")
        XCTAssertFalse(redacted.contains("eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertTrue(redacted.lowercased().contains("authorization"))
    }

    func testRedactText_BareTokenLiteral_IsRedacted() {
        let redacted = MCPRedaction.redact(text: "error: invalid credential sk-proj-AbCdEf0123456789xyz")
        XCTAssertFalse(redacted.contains("sk-proj-AbCdEf0123456789xyz"), "Got: \(redacted)")
    }

    func testRedactText_JSONEmbeddedSecret_IsRedacted() {
        let redacted = MCPRedaction.redact(text: "config: {\"apiKey\": \"verysecretvalue123\", \"port\": 8080}")
        XCTAssertFalse(redacted.contains("verysecretvalue123"), "Got: \(redacted)")
        XCTAssertTrue(redacted.contains("8080"), "Non-secret fields must survive")
    }

    func testRedactText_OrdinaryStderr_IsUnchanged() {
        let message = "Server listening on stdio. Ready to accept requests."
        XCTAssertEqual(MCPRedaction.redact(text: message), message)
    }

    // MARK: - #25 icon-fetch SSRF allowlist

    func testIconURL_HTTPSPublicHost_IsAllowed() {
        XCTAssertTrue(MCPIconLoader.isPermittedIconURL(URL(string: "https://cdn.example.com/icon.png")!))
    }

    func testIconURL_PlainHTTPRemote_IsRefused() {
        XCTAssertFalse(MCPIconLoader.isPermittedIconURL(URL(string: "http://cdn.example.com/icon.png")!))
    }

    func testIconURL_FileScheme_IsRefused() {
        XCTAssertFalse(MCPIconLoader.isPermittedIconURL(URL(string: "file:///etc/passwd")!))
    }

    /// Cloud instance-metadata is the classic SSRF target.
    func testIconURL_LinkLocalMetadata_IsRefused() {
        XCTAssertFalse(MCPIconLoader.isPermittedIconURL(URL(string: "http://169.254.169.254/latest/meta-data/")!))
        XCTAssertFalse(MCPIconLoader.isPermittedIconURL(URL(string: "https://169.254.169.254/latest/meta-data/")!))
    }

    func testIconURL_PrivateRanges_AreRefused() {
        for host in ["10.0.0.1", "192.168.1.1", "172.16.0.1", "172.31.255.255", "127.0.0.1"] {
            XCTAssertFalse(
                MCPIconLoader.isPermittedIconURL(URL(string: "https://\(host)/icon.png")!),
                "\(host) must be refused over https"
            )
        }
    }

    /// 172.15 and 172.32 are OUTSIDE 172.16.0.0/12 — an off-by-one here would
    /// block legitimate public addresses.
    func testIconURL_AddressesAdjacentToPrivateRange_AreAllowed() {
        XCTAssertTrue(MCPIconLoader.isPermittedIconURL(URL(string: "https://172.15.0.1/icon.png")!))
        XCTAssertTrue(MCPIconLoader.isPermittedIconURL(URL(string: "https://172.32.0.1/icon.png")!))
    }

    /// Loopback is refused for ICONS specifically — unlike the OAuth redirect, where
    /// RFC 8252 requires it. An icon is decoration, so refusing costs only a fallback
    /// glyph, while allowing it would let a remote server probe the user's own machine.
    func testIconURL_Loopback_IsRefused() {
        XCTAssertFalse(MCPIconLoader.isPermittedIconURL(URL(string: "http://localhost:3000/icon.png")!))
        XCTAssertFalse(MCPIconLoader.isPermittedIconURL(URL(string: "https://localhost:3000/icon.png")!))
    }

    // MARK: - #29 PKCE advertisement

    private func metadata(codeChallengeMethods: [String]?) throws -> MCPOAuthMetadata {
        let methods = codeChallengeMethods.map { list in
            ",\"code_challenge_methods_supported\":[\(list.map { "\"\($0)\"" }.joined(separator: ","))]"
        } ?? ""
        let json = """
        {"issuer":"https://as.example.com",
         "authorization_endpoint":"https://as.example.com/authorize",
         "token_endpoint":"https://as.example.com/token"\(methods)}
        """
        return try JSONDecoder().decode(MCPOAuthMetadata.self, from: Data(json.utf8))
    }

    func testPKCE_S256Advertised_IsSupported() throws {
        XCTAssertTrue(try metadata(codeChallengeMethods: ["S256"]).supportsDesktopPKCEFlow)
    }

    /// RFC 8414: omitting the field means the server does NOT support PKCE.
    /// This previously defaulted to `true`, accepting a non-PKCE server as PKCE-capable.
    func testPKCE_FieldOmitted_IsRefused() throws {
        XCTAssertFalse(
            try metadata(codeChallengeMethods: nil).supportsDesktopPKCEFlow,
            "Omitted code_challenge_methods_supported means NO PKCE per RFC 8414"
        )
    }

    func testPKCE_OnlyPlainAdvertised_IsRefused() throws {
        XCTAssertFalse(try metadata(codeChallengeMethods: ["plain"]).supportsDesktopPKCEFlow)
    }
}
