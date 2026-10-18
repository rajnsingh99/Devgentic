// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NotificationChannelRegistryTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import UserNotifications
@testable import devgentic

final class NotificationChannelRegistryTests: XCTestCase {

    // MARK: - Fake

    /// A registerable channel that reaches nothing. `isEnabled` is a plain stored property here on
    /// purpose — the real channels' persistence is tested separately, below.
    private final class FakeChannel: NotificationChannel {
        let channelID: String
        let displayName: String
        var isEnabled: Bool
        let requiresConfiguration: Bool
        private(set) var sent: [AppNotificationPayload] = []
        var sentCount: Int { sent.count }

        init(channelID: String, displayName: String, isEnabled: Bool = true, requiresConfiguration: Bool = false) {
            self.channelID = channelID
            self.displayName = displayName
            self.isEnabled = isEnabled
            self.requiresConfiguration = requiresConfiguration
        }

        func send(_ payload: AppNotificationPayload) async throws { sent.append(payload) }
    }

    /// Accepts nothing. Proves `dispatch` counts deliveries, not attempts.
    private final class ThrowingChannel: NotificationChannel {
        let channelID: String
        let displayName: String
        var isEnabled: Bool = true
        let requiresConfiguration = false
        private(set) var wasAsked = false

        init(channelID: String, displayName: String) {
            self.channelID = channelID
            self.displayName = displayName
        }

        struct Refused: Error {}
        func send(_ payload: AppNotificationPayload) async throws {
            wasAsked = true
            throw Refused()
        }
    }

    /// ⚠️ `NotificationDispatcher.shared` is the only instance there is (`private init`), so these
    /// tests register into the REAL registry and must remove what they add. Nothing registers it in
    /// a unit-test process — `DevgenticApp` and `ChatOpsCoordinator` never run — so the ids below
    /// start unclaimed.
    private var registered: [String] = []

    private func register(_ channel: FakeChannel) async {
        await NotificationDispatcher.shared.register(channel)
        registered.append(channel.channelID)
    }

    override func tearDown() async throws {
        for id in registered {
            await NotificationDispatcher.shared.unregister(channelID: id)
        }
        registered = []
        try await super.tearDown()
    }

    // MARK: - Snapshots

    /// Mutation that must turn this red: return `Array(channels.values)` mapped without the sort.
    ///
    /// ⚠️ THE ORDER IS THE ASSERTION. `channels` is a dictionary, so an unsorted projection renders
    /// the settings rows in a different order on every launch — the kind of defect that reads as a
    /// rendering glitch and never gets traced back to the registry.
    func testSnapshotsComeBackInAStableOrderWithLocalDeliveryFirst() async throws {
        await register(FakeChannel(channelID: "zzz_test", displayName: "Zebra"))
        await register(FakeChannel(channelID: "aaa_test", displayName: "Alpha"))

        // ⚠️ DO NOT REGISTER OVER `local_notification` UNCONDITIONALLY. `register` overwrites by
        // key, and `tearDown` unregisters by key — so an earlier draft of this test EVICTED the
        // app's real local channel and then deleted it, leaving every later test in the process
        // running against a registry with no local delivery. A test that quietly breaks its
        // neighbours is worse than the defect it covers.
        let alreadyRegistered = await NotificationDispatcher.shared.channelSnapshots()
        if !alreadyRegistered.contains(where: { $0.id == "local_notification" }) {
            await register(FakeChannel(channelID: "local_notification", displayName: "Local Notification"))
        }

        // ⚠️ THE RULE IS ASSERTED, NOT ONE ARRANGEMENT. An earlier draft pinned the exact array
        // and failed — the real ChatOps channel is already registered by the time this runs,
        // because the dispatcher is a process-wide singleton that other test classes register into
        // and never clear. Pinning the literal list made this test a hostage to test ORDER.
        let names = await NotificationDispatcher.shared.channelSnapshots().map(\.displayName)

        let localFirst = await NotificationDispatcher.shared.channelSnapshots().first?.id
        XCTAssertEqual(localFirst, "local_notification", """
            Local delivery sorts first because every install has it. \
            A dictionary's own order is not an order.
            """)
        let rest = Array(names.dropFirst())
        XCTAssertEqual(rest, rest.sorted(), "everything after local delivery sorts by name: \(rest)")
        XCTAssertLessThan(try XCTUnwrap(rest.firstIndex(of: "Alpha")),
                          try XCTUnwrap(rest.firstIndex(of: "Zebra")),
                          "registration order must not survive into the rendered order")
    }

    /// Mutation that must turn this red: change `channelSnapshots()` to hand back the channel
    /// objects, or drop a field from the projection.
    func testASnapshotCarriesEveryFieldTheSettingsPaneRenders() async {
        await register(FakeChannel(channelID: "cfg_test", displayName: "Needs Setup",
                                   isEnabled: false, requiresConfiguration: true))

        let info = await NotificationDispatcher.shared.channelSnapshots().first { $0.id == "cfg_test" }
        XCTAssertEqual(info?.displayName, "Needs Setup")
        XCTAssertEqual(info?.isEnabled, false)
        XCTAssertEqual(info?.requiresConfiguration, true)
    }

    // MARK: - setEnabled

    /// Mutation that must turn this red: go back to `channels[channelID]?.isEnabled = enabled`
    /// followed by an unconditional success log.
    ///
    /// ⚠️ THE `false` RETURN IS THE POINT. The optional chain quietly did nothing for an
    /// unregistered id and then logged "enabled: true" — and registration is asynchronous from two
    /// detached `Task`s, so a toggle flipped early really can land before its channel exists. A
    /// dropped setting that logs success is unfindable from logs.
    func testEnablingAnUnregisteredChannelReportsFailureRatherThanLoggingSuccess() async {
        let applied = await NotificationDispatcher.shared.setEnabled(true, for: "no_such_channel")
        XCTAssertFalse(applied, "an id that is not registered must report that the change was dropped")
    }

    func testEnablingARegisteredChannelAppliesAndReportsSuccess() async {
        let channel = FakeChannel(channelID: "flip_test", displayName: "Flippable", isEnabled: false)
        await register(channel)

        let applied = await NotificationDispatcher.shared.setEnabled(true, for: "flip_test")
        XCTAssertTrue(applied)

        let info = await NotificationDispatcher.shared.channelSnapshots().first { $0.id == "flip_test" }
        XCTAssertEqual(info?.isEnabled, true, "the snapshot must reflect the write, not a stale copy")
    }

    // MARK: - Persistence

    /// ⚠️ THIS IS THE DEFECT THAT HAD TO BE FIXED BEFORE THE PANE COULD GET A TOGGLE AT ALL.
    /// `LocalNotificationChannel.isEnabled` was a plain stored `var` on an instance rebuilt at every
    /// launch (`DevgenticApp.swift`), so switching macOS notifications off lasted until the next
    /// start and the pane then rendered the switch back ON. A toggle that silently forgets the
    /// user's decision is worse than no toggle.
    ///
    /// Mutation that must turn this red: restore `var isEnabled: Bool = true`.
    ///
    /// ⚠️ Save/restore, not a fresh suite: the channel reads `UserDefaults.standard` directly, and
    /// a test that leaves this key set would change the developer's own notification setting.
    func testTheLocalChannelRemembersItsSwitchAcrossRelaunches() {
        let defaults = UserDefaults.standard
        let key = AppSettings.localNotificationsEnabledKey
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        XCTAssertTrue(LocalNotificationChannel().isEnabled, """
            With no stored value the channel must default to ON. `bool(forKey:)` alone returns false \
            for an absent key, which would silently turn macOS notifications off for every existing \
            install on upgrade.
            """)

        LocalNotificationChannel().isEnabled = false
        // A DIFFERENT instance — this is what the next launch constructs.
        XCTAssertFalse(LocalNotificationChannel().isEnabled,
                       "the user's choice must outlive the instance that recorded it")
    }

    // MARK: - Wiring

    /// Mutation that must turn this red: replace the `ForEach` over `channels` with hardcoded rows
    /// again, or delete the `channelSnapshots()` call.
    func testTheSettingsPaneReadsTheRegistryInsteadOfHardcodingChannels() throws {
        let source = try Self.readSource(
            "Devgentic/Interfaces/Main/Views/Sidebar/Settings/NotificationSettingsView.swift")
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(code.contains("NotificationDispatcher.shared.channelSnapshots()"),
                      "the pane must ask the registry what channels exist")
        XCTAssertTrue(code.contains("NotificationDispatcher.shared.setEnabled("),
                      "each row's toggle must write back through the dispatcher")
        XCTAssertFalse(code.contains("Coming soon"), """
            The pane advertised Slack, Discord and Telegram as unbuilt while the ChatOps channel \
            was registered and delivering to all three.
            """)
        XCTAssertTrue(code.contains("Text(verbatim: name)"), """
            A channel's `displayName` is a runtime string. Passing it where a `LocalizedStringKey` \
            is expected asks the bundle for a translation keyed by that text and renders the key \
            when there is none.
            """)
    }

    // MARK: - The master switch, enforced inside dispatch()

    /// ⚠️ THE TEST THE OLD ONE COULD NOT BE. Its predecessor enumerated dispatch call sites BY PATH
    /// and asserted each carried its own guard — which meant a fifth call site added anywhere else
    /// was simply not covered, and the test would stay green while the user's switch was bypassed.
    /// This test calls `dispatch()` directly with no guard of any kind in front of it. That is
    /// exactly the shape of a new, unguarded call site, so passing it IS the coverage claim.
    ///
    /// Mutation that must turn this red: delete the `NotificationGatePolicy.shouldDeliver` guard
    /// from `NotificationDispatcher.dispatch(_:)`.
    func testAnUnguardedCallSiteStillCannotBypassTheMasterSwitch() async {
        let channel = FakeChannel(channelID: "gate_test", displayName: "Gate Test")
        await register(channel)

        await withMasterSwitch(off: true) {
            let sent = await deliver(conversationID: nil, to: channel)
            XCTAssertEqual(sent, 0, """
                dispatch() must suppress delivery itself. Enforcing the switch only at call sites \
                means a caller bypasses the user's preference by simply not asking.
                """)
        }
        await withMasterSwitch(off: false) {
            let sent = await deliver(conversationID: nil, to: channel)
            XCTAssertEqual(sent, 1, "with the switch on, the same unguarded call must deliver")
        }
    }

    /// Mutation that must turn this red: make `isGloballyEnabled(in:)` a bare
    /// `defaults.bool(forKey:)`.
    ///
    /// ⚠️ `bool(forKey:)` returns false for an ABSENT key, and the shipped default is
    /// `@AppStorage(...) var isGloballyEnabled: Bool = true`. Getting this backwards would switch
    /// notifications off for every install that had never touched the setting — a silent,
    /// app-wide regression delivered by an upgrade.
    func testTheMasterSwitchDefaultsToOnWhenItWasNeverSet() async {
        let channel = FakeChannel(channelID: "default_test", displayName: "Default Test")
        await register(channel)

        let defaults = UserDefaults.standard
        let key = AppSettings.notificationsEnabledKey
        let original = defaults.object(forKey: key)
        defer { if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) } }

        defaults.removeObject(forKey: key)
        XCTAssertTrue(NotificationGatePolicy.isGloballyEnabled(in: defaults))
        let sent = await deliver(conversationID: nil, to: channel)
        XCTAssertEqual(sent, 1, "a fresh install has no stored value and must still receive notifications")
    }

    /// The per-conversation override, enforced from the actor.
    ///
    /// ⚠️ `setOverride` has NO callers today, so this path is unreachable from the UI — which is
    /// precisely why it needs a test. The moment a per-conversation mute ships, the dispatcher must
    /// already honour it; a gate that reads only the global switch would silently ignore it.
    ///
    /// Mutation that must turn this red: drop the override lookup from
    /// `NotificationGatePolicy.shouldDeliver(conversationID:defaults:)`.
    func testAPerConversationOptOutSuppressesOnlyThatConversation() async {
        let channel = FakeChannel(channelID: "override_test", displayName: "Override Test")
        await register(channel)

        let muted = UUID(), unmuted = UUID()
        let defaults = UserDefaults.standard
        let key = AppSettings.notificationPerConversationKey
        let original = defaults.object(forKey: key)
        defer { if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) } }

        defaults.set(NotificationGatePolicy.encodeOverrides([muted: false]), forKey: key)

        let mutedSends = await deliver(conversationID: muted, to: channel)
        XCTAssertEqual(mutedSends, 0, "a muted conversation must not deliver")
        let unmutedSends = await deliver(conversationID: unmuted, to: channel)
        XCTAssertEqual(unmutedSends, 1, "muting one conversation must not mute the others")

        // ⚠️ AND THE ORDERING, ON THE REAL PATH. `testTheMasterSwitchOutranksAnyPerConversationOverride`
        // pins this on the pure function, but a pure test cannot fail when `dispatch` reads the two
        // in the wrong order. An override saying "on" must not resurrect a notification the user
        // switched off globally.
        defaults.set(NotificationGatePolicy.encodeOverrides([unmuted: true]), forKey: key)
        await withMasterSwitch(off: true) {
            let sends = await deliver(conversationID: unmuted, to: channel)
            XCTAssertEqual(sends, 0, """
                A per-conversation override said ON while the master switch said OFF, and the \
                notification was delivered. The master switch must be checked FIRST.
                """)
        }
    }

    /// ⚠️ THE ANTI-DRIFT TEST, and the reason the decision lives in a shared pure function. The
    /// settings pane reads the gate through `NotificationConfiguration` (MainActor, in-memory
    /// state); `dispatch()` reads it through `NotificationGatePolicy` (actor, UserDefaults). If
    /// those two implementations were written separately, the switch would come to mean one thing
    /// to the UI and another to delivery, and the pane would confidently show the wrong state.
    ///
    /// Mutation that must turn this red: reinstate a hand-written rule inside
    /// `isNotificationEnabled(for:)` that differs at all — e.g. let an override outrank the master
    /// switch by checking it first.
    @MainActor
    func testTheSettingsPaneAndTheDispatcherCannotDisagree() {
        let defaults = UserDefaults.standard
        let config = NotificationConfiguration.shared
        let conversation = UUID()

        let globalKey = AppSettings.notificationsEnabledKey
        let overrideKey = AppSettings.notificationPerConversationKey
        let originalGlobal = defaults.object(forKey: globalKey)
        let originalOverrides = defaults.object(forKey: overrideKey)
        let originalInMemory = config.perConversationOverrides
        // ⚠️ RESTORED THROUGH THE WRAPPER, not just through UserDefaults. `isGloballyEnabled` is
        // `@ObservationIgnored @AppStorage` on a class, so it caches: writing the underlying key
        // does not update the in-memory wrapper, and the singleton would carry this test's last
        // loop value into every later test in the process.
        let originalWrapperValue = config.isGloballyEnabled
        defer {
            config.isGloballyEnabled = originalWrapperValue
            if let originalGlobal { defaults.set(originalGlobal, forKey: globalKey) } else { defaults.removeObject(forKey: globalKey) }
            config.perConversationOverrides = originalInMemory
            if let originalOverrides { defaults.set(originalOverrides, forKey: overrideKey) } else { defaults.removeObject(forKey: overrideKey) }
        }

        for globallyEnabled in [true, false] {
            for override in [nil, true, false] as [Bool?] {
                config.isGloballyEnabled = globallyEnabled
                config.setOverride(override, for: conversation)   // persists, so both readers see it

                let paneSays = config.isNotificationEnabled(for: conversation)
                let dispatcherSays = NotificationGatePolicy.shouldDeliver(
                    conversationID: conversation, defaults: defaults)

                XCTAssertEqual(paneSays, dispatcherSays, """
                    The settings pane and the dispatcher disagree for \
                    global=\(globallyEnabled) override=\(String(describing: override)). \
                    One of them is lying to the user.
                    """)
            }
        }
    }

    /// The decision itself, with no store involved.
    ///
    /// Mutation that must turn this red: move the `if let override` above the `guard
    /// globallyEnabled` — which would let a stale per-conversation "on" resurrect notifications the
    /// user had switched off globally.
    func testTheMasterSwitchOutranksAnyPerConversationOverride() {
        XCTAssertFalse(NotificationGatePolicy.shouldDeliver(globallyEnabled: false, override: true),
                       "OFF globally must beat an override that says on")
        XCTAssertFalse(NotificationGatePolicy.shouldDeliver(globallyEnabled: false, override: nil))
        XCTAssertFalse(NotificationGatePolicy.shouldDeliver(globallyEnabled: false, override: false))
        XCTAssertTrue(NotificationGatePolicy.shouldDeliver(globallyEnabled: true, override: nil),
                      "on unless told otherwise")
        XCTAssertTrue(NotificationGatePolicy.shouldDeliver(globallyEnabled: true, override: true))
        XCTAssertFalse(NotificationGatePolicy.shouldDeliver(globallyEnabled: true, override: false),
                       "an override may mute one conversation while the switch is on")
    }

    // MARK: - Delivery is reported, not assumed

    /// Mutation that must turn this red: make `dispatch` return `Void` again, or return
    /// `enabledChannels.count` instead of counting actual successes.
    ///
    /// ⚠️ THE COUNT IS OF CHANNELS THAT TOOK IT, not of channels that were asked. A channel that
    /// throws must not be counted, or the settings pane's "Test Sent!" comes back for a test that
    /// failed on every channel.
    func testDispatchReportsHowManyChannelsActuallyTookIt() async {
        // ⚠️ MEASURED AS A DELTA, not an absolute. The dispatcher is a process-wide singleton with
        // the app's real channels already in it, so an absolute count would depend on what else is
        // registered and on whether the local channel can reach the notification centre in a test
        // host. The delta is immune to both.
        let probe = AppNotificationPayload(title: "probe", body: "probe")
        let baseline = await NotificationDispatcher.shared.dispatch(probe)

        let willAccept = FakeChannel(channelID: "accept_test", displayName: "Accepts")
        let willThrow = ThrowingChannel(channelID: "throw_test", displayName: "Throws")
        await register(willAccept)
        await NotificationDispatcher.shared.register(willThrow)
        registered.append(willThrow.channelID)
        let switchedOff = FakeChannel(channelID: "off_test", displayName: "Switched Off", isEnabled: false)
        await register(switchedOff)

        let after = await NotificationDispatcher.shared.dispatch(probe)

        XCTAssertEqual(after, baseline + 1, """
            Two enabled channels were added and both were asked, but only one ACCEPTED. \
            dispatch must count deliveries, not attempts — otherwise the settings pane reports \
            "Test Sent!" for a test that failed on every channel.
            """)
        XCTAssertEqual(willAccept.sentCount, 1)
        XCTAssertTrue(willThrow.wasAsked, "the throwing channel must have been attempted")
        XCTAssertEqual(switchedOff.sentCount, 0, "a switched-off channel is never asked")
    }

    /// ⚠️ THE ONE NOTIFICATION PATH NO SETTING COULD STOP. `push_local_notification` is an agent
    /// tool that built its own `UNMutableNotificationContent` and called `center.add(request)`
    /// directly, so neither the master switch nor the per-channel switches reached it — an agent
    /// could notify a user who had switched notifications off. Gating `dispatch()` covers every
    /// caller OF `dispatch`; it cannot cover a caller that never goes near it.
    ///
    /// Mutation that must turn this red: restore the direct `center.add(request)` delivery.
    func testTheAgentToolCannotBypassTheUsersNotificationSettings() throws {
        let source = try Self.readSource(
            "Devgentic/Interfaces/Main/Views/Tooling/Local/SystemStateTools.swift")
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(code.contains("NotificationDispatcher.shared.dispatch("),
                      "push_local_notification must deliver through the dispatcher")
        XCTAssertFalse(code.contains("center.add(request)"), """
            Delivering straight to UNUserNotificationCenter puts this tool outside every switch \
            the Settings pane offers.
            """)
        XCTAssertFalse(code.contains("UNMutableNotificationContent()"),
                       "building notification content here means it is not going through a channel")
    }

    /// Mutation that must turn this red: set `testSent = true` unconditionally again.
    func testTheTestButtonOnlyClaimsSuccessWhenAChannelTookIt() throws {
        let source = try Self.readSource(
            "Devgentic/Interfaces/Main/Views/Sidebar/Settings/NotificationSettingsView.swift")
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(code.contains("let delivered = await NotificationDispatcher.shared.dispatch("),
                      "the button must read the delivery count")
        XCTAssertTrue(code.contains("if delivered > 0 {"), """
            "Test Sent!" must be conditional. With per-channel switches in this very pane, a user \
            can switch every channel off — an unconditional success message would be a lie the \
            pane itself made reachable.
            """)
    }

    /// ⚠️ `delivered == 0` HAS TWO CAUSES and this is the one screen whose purpose is telling the
    /// user which. `dispatch` returns `Int`, so it cannot distinguish "the master switch suppressed
    /// it" from "every channel is switched off" — the pane re-derives the first from the same pure
    /// policy. Before this, it asserted the second unconditionally, so a user who had switched
    /// notifications off was told to go and check the channel switches, which were fine.
    ///
    /// Mutation that must turn this red: collapse the two branches back into one message.
    func testAFailedTestNotificationNamesTheRealCause() throws {
        let source = try Self.readSource(
            "Devgentic/Interfaces/Main/Views/Sidebar/Settings/NotificationSettingsView.swift")
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(code.contains("NotificationGatePolicy.shouldDeliver(conversationID: nil)"), """
            The pane must re-derive WHY nothing was delivered, using the same policy the \
            dispatcher enforced.
            """)
        XCTAssertTrue(code.contains("} else if !masterSwitchAllowedIt {"),
                      "the two causes of a zero delivery count need two different messages")
        // ⚠️ NO CONTROL IN THIS PANE MAY BE DISABLED BY THE MASTER SWITCH. Reading the value is
        // fine — the Channels card shows a notice with it, and that renders correctly now that the
        // property is observable. Taking the control AWAY is what this forbids: it greyed out every
        // channel switch whenever notifications were off, so no combination of controls produced
        // ChatOps mirroring without desktop banners, and a channel could not be configured ahead of
        // switching notifications on. Delivery is enforced in `dispatch()`; this pane records
        // intent. (The original reason was different — the value was `@ObservationIgnored`
        // `@AppStorage` on a class and went stale. That is fixed at its source, and the reason
        // above is why the rule outlived it.)
        XCTAssertFalse(code.contains(".disabled(!config.isGloballyEnabled"), """
            A control in this pane is disabled by the master switch. Record intent and report \
            outcomes truthfully instead of removing the control.
            """)
    }

    // MARK: - Gate helpers

    /// Dispatches one payload and reports how many the channel actually received.
    private func deliver(conversationID: UUID?, to channel: FakeChannel) async -> Int {
        let before = channel.sentCount
        await NotificationDispatcher.shared.dispatch(
            AppNotificationPayload(title: "probe", body: "probe", conversationID: conversationID))
        return channel.sentCount - before
    }

    /// ⚠️ Save/restore, never a fresh suite: the gate reads `UserDefaults.standard`, and a test that
    /// left this key set would change the developer's own notification setting.
    private func withMasterSwitch(off: Bool, _ body: () async -> Void) async {
        let defaults = UserDefaults.standard
        let key = AppSettings.notificationsEnabledKey
        let original = defaults.object(forKey: key)
        // ⚠️ `defer`, NOT a trailing statement. This writes the developer's REAL notification
        // setting; an assertion failure, a thrown error or a killed run in the middle of `body`
        // would otherwise leave their notifications switched off with no sign of why.
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.set(!off, forKey: key)
        await body()
    }

    // MARK: - Helpers

    private static func readSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)   // …/DevgenticTests/Core/Notifications/<this>
            .deletingLastPathComponent()                 // …/Core/Notifications
            .deletingLastPathComponent()                 // …/Core
            .deletingLastPathComponent()                 // …/DevgenticTests
            .deletingLastPathComponent()                 // repo root
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(relativePath) not reachable from \(repoRoot.path) — running outside a checkout")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
