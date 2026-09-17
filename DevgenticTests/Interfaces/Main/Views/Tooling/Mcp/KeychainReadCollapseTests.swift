// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  KeychainReadCollapseTests.swift
//  devgenticTests
//
//  Registers KC-8 and KC-10 — the read-collapse defect in the two stores that never adopted
//  `SecureKeyStorage.read`.
//
//  ⚠️⚠️ WHAT BOTH ROWS SHARE. `retrieve` maps "no secret stored" and "the read FAILED" to the same
//  nil. `HuggingFaceTokenStore` then MEMOIZED that nil for the life of the process, and
//  `ChatOpsConfigManager` fed it to the pairing restore, which reported an outage as "you have never
//  paired" — offering to re-pair over four credentials that were intact the whole time.
//
//  ⚠️ Every test here drives `.failed`, never `.notFound`. A dev machine only ever produces
//  `errSecItemNotFound`, which is exactly why both defects survived. A stub that cannot fail a read
//  would make this whole file vacuous.
//

import XCTest
@testable import devgentic

// MARK: - KC-8

@MainActor
final class HuggingFaceTokenReadTests: XCTestCase {

    private var keychain: ProgrammableKeychain!

    override func setUp() {
        super.setUp()
        keychain = ProgrammableKeychain()
        HuggingFaceTokenStore.setBackingForTesting(keychain)
    }

    override func tearDown() {
        HuggingFaceTokenStore.setBackingForTesting(nil)
        keychain = nil
        super.tearDown()
    }

    private var store: HuggingFaceTokenStore { .shared }

    /// ⚠️⚠️ THE DEFECT, AND THE TEST THAT NEARLY MISSED IT. A failed read must not be memoized: the
    /// getter's `if let cached` short-circuits every later read, so caching `.some(nil)` here made a
    /// momentary Keychain lock look like "no token" until the app was quit.
    ///
    /// ⚠️ An earlier draft of this test exercised the `KeychainAccessing` stub directly instead of
    /// this store, and re-introducing the cache poisoning left it GREEN. It has to drive
    /// `HuggingFaceTokenStore.token` or it proves nothing.
    func testAFailedReadIsNotMemoizedAndTheNextAccessRecovers() {
        keychain.store["access-token"] = "hf_live"
        keychain.readStatusOverride = errSecAuthFailed
        store.refreshFromKeychain()

        XCTAssertNil(store.token, "a failed read yields no value to send")
        XCTAssertTrue(store.readFailed, "but the store must know it FAILED rather than found nothing")
        XCTAssertFalse(store.hasToken)

        // The Keychain becomes readable — without quitting the app.
        keychain.readStatusOverride = nil
        XCTAssertEqual(store.token, "hf_live",
                       "the very next access must re-read; caching the failure is what made this unrecoverable")
    }

    /// A genuine absence IS cached — otherwise every download hits the Keychain for nothing.
    func testAGenuineAbsenceIsCached() {
        store.refreshFromKeychain()
        XCTAssertNil(store.token)
        XCTAssertFalse(store.readFailed, "absence is not failure")

        let readsBefore = keychain.readCount
        _ = store.token
        XCTAssertEqual(keychain.readCount, readsBefore, "a known-absent token must not re-hit the Keychain")
    }

    func testAFoundTokenIsCachedAndReported() {
        keychain.store["access-token"] = "hf_live"
        store.refreshFromKeychain()

        XCTAssertEqual(store.token, "hf_live")
        XCTAssertTrue(store.hasToken)
        XCTAssertFalse(store.readFailed)
    }

    // MARK: - KC-20: clear() must not claim success it did not have

    /// ⚠️ `hasToken` used to be set to false on the line BEFORE the status check, so a failed
    /// delete still painted the card as "no token" — the user was told a token they meant to revoke
    /// was gone while it was still stored and still being sent.
    func testAFailedDeleteDoesNotReportTheTokenAsRemoved() {
        keychain.store["access-token"] = "hf_live"
        store.refreshFromKeychain()
        keychain.deleteStatusOverride = errSecAuthFailed

        XCTAssertFalse(store.clear(), "a failed delete must report failure")
        XCTAssertTrue(store.hasToken,
                      "the token is still in the Keychain and still sent — the card must not say otherwise")
        XCTAssertEqual(keychain.store["access-token"], "hf_live")
    }

    func testASuccessfulClearRemovesTheTokenAndTheState() {
        keychain.store["access-token"] = "hf_live"
        store.refreshFromKeychain()

        XCTAssertTrue(store.clear())
        XCTAssertFalse(store.hasToken)
        XCTAssertFalse(store.readFailed)
        XCTAssertNil(keychain.store["access-token"])
    }
}

// MARK: - KC-10

final class ChatOpsCredentialStateTests: XCTestCase {

    // MARK: The restore verdict

    /// ⚠️ THE DEFECT. An unreadable Keychain must NOT render as `.disconnected`, which is the state
    /// the Settings pane shows as "never paired" with a Start Pairing button.
    func testAnUnreadableCredentialDoesNotRestoreAsDisconnected() {
        let state = ChatOpsPairingRestore.state(
            credentials: .unreadable(errSecAuthFailed),
            addressPresent: true, authorizedUserID: "u1", chatID: 42)

        XCTAssertNotEqual(state, .disconnected,
                          "reporting an outage as 'never paired' is what invited the user to overwrite a good credential")
        guard case .error(let message) = state else { return XCTFail("expected .error, got \(state)") }
        XCTAssertEqual(message, ChatOpsPairingRestore.unreadableMessage)
    }

    /// ⚠️ And it must NOT offer re-pairing. `needsRepairing` drives the Settings button, and
    /// re-pairing here would replace an intact credential to fix a problem it cannot fix.
    func testAnUnreadableCredentialDoesNotOfferRePairing() {
        let state = ChatOpsPairingRestore.state(
            credentials: .unreadable(errSecAuthFailed),
            addressPresent: true, authorizedUserID: "u1", chatID: 42)
        XCTAssertFalse(state.needsRepairing,
                       "the fix is to make the Keychain readable, not to re-pair")
    }

    /// Unreadable is decided BEFORE the address check — otherwise a paired-but-unreadable provider
    /// whose address also failed to load would fall through to `.disconnected`.
    func testUnreadableWinsEvenWithNoAddress() {
        XCTAssertNotEqual(
            ChatOpsPairingRestore.state(credentials: .unreadable(errSecIO),
                                        addressPresent: false, authorizedUserID: nil, chatID: 0),
            .disconnected)
    }

    /// A genuinely absent credential is still "never paired" — the fix must not turn every
    /// first-run into an error banner.
    func testAnAbsentCredentialStillRestoresAsDisconnected() {
        XCTAssertEqual(
            ChatOpsPairingRestore.state(credentials: .absent, addressPresent: true,
                                        authorizedUserID: "u1", chatID: 42),
            .disconnected)
    }

    /// The common path must not regress.
    func testACompletePairingStillRestoresAsConnected() {
        XCTAssertEqual(
            ChatOpsPairingRestore.state(credentials: .present, addressPresent: true,
                                        authorizedUserID: "u1", chatID: 42),
            .connected(chatID: 42))
    }

    /// The pre-invariant-38 upgrade case still reports as needing re-pairing, and is NOT shadowed
    /// by the new unreadable branch.
    func testTheUpgradeCaseIsUnaffected() {
        let state = ChatOpsPairingRestore.state(
            credentials: .present, addressPresent: true, authorizedUserID: nil, chatID: 42)
        XCTAssertTrue(state.needsRepairing)
    }

    /// ⚠️ The two error messages must stay distinct literals, or `needsRepairing` starts matching
    /// the outage and offers the button that overwrites a good credential.
    func testTheTwoErrorMessagesAreNotInterchangeable() {
        XCTAssertNotEqual(ChatOpsPairingRestore.unreadableMessage,
                          ChatOpsPairingRestore.needsRepairingMessage)
        XCTAssertFalse(ChatOpsConnectionState.error(ChatOpsPairingRestore.unreadableMessage).needsRepairing)
        XCTAssertTrue(ChatOpsConnectionState.error(ChatOpsPairingRestore.needsRepairingMessage).needsRepairing)
    }

    // MARK: THE WIRING — registers KC-10

    /// ⚠️⚠️ THE TEST THAT MATTERS. Mutation-checking showed that the policy tests above ALL stay
    /// green when the restore path goes back to `botToken != nil ? .present : .absent` — they cover
    /// `ChatOpsPairingRestore.state` and not the thing that decides what the user actually sees.
    /// This drives `restoreStates`, which is what `init` calls, against a failing Keychain.
    func testAnUnreadableKeychainMakesEveryProviderReportUnreadableNotUnpaired() {
        let keychain = ProgrammableKeychain()
        keychain.store[AppSettings.chatOpsBotTokenKey] = "tg"
        keychain.store[AppSettings.chatOpsDiscordBotTokenKey] = "dc"
        keychain.store[AppSettings.chatOpsSlackBotTokenKey] = "xoxb"
        keychain.store[AppSettings.chatOpsSlackAppTokenKey] = "xapp"
        keychain.readStatusOverride = errSecAuthFailed

        let states = ChatOpsConfigManager.restoreStates(
            keychain: keychain,
            telegram: (true, "u1", 42),
            discord: (true, "u2", 7),
            slack: (true, "u3"))

        for (name, state) in [("telegram", states.telegram), ("discord", states.discord), ("slack", states.slack)] {
            XCTAssertNotEqual(state, .disconnected,
                              "\(name): an unreadable Keychain must not render as 'never paired'")
            XCTAssertFalse(state.needsRepairing,
                           "\(name): must not offer to re-pair over an intact credential")
            guard case .error(let message) = state else {
                return XCTFail("\(name): expected .error, got \(state)")
            }
            XCTAssertEqual(message, ChatOpsPairingRestore.unreadableMessage, name)
        }
    }

    /// The readable, fully-paired path must still restore as connected through the same function.
    func testAReadableKeychainStillRestoresEveryProviderAsConnected() {
        let keychain = ProgrammableKeychain()
        keychain.store[AppSettings.chatOpsBotTokenKey] = "tg"
        keychain.store[AppSettings.chatOpsDiscordBotTokenKey] = "dc"
        keychain.store[AppSettings.chatOpsSlackBotTokenKey] = "xoxb"
        keychain.store[AppSettings.chatOpsSlackAppTokenKey] = "xapp"

        let states = ChatOpsConfigManager.restoreStates(
            keychain: keychain,
            telegram: (true, "u1", 42),
            discord: (true, "u2", 7),
            slack: (true, "u3"))

        XCTAssertEqual(states.telegram, .connected(chatID: 42))
        XCTAssertEqual(states.discord, .connected(chatID: 7))
        XCTAssertEqual(states.slack, .connected(chatID: 0))
    }

    /// A first-run install — nothing stored — must still read as "never paired", not as an outage.
    func testAnEmptyKeychainStillRestoresAsDisconnected() {
        let states = ChatOpsConfigManager.restoreStates(
            keychain: ProgrammableKeychain(),
            telegram: (false, nil, 0), discord: (false, nil, 0), slack: (false, nil))

        XCTAssertEqual(states.telegram, .disconnected)
        XCTAssertEqual(states.discord, .disconnected)
        XCTAssertEqual(states.slack, .disconnected)
    }

    /// ⚠️ Slack specifically: one token readable, the other not. If `absent` won, Slack would report
    /// "never paired" for exactly the case this register is about.
    func testSlackWithOneUnreadableTokenIsAnOutageNotAHalfPairing() {
        final class PartialKeychain: KeychainAccessing, @unchecked Sendable {
            func save(value: String, service: String, account: String) -> OSStatus { errSecSuccess }
            func read(service: String, account: String) -> KeychainReadOutcome {
                account == AppSettings.chatOpsSlackAppTokenKey ? .failed(errSecAuthFailed) : .found("xoxb")
            }
            func delete(service: String, account: String) -> OSStatus { errSecSuccess }
        }

        let states = ChatOpsConfigManager.restoreStates(
            keychain: PartialKeychain(),
            telegram: (false, nil, 0), discord: (false, nil, 0), slack: (true, "u3"))

        XCTAssertNotEqual(states.slack, .disconnected)
        guard case .error(let message) = states.slack else { return XCTFail("expected .error") }
        XCTAssertEqual(message, ChatOpsPairingRestore.unreadableMessage)
    }

    // MARK: Slack's two-token fold

    /// ⚠️ Slack needs BOTH tokens. "One present, one unreadable" is an outage, not a half pairing —
    /// if `absent` won, Slack would report "never paired" for exactly the case KC-10 is about.
    func testUnreadableDominatesAbsentWhenCombining() {
        XCTAssertEqual(
            ChatOpsCredentialState.combining([.present, .unreadable(errSecAuthFailed)]),
            .unreadable(errSecAuthFailed))
        XCTAssertEqual(
            ChatOpsCredentialState.combining([.absent, .unreadable(errSecAuthFailed)]),
            .unreadable(errSecAuthFailed))
    }

    func testCombiningRequiresEveryCredentialPresent() {
        XCTAssertEqual(ChatOpsCredentialState.combining([.present, .present]), .present)
        XCTAssertEqual(ChatOpsCredentialState.combining([.present, .absent]), .absent)
        XCTAssertEqual(ChatOpsCredentialState.combining([.absent, .absent]), .absent)
    }
}
