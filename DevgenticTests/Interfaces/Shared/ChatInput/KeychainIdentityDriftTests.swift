// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  KeychainIdentityDriftTests.swift
//  devgenticTests
//
//  Registers KC-56 and KC-62 — the two edits that would silently change WHERE every stored
//  credential lives, with nothing going red.
//
//  ⚠️ KC-56 — the (service, account) pair IS the credential's address. Rename either and every item
//  written by an earlier build becomes unreachable: the user's keys still sit in their Keychain,
//  and the app presents every store as "never configured". ChatOps already shipped exactly this
//  (the 2faad1c bundle-id rename; `legacyKeychainServices` is the repair). So these tests pin the
//  LITERAL strings each store writes under, observed through its test seam — never the constant it
//  reads from, because the constant is exactly what a rename changes.
//
//  If you are changing one of these deliberately: the old address must be migrated in the same
//  commit (copy-then-delete, gated on a successful write — see `ProviderKeyStore` and ChatOps'
//  `legacyKeychainServices`), and only then is the pin below updated.
//
//  ⚠️ KC-62 — nothing this app stores may be iCloud-synchronizable, and no Keychain traffic may
//  bypass the one primitive where that is enforced. Adding `kSecAttrSynchronizable: true` reads
//  like a feature ("cross-device parity") and would push every API key, bot token and OAuth refresh
//  token to iCloud Keychain. This is pinned by SOURCE SCAN on purpose: a read-back of the attribute
//  on the legacy file keychain proves nothing (see the §7 note on KC-62 in the readiness doc).
//

import XCTest
@testable import devgentic

/// Records the address of every Keychain call and holds values in memory. Cannot fail.
private final class AddressRecordingKeychain: KeychainAccessing, @unchecked Sendable {
    struct Address: Hashable, CustomStringConvertible {
        let service: String
        let account: String
        var description: String { "(\(service), \(account))" }
    }

    private let lock = NSLock()
    private var values: [Address: String] = [:]
    private var _writes: [Address] = []

    var writes: [Address] { lock.withLock { _writes } }

    func save(value: String, service: String, account: String) -> OSStatus {
        let address = Address(service: service, account: account)
        lock.withLock {
            values[address] = value
            _writes.append(address)
        }
        return errSecSuccess
    }

    func read(service: String, account: String) -> KeychainReadOutcome {
        lock.withLock {
            values[Address(service: service, account: account)].map { .found($0) } ?? .notFound
        }
    }

    func delete(service: String, account: String) -> OSStatus {
        lock.withLock {
            values.removeValue(forKey: Address(service: service, account: account)) == nil
                ? errSecItemNotFound : errSecSuccess
        }
    }
}

// MARK: - KC-56: every store's Keychain address is pinned

@MainActor
final class KeychainServiceIdentityTests: XCTestCase {

    private var keychain: AddressRecordingKeychain!

    override func setUp() {
        super.setUp()
        keychain = AddressRecordingKeychain()
    }

    override func tearDown() {
        keychain = nil
        super.tearDown()
    }

    private func assertSingleWrite(
        service: String, account: String, _ store: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            keychain.writes.map(\.description), ["(\(service), \(account))"],
            "\(store) must write under exactly this Keychain address. A rename orphans every "
                + "credential stored by an earlier build — migrate the old address in the same "
                + "commit, then update this pin.",
            file: file, line: line
        )
    }

    func testProviderKeysLiveUnderComDevgenticProvider() {
        ProviderKeyStore.setStorageForTesting(keychain)
        defer { ProviderKeyStore.setStorageForTesting(nil) }
        let profileID = UUID()

        XCTAssertTrue(ProviderKeyStore.save("sk-test-pin", for: profileID))

        assertSingleWrite(service: "com.devgentic.provider", account: profileID.uuidString, "ProviderKeyStore")
    }

    func testTheWebSearchKeyLivesUnderComDevgenticWebsearch() {
        WebSearchKeyStore.setStorageForTesting(keychain)
        defer { WebSearchKeyStore.setStorageForTesting(nil) }

        XCTAssertTrue(WebSearchKeyStore.save("websearch-test-pin"))

        assertSingleWrite(service: "com.devgentic.websearch", account: "apiKey", "WebSearchKeyStore")
    }

    func testMCPSecretsLiveUnderComDevgenticMcpSecrets() {
        MCPSecretStore.setBackingForTesting(keychain)
        defer { MCPSecretStore.setBackingForTesting(nil) }
        let sourceID = UUID()

        XCTAssertTrue(MCPSecretStore.shared.store("bearer-test-pin", for: .bearerToken, sourceID: sourceID))

        assertSingleWrite(service: "com.devgentic.mcp.secrets",
                          account: "\(sourceID.uuidString)::auth.bearer", "MCPSecretStore")
    }

    /// Every scope's account suffix is part of the address too — the OAuth bundle (access +
    /// refresh token) and env values included.
    func testEveryMCPSecretScopeKeepsItsAccountSuffix() {
        XCTAssertEqual(MCPSecretScope.bearerToken.rawScope, "auth.bearer")
        XCTAssertEqual(MCPSecretScope.apiKeyHeaderValue.rawScope, "auth.headerValue")
        XCTAssertEqual(MCPSecretScope.envValue(key: "GITHUB_TOKEN").rawScope, "env.GITHUB_TOKEN")
        XCTAssertEqual(MCPSecretScope.oauthBundle.rawScope, "oauth.bundle")
    }

    func testTheHuggingFaceTokenLivesUnderComDevgenticHuggingface() {
        HuggingFaceTokenStore.setBackingForTesting(keychain)
        defer { HuggingFaceTokenStore.setBackingForTesting(nil) }

        XCTAssertTrue(HuggingFaceTokenStore.shared.store("hf_testpin0123456789"))

        assertSingleWrite(service: "com.devgentic.huggingface", account: "access-token", "HuggingFaceTokenStore")
    }

    /// ⚠️ ChatOps is the one store whose service DERIVES from the bundle identifier, so this pin
    /// also fails on a bundle-id rename (register KC-41). That is intended: the outgoing identifier
    /// must be added to `ChatOpsConfigManager.legacyKeychainServices` in the same commit, or every
    /// paired bot token is orphaned exactly as 2faad1c orphaned them.
    func testChatOpsTokensLiveUnderTheAppBundleIdentifier() {
        let config = ChatOpsConfigManager.shared
        ChatOpsConfigManager.setKeychainForTesting(keychain)
        defer {
            config.clearBotToken()
            config.clearDiscordBotToken()
            config.clearSlackBotToken()
            config.clearSlackAppToken()
            ChatOpsConfigManager.setKeychainForTesting(nil)
        }

        XCTAssertEqual(config.storeBotToken("tg-pin"), errSecSuccess)
        XCTAssertEqual(config.storeDiscordBotToken("dc-pin"), errSecSuccess)
        XCTAssertEqual(config.storeSlackBotToken("xoxb-pin"), errSecSuccess)
        XCTAssertEqual(config.storeSlackAppToken("xapp-pin"), errSecSuccess)

        XCTAssertEqual(
            keychain.writes.map(\.description),
            [
                "(app.devgentic.macos, chatOpsBotToken)",
                "(app.devgentic.macos, chatOpsDiscordBotToken)",
                "(app.devgentic.macos, chatOpsSlackBotToken)",
                "(app.devgentic.macos, chatOpsSlackAppToken)",
            ],
            "ChatOps credentials must stay at these addresses. A bundle-id rename needs the old id "
                + "in legacyKeychainServices (KC-41); an account rename needs its own migration."
        )
    }
}

// MARK: - KC-62: nothing is synchronizable, and nothing bypasses the primitive

final class KeychainAttributeDriftTests: XCTestCase {

    /// Attributes that would move a credential somewhere other than this Mac's login keychain.
    /// `kSecUseDataProtectionKeychain` / `kSecAttrAccessGroup` were considered and DECLINED under
    /// KC-7 (they need an application-identifier entitlement a Developer ID app does not carry);
    /// adopting either is a deliberate migration, not a drive-by edit.
    private static let forbiddenAttributes = [
        "kSecAttrSynchronizable",
        "kSecUseDataProtectionKeychain",
        "kSecAttrAccessGroup",
    ]

    private static let primitive = "Devgentic/Interfaces/Shared/ChatInput/SecureKeyStorage.swift"

    /// Every non-comment line of every production Swift file, as (relative path, line number, text).
    private func productionCodeLines() throws -> [(path: String, line: Int, text: String)] {
        let root = try TestRepositorySource.root()
        let sources = root.appendingPathComponent("Devgentic")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate \(sources.path)")
            return []
        }
        var lines: [(String, Int, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
                lines.append((relative, index + 1, line))
            }
        }
        return lines
    }

    func testNoProductionCodeMakesACredentialSynchronizableOrRelocatesIt() throws {
        let offenders = try productionCodeLines().filter { entry in
            Self.forbiddenAttributes.contains { entry.text.contains($0) }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "A Keychain attribute that syncs or relocates credentials appeared. kSecAttrSynchronizable "
                + "pushes every API key and bot token to iCloud Keychain. Offenders: "
                + offenders.map { "\($0.path):\($0.line)" }.joined(separator: ", ")
        )
    }

    /// The scan above only means something if every `SecItem*` call sits in the one primitive.
    func testEveryKeychainCallGoesThroughSecureKeyStorage() throws {
        let calls = try productionCodeLines().filter { entry in
            ["SecItemAdd(", "SecItemUpdate(", "SecItemCopyMatching(", "SecItemDelete("]
                .contains { entry.text.contains($0) }
        }
        let outside = calls.filter { $0.path != Self.primitive }
        XCTAssertFalse(calls.isEmpty, "the scan found no SecItem calls at all — it is no longer looking at the primitive")
        XCTAssertTrue(
            outside.isEmpty,
            "Keychain calls must go through SecureKeyStorage, where the attribute set is pinned and "
                + "the XCTest redirect applies. Offenders: "
                + outside.map { "\($0.path):\($0.line)" }.joined(separator: ", ")
        )
    }
}
