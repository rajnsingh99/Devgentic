// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsCommandServiceTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class ChatOpsCommandServiceTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeRunControl: RemoteRunControlling {
        var busy: Set<UUID> = []
        var clarifications: [UUID: UUID] = [:]
        func hasActiveRun(inConversation conversation: UUID) -> Bool { busy.contains(conversation) }
        func pendingClarificationID(inConversation conversation: UUID) -> UUID? { clarifications[conversation] }
        func pendingQuestionNoun(inConversation conversation: UUID) -> String? { nil }
        @discardableResult
        func cancelRun(inConversation conversation: UUID) async -> Bool { busy.remove(conversation) != nil }
    }

    private final class FakeConversations: ConversationReading {
        var rows: [ConversationRow] = []
        var throwsStoreUnavailable = false
        private(set) var requestedLimits: [Int] = []
        private(set) var requestedOffsets: [Int] = []

        func conversationRows(limit: Int, offset: Int) throws -> [ConversationRow] {
            requestedLimits.append(limit)
            requestedOffsets.append(offset)
            if throwsStoreUnavailable { throw ConversationReadError.storeUnavailable }
            // ⚠️ THE FAKE MUST ACTUALLY PAGE. It returned `rows.prefix(limit)` and ignored
            // `offset`, so every paging assertion written against it would have passed with the
            // offset thrown away in production too — a fake that cannot express the bug is the
            // instrument failing, not the feature working.
            return Array(rows.dropFirst(max(0, offset)).prefix(limit))
        }
        /// ⚠️ The fake reproduces the REAL predicate and the REAL bound, so a test can observe a
        /// truncated scan. A fake that always reported `scanWasTruncated: false` would make the
        /// disclosure untestable — and the disclosure is the point of the type.
        var searchScanLimit = 200
        private(set) var searchQueries: [String] = []

        func searchConversations(matching query: String, limit: Int) throws -> ConversationSearchResult {
            searchQueries.append(query)
            if throwsStoreUnavailable { throw ConversationReadError.storeUnavailable }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return ConversationSearchResult(rows: [], scanWasTruncated: false) }
            let scanned = Array(rows.prefix(searchScanLimit))
            // ⚠️ THE REAL PREDICATE, not a copy. This fake had its own
            // `localizedCaseInsensitiveContains` line, and a mutation making the production matcher
            // case-sensitive left every search test green — the fake was answering for it.
            let matches = scanned.filter { ConversationSearchPolicy.matches(title: $0.title, query: trimmed) }
            return ConversationSearchResult(
                rows: Array(matches.prefix(limit)),
                scanWasTruncated: scanned.count == searchScanLimit
            )
        }

        func reusableEmptyConversationID(preferring preferred: UUID?) throws -> UUID? {
            if throwsStoreUnavailable { throw ConversationReadError.storeUnavailable }
            return rows.first(where: \.isEmpty)?.id
        }
        var messages: [ConversationMessageRow] = []
        private(set) var requestedMessageLimits: [Int] = []

        func recentMessages(inConversation conversationID: UUID, limit: Int) throws -> [ConversationMessageRow] {
            requestedMessageLimits.append(limit)
            if throwsStoreUnavailable { throw ConversationReadError.storeUnavailable }
            // ⚠️ The fake keeps the REAL contract: it holds messages oldest-first and returns the
            // most recent `limit` still oldest-first, which is what the store's reverse produces.
            return Array(messages.suffix(limit))
        }

        func conversationRow(id: UUID) throws -> ConversationRow? {
            if throwsStoreUnavailable { throw ConversationReadError.storeUnavailable }
            return rows.first { $0.id == id }
        }
    }

    /// Shared ordering log. ⚠️ The point of C5b is that every state write lands BEFORE the view is
    /// returned, so the ORDER of effects is the property under test, not just their presence.
    private final class EffectLog {
        private(set) var effects: [String] = []
        func record(_ effect: String) { effects.append(effect) }
        /// ⚠️ Call after ARRANGING. `FakeSession` records on its setter, so a test that seeds
        /// `activeConversationID` logs a "cursor" effect that belongs to the setup, not the act —
        /// which would otherwise make an "effects are empty" assertion impossible to write.
        func reset() { effects.removeAll() }
    }

    private final class FakeCommanding: RemoteConversationCommanding {
        let log: EffectLog
        var defaultProfileID: UUID?
        var createdID = UUID()
        private(set) var createdTitles: [String] = []
        private(set) var focused: [UUID] = []
        private(set) var bindings: [(profile: UUID, conversation: UUID)] = []
        init(log: EffectLog) { self.log = log }

        func createConversation(profile: BackendProfileModel, title: String) -> UUID {
            createdTitles.append(title)
            log.record("create(\(title))")
            return createdID
        }
        func focusConversationInMainWindow(_ conversation: UUID) {
            focused.append(conversation)
            log.record("focus")
        }
        func bindProfile(_ profile: UUID, toConversation conversation: UUID) {
            bindings.append((profile, conversation))
            log.record("bind")
        }
        func submitRemote(prompt: String, conversationID: UUID, source: MessageSource, config: BackendRequestConfig) {
            log.record("submit")
        }
    }

    private final class FakeProfiles: ChatOpsProfileReading {
        var profiles: [BackendProfileModel] = []
        /// Reachable ONLY by id — stands for a profile outside the capped `sharedProfiles()` window.
        var byID: [UUID: BackendProfileModel] = [:]
        private(set) var sharedProfilesCallCount = 0

        func sharedProfiles() -> [BackendProfileModel] {
            sharedProfilesCallCount += 1
            return profiles
        }
        func profile(id: UUID) -> BackendProfileModel? { byID[id] ?? profiles.first { $0.id == id } }
    }

    private final class FakeSession: ChatOpsSessionContext {
        let log: EffectLog
        var securityTier: ChatOpsSecurityTier = .standard
        private var stored: UUID?
        var activeConversationID: UUID? {
            get { stored }
            set { stored = newValue; log.record("cursor") }
        }
        init(log: EffectLog) { self.log = log }
    }

    private var runControl: FakeRunControl!
    private var conversations: FakeConversations!
    private var session: FakeSession!
    private var commanding: FakeCommanding!
    private var profiles: FakeProfiles!
    private var log: EffectLog!
    private var recordedOrigins: [(RemoteConversationOrigin, UUID)]!
    private var service: ChatOpsCommandService!

    override func setUp() {
        super.setUp()
        runControl = FakeRunControl()
        conversations = FakeConversations()
        log = EffectLog()
        session = FakeSession(log: log)
        commanding = FakeCommanding(log: log)
        profiles = FakeProfiles()
        recordedOrigins = []
        let capture: (RemoteConversationOrigin, UUID) -> Void = { [weak self] origin, id in
            self?.recordedOrigins.append((origin, id))
            self?.log.record("origin")
        }
        service = ChatOpsCommandService(
            provider: .telegram,
            runControl: runControl,
            commanding: commanding,
            conversations: conversations,
            profiles: profiles,
            session: session,
            recordOrigin: capture
        )
    }

    private func row(_ title: String, id: UUID = UUID(), empty: Bool = false, boundProfileID: UUID? = nil) -> ConversationRow {
        ConversationRow(id: id, title: title, timestamp: Date(timeIntervalSince1970: 0), isEmpty: empty, boundProfileID: boundProfileID)
    }

    private func agentProfile(_ name: String) -> BackendProfileModel {
        var config = AgentConfig(llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude"))
        config.instructions = "be helpful"
        return BackendProfileSnapshot(displayName: name, details: .agent(config))
    }

    private func botProfile(_ name: String) -> BackendProfileModel {
        var config = BotConfig(llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude"))
        config.instructions = "be helpful"
        return BackendProfileSnapshot(displayName: name, details: .bot(config))
    }

    private func telegramText(_ view: RemoteView) throws -> String {
        try XCTUnwrap(TelegramRemoteRenderer.draft(for: view)).text
    }

    // MARK: - /conversations

    /// ⚠️ THE REGRESSION THIS COMMIT WAS MOST LIKELY TO SHIP. An empty chooser renders as its
    /// heading alone, so returning one here would silently replace this sentence with a bare
    /// "📋 *Your Conversations:*" — no error, no failing renderer test.
    ///
    /// Mutation that must turn this red: drop the `rows.isEmpty` guard and always return a chooser.
    func testAnEmptyListIsTheSentenceNotAnEmptyChooser() throws {
        let view = service.conversationList(offset: 0)

        guard case .notice(let notice) = view else {
            return XCTFail("an empty list produced a \(view) — a chooser here renders as a bare header")
        }
        XCTAssertEqual(notice.body, "No conversations yet. Use /new to create one.")
        XCTAssertEqual(try telegramText(view), "No conversations yet. Use /new to create one.")
    }

    func testTheListCarriesOneOptionPerConversationPlusTheNewAction() throws {
        conversations.rows = [row("Deploy checklist"), row("Release notes")]

        guard case .chooser(let chooser) = service.conversationList(offset: 0) else { return XCTFail("expected a chooser") }
        XCTAssertEqual(chooser.icon, "📋")
        XCTAssertEqual(chooser.title, "Your Conversations:")
        XCTAssertEqual(chooser.options.map(\.label), ["Deploy checklist", "Release notes"])
        XCTAssertEqual(chooser.extraActions.map(\.label), ["➕ New Conversation"])
        XCTAssertEqual(chooser.extraActions.first?.token, .action(.new))
    }

    /// The star is a FLAG on the option, applied by the renderer — not baked into the label here.
    func testTheActiveConversationIsFlaggedNotStarPrefixed() throws {
        let active = UUID()
        conversations.rows = [row("Other"), row("Active one", id: active)]
        session.activeConversationID = active

        guard case .chooser(let chooser) = service.conversationList(offset: 0) else { return XCTFail("expected a chooser") }
        let activeOption = try XCTUnwrap(chooser.options.first { $0.token == .switchConversation(active) })
        XCTAssertTrue(activeOption.isCurrent)
        XCTAssertEqual(activeOption.label, "Active one", "the star must not be in the label")
        XCTAssertFalse(try XCTUnwrap(chooser.options.first).isCurrent)
    }

    /// Transcribed from `fetchRecentConversations(limit: 10)` at the shipping call site.
    /// ⚠️ UPDATED IN SLICE 5: this asserted `requestedLimits == [conversationListLimit]` under the
    /// name `testTheListAsksForTenConversations`, and the list now asks for ELEVEN. The extra row is
    /// never rendered — it exists so the service can learn whether a "Next" button belongs without
    /// a count query, which would materialise every conversation's messages and derive every title
    /// just to produce a number. Asking for exactly the page size would make the last page and a
    /// full page indistinguishable.
    func testTheListAsksForOneMoreRowThanItShows() {
        _ = service.conversationList(offset: 0)
        XCTAssertEqual(conversations.requestedLimits,
                       [ChatOpsCommandService.conversationListLimit + 1],
                       "the extra row is the whole next-page detector")
        XCTAssertEqual(conversations.requestedOffsets, [0])
        XCTAssertEqual(ChatOpsCommandService.conversationListLimit, 10)
    }

    /// ⚠️ Pagination must reach the STORE, not be simulated by slicing a full read. Paging in Swift
    /// would materialise every skipped conversation's messages and derive every skipped title.
    ///
    /// Mutation that must turn this red: ignore `offset` in `conversationList` and always pass 0.
    func testAPageRequestReachesTheStoreWithItsOffset() {
        _ = service.conversationList(offset: 20)
        XCTAssertEqual(conversations.requestedOffsets, [20])
    }

    // MARK: - History (slice 5)

    private func seedMessages(_ turns: [(user: Bool, text: String)]) {
        conversations.messages = turns.enumerated().map { index, turn in
            ConversationMessageRow(isFromUser: turn.user, text: turn.text,
                                   timestamp: Date(timeIntervalSince1970: TimeInterval(index)))
        }
    }

    private func historyLines(_ view: RemoteView) -> [String] {
        guard case .notice(let notice) = view else { return [] }
        return notice.fields.map(\.value).filter { !$0.isEmpty }
    }

    /// ⚠️⚠️ OLDEST FIRST, AND THIS IS INVARIANT 8's TERRITORY. The store sorts `.reverse` so the
    /// limit keeps RECENT messages, and shipping that order to a reader is the exact failure that
    /// mispaired every scheduled run's history for a release. A transcript printed newest-first
    /// reads as a conversation happening backwards and nothing about it looks like an error.
    ///
    /// Mutation that must turn this red: drop the `.reversed()` in the store conformance.
    func testHistoryReadsOldestFirst() {
        session.activeConversationID = UUID()
        seedMessages([(true, "first question"), (false, "first answer"), (true, "second question")])

        let lines = historyLines(service.conversationHistory(argument: ""))
        XCTAssertEqual(lines, ["👤 first question", "🤖 first answer", "👤 second question"])
    }

    /// Mutation that must turn this red: ignore the argument and always use the default.
    func testAnExplicitCountIsHonouredAndClamped() {
        session.activeConversationID = UUID()
        seedMessages((1...30).map { (user: $0 % 2 == 1, text: "turn \($0)") })

        _ = service.conversationHistory(argument: "3")
        XCTAssertEqual(conversations.requestedMessageLimits.last, 3)

        _ = service.conversationHistory(argument: "500")
        XCTAssertEqual(conversations.requestedMessageLimits.last,
                       ChatOpsCommandService.historyMaxCount,
                       "a request above the cap is clamped, not honoured")

        _ = service.conversationHistory(argument: "")
        XCTAssertEqual(conversations.requestedMessageLimits.last,
                       ChatOpsCommandService.historyDefaultCount)
    }

    /// ⚠️ A CLAMP THE USER IS NOT TOLD ABOUT READS AS "THAT IS ALL THERE IS". Someone asking for 500
    /// turns and silently getting 20 concludes the conversation is 20 turns long.
    ///
    /// Mutation that must turn this red: use the same heading regardless of the requested count.
    func testAClampedRequestSaysSo() {
        session.activeConversationID = UUID()
        seedMessages((1...30).map { (user: true, text: "turn \($0)") })

        guard case .notice(let clamped) = service.conversationHistory(argument: "500"),
              case .notice(let normal) = service.conversationHistory(argument: "3") else {
            return XCTFail("expected notices")
        }
        XCTAssertTrue(clamped.title?.contains("limit") ?? false, "got: \(clamped.title ?? "nil")")
        XCTAssertFalse(normal.title?.contains("limit") ?? true,
                       "an unclamped request must not carry the warning: \(normal.title ?? "nil")")
    }

    /// ⚠️ A TYPED ARGUMENT IS A HUMAN, so a typo gets a usage hint rather than "unknown command",
    /// which would send them looking for the wrong problem.
    ///
    /// Mutation that must turn this red: fall back to the default count for an unparseable argument.
    func testANonNumericCountAsksAgainRatherThanGuessing() {
        session.activeConversationID = UUID()
        seedMessages([(true, "hello")])

        for junk in ["five", "-3", "0", "3.5"] {
            guard case .notice(let notice) = service.conversationHistory(argument: junk) else {
                return XCTFail("`\(junk)` must produce a usage hint")
            }
            XCTAssertTrue(notice.body.contains("/history"), "got: \(notice.body)")
        }
        XCTAssertTrue(conversations.requestedMessageLimits.isEmpty,
                      "an unparseable count must not reach the store")
    }

    /// ⚠️ MESSAGE TEXT IS THE MOST HOSTILE CONTENT THIS APP SENDS. Each line goes out as its own
    /// `Notice.Field`, which `NoticeText.build` escapes for the platform's markup — a stray `*` or
    /// `_` from an agent reply under Telegram's Markdown parse mode is a 400 that makes the WHOLE
    /// message vanish, which is how a conversation title once silently killed a reply.
    ///
    /// Mutation that must turn this red: join the lines into `Notice.body` yourself.
    func testHostileMessageTextIsEscapedRatherThanBreakingTheSend() throws {
        session.activeConversationID = UUID()
        seedMessages([(true, "use *args and _kwargs"), (false, "see `main.py` [here]")])

        let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: service.conversationHistory(argument: "")))
        XCTAssertEqual(draft.parse_mode, "Markdown", "a notice renders as Markdown — hence the escaping")
        XCTAssertTrue(draft.text.contains("\\*args"), "got: \(draft.text)")
        XCTAssertTrue(draft.text.contains("\\_kwargs"), "got: \(draft.text)")
        XCTAssertTrue(draft.text.contains("\\`main.py\\`"), "got: \(draft.text)")
    }

    func testHistoryWithNoActiveConversationSaysHowToPickOne() {
        session.activeConversationID = nil
        guard case .notice(let notice) = service.conversationHistory(argument: "") else {
            return XCTFail("expected a notice")
        }
        XCTAssertTrue(notice.body.contains("/conversations"), "got: \(notice.body)")
    }

    /// A dead store must not read as an empty conversation — the collapse `ConversationReading`
    /// exists to prevent.
    func testADeadStoreDoesNotLookLikeAnEmptyConversation() {
        session.activeConversationID = UUID()
        conversations.throwsStoreUnavailable = true
        guard case .notice(let notice) = service.conversationHistory(argument: "") else {
            return XCTFail("expected a notice")
        }
        XCTAssertEqual(notice.tone, .failure)
        XCTAssertFalse(notice.body.contains("no messages yet"), "got: \(notice.body)")
    }

    // MARK: - Search (slice 5)

    private func seedTitled(_ titles: [String]) {
        conversations.rows = titles.enumerated().map { index, title in
            ConversationRow(id: UUID(), title: title,
                            timestamp: Date(timeIntervalSince1970: TimeInterval(10_000 - index)),
                            isEmpty: false, boundProfileID: nil)
        }
    }

    /// Matches the sidebar's predicate exactly — substring, case-insensitive, locale-folded.
    ///
    /// Mutation that must turn this red: make the match case-sensitive or prefix-only.
    func testSearchMatchesTheSameWayTheAppsOwnSidebarDoes() {
        seedTitled(["Deploy checklist", "Release NOTES", "Groceries"])
        guard case .chooser(let chooser) = service.searchConversations(query: "notes") else {
            return XCTFail("expected a chooser")
        }
        XCTAssertEqual(chooser.options.map(\.label), ["Release NOTES"],
                       "case-insensitive substring, as ConversationSidebarView does it")
    }

    /// ⚠️ "NOTHING MATCHED" AND "I ONLY LOOKED AT THE NEWEST N" ARE DIFFERENT FACTS. A remote user
    /// reads the first as "that conversation does not exist" and acts on it — by starting a
    /// duplicate, or by giving up. A bounded scan that stays quiet about its bound makes the
    /// stronger claim for free, silently and with no error.
    ///
    /// Mutation that must turn this red: report the same copy regardless of `scanWasTruncated`.
    func testAnEmptyResultAdmitsWhenTheScanWasBounded() {
        conversations.searchScanLimit = 3
        seedTitled(["one", "two", "three"])   // exactly the bound → truncated

        guard case .notice(let bounded) = service.searchConversations(query: "zzz") else {
            return XCTFail("expected a notice")
        }
        XCTAssertTrue(bounded.body.contains("Older ones were not searched"), "got: \(bounded.body)")

        seedTitled(["one", "two"])            // under the bound → complete
        guard case .notice(let complete) = service.searchConversations(query: "zzz") else {
            return XCTFail("expected a notice")
        }
        XCTAssertFalse(complete.body.contains("Older ones were not searched"), """
            A complete scan must NOT hedge — a search that always says it might have missed \
            something is as useless as one that never does. Got: \(complete.body)
            """)
    }

    /// The bound is disclosed on a RESULT too, not only on an empty one: matches inside the window
    /// say nothing about matches outside it.
    func testABoundedScanSaysSoEvenWhenItFoundSomething() {
        conversations.searchScanLimit = 3
        seedTitled(["deploy a", "deploy b", "deploy c"])
        guard case .chooser(let chooser) = service.searchConversations(query: "deploy") else {
            return XCTFail("expected a chooser")
        }
        XCTAssertTrue(chooser.title.contains("searched"), "got: \(chooser.title)")
    }

    /// ⚠️ AN EMPTY QUERY IS A USAGE HINT, NOT THE WHOLE LIST. `localizedCaseInsensitiveContains("")`
    /// is false, so the sidebar guards `!searchText.isEmpty` to mean "show everything" — but a
    /// remote `/search` with nothing after it is a user who forgot the query, and answering with
    /// every conversation would look like the search was ignored.
    ///
    /// Mutation that must turn this red: fall through to the conversation list for a blank query.
    func testABlankQueryAsksForOneRatherThanListingEverything() {
        seedTitled(["Deploy checklist", "Groceries"])
        for blank in ["", "   "] {
            guard case .notice(let notice) = service.searchConversations(query: blank) else {
                return XCTFail("a blank query must not return a chooser")
            }
            XCTAssertTrue(notice.body.contains("/search"), "the hint must show the shape: \(notice.body)")
        }
        XCTAssertEqual(conversations.searchQueries.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count, 0,
                       "a blank query must not reach the store at all")
    }

    /// A dead store must not read as "nothing matched" — the collapse `ConversationReading` exists
    /// to prevent, and search is where it is most convincing.
    ///
    /// Mutation that must turn this red: swallow the error and return the no-matches notice.
    func testADeadStoreDoesNotLookLikeAnEmptySearch() {
        conversations.throwsStoreUnavailable = true
        guard case .notice(let notice) = service.searchConversations(query: "deploy") else {
            return XCTFail("expected a notice")
        }
        XCTAssertFalse(notice.body.contains("No conversation title matches"), "got: \(notice.body)")
        XCTAssertEqual(notice.tone, .failure)
    }

    /// `/search <query>` must reach the search command on every platform — the argument dispatch
    /// this slice generalised.
    ///
    /// Mutation that must turn this red: restore `verb.takesArgument ? .useProfile(argument) : …`.
    func testASearchVerbCarriesItsQueryOnEveryPlatform() {
        for parsed in [
            ChatOpsCommand.parse(text: "/search deploy notes", callbackData: nil),
            ChatOpsCommand.parseDiscord(text: "/search deploy notes"),
            ChatOpsCommand.parseSlack(text: "/search deploy notes"),
            ChatOpsCommand.parseSlack(slashCommand: "/search", slashArgument: "deploy notes"),
        ] {
            guard case .searchConversations(let query) = parsed else {
                return XCTFail("`/search deploy notes` did not reach the search command: \(parsed)")
            }
            XCTAssertEqual(query, "deploy notes", "the argument keeps its own spaces")
        }
    }

    // MARK: - Paging (slice 5)

    /// Builds `count` conversations, newest first.
    private func seedConversations(_ count: Int) {
        conversations.rows = (0..<count).map { index in
            ConversationRow(
                id: UUID(),
                title: "Conversation \(index + 1)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(10_000 - index)),
                isEmpty: false,
                boundProfileID: nil
            )
        }
    }

    private func options(_ view: RemoteView) -> (labels: [String], extras: [String]) {
        guard case .chooser(let chooser) = view else { return ([], []) }
        return (chooser.options.map(\.label), chooser.extraActions.map(\.label))
    }

    /// ⚠️ THE PROBE ROW IS NEVER SHOWN. The service asks for one more than the page size to learn
    /// whether a "Next" button belongs; rendering it would put eleven conversations on a ten-row
    /// page and make the next page start one row late, silently skipping a conversation.
    ///
    /// Mutation that must turn this red: render `page` instead of `page.prefix(limit)`.
    func testTheExtraProbeRowIsNeverRendered() {
        seedConversations(11)
        let shown = options(service.conversationList(offset: 0))
        XCTAssertEqual(shown.labels.count, ChatOpsCommandService.conversationListLimit)
        XCTAssertEqual(shown.labels.last, "Conversation 10")
    }

    /// Mutation that must turn this red: always offer Next.
    func testNextIsOfferedOnlyWhenThereIsAnotherPage() {
        seedConversations(11)
        XCTAssertTrue(options(service.conversationList(offset: 0)).extras.contains("Next ▸"))

        seedConversations(10)
        XCTAssertFalse(options(service.conversationList(offset: 0)).extras.contains("Next ▸"), """
            A Next button on the last page takes the user to an empty page, which then has to             explain itself. The extra row exists precisely so this is knowable.
            """)
    }

    /// Mutation that must turn this red: offer Previous at offset 0.
    func testPreviousIsOfferedOnlyPastTheFirstPage() {
        seedConversations(25)
        XCTAssertFalse(options(service.conversationList(offset: 0)).extras.contains("◂ Previous"))

        let second = options(service.conversationList(offset: 10))
        XCTAssertTrue(second.extras.contains("◂ Previous"))
        XCTAssertTrue(second.extras.contains("Next ▸"))
        XCTAssertEqual(second.labels.first, "Conversation 11", "the second page starts where the first ended")
    }

    /// ⚠️ AN EMPTY LATER PAGE IS NOT AN EMPTY LIST. Telling a user with twenty-five conversations
    /// "No conversations yet. Use /new to create one." because they tapped a stale Next button is
    /// the same class of lie as the store-down copy this service already refuses to tell — and it
    /// invites them to create a conversation they do not need.
    ///
    /// Mutation that must turn this red: drop the `offset == 0` guard on the empty-state notice.
    func testAnEmptyLaterPageSaysTheListChangedRatherThanThatYouHaveNone() {
        seedConversations(25)
        guard case .notice(let notice) = service.conversationList(offset: 200) else {
            return XCTFail("an empty page must be a notice, not an empty chooser")
        }
        XCTAssertFalse(notice.body.contains("No conversations yet"), "got: \(notice.body)")
        XCTAssertTrue(notice.body.contains("changed"), "got: \(notice.body)")
    }

    /// ⚠️ THE OTHER HALF OF THE EMPTY STATE, and it was uncovered: a mutation that sent EVERY
    /// empty page down the "the list has changed" path stayed green, because only the later-page
    /// case was pinned. A first-time user would then be told their list had changed since a button
    /// they never saw was posted, instead of being told how to create their first conversation.
    ///
    /// Mutation that must turn this red: make the stale-page notice unconditional.
    func testAnEmptyFirstPageStillTellsYouHowToStart() {
        conversations.rows = []
        guard case .notice(let notice) = service.conversationList(offset: 0) else {
            return XCTFail("expected a notice")
        }
        XCTAssertTrue(notice.body.contains("No conversations yet"), "got: \(notice.body)")
        XCTAssertTrue(notice.body.contains("/new"), "the empty state must say how to start: \(notice.body)")
    }

    /// A list that silently starts at the eleventh newest conversation is indistinguishable from a
    /// list that has lost rows, so past page one the heading says where you are.
    func testTheHeadingNamesTheRangeOnlyWhilePaging() {
        seedConversations(25)
        guard case .chooser(let first) = service.conversationList(offset: 0),
              case .chooser(let second) = service.conversationList(offset: 10) else {
            return XCTFail("expected choosers")
        }
        XCTAssertEqual(first.title, "Your Conversations:")
        XCTAssertEqual(second.title, "Your Conversations (11–20):")
    }

    /// The paging buttons must carry an OFFSET the read model can use directly.
    func testThePagingButtonsCarryTheOffsetsTheyClaim() {
        seedConversations(25)
        guard case .chooser(let second) = service.conversationList(offset: 10) else {
            return XCTFail("expected a chooser")
        }
        let tokens = Dictionary(uniqueKeysWithValues: second.extraActions.map { ($0.label, $0.token) })
        XCTAssertEqual(tokens["◂ Previous"], .conversationPage(offset: 0))
        XCTAssertEqual(tokens["Next ▸"], .conversationPage(offset: 20))
    }

    /// ⚠️ The shipping handler writes `(try?) ?? []`, so a dead store is reported as "no
    /// conversations yet" — which the user acts on by creating a duplicate. A deliberate divergence.
    ///
    /// Mutation that must turn this red: swallow the error and return the empty-state notice.
    func testADeadStoreSaysSoInsteadOfClaimingYouHaveNoConversations() throws {
        conversations.throwsStoreUnavailable = true

        guard case .notice(let notice) = service.conversationList(offset: 0) else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice.tone, .failure)
        XCTAssertTrue(notice.body.contains("not available"), "got: \(notice.body)")
        XCTAssertNotEqual(notice.body, "No conversations yet. Use /new to create one.",
                          "a dead store must not be reported as an empty history")
    }

    // MARK: - /status

    func testStatusReportsTheActiveConversationsTitleEvenWhenItIsOutsideTheListWindow() throws {
        let active = UUID()
        // Deliberately NOT in `rows`' first page — the title must come from the by-id read.
        conversations.rows = [row("Old but active", id: active)]
        session.activeConversationID = active

        guard case .notice(let notice) = service.status() else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice.icon, "📊")
        XCTAssertEqual(notice.fields.first { $0.label == "🗣 Active Conversation" }?.value, "Old but active")
    }

    func testStatusReportsNoneWhenNoConversationIsBound() throws {
        session.activeConversationID = nil

        guard case .notice(let notice) = service.status() else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice.fields.first { $0.label == "🗣 Active Conversation" }?.value, "None")
        XCTAssertEqual(notice.fields.first { $0.label == "⚡ Agent Streaming" }?.value, "No")
        XCTAssertEqual(notice.fields.first { $0.label == "⏳ HITL Pending" }?.value, "No")
    }

    /// ⚠️ Conversation-scoped, not app-global. `/status` once read `vm.streamingMessageID` and
    /// reported "streaming" whenever ANY conversation was busy.
    ///
    /// Mutation that must turn this red: report streaming for any busy conversation.
    func testStreamingIsScopedToTheBoundConversation() throws {
        let bound = UUID(), unrelated = UUID()
        conversations.rows = [row("Bound", id: bound)]
        runControl.busy = [unrelated]
        session.activeConversationID = bound

        guard case .notice(let idle) = service.status() else { return XCTFail("expected a notice") }
        XCTAssertEqual(idle.fields.first { $0.label == "⚡ Agent Streaming" }?.value, "No",
                       "an unrelated conversation's run must not report as this one's")

        runControl.busy = [bound]
        guard case .notice(let busy) = service.status() else { return XCTFail("expected a notice") }
        XCTAssertEqual(busy.fields.first { $0.label == "⚡ Agent Streaming" }?.value, "Yes")
    }

    func testStatusReportsAPendingClarification() throws {
        let bound = UUID()
        conversations.rows = [row("Bound", id: bound)]
        runControl.clarifications = [bound: UUID()]
        session.activeConversationID = bound

        guard case .notice(let notice) = service.status() else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice.fields.first { $0.label == "⏳ HITL Pending" }?.value, "Yes")
    }

    /// Transcribed from `fetchRecentConversations(limit: 100)` — "Total Conversations" has always
    /// meant "of the 100 most recent".
    func testStatusCountsWithinTheShippingWindow() throws {
        conversations.rows = (0..<3).map { row("c\($0)") }
        _ = service.status()
        XCTAssertTrue(conversations.requestedLimits.contains(ChatOpsCommandService.statusCountLimit))
        XCTAssertEqual(ChatOpsCommandService.statusCountLimit, 100)
    }

    /// ⚠️ Deliberate divergence: the shipping handler reports 0 on a dead store, which is
    /// indistinguishable from an empty history.
    func testStatusSaysUnavailableRatherThanZeroWhenTheStoreIsDown() throws {
        conversations.throwsStoreUnavailable = true

        guard case .notice(let notice) = service.status() else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice.fields.first { $0.label == "📋 Total Conversations" }?.value, "unavailable")
        XCTAssertEqual(notice.fields.first { $0.label == "🔐 Security Tier" }?.value,
                       session.securityTier.rawValue,
                       "the rest of /status must still answer — a dead store is not a dead command")
    }

    /// ⚠️⚠️ ONE OUTAGE MUST NOT BE DESCRIBED THREE WAYS IN ONE REPLY. The count said "unavailable"
    /// while the title said "None" and the profile said "Default" — both of which name real,
    /// benign states. A user reading "Active Conversation: None" runs `/new` and creates a
    /// duplicate of the conversation they were already in; a user reading "Profile: Default"
    /// believes they know what is about to answer them.
    ///
    /// Mutation that must turn this red: initialise `activeTitle` to "None" regardless of the
    /// cursor, or resolve `boundProfileName` before the do/catch.
    func testStatusDoesNotClaimThereIsNoActiveConversationWhenTheStoreIsSimplyDown() throws {
        session.activeConversationID = UUID()
        conversations.throwsStoreUnavailable = true

        guard case .notice(let notice) = service.status() else { return XCTFail("expected a notice") }
        func field(_ label: String) -> String? { notice.fields.first { $0.label == label }?.value }

        XCTAssertEqual(field("🗣 Active Conversation"), ChatOpsCommandService.unavailable,
                       "a failed read reported as \"None\" invites the user to create a duplicate")
        XCTAssertEqual(field("🧠 Profile"), ChatOpsCommandService.unavailable,
                       "\"Default\" names a real fallback profile and would be believed")
        XCTAssertEqual(field("📋 Total Conversations"), ChatOpsCommandService.unavailable)
    }

    /// ⚠️ THE OTHER HALF, AND IT IS WHAT KEEPS THE FIX HONEST. "None" must still mean "no cursor" —
    /// answering "unavailable" when the store is fine and simply has no active conversation would
    /// trade one lie for another.
    ///
    /// Mutation that must turn this red: initialise `activeTitle` to `unavailable` unconditionally.
    func testStatusStillSaysNoneWhenThereIsGenuinelyNoActiveConversation() throws {
        session.activeConversationID = nil

        guard case .notice(let notice) = service.status() else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice.fields.first { $0.label == "🗣 Active Conversation" }?.value, "None")
    }

    /// ⚠️ A CURSOR OUTLIVING ITS CONVERSATION IS A SUCCESSFUL READ, not an outage. Deleting the
    /// conversation on the Mac must not make `/status` report the database as unavailable and send
    /// the user hunting a problem that does not exist.
    func testStatusSaysNoneWhenTheCursorPointsAtADeletedConversation() throws {
        session.activeConversationID = UUID()   // present in no row the fake holds

        guard case .notice(let notice) = service.status() else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice.fields.first { $0.label == "🗣 Active Conversation" }?.value, "None")
    }

    // MARK: - /help

    /// ⚠️⚠️ THIS COMMENT WAS STALE TOO, and a stale comment on a PASSING test is the more dangerous
    /// of the two: it is read as confirmation. It claimed the command lines are NOT generated from
    /// `ChatOpsVerbTable` — they are, from `ChatOpsVerb.presentationOrder`.
    ///
    /// ⚠️ WHICH CHANGES WHAT THIS TEST IS FOR. Against a hand-written list it checked that someone
    /// had remembered to add a line. Against a derived one it checks the DERIVATION still reaches
    /// every verb a user can type — so it fails if `presentationOrder` drops one, which `allCases`
    /// would not catch because the order is explicit rather than generated.
    func testHelpDocumentsEveryVerbAUserCanType() throws {
        guard case .notice(let notice) = service.help() else { return XCTFail("expected a notice") }
        let lines = notice.fields.map(\.value)

        // ⚠️⚠️ DERIVED FROM `allCases`, NOT A HAND-WRITTEN LIST — and the hand-written list is
        // exactly why this matters. It named seven verbs against a table that had grown to nine, so
        // `/search` and `/history` could have been dropped from `presentationOrder` with this test
        // still green: the same drift, in the test guarding the fix for that drift.
        //
        // `presentationOrder` is explicit rather than generated, so nothing else notices an omission.
        for verb in ChatOpsVerb.allCases {
            XCTAssertTrue(lines.contains { $0.hasPrefix("/" + verb.canonicalName) },
                          "/help no longer documents /\(verb.canonicalName) — presentationOrder has dropped it")
        }
        XCTAssertFalse(lines.contains { $0.contains("/convos") || $0.contains("/stop") },
                       "/help gained an alias it has never listed — that is a copy change, not a refactor")
    }

    func testHelpReportsTheCurrentSecurityTierWithABoldLabel() throws {
        guard case .notice(let notice) = service.help() else { return XCTFail("expected a notice") }
        let tier = try XCTUnwrap(notice.fields.first { $0.label == "Security Tier" })
        XCTAssertEqual(tier.value, session.securityTier.rawValue)
        XCTAssertTrue(tier.labelEmphasis, "the shipping literal bolds the LABEL, not the value")
        XCTAssertFalse(tier.emphasis)
    }

    /// AGPL §13 — a user who reaches the app over a network must be offered its Corresponding
    /// Source. The offer lives in `/help` so an operator running a modified build inherits it.
    /// Cutting the field, or pointing it anywhere but the public repository, fails here; the
    /// rendered golden below pins the exact line a Telegram user reads.
    func testHelpOffersTheSourceRepositoryToRemoteUsers() throws {
        guard case .notice(let notice) = service.help() else { return XCTFail("expected a notice") }
        let source = try XCTUnwrap(notice.fields.first { $0.label == "Source" },
                                   "/help no longer offers the source — the AGPL network offer is gone")
        XCTAssertTrue(source.value.contains(GlobalConstants.sourceCodeURL),
                      "the offer must be wired to the one constant, not a second copy of the URL")
        XCTAssertTrue(source.value.hasPrefix("https://github.com/rajnsingh99/devgentic"),
                      "the offer must name the public repository, not a mirror or a placeholder")
        XCTAssertTrue(source.labelEmphasis, "bold LABEL, matching the Security Tier line above it")
        XCTAssertFalse(source.emphasis)
    }

    // MARK: - End to end, through the real renderer

    /// The service's output, rendered by the real Telegram renderer, must equal the shipping literal
    /// character for character. This is the assertion the swap actually rests on.
    /// ⚠️ NO LONGER THE SHIPPING LITERAL — slice 2 adds the Profile line ON PURPOSE. This test
    /// failed when that landed, which is the guard working: a change to what a remote user reads
    /// should never pass silently. `ShippingLiteralGoldenTests` still pins the ORIGINAL strings
    /// against the renderer, so slice 1's preservation claim remains checkable independently.
    func testStatusRendersWithTheBoundProfile() throws {
        conversations.rows = [row("a"), row("b"), row("c")]
        session.activeConversationID = nil

        XCTAssertEqual(try telegramText(service.status()), """
        📊 *Devgentic Status*

        🗣 Active Conversation: None
        🧠 Profile: Default
        ⚡ Agent Streaming: No
        🔐 Security Tier: \(session.securityTier.rawValue)
        ⏳ HITL Pending: No
        📋 Total Conversations: 3
        """)
    }

    /// ⚠️ Slice 2 added two commands to /help; slice 5 added `/search` AND stopped this list being
    /// hand-written. It was seven literals against a table of eight verbs, so a shipped command was
    /// undiscoverable in the one place users look — the drift `ChatOpsVerbTable` exists to prevent,
    /// reappearing in `/help` itself. The golden text below is still spelled out in full, because a
    /// fixture derived from the same table it guards would pin nothing.
    /// ⚠️ `\\[n]` IS CORRECT, NOT A TYPO. `RemoteMarkupEscaping.telegram` escapes `[` because it
    /// opens a link in Telegram's legacy Markdown, and this fixture asserts the WIRE text. Telegram
    /// honours the backslash, so the user reads `/history [n]`. Removing the escape here to make the
    /// fixture prettier would mean removing it from the escaper, which is the 400-that-vanishes bug.
    func testHelpRendersEveryVerbTheTableDeclares() throws {
        XCTAssertEqual(try telegramText(service.help()), """
        🤖 *Devgentic ChatOps*

        *Commands:*
        /conversations — List your conversations
        /search <query> — Find a conversation by title
        /history \\[n] — Read back the last few turns
        /profiles — Choose which agent answers
        /use <name> — Switch profile by name
        /new — Start a new conversation
        /status — Current agent status
        /cancel — Stop the active agent
        /help — Show this message

        *How it works:*
        1. Use /conversations to pick a conversation
        2. Type your message — it routes to the agent
        3. The agent responds right here

        *Security Tier:* \(session.securityTier.rawValue)
        *Source:* https://github.com/rajnsingh99/devgentic · GNU AGPL v3
        """)
    }

    func testTheConversationListRendersToTheShippingHeaderAndButtons() throws {
        let a = UUID(), b = UUID()
        conversations.rows = [row("Deploy checklist", id: a), row("Release notes", id: b)]
        session.activeConversationID = a

        let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: service.conversationList(offset: 0)))
        XCTAssertEqual(draft.text, "📋 *Your Conversations:*")
        XCTAssertEqual(draft.parse_mode, "Markdown")

        let keyboard = try XCTUnwrap(inlineKeyboard(draft.reply_markup))
        XCTAssertEqual(keyboard.map { $0.map(\.text) },
                       [["⭐ Deploy checklist"], ["Release notes"], ["➕ New Conversation"]])
        XCTAssertEqual(keyboard.map { $0.map { $0.callback_data ?? "" } },
                       [["switch:\(a.uuidString)"], ["switch:\(b.uuidString)"], ["action:new"]])
    }

    // MARK: - /new  (C5b)

    /// ⚠️ THE ORDERING PROPERTY C5b EXISTS TO PRESERVE. Every state write lands before the view is
    /// returned. A render-then-apply pipeline would tell the user the conversation moved and only
    /// then move it — so a failed send leaves the cursor behind while the user believes it advanced,
    /// and their next message goes to the wrong conversation.
    ///
    /// Mutation that must turn this red: move `session.activeConversationID = …` or
    /// `focusConversationInMainWindow` after the `return`.
    func testNewConversationAppliesEveryStateWriteBeforeReturningTheView() {
        profiles.profiles = [agentProfile("Coder")]

        _ = service.newConversation()

        // ⚠️ Order, not just presence: the origin is recorded while it is a fact, before the cursor
        // moves — matching the shipping handler.
        // ⚠️ `create()` — the empty title is the slice-5 change; the ORDER is what this test pins.
        XCTAssertEqual(log.effects, ["create()", "origin", "cursor", "focus"])
        XCTAssertEqual(session.activeConversationID, commanding.createdID)
        XCTAssertEqual(commanding.focused, [commanding.createdID])
    }

    /// ⚠️ INVERTED IN SLICE 5, DELIBERATELY. This asserted `createdTitles == ["Telegram Chat"]`
    /// under the name `testANewConversationIsTitledFromTheOriginNotAHardCodedLiteral`, and the
    /// title really did come from `RemoteConversationOrigin.bridgeTitle` — which turned out to be
    /// the defect, not the design. The auto-title path that names a conversation after the user's
    /// first message fires only when the title is nil or EMPTY, so a stamped constant meant every
    /// conversation ever started from chat stayed called "Telegram Chat" for its whole life:
    /// `/conversations` listed N identical rows, and a title search could match only one of three
    /// constants.
    ///
    /// ⚠️ THE ORIGIN IS STILL RECORDED — that assertion is unchanged and is the point. Provenance
    /// travels in the side store (CF-39), never in the title, so dropping the stamp costs nothing.
    ///
    /// Mutation that must turn this red: pass `origin.bridgeTitle` as the title again.
    func testANewConversationIsLeftUntitledSoTheFirstMessageNamesIt() {
        profiles.profiles = [agentProfile("Coder")]

        _ = service.newConversation()
        XCTAssertEqual(commanding.createdTitles, [""], """
            A remote conversation must be created untitled so the shared auto-title path names it \
            after what the user actually said, exactly as every other surface does.
            """)
        XCTAssertEqual(recordedOrigins.map(\.0), [.telegram],
                       "provenance still travels, just not in the title")

        // A second service, scoped to Discord — the provider is fixed at construction.
        let discordService = ChatOpsCommandService(
            provider: .discord, runControl: runControl, commanding: commanding,
            conversations: conversations, profiles: profiles, session: session,
            recordOrigin: { [weak self] origin, id in self?.recordedOrigins.append((origin, id)); self?.log.record("origin") }
        )
        _ = discordService.newConversation()
        XCTAssertEqual(commanding.createdTitles.last, "", "untitled on every provider")
        XCTAssertEqual(recordedOrigins.last?.0, .discord,
                       "the provider still reaches the origin store — only the title changed")
    }

    func testNewConversationRendersTheShippingLiteral() throws {
        profiles.profiles = [agentProfile("Coder")]
        XCTAssertEqual(try telegramText(service.newConversation()), """
        ✅ New conversation created and set as active.
        Just type your message to start.
        """)
    }

    /// ⚠️ The reuse branch must NOT record an origin — the conversation already has whatever
    /// provenance it was created with, and stamping it would relabel a locally-created conversation
    /// as remote in the Mac empty-state placeholder.
    ///
    /// Mutation that must turn this red: add `recordOrigin(...)` to the reuse branch.
    func testReusingAnEmptyConversationMovesTheCursorButRecordsNoOrigin() throws {
        profiles.profiles = [agentProfile("Coder")]
        let empty = UUID()
        conversations.rows = [ConversationRow(id: empty, title: "New Chat", timestamp: Date(timeIntervalSince1970: 0), isEmpty: true, boundProfileID: nil)]

        let view = service.newConversation()

        XCTAssertEqual(log.effects, ["cursor", "focus"], "the reuse branch creates nothing and records no origin")
        XCTAssertTrue(recordedOrigins.isEmpty)
        XCTAssertEqual(session.activeConversationID, empty)
        XCTAssertEqual(try telegramText(view), """
        ✅ Switched to existing empty conversation.
        Just type your message to start.
        """)
    }

    /// No profile means no conversation — and, critically, no state change at all.
    func testNewConversationWithNoProfileChangesNothing() throws {
        profiles.profiles = []

        let view = service.newConversation()

        XCTAssertEqual(try telegramText(view), "⚠️ No agent profile configured. Set one in Devgentic Settings.")
        XCTAssertTrue(log.effects.isEmpty, "a refused /new must not move the cursor or the Mac window")
        XCTAssertNil(session.activeConversationID)
    }

    // MARK: - Default-profile policy

    /// Pure, over plain values — so the preference order is checkable with no store.
    func testTheDefaultProfilePrefersTheSelectionThenAnAgentThenAnything() {
        let bot = botProfile("Bot"), agent = agentProfile("Agent")

        XCTAssertEqual(ChatOpsCommandService.defaultProfile(from: [bot, agent], selected: bot.id)?.id, bot.id,
                       "an explicit selection wins")
        XCTAssertEqual(ChatOpsCommandService.defaultProfile(from: [bot, agent], selected: nil)?.id, agent.id,
                       "with no selection, an agent is preferred over a bot")
        XCTAssertEqual(ChatOpsCommandService.defaultProfile(from: [bot], selected: nil)?.id, bot.id,
                       "with no agent at all, fall back to the first profile")
        XCTAssertEqual(ChatOpsCommandService.defaultProfile(from: [bot, agent], selected: UUID())?.id, agent.id,
                       "a stale selection falls through rather than returning nil")
        XCTAssertNil(ChatOpsCommandService.defaultProfile(from: [], selected: nil))
    }

    // MARK: - switch:<uuid>  (C5b)

    func testSwitchingAppliesStateBeforeReturningAndRendersTheShippingLiteral() throws {
        let target = UUID()
        conversations.rows = [ConversationRow(id: target, title: "Deploy checklist", timestamp: Date(timeIntervalSince1970: 0), isEmpty: false, boundProfileID: nil)]

        let view = service.switchConversation(to: target)

        XCTAssertEqual(log.effects, ["cursor", "focus"])
        XCTAssertEqual(session.activeConversationID, target)
        XCTAssertEqual(try telegramText(view), """
        ✅ Switched to: *Deploy checklist*

        Just type your message to continue.
        """)
    }

    /// ⚠️ The title is user-controlled, so it is escaped — which is the fix for a live bug where an
    /// unbalanced `*` in a derived title 400s the whole reply and the user receives nothing.
    func testAHostileConversationTitleCannotBreakTheSwitchReply() throws {
        let target = UUID()
        conversations.rows = [ConversationRow(id: target, title: "fix *bold", timestamp: Date(timeIntervalSince1970: 0), isEmpty: false, boundProfileID: nil)]

        let text = try telegramText(service.switchConversation(to: target))
        XCTAssertTrue(text.contains(#"*fix \*bold*"#), "got: \(text)")
    }

    func testSwitchingToAMissingConversationChangesNothing() throws {
        let view = service.switchConversation(to: UUID())

        XCTAssertEqual(try telegramText(view), "⚠️ Conversation not found.")
        XCTAssertTrue(log.effects.isEmpty, "a failed switch must not move the cursor")
        XCTAssertNil(session.activeConversationID)
    }

    // MARK: - /cancel  (C5b)

    func testCancelWithNoBoundConversationDoesNotReachTheRunControl() async throws {
        let view = await service.cancelRun()

        XCTAssertEqual(try telegramText(view), "No active conversation to cancel.")
        XCTAssertTrue(log.effects.isEmpty)
    }

    func testCancelReportsWhetherARunWasActuallyRunning() async throws {
        let bound = UUID()
        session.activeConversationID = bound
        runControl.busy = [bound]

        let cancelled = await service.cancelRun()
        XCTAssertEqual(try telegramText(cancelled), "🛑 Cancelled the active run for this conversation.")

        // Second cancel: nothing is running any more.
        let idle = await service.cancelRun()
        XCTAssertEqual(try telegramText(idle),
                       "No run is currently active for this conversation — cleared any pending approvals.")
    }

    /// ⚠️ NEITHER branch may be toned `.failure`: `RemoteRenderLog.posted` logs a failure notice at
    /// `.error`, so cancelling an idle conversation would write an error line every time — noise in
    /// the one log a field debugger reads.
    ///
    /// Mutation that must turn this red: tone the idle branch `.failure`.
    func testNeitherCancelBranchIsTonedAsAFailure() async {
        let bound = UUID()
        session.activeConversationID = bound

        guard case .notice(let idle) = await service.cancelRun() else { return XCTFail("expected a notice") }
        XCTAssertEqual(idle.tone, .info)

        runControl.busy = [bound]
        guard case .notice(let cancelled) = await service.cancelRun() else { return XCTFail("expected a notice") }
        XCTAssertEqual(cancelled.tone, .success)
    }

    // MARK: - Clarification  (C8)

    /// ⚠️ THE BLOCKER C8 CLOSES. On Discord and Slack `awaitingClarification` was a stored flag that
    /// **nothing ever set to true**, so `ChatOpsCommand.parse` could never return
    /// `.clarificationResponse` there: a reply to a mirrored clarification parsed as free text and
    /// started a SECOND CONCURRENT RUN while the first stayed parked indefinitely.
    ///
    /// Mutation that must turn this red: return a constant `false`/`nil` — i.e. reinstate the flag.
    func testAParkedClarificationIsVisibleToTheParser() {
        let bound = UUID()
        session.activeConversationID = bound
        XCTAssertFalse(service.isAwaitingClarification, "nothing is parked yet")

        let operation = UUID()
        runControl.clarifications = [bound: operation]

        XCTAssertTrue(service.isAwaitingClarification,
                      "a parked clarification must make the next plain-text reply an ANSWER, not a new run")
        XCTAssertEqual(service.pendingClarificationOperationID(), operation)
    }

    /// Scoped to the BOUND conversation. A clarification parked in some other conversation — a
    /// main-window run, or another provider's — must not swallow this channel's next message.
    func testAClarificationInAnotherConversationDoesNotSwallowThisChannelsReply() {
        let bound = UUID(), elsewhere = UUID()
        session.activeConversationID = bound
        runControl.clarifications = [elsewhere: UUID()]

        XCTAssertFalse(service.isAwaitingClarification)
        XCTAssertNil(service.pendingClarificationOperationID())
    }

    func testWithNoBoundConversationNothingIsAwaited() {
        session.activeConversationID = nil
        runControl.clarifications = [UUID(): UUID()]

        XCTAssertFalse(service.isAwaitingClarification)
        XCTAssertNil(service.pendingClarificationOperationID())
    }

    /// ⚠️ DERIVED AT THE MOMENT OF THE REPLY, never remembered from when the prompt was sent. A run
    /// cancelled in between leaves no pending item, and answering a stale id would resume a
    /// continuation that no longer exists.
    func testTheOperationIdIsRederivedRatherThanRemembered() {
        let bound = UUID(), operation = UUID()
        session.activeConversationID = bound
        runControl.clarifications = [bound: operation]
        XCTAssertEqual(service.pendingClarificationOperationID(), operation)

        // The run is cancelled; the pending item goes with it.
        runControl.clarifications = [:]
        XCTAssertNil(service.pendingClarificationOperationID(),
                     "a stale id here would resume a continuation that no longer exists")
    }

    // MARK: - Profile binding  (C9)

    /// ⚠️ THE DEFECT C9 FIXES, ASSERTED AS THE BUG ITSELF. All three bridges resolved a
    /// conversation's profile by SCANNING `fetchProfiles()` — capped at 500 rows and sorted by
    /// `lastSelected` descending. A conversation bound to a profile the user had not touched
    /// recently resolved to nil, and the remote user was told their conversation had no profile
    /// while their message was dropped. Workflow node-owned rows make 500 reachable: every node
    /// adds one.
    ///
    /// This fake makes the profile reachable ONLY by id, standing for one outside that window.
    ///
    /// Mutation that must turn this red: resolve by scanning `sharedProfiles()` again.
    func testAProfileOutsideTheCappedListStillResolves() {
        let conversation = UUID()
        let distant = agentProfile("Rarely used")
        conversations.rows = [row("Bound", id: conversation, boundProfileID: distant.id)]
        profiles.profiles = []                 // the capped window does not contain it
        profiles.byID = [distant.id: distant]  // but an id-keyed read finds it

        XCTAssertEqual(service.profile(boundTo: conversation)?.id, distant.id, """
            The bound profile was not found. This is the shipped defect: a capped, \
            lastSelected-sorted scan cannot see a profile the user has not touched recently.
            """)
    }

    /// Stronger than the above: the resolver must not consult the capped list AT ALL. Scanning it
    /// and falling back to an id read would pass the test above while keeping the bug's cost.
    func testResolvingABoundProfileNeverTouchesTheCappedList() {
        let conversation = UUID()
        let profile = agentProfile("Bound")
        conversations.rows = [row("Bound", id: conversation, boundProfileID: profile.id)]
        profiles.byID = [profile.id: profile]

        _ = service.profile(boundTo: conversation)

        XCTAssertEqual(profiles.sharedProfilesCallCount, 0,
                       "the bound-profile resolver consulted the 500-row window; it must be id-keyed only")
    }

    func testAnUnboundConversationResolvesToNoProfile() {
        let conversation = UUID()
        conversations.rows = [row("Never bound", id: conversation, boundProfileID: nil)]
        XCTAssertNil(service.profile(boundTo: conversation))
    }

    func testAMissingConversationResolvesToNoProfile() {
        XCTAssertNil(service.profile(boundTo: UUID()))
    }

    /// A dead store must not be reported as "unconfigured" — the binding may be perfectly intact.
    func testADeadStoreDoesNotClaimTheConversationIsUnconfigured() {
        conversations.throwsStoreUnavailable = true
        XCTAssertNil(service.profile(boundTo: UUID()),
                     "nil is correct here, but the log must say the store failed, not that no profile is bound")
    }

    // MARK: - /profiles, /use  (slice 2)

    func testTheProfileListOffersEverySelectableProfile() throws {
        let agent = agentProfile("Coding Agent"), bot = botProfile("Chat Bot")
        profiles.profiles = [agent, bot]

        guard case .chooser(let chooser) = service.profileList() else { return XCTFail("expected a chooser") }
        XCTAssertEqual(chooser.icon, "🧠")
        XCTAssertEqual(chooser.options.map(\.label), ["Coding Agent", "Chat Bot"])
        XCTAssertEqual(chooser.options.map(\.token), [.selectProfile(agent.id), .selectProfile(bot.id)])
        XCTAssertEqual(chooser.options.first?.detail, "Agent · claude", "the row says what it is and what it runs")
    }

    /// ⚠️ `.code` profiles are configured by the Code interface and are never offered in a picker —
    /// the composer's own popover omits them for the same reason.
    func testCodeProfilesAreNotOffered() throws {
        var codeConfig = AgentConfig(llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude"))
        codeConfig.instructions = "code"
        let code = BackendProfileSnapshot(displayName: "Code", details: .code(codeConfig))
        profiles.profiles = [code, agentProfile("Coding Agent")]

        guard case .chooser(let chooser) = service.profileList() else { return XCTFail("expected a chooser") }
        XCTAssertEqual(chooser.options.map(\.label), ["Coding Agent"])
    }

    func testTheProfileListMarksTheOneAlreadyBound() throws {
        let agent = agentProfile("Coding Agent"), bot = botProfile("Chat Bot")
        profiles.profiles = [agent, bot]
        let conversation = UUID()
        session.activeConversationID = conversation
        log.reset()
        conversations.rows = [row("Bound", id: conversation, boundProfileID: bot.id)]

        guard case .chooser(let chooser) = service.profileList() else { return XCTFail("expected a chooser") }
        XCTAssertEqual(chooser.options.map(\.isCurrent), [false, true])
    }

    func testAnEmptyProfileListIsASentenceNotAnEmptyChooser() throws {
        profiles.profiles = []
        guard case .notice(let notice) = service.profileList() else {
            return XCTFail("an empty chooser would render as a bare header")
        }
        XCTAssertTrue(notice.body.contains("No profiles configured"))
    }

    /// ⚠️ THE STATE WRITE LANDS BEFORE THE VIEW IS RETURNED, as everywhere else in this service.
    func testSelectingAProfileBindsItToTheConversationBeforeReplying() throws {
        let agent = agentProfile("Coding Agent")
        profiles.byID = [agent.id: agent]
        let conversation = UUID()
        session.activeConversationID = conversation
        log.reset()

        let view = service.selectProfile(agent.id)

        XCTAssertEqual(log.effects, ["bind"])
        XCTAssertEqual(commanding.bindings.map(\.profile), [agent.id])
        XCTAssertEqual(commanding.bindings.map(\.conversation), [conversation])
        XCTAssertEqual(try telegramText(view), """
        ✅ Now using: *Coding Agent*

        Type your message and it will run under this profile.
        """)
    }

    /// ⚠️ The binding is PERSISTED on the conversation, not written to the app-global composer
    /// selection — a remote write to that would retarget the local user's next send.
    func testBindingNeverTouchesTheComposerSelection() {
        let agent = agentProfile("Coding Agent")
        profiles.byID = [agent.id: agent]
        session.activeConversationID = UUID()
        log.reset()
        commanding.defaultProfileID = UUID()
        let before = commanding.defaultProfileID

        _ = service.selectProfile(agent.id)
        XCTAssertEqual(commanding.defaultProfileID, before, "the Mac composer's selection must not move")
    }

    func testSelectingWithNoConversationAsksForOneAndChangesNothing() throws {
        let agent = agentProfile("Coding Agent")
        profiles.byID = [agent.id: agent]
        session.activeConversationID = nil
        log.reset()

        let view = service.selectProfile(agent.id)
        XCTAssertTrue(try telegramText(view).contains("Run /new first"))
        XCTAssertTrue(log.effects.isEmpty)
    }

    func testSelectingADeletedProfileChangesNothing() throws {
        session.activeConversationID = UUID()
        log.reset()
        let view = service.selectProfile(UUID())
        XCTAssertEqual(try telegramText(view), "⚠️ That profile no longer exists.")
        XCTAssertTrue(log.effects.isEmpty)
    }

    // MARK: /use <name>

    func testUseMatchesAnExactNameCaseInsensitively() {
        let agent = agentProfile("Coding Agent")
        profiles.profiles = [agent]
        session.activeConversationID = UUID()
        log.reset()

        _ = service.useProfile(named: "coding agent")
        XCTAssertEqual(commanding.bindings.map(\.profile), [agent.id])
    }

    func testUseAcceptsAUniquePrefix() {
        let agent = agentProfile("Coding Agent")
        profiles.profiles = [agent, botProfile("Weather Bot")]
        session.activeConversationID = UUID()
        log.reset()

        _ = service.useProfile(named: "cod")
        XCTAssertEqual(commanding.bindings.map(\.profile), [agent.id])
    }

    /// ⚠️ AN AMBIGUOUS PREFIX IS REFUSED, NOT RESOLVED. Silently binding the wrong agent — and then
    /// running the user's next message under it — is worse than asking again.
    func testAnAmbiguousNameIsRefusedRatherThanGuessed() throws {
        profiles.profiles = [agentProfile("Coding Agent"), agentProfile("Coding Reviewer")]
        session.activeConversationID = UUID()
        log.reset()

        let view = service.useProfile(named: "coding")
        XCTAssertTrue(log.effects.isEmpty, "an ambiguous name must not bind anything")
        let text = try telegramText(view)
        XCTAssertTrue(text.contains("matches 2 profiles"), text)
        XCTAssertTrue(text.contains("Coding Agent") && text.contains("Coding Reviewer"))
    }

    /// An EXACT name wins over a prefix that would otherwise be ambiguous — otherwise a profile
    /// named "Code" would be unreachable whenever "Code Reviewer" also existed.
    func testAnExactNameWinsOverAnAmbiguousPrefix() {
        let exact = agentProfile("Code")
        profiles.profiles = [exact, agentProfile("Code Reviewer")]
        session.activeConversationID = UUID()
        log.reset()

        _ = service.useProfile(named: "Code")
        XCTAssertEqual(commanding.bindings.map(\.profile), [exact.id])
    }

    func testUseWithNoNameExplainsItself() throws {
        session.activeConversationID = UUID()
        log.reset()
        let text = try telegramText(service.useProfile(named: "  "))
        XCTAssertTrue(text.contains("/use"), text)
        XCTAssertTrue(log.effects.isEmpty)
    }

    func testUseWithAnUnknownNameChangesNothing() throws {
        profiles.profiles = [agentProfile("Coding Agent")]
        session.activeConversationID = UUID()
        log.reset()

        let view = service.useProfile(named: "nonexistent")
        XCTAssertTrue(try telegramText(view).contains("No profile named"))
        XCTAssertTrue(log.effects.isEmpty)
    }

    // MARK: - The structural rule

    /// ⚠️ The service must never gain a way to post. Its whole guarantee is that a command decides
    /// and the caller renders — a transport or API client here would let a handler send again, which
    /// is how the three bridges came to hold three copies of every verb.
    ///
    /// Mutation that must turn this red: give the service a transport or an api client.
    func testTheServiceCannotPostAnything() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Devgentic/ChatOps/Services/ChatOpsCommandService.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("ChatOpsCommandService.swift not reachable — running outside a checkout")
        }
        let source = try String(contentsOf: url, encoding: .utf8)

        // ⚠️ Comments stripped first: this file's own header says "holds no transport", which a naive
        // substring scan would flag.
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        for forbidden in ["ChatOpsTransport", "TelegramAPIClient", "apiClient", "sendMessage("] {
            XCTAssertFalse(code.contains(forbidden), """
                ChatOpsCommandService mentions `\(forbidden)`. It must hold no transport and no API \
                client: a command decides WHAT to show, the caller decides how to send it. A service \
                that can post is a handler again.
                """)
        }
    }
}

/// The inline keyboard, when the markup IS one.
///
/// ⚠️ `Draft.reply_markup` became type-erased in slice 4 so that Telegram's `ForceReply` — the
/// platform's only structured-input affordance — could be expressed at all. These fixtures still
/// care about buttons, so they unwrap; asserting the KIND is now itself meaningful.
private func inlineKeyboard(_ markup: SendMessagePayload.ReplyMarkup?) -> [[InlineKeyboardButton]]? {
    guard case .inline(let keyboard)? = markup else { return nil }
    return keyboard.inline_keyboard
}
