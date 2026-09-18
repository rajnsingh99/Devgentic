// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsCommandService.swift
//  Devgentic
//
//  Deciding what to show, without knowing how to show it — C5a of the ChatOps remote-interface plan.
//
//  ⚠️ THE ONE STRUCTURAL RULE: THIS TYPE HOLDS NO TRANSPORT AND NO API CLIENT, SO IT CANNOT POST.
//  Every method returns a `RemoteView` and the caller renders it. That is not a convention to be
//  remembered — there is physically nothing here to send with. It is the replacement for twelve
//  `private func … -> Void` handlers that each ran a SwiftData query, built a Telegram widget AND
//  sent the message in one body, which is why the same five verbs exist three times and why
//  `/conversations` already has two different Discord renderings.
//
//  ⚠️ AND IT IS THE FIRST CHATOPS COMMAND LOGIC THAT A TEST CAN DRIVE. Its two dependencies are
//  narrow protocols, so `ChatOpsCommandServiceTests` exercises every verb with no
//  `MainApplicationViewModel` (whose init opens real Telegram/Discord/Slack connections), no
//  SwiftData and no network. The bridges' handlers were unreachable from a test, and being
//  unreachable is why three of them silently diverged and two shipped dead.
//
//  ## Scope: C5a is the READ-ONLY verbs only
//  `/conversations`, `/status` and `/help`. `/new`, `switch:` and `/cancel` all mutate state and
//  move in C5b, so their ordering constraints get their own commit and their own tests. Until then
//  the bridge keeps those arms, along with the ack, the tier-denial send, the four HITL arms and the
//  `registerSession` + `submitRemote` pair — each of which is a transport-level side effect that a
//  `-> RemoteView` return cannot express. Gathering the arms into one exhaustive `execute` switch
//  (so a new `ChatOpsCommand` case becomes a build error rather than silence) is the endgame, and
//  it can only happen once every arm has moved.
//

import Foundation

// MARK: - Session context

/// The two pieces of ChatOps configuration a read-only verb needs.
///
/// ⚠️ A SEAM RATHER THAN `ChatOpsConfigManager` ITSELF, for a concrete reason: that type is a
/// singleton whose cursor now forwards to `RemoteSessionStore.shared`, which is bound to
/// `UserDefaults.standard`. A test that set `activeConversationID` on it would move the DEVELOPER's
/// own ChatOps cursor, and a crash mid-test would leave it moved. Two members, satisfied by
/// `ChatOpsConfigManager` with no code at all.
@MainActor
protocol ChatOpsSessionContext: AnyObject {
    /// ⚠️ SETTABLE as of C5b: `/new` and `switch:` move the cursor. Writing it is what makes the
    /// write-before-post ordering testable — a fake records the assignment, so a test can prove the
    /// state change happened before the view was returned rather than after a send that might fail.
    var activeConversationID: UUID? { get set }
    var securityTier: ChatOpsSecurityTier { get }
}

/// Binds the shared config to ONE provider's cursor.
///
/// ⚠️ WITHOUT THIS THE SERVICE IS TELEGRAM-ONLY. `ChatOpsConfigManager.activeConversationID` IS the
/// Telegram cursor — the Discord and Slack cursors are separate properties — so a service reading
/// the bare property would have moved Discord's conversation by writing Telegram's.
///
/// ⚠️ It writes through `ChatOpsConfigManager`'s provider-specific property rather than straight to
/// `RemoteSessionStore`, even though the store is where both end up. Going direct would bypass the
/// `withMutation(keyPath:)` wrapper and silently drop `@Observable` invalidation. Nothing observes
/// those three today, which is exactly why the loss would go unnoticed until something did.
@MainActor
final class ProviderSessionContext: ChatOpsSessionContext {

    private let provider: RemoteChannel.Provider
    private let config: ChatOpsConfigManager

    init(provider: RemoteChannel.Provider, config: ChatOpsConfigManager = .shared) {
        self.provider = provider
        self.config = config
    }

    var activeConversationID: UUID? {
        get {
            switch provider {
            case .telegram: return config.activeConversationID
            case .discord:  return config.discordActiveConversationID
            case .slack:    return config.slackActiveConversationID
            }
        }
        set {
            switch provider {
            case .telegram: config.activeConversationID = newValue
            case .discord:  config.discordActiveConversationID = newValue
            case .slack:    config.slackActiveConversationID = newValue
            }
        }
    }

    /// ⚠️ PROVIDER-SCOPED, for exactly the reason this type's header gives about the cursor: reading
    /// the bare property would report TELEGRAM's tier on Discord and Slack — which is what `/status`
    /// did, and what every tier refusal message quoted.
    var securityTier: ChatOpsSecurityTier { config.securityTier(for: provider) }
}

// MARK: - Profile reading

/// The picker-safe profile list, as a seam.
@MainActor
protocol ChatOpsProfileReading: AnyObject {
    /// ⚠️ SHARED profiles only — node-owned rows must never be offered anywhere a shared profile is,
    /// and `fetchSharedProfiles()` applies that predicate at the query rather than after the
    /// 500-row cap.
    func sharedProfiles() -> [BackendProfileModel]

    /// One profile by id.
    ///
    /// ⚠️ MUST BE AN UNCAPPED, ID-KEYED READ — never a scan of `sharedProfiles()`. That scan is the
    /// C9 defect: `fetchProfiles()` is capped at 500 rows and sorted by `lastSelected`, so a
    /// conversation bound to a profile outside that window resolved to NOTHING.
    func profile(id: UUID) -> BackendProfileModel?
}

extension BackendProfileStore: ChatOpsProfileReading {
    /// ⚠️ SWALLOWS, deliberately and temporarily. The shipping `resolveProfile()` writes
    /// `(try? fetchSharedProfiles()) ?? []`, so a store failure currently reads as "no agent profile
    /// configured". Preserved here so C5b changes no copy; it is the one place left where a store
    /// error is still reported as a configuration problem, and it wants the same `throws` treatment
    /// `ConversationReading` got — in its own commit, with its own copy decision.
    func sharedProfiles() -> [BackendProfileModel] { (try? fetchSharedProfiles()) ?? [] }

    /// `fetchProfile(byId:)` is the uncapped single-row query — deliberately not `fetchProfiles()`.
    func profile(id: UUID) -> BackendProfileModel? { (try? fetchProfile(byId: id)) ?? nil }
}

// MARK: - Provider mapping

extension RemoteChannel.Provider {
    /// ⚠️ The origin enum owns the conversation TITLE too (`bridgeTitle` == "Telegram Chat"), so
    /// taking it from here deletes a literal that was duplicated three ways while emitting the same
    /// bytes. The pre-CF-39 placeholder fallback matches on that exact string.
    var conversationOrigin: RemoteConversationOrigin {
        switch self {
        case .telegram: return .telegram
        case .discord:  return .discord
        case .slack:    return .slack
        }
    }
}

@MainActor
final class ChatOpsCommandService {

    private let logger = DGLogger(category: "ChatOpsCommands")

    /// ⚠️⚠️ [LIFE-7] WEAK, BECAUSE STRONG RE-CREATED THROUGH THE BACK DOOR THE EXACT RETAIN CYCLE
    /// `ChatOpsCoordinator`'s `weak var viewModel` was written to prevent. The three bridges declare
    /// `weak var viewModel` and then hold THIS service strongly — and this service held the view
    /// model strongly, so the cycle closed: view model → bridge → command service → view model.
    /// `stop()` did not clear `commands` either, so it outlived a disconnect.
    ///
    /// ⚠️ AND THE FIX GOT LARGER TODAY, NOT SMALLER: `submitTurn` routes all free text through this
    /// service, so it is now on the main command path for all three providers rather than a
    /// read-only helper. Both protocols are already `AnyObject`-constrained, so no protocol change
    /// is needed — and deliberately NOT composed into one `RemoteHosting` type, because the tests
    /// inject two separate fakes.
    private weak var runControlRef: (any RemoteRunControlling)?
    private let conversations: any ConversationReading
    /// ⚠️ ONE SERVICE PER PROVIDER. The provider decides the conversation cursor, the recorded
    /// origin and the log attribution, and `session` must be scoped to the SAME one — which is why
    /// the bridge constructs both together rather than passing a provider per call.
    private let provider: RemoteChannel.Provider
    private var session: any ChatOpsSessionContext
    private weak var commandingRef: (any RemoteConversationCommanding)?

    /// ⚠️ Named so the 13 existing call sites read unchanged; the optionality is the point.
    private var runControl: (any RemoteRunControlling)? { runControlRef }
    private var commanding: (any RemoteConversationCommanding)? { commandingRef }

    /// What to post when the host is gone.
    ///
    /// ⚠️⚠️ ANSWERED, NOT SWALLOWED — the `[NEW-4]` rule this file already applies to `attachMirror`.
    /// A bridge can outlive the window it acts for (it is retained by the coordinator, the view model
    /// is not), and a command that silently does nothing is the failure this whole path exists to
    /// avoid: the user sees a bot that stopped answering with no explanation anywhere.
    private func hostLost(_ verb: String) -> RemoteView {
        logger.error("[CHATOPS] A \(provider.rawValue) \(verb) could not run: the app's main view model was deallocated while this bridge was still listening. CONSEQUENCE: the command is REFUSED and the user is told, rather than silently doing nothing. The bridge has outlived the window it acts for and should have been stopped.")
        return .notice(Notice(tone: .failure,
                              body: "⚠️ Devgentic's main window is no longer available, so that command could not run. Reopen the app and try again."))
    }
    private let profiles: any ChatOpsProfileReading
    private let recordOrigin: (RemoteConversationOrigin, UUID) -> Void

    /// ⚠️ `conversations` is its OWN parameter rather than being reached through the view model's
    /// `persistenceService`. That property is typed `ChatPersistenceProtocol`, which
    /// `ConversationReading` deliberately is not part of, so an `as?` cast would compile and then
    /// silently return nil against any injected stub — `/conversations` and `/status` would answer
    /// nothing at all, with no error.
    init(
        provider: RemoteChannel.Provider,
        runControl: any RemoteRunControlling,
        commanding: any RemoteConversationCommanding,
        conversations: any ConversationReading,
        profiles: any ChatOpsProfileReading = BackendProfileStore.shared,
        session: (any ChatOpsSessionContext)? = nil,
        recordOrigin: @escaping (RemoteConversationOrigin, UUID) -> Void = RemoteConversationOriginStore.record
    ) {
        self.provider = provider
        self.runControlRef = runControl
        self.commandingRef = commanding
        self.conversations = conversations
        self.profiles = profiles
        self.session = session ?? ProviderSessionContext(provider: provider)
        self.recordOrigin = recordOrigin
    }

    // MARK: - /conversations

    /// ⚠️ How many the list shows. Ten, transcribed from `fetchRecentConversations(limit: 10)` at
    /// the shipping call site — not a new product decision.
    /// Conversations per page.
    ///
    /// ⚠️ TEN FITS EVERY PLATFORM WITH ROOM FOR THE PAGING BUTTONS. Discord and Slack both cap a
    /// message at 25 buttons; ten rows plus Previous, Next and New Conversation is thirteen.
    /// Telegram allows a hundred, so the tightest cap governs — the same reasoning that makes
    /// Telegram's 64-byte payload budget bind the shared callback grammar.
    static let conversationListLimit = 10

    /// - Parameter offset: how many of the newest conversations to skip. Zero is the first page.
    ///
    /// ⚠️ REQUIRED, NOT DEFAULTED. Every caller states which page it wants, so a bridge cannot page
    /// by accident or fail to page by omission.
    func conversationList(offset: Int) -> RemoteView {
        let page: [ConversationRow]
        do {
            // ⚠️ ONE MORE ROW THAN WE SHOW. The extra row is how we learn whether a "Next" button
            // belongs, without a count query — counting would materialise every conversation's
            // messages and derive every title just to produce a number we compare against a page
            // size. The extra row is discarded below and never rendered.
            page = try conversations.conversationRows(limit: Self.conversationListLimit + 1, offset: offset)
        } catch {
            return Self.storeUnavailableNotice(while: "listing your conversations", logger: logger, error: error)
        }

        let hasNextPage = page.count > Self.conversationListLimit
        let rows = Array(page.prefix(Self.conversationListLimit))

        // ⚠️ THE EMPTY CASE IS A NOTICE, NOT AN EMPTY CHOOSER. A chooser with no options renders as
        // its heading alone, so handing one over here would silently replace this sentence with a
        // bare "📋 *Your Conversations:*" — no error, no failing test. Producing the empty-state copy
        // is this method's job; the renderer never invents it.
        guard !rows.isEmpty else {
            // ⚠️ AN EMPTY LATER PAGE IS NOT AN EMPTY LIST. Telling a user with fifty conversations
            // "No conversations yet. Use /new to create one." because they tapped a stale Next
            // button would be the same class of lie as the store-down copy this method already
            // avoids — and it would invite them to create a conversation they do not need.
            guard offset == 0 else {
                logger.info("[CHATOPS] A conversation page at offset \(offset) came back empty. CONSEQUENCE: the user is told the list has changed rather than that they have no conversations; this happens when a paging button outlives the rows it was posted for.")
                return .notice(Notice(
                    tone: .info,
                    body: "That page is empty now — the list has changed since this button was posted. Use /conversations to start again."))
            }
            return .notice(Notice(tone: .info, body: "No conversations yet. Use /new to create one."))
        }

        let active = session.activeConversationID

        // ⚠️ THE RANGE IS SHOWN ONLY WHEN PAGING. On the first page it would be noise; past it, a
        // list that silently starts at the eleventh newest conversation is indistinguishable from
        // a list that has lost rows.
        let heading = offset == 0
            ? "Your Conversations:"
            : "Your Conversations (\(offset + 1)–\(offset + rows.count)):"

        var extras: [Chooser.Option] = []
        if offset > 0 {
            extras.append(Chooser.Option(
                label: "◂ Previous",
                token: .conversationPage(offset: max(0, offset - Self.conversationListLimit))))
        }
        if hasNextPage {
            extras.append(Chooser.Option(
                label: "Next ▸",
                token: .conversationPage(offset: offset + Self.conversationListLimit)))
        }
        extras.append(Chooser.Option(label: "➕ New Conversation", token: .action(.new), intent: .primary))

        return .chooser(Chooser(
            icon: "📋",
            title: heading,
            options: rows.map { row in
                Chooser.Option(
                    label: row.title,
                    token: .switchConversation(row.id),
                    // ⚠️ A FLAG. The bridges prepend "⭐ " to the label string here; keeping it a
                    // flag is what leaves Slack's native `initial_option` reachable later.
                    isCurrent: row.id == active
                )
            },
            extraActions: extras
        ))
    }

    // MARK: - /status

    /// ⚠️ The count's window. One hundred, transcribed from `fetchRecentConversations(limit: 100)`
    /// at the shipping `/status` call site — so "Total Conversations" has always meant "of the 100
    /// most recent", and this preserves that rather than quietly making it exact.
    static let statusCountLimit = 100

    /// What a field reads when the store could not answer it.
    ///
    /// ⚠️ ONE literal, because the failure is one event: `/status` reporting a real title beside an
    /// "unavailable" count (or the reverse) would tell the user the store is half-working.
    static let unavailable = "unavailable"

    func status() -> RemoteView {
        let activeID = session.activeConversationID

        // ⚠️ Conversation-scoped, not app-global. `/status` once read `vm.streamingMessageID` and so
        // reported "streaming" whenever ANY conversation was busy, including a main-window run the
        // remote user has nothing to do with.
        let isStreaming = activeID.flatMap { runControl?.hasActiveRun(inConversation: $0) } ?? false
        let hitlPending = activeID.flatMap { runControl?.pendingClarificationID(inConversation: $0) } != nil

        // ⚠️ The active conversation's title cannot come from the list above: a conversation older
        // than that window would render as "None" while still being active.
        //
        // ⚠️ "None" MEANS "NO CURSOR", NEVER "THE READ FAILED". Those are different facts and this
        // variable used to conflate them: it was initialised to "None" and only overwritten on a
        // SUCCESSFUL read, so a dead store reported `Active Conversation: None` beside
        // `Total Conversations: unavailable` — one honest field and one lie, in the same reply,
        // from the same catch. A user acting on "None" runs /new and creates a duplicate of the
        // conversation they were already in.
        var activeTitle = activeID == nil ? "None" : Self.unavailable
        var totalConversations: String
        var storeAnswered = true
        do {
            if let activeID {
                // ⚠️ A SUCCESSFUL READ THAT FINDS NOTHING IS STILL "None". The cursor outliving its
                // conversation (deleted on the Mac) is a different fact from the store being down,
                // and reporting "unavailable" for it would send the user looking for an outage.
                activeTitle = try conversations.conversationRow(id: activeID)?.title ?? "None"
            }
            totalConversations = String(try conversations.conversationRows(limit: Self.statusCountLimit, offset: 0).count)
        } catch {
            // ⚠️ DELIBERATE DIVERGENCE, RECORDED. The shipping handler writes
            // `(try? context.fetch(...)) ?? []`, so a dead store reports "Total Conversations: 0" —
            // indistinguishable from a genuinely empty history. Saying "unavailable" is the whole
            // reason `ConversationReading` throws; reporting 0 here would re-tell the lie C1 removed.
            logger.error("[CHATOPS] /status could not read conversations: \(error.localizedDescription). CONSEQUENCE: both the active conversation and the count read \"unavailable\" instead of \"None\" and 0, so the remote user is not told they have no history — or no active conversation — when the store is simply down.")
            totalConversations = Self.unavailable
            storeAnswered = false
        }

        // [Slice 2] Which profile answers here. Previously invisible remotely: `/new` picked one and
        // never said which, so a user could not tell what was about to run.
        //
        // ⚠️ RESOLVED AFTER THE READ ABOVE, AND GATED ON IT. `profile(boundTo:)` swallows a store
        // failure and returns nil, which falls to "Default" — the name of a real fallback. With the
        // store down that put a THIRD description of one outage in a single reply: an "unavailable"
        // count, an "unavailable" title, and a profile the user would reasonably believe is running.
        let boundProfileName = storeAnswered
            ? (activeID.flatMap { profile(boundTo: $0)?.displayName } ?? "Default")
            : Self.unavailable

        return .notice(Notice(
            tone: .info,
            icon: "📊",
            title: "Devgentic Status",
            fields: [
                .spacer,
                .init(label: "🗣 Active Conversation", value: activeTitle),
                .init(label: "🧠 Profile", value: boundProfileName),
                .init(label: "⚡ Agent Streaming", value: isStreaming ? "Yes" : "No"),
                .init(label: "🔐 Security Tier", value: session.securityTier.rawValue),
                .init(label: "⏳ HITL Pending", value: hitlPending ? "Yes" : "No"),
                .init(label: "📋 Total Conversations", value: totalConversations),
            ]
        ))
    }

    // MARK: - /help

    /// ⚠️⚠️ THIS COMMENT USED TO SAY THE OPPOSITE OF THE CODE BENEATH IT. It read: "the command
    /// lines are transcribed from the shipping literal rather than generated from
    /// `ChatOpsVerbTable`. Generating them would change the copy … Deriving help from the table is a
    /// product decision for its own commit." That commit happened — the list fourteen lines below is
    /// built from `ChatOpsVerb.presentationOrder` — and the comment was left behind describing a
    /// design that no longer existed, three lines above the code that contradicted it.
    ///
    /// ⚠️ THE OBJECTION IT RAISED WAS REAL AND IS ANSWERED BY `usage`. The worry was that the table
    /// carries aliases (`/convos`, `/stop`, `/start`) this text has never advertised, so generating
    /// from it would change the copy. `ChatOpsVerb.usage` emits the CANONICAL name only, so the
    /// aliases stay reachable and stay unlisted — which is why deriving the list was safe.
    ///
    /// ⚠️ AND DERIVING IT FIXED A REAL DEFECT. The hand-written list had drifted to seven entries
    /// against a table of eight, so a shipped command was undiscoverable in the one place users go
    /// to learn what exists. A verb added to the table is now advertised without touching this file.
    func help() -> RemoteView {
        .notice(Notice(
            tone: .info,
            icon: "🤖",
            title: "Devgentic ChatOps",
            fields: [
                .spacer,
                .init(value: "Commands:", emphasis: true),
            ]
            // ⚠️ DERIVED FROM THE TABLE, not hand-written. This list was seven literals against a
            // table of eight verbs, so a shipped command was undiscoverable — the exact drift the
            // catalogue exists to prevent, reappearing in the one place users go to learn what
            // exists. A verb added to the table is now advertised without touching this file.
            + ChatOpsVerb.presentationOrder.map { verb in
                Notice.Field(value: "\(verb.usage) — \(verb.helpDescription)")
            }
            + [
                .spacer,
                .init(value: "How it works:", emphasis: true),
                .init(value: "1. Use /conversations to pick a conversation"),
                .init(value: "2. Type your message — it routes to the agent"),
                .init(value: "3. The agent responds right here"),
                .spacer,
                .init(label: "Security Tier", value: session.securityTier.rawValue, labelEmphasis: true),
                // AGPL §13: everyone who reaches this app over a network is offered its source. It
                // lives in the DEFAULT reply so an operator running a modified build inherits a
                // compliant `/help` without editing anything. See `GlobalConstants.sourceCodeURL`.
                .init(label: "Source", value: "\(GlobalConstants.sourceCodeURL) · GNU AGPL v3", labelEmphasis: true),
            ]
        ))
    }

    // MARK: - /new  (C5b)

    /// ⚠️ EVERY STATE WRITE HAPPENS BEFORE THIS RETURNS, which is the ordering the shipping handler
    /// has and a render-then-apply pipeline would lose. The cursor and the Mac-window selection are
    /// written first; only then is the view handed back to be posted. Reversing it means a failed
    /// send leaves the cursor unmoved while the user has been told it moved — and the next `/status`
    /// or free-text message goes to the wrong conversation.
    func newConversation() -> RemoteView {
        guard let profile = Self.defaultProfile(from: profiles.sharedProfiles(), selected: commanding?.defaultProfileID) else {
            return .notice(Notice(tone: .warning, body: "⚠️ No agent profile configured. Set one in Devgentic Settings."))
        }

        let reusable: UUID?
        do {
            reusable = try conversations.reusableEmptyConversationID(preferring: session.activeConversationID)
        } catch {
            return Self.storeUnavailableNotice(while: "looking for a conversation to reuse", logger: logger, error: error)
        }

        if let reusedID = reusable {
            session.activeConversationID = reusedID
            commanding?.focusConversationInMainWindow(reusedID)
            // ⚠️ No origin record on the reuse branch — the conversation already has whatever
            // provenance it was created with, and stamping it here would relabel a locally-created
            // conversation as remote.
            logger.info("[ChatOps] Reused empty conversation \(reusedID.uuidString) instead of creating a new one, via \(provider.rawValue).")
            return .notice(Notice(
                tone: .success,
                body: "✅ Switched to existing empty conversation.",
                fields: [.init(value: "Just type your message to start.")]
            ))
        }

        let origin = provider.conversationOrigin

        // ⚠️ CREATED WITH NO TITLE, DELIBERATELY — this used to stamp `origin.bridgeTitle`, so every
        // conversation ever started from chat was called "Telegram Chat", "Discord Chat" or "Slack
        // Chat" FOREVER. The auto-title path that names a conversation after the user's first
        // message (`MessagingCoordinator`, both send paths) only fires when the title is nil or
        // EMPTY, and a stamped constant is neither — so remote conversations were the one corpus in
        // the app that never got a meaningful name. `/conversations` listed them as N identical
        // rows, and a title search over them could only ever match one of three constants.
        //
        // ⚠️ THE STAMP WAS NOT LOAD-BEARING FOR ORIGIN. `recordOrigin` below writes the origin to a
        // side store keyed by conversation id (CF-39), and `RemoteConversationOriginStore.origin(for:)`
        // reads it from there. `ChatHistoryView`'s `bridgeTitle == title` match is documented as the
        // fallback for conversations created BEFORE origins were recorded; those keep their stamped
        // titles and keep resolving. Only new conversations change, and they change to being named
        // after what the user actually said.
        guard let commanding else { return hostLost("/new") }
        let conversationID = commanding.createConversation(profile: profile, title: "")
        // [CF-39] Recorded while it is a FACT, before anything can rename the conversation — and
        // BEFORE the cursor moves, matching the shipping order.
        recordOrigin(origin, conversationID)
        session.activeConversationID = conversationID
        commanding.focusConversationInMainWindow(conversationID)
        logger.info("[ChatOps] Mac UI navigated to new conversation \(conversationID.uuidString).")
        logger.info("[ChatOps] Created new conversation via \(provider.rawValue): \(conversationID.uuidString).")

        return .notice(Notice(
            tone: .success,
            body: "✅ New conversation created and set as active.",
            fields: [.init(value: "Just type your message to start.")]
        ))
    }

    /// Which profile a new remote conversation runs under: the composer's current selection if it is
    /// still a shared profile, else the first agent profile, else the first profile at all.
    ///
    /// `nonisolated static` over plain values — the `RunAdmissionPolicy` shape — so the preference
    /// order is testable with no store and no view model.
    nonisolated static func defaultProfile(
        from profiles: [BackendProfileModel],
        selected: UUID?
    ) -> BackendProfileModel? {
        if let selected, let profile = profiles.first(where: { $0.id == selected }) {
            return profile
        }
        return profiles.first { $0.profileType == .agent } ?? profiles.first
    }

    // MARK: - switch:<uuid>  (C5b)

    func switchConversation(to conversationID: UUID) -> RemoteView {
        let row: ConversationRow?
        do {
            row = try conversations.conversationRow(id: conversationID)
        } catch {
            // ⚠️ DELIBERATE DIVERGENCE. Today a dead store makes the lookup return nil, so the user
            // is told the conversation was "not found" — a lie about their data. Same class as the
            // other two store-down cases.
            return Self.storeUnavailableNotice(while: "opening that conversation", logger: logger, error: error)
        }
        guard let row else {
            return .notice(Notice(tone: .warning, body: "⚠️ Conversation not found."))
        }

        session.activeConversationID = conversationID
        commanding?.focusConversationInMainWindow(conversationID)
        logger.info("[ChatOps] Mac UI navigated to conversation \(conversationID.uuidString).")
        logger.info("[ChatOps] Switched to conversation \(conversationID.uuidString) via \(provider.rawValue).")

        // ⚠️ The title is a FIELD, not interpolated into `body`: it is user-controlled, so it must be
        // escaped, and `inline` is what keeps `✅ Switched to: *<title>*` on one line.
        return .notice(Notice(
            tone: .success,
            body: "✅ Switched to:",
            fields: [
                .init(value: row.title, emphasis: true, inline: true),
                .spacer,
                .init(value: "Just type your message to continue."),
            ]
        ))
    }

    // MARK: - /cancel  (C5b)

    /// ⚠️ `runControl.cancelRun` bundles the [WF-SE10] three-step ordering — read activity, cancel
    /// the stream, then clear any parked suspension — precisely so this method cannot reorder it.
    /// The reply text depends on the activity read, which is why it must happen before the cancel.
    func cancelRun() async -> RemoteView {
        guard let conversationID = session.activeConversationID else {
            return .notice(Notice(tone: .info, body: "No active conversation to cancel."))
        }

        let hadActiveRun = await runControl?.cancelRun(inConversation: conversationID) ?? false
        logger.info("[CHATOPS] /cancel via \(provider.rawValue) for conversation \(conversationID.uuidString) — hadActiveRun=\(hadActiveRun). CONSEQUENCE: the stream task itself was cancelled (not just the parked HITL), so the run stops instead of continuing after the bot claims it was cancelled.")

        // ⚠️ NOT `.failure` on either branch: `RemoteRenderLog.posted` logs a failure notice at
        // `.error`, and cancelling an idle conversation is a normal outcome, not an error.
        return .notice(Notice(
            tone: hadActiveRun ? .success : .info,
            body: hadActiveRun
                ? "🛑 Cancelled the active run for this conversation."
                : "No run is currently active for this conversation — cleared any pending approvals."
        ))
    }

    // MARK: - Profile binding  (C9)

    /// The profile a conversation runs under.
    ///
    /// ⚠️⚠️ THIS FIXES A LIVE DEFECT THAT WAS DUPLICATED THREE WAYS. Every bridge's
    /// `resolveProfileForConversation` did:
    ///
    ///     ((try? BackendProfileStore.shared.fetchProfiles()) ?? []).first { $0.id == profileID }
    ///
    /// `fetchProfiles()` is capped at 500 rows and sorted by `lastSelected` descending, so a
    /// conversation bound to a profile the user had not touched recently — trivially reachable once
    /// workflow node-owned rows are counted, since every node adds one — resolved to nil. The
    /// remote user then got "⚠️ No agent profile configured for this conversation." for a
    /// conversation that plainly had one, and their message was dropped.
    ///
    /// The id-keyed read is uncapped, so the window cannot bite.
    func profile(boundTo conversationID: UUID) -> BackendProfileModel? {
        let row: ConversationRow?
        do {
            row = try conversations.conversationRow(id: conversationID)
        } catch {
            logger.error("[CHATOPS] Could not read conversation \(conversationID.uuidString.prefix(8)) while resolving its profile: \(error.localizedDescription). CONSEQUENCE: the run is refused as unconfigured even though the binding may be intact.")
            return nil
        }
        guard let profileID = row?.boundProfileID else { return nil }
        return profiles.profile(id: profileID)
    }

    // MARK: - Submitting a turn  (BR-4)

    /// Admits or refuses a remote free-text turn, and submits it when admitted.
    ///
    /// ⚠️⚠️ THE THREE STEPS ARE ONE METHOD SO THEIR ORDER CANNOT BE GOT WRONG — the same reasoning
    /// as `RemoteRunControlling.cancelRun`. They must run as: decide, then register the mirror
    /// session, then submit. Registering before deciding attaches a remote session to a run that is
    /// about to be refused; submitting before registering races the mirror against the first
    /// streamed token. Exposing the steps separately would let each of the three bridges order them
    /// differently, which is precisely how this subsystem acquired three copies of every other bug.
    ///
    /// ⚠️ IT LIVES HERE, NOT IN THE BRIDGES, FOR ONE REASON: THE BRIDGES ARE NOT TESTABLE. They
    /// construct their own API client, listener and transport inside `start()` and hold a `weak var
    /// viewModel: MainApplicationViewModel?`, so nothing can stand one up and watch what it submits.
    /// `ChatOpsCommandService` takes `runControl` and `commanding` as injected seams, so a test can
    /// report an active run through one and count the submits that reach the other — and a test of
    /// `RemoteTurnAdmission.decide` alone would stay green for a bridge that never called it.
    ///
    /// - Parameter attachMirror: attaches the mirror to this conversation and reports whether it
    ///   actually managed to. A closure because the transport is the one thing only the bridge holds.
    ///   ⚠️ NOT CALLED ON A REFUSAL.
    ///
    ///   ⚠️⚠️ [NEW-4] IT RETURNS `Bool` BECAUSE `Void` LET IT LIE. This was `() -> Void` and the doc
    ///   comment claimed the registration was unconditional, but every bridge passed a fully
    ///   optional-chained body — `self?.remoteMirrorService?.registerSession(...)` — so a nil weak
    ///   self, a nil mirror or (on Discord and Slack) a nil transport made it a silent no-op. The
    ///   turn was then submitted anyway: the run streamed to the Mac, spent tokens, possibly ran
    ///   tools, and the remote user waited forever with nothing logged at any layer. A closure that
    ///   cannot report failure cannot be checked, so the caller could not have handled it.
    /// - Returns: `.admitted` when the turn was submitted, `.refused` with the copy to post when it
    ///   was not. ⚠️ The bridge MUST post a refusal: a silently dropped prompt is the failure this
    ///   whole path exists to avoid.
    @discardableResult
    func submitTurn(prompt: String,
                    conversationID: UUID,
                    source: MessageSource,
                    config: BackendRequestConfig,
                    attachMirror: () -> Bool) -> RemoteTurnAdmission.Decision {

        let decision = RemoteTurnAdmission.decide(
            hasActiveRun: runControl?.hasActiveRun(inConversation: conversationID) ?? false
        )

        guard case .admitted = decision else {
            logger.warning("[CHATOPS] A \(provider.rawValue) prompt for conversation \(conversationID.uuidString.prefix(8)) was REFUSED because a run is already streaming there. CONSEQUENCE: it was not submitted and the user was told to /cancel or wait; before this check a second prompt started a second root run in the same conversation, so two answers interleaved into one chat, /cancel silently killed both, and a clarification answer could resolve the wrong run's question.")
            return decision
        }

        // ⚠️ [NEW-3/NEW-4] THE SUBMIT IS CONDITIONAL ON THE MIRROR, and that ordering is the fix: a
        // run nobody can hear from is not worth starting. Checked BEFORE `submitRemote` so a failed
        // attachment costs nothing at all.
        guard attachMirror() else {
            logger.error("[CHATOPS] A \(provider.rawValue) prompt for conversation \(conversationID.uuidString.prefix(8)) was REFUSED because the mirror could not be attached — the transport or the mirror service was unavailable. CONSEQUENCE: nothing was submitted and the user was told, which is deliberate: submitting anyway would run the agent on the Mac, spend tokens and possibly run tools while the remote user watched a chat that never answered.")
            return RemoteTurnAdmission.mirrorUnavailable
        }

        // ⚠️ [LIFE-7 + NEW-4] A lost host cannot submit, and a turn that cannot run must be REFUSED
        //   rather than reported as started — the same rule `attachMirror` follows above.
        guard let commanding else {
            logger.error("[CHATOPS] A \(provider.rawValue) prompt for conversation \(conversationID.uuidString.prefix(8)) was REFUSED because the app's main view model was deallocated while this bridge was still listening. CONSEQUENCE: nothing was submitted and the user is told, rather than waiting for an answer to a run that could never start.")
            return RemoteTurnAdmission.hostUnavailable
        }

        commanding.submitRemote(
            prompt: prompt,
            conversationID: conversationID,
            source: source,
            config: config
        )
        return .admitted
    }

    // MARK: - Profiles  (slice 2)

    /// How many profiles the list offers. Ten, matching `/conversations` — a chat list is a picker,
    /// not a directory, and `/use <name>` covers anything past it.
    static let profileListLimit = 10

    /// The profiles a remote user may choose from.
    ///
    /// ⚠️ SELECTION ONLY. Creating, editing, duplicating and deleting a profile stay local: a
    /// profile carries provider credentials, and the create flow immediately needs a model picker
    /// and an API key — neither of which belongs in a third-party chat client.
    ///
    /// ⚠️ SECRETS CANNOT REACH THE VIEW, AND THE COMPILER ENFORCES IT. `BackendProfileSnapshot`
    /// carries the DECRYPTED provider API key (its `details` getter injects it from the Keychain)
    /// and was deliberately made non-`Codable` for that reason; `RemoteView` requires `Codable`, so
    /// a profile object literally cannot be placed in one. Only the projected strings below travel.
    func profileList() -> RemoteView {
        // ⚠️ `sharedProfiles()` excludes node-owned rows at the query. `.code` is excluded here for
        // the same reason the composer picker omits it: it is configured by the Code interface and
        // is not a thing a user picks from a list.
        let selectable = profiles.sharedProfiles().filter { $0.profileType != .code }

        guard !selectable.isEmpty else {
            return .notice(Notice(
                tone: .info,
                body: "No profiles configured yet. Create one in Devgentic, then run /profiles again."
            ))
        }

        let boundID = session.activeConversationID.flatMap { conversationID -> UUID? in
            (try? conversations.conversationRow(id: conversationID))??.boundProfileID
        }

        return .chooser(Chooser(
            icon: "🧠",
            title: "Choose a Profile:",
            options: selectable.prefix(Self.profileListLimit).map { profile in
                Chooser.Option(
                    label: profile.displayName,
                    detail: Self.subtitle(for: profile),
                    token: .selectProfile(profile.id),
                    isCurrent: profile.id == boundID
                )
            }
        ))
    }

    /// The one-line description under a profile's name.
    ///
    /// ⚠️ A DELIBERATE RE-DERIVATION, not a reuse. The composer's equivalent
    /// (`ProfileSelectorPopover.detailText`) is `fileprivate static` and unreachable, and its
    /// workflow arm reaches `WorkflowLayoutStore.shared` for a node count — a store this service has
    /// no business holding. Kind and model are what a remote picker needs.
    nonisolated static func subtitle(for profile: BackendProfileModel) -> String? {
        switch profile.details {
        case .bot(let config):      return "Bot · \(config.llmConfig.modelName)"
        case .agent(let config):    return "Agent · \(config.llmConfig.modelName)"
        case .imageGen(let config): return "Image · \(config.llmConfig.modelName)"
        case .code(let config):     return "Code · \(config.llmConfig.modelName)"
        case .workflow:             return "Workflow"
        }
    }

    /// Binds a profile chosen from the list to the channel's conversation.
    func selectProfile(_ profileID: UUID) -> RemoteView {
        guard let profile = profiles.profile(id: profileID) else {
            return .notice(Notice(tone: .warning, body: "⚠️ That profile no longer exists."))
        }
        return bind(profile)
    }

    /// Binds a profile by name, for users who would rather type than tap.
    func useProfile(named name: String) -> RemoteView {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .notice(Notice(
                tone: .info,
                body: "Name a profile, like /use Coding Agent — or run /profiles to pick one."
            ))
        }

        let selectable = profiles.sharedProfiles().filter { $0.profileType != .code }
        // Exact match first, then a unique case-insensitive prefix. ⚠️ An AMBIGUOUS prefix is
        // refused rather than resolved: silently binding the wrong agent is worse than asking again.
        if let exact = selectable.first(where: { $0.displayName.caseInsensitiveCompare(query) == .orderedSame }) {
            return bind(exact)
        }
        let matches = selectable.filter { $0.displayName.lowercased().hasPrefix(query.lowercased()) }
        switch matches.count {
        case 0:
            return .notice(Notice(tone: .warning, body: "⚠️ No profile named \"\(query)\". Run /profiles to see the list."))
        case 1:
            return bind(matches[0])
        default:
            return .notice(Notice(
                tone: .warning,
                body: "⚠️ \"\(query)\" matches \(matches.count) profiles:",
                fields: matches.prefix(5).map { .init(value: $0.displayName) }
                    + [.spacer, .init(value: "Use the full name, or run /profiles to pick one.")]
            ))
        }
    }

    /// ⚠️ THE STATE WRITE HAPPENS BEFORE THE VIEW IS RETURNED, as everywhere else in this service.
    private func bind(_ profile: BackendProfileModel) -> RemoteView {
        guard let conversationID = session.activeConversationID else {
            return .notice(Notice(
                tone: .warning,
                body: "⚠️ No active conversation. Run /new first, then choose a profile."
            ))
        }
        commanding?.bindProfile(profile.id, toConversation: conversationID)
        logger.info("[CHATOPS] Bound profile \(profile.id.uuidString) to conversation \(conversationID.uuidString) via \(provider.rawValue). CONSEQUENCE: every subsequent free-text message in this conversation runs under that profile, on the Mac as well as remotely.")

        return .notice(Notice(
            tone: .success,
            body: "✅ Now using:",
            fields: [
                .init(value: profile.displayName, emphasis: true, inline: true),
                .spacer,
                .init(value: "Type your message and it will run under this profile."),
            ]
        ))
    }

    // MARK: - History  (slice 5)

    /// How many turns `/history` shows when the user gives no number.
    static let historyDefaultCount = 6
    /// The most it will show, whatever they ask for.
    ///
    /// ⚠️⚠️ THE ARITHMETIC HERE USED TO BE WRONG, IN BOTH DIRECTIONS. It read: "20 because every
    /// line is escaped, joined and sent as ONE message: Telegram caps a message at 4096 characters
    /// … 20 lines × a 200-character preview plus icons sits inside that with room for the heading."
    /// It does not — 20 × (200 + `…` + icon + space) plus separators and the heading is about
    /// 4 130, over Telegram's 4 096 before escaping adds a backslash per metacharacter. And it
    /// considered only Telegram: `render` posts through the UNCHUNKED `sendMessage`, so Discord's
    /// 2 000-character `content` cap was already exceeded at TEN turns and Slack's 3 000-character
    /// section-block cap at about fifteen. An over-long reply was not truncated, it was rejected,
    /// and the remote user received nothing.
    ///
    /// ⚠️ SO THIS NUMBER IS NO LONGER LOAD-BEARING FOR DELIVERY. `RemoteTextBudget` enforces each
    /// platform's real limit at render time and says how many lines it dropped. 20 stays as the
    /// PRODUCT bound — the point past which a chat transcript stops being readable — and the user
    /// is told when it bites, by the heading below and by the renderer's own marker.
    static let historyMaxCount = 20

    func conversationHistory(argument: String) -> RemoteView {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)

        let count: Int
        if trimmed.isEmpty {
            count = Self.historyDefaultCount
        } else if let requested = Int(trimmed), requested > 0 {
            // ⚠️ CLAMPED, and the user is told below when the clamp bit — silently showing 20 of the
            // 500 they asked for reads as "that is all there is".
            count = min(requested, Self.historyMaxCount)
        } else {
            // ⚠️ A USAGE HINT, NOT `.unknown`. A typed argument is a human making a typo; answering
            // "unknown command" for `/history five` sends them looking for the wrong problem.
            return .notice(Notice(
                tone: .info,
                body: "How many turns? For example: /history 10 (up to \(Self.historyMaxCount))."))
        }

        guard let conversationID = session.activeConversationID else {
            return .notice(Notice(
                tone: .info,
                body: "No conversation is active. Use /conversations to pick one, or /new to start one."))
        }

        let rows: [ConversationMessageRow]
        do {
            rows = try conversations.recentMessages(inConversation: conversationID, limit: count)
        } catch {
            return Self.storeUnavailableNotice(while: "reading this conversation's history", logger: logger, error: error)
        }

        guard !rows.isEmpty else {
            return .notice(Notice(tone: .info, body: "This conversation has no messages yet."))
        }

        // ⚠️ ESCAPING IS WHAT MATTERS HERE, AND `NoticeText.build` DOES IT FOR BOTH `body` AND
        // `fields` — an earlier version of this comment claimed fields were required for it, which
        // is false and would have sent the next reader hunting a safety property that does not
        // depend on this choice. Message text IS the most hostile content this app sends (a stray
        // `*` or `_` from an agent reply under Telegram's Markdown parse mode is a 400 that makes
        // the whole message vanish), and it is escaped either way.
        //
        // Fields are used because a transcript is a LIST: it keeps each line addressable, and it is
        // how every other structured notice in this service is built.
        let lines = rows.map { row in
            Notice.Field(value: "\(row.isFromUser ? "👤" : "🤖") \(row.text)")
        }

        var heading = "Last \(rows.count) message(s):"
        if !trimmed.isEmpty, let requested = Int(trimmed), requested > Self.historyMaxCount {
            heading = "Last \(rows.count) message(s) — \(requested) is above the \(Self.historyMaxCount) limit:"
        }

        return .notice(Notice(
            tone: .info,
            icon: "🕘",
            title: heading,
            fields: [.spacer] + lines
        ))
    }

    // MARK: - Search  (slice 5)

    /// Conversations whose title matches `query`.
    func searchConversations(query: String) -> RemoteView {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // ⚠️ A USAGE HINT, NOT THE WHOLE LIST. `/search` with no query is a user who forgot it;
            // answering with every conversation would look like the query was ignored.
            return .notice(Notice(
                tone: .info,
                body: "Give me something to look for — for example: /search deploy"))
        }

        let result: ConversationSearchResult
        do {
            result = try conversations.searchConversations(matching: trimmed, limit: Self.conversationListLimit)
        } catch {
            return Self.storeUnavailableNotice(while: "searching your conversations", logger: logger, error: error)
        }

        guard !result.rows.isEmpty else {
            // ⚠️ "NOTHING MATCHED" AND "I ONLY LOOKED AT THE NEWEST 200" ARE DIFFERENT FACTS, and a
            // remote user acts on the first by concluding the conversation is gone. The scan bound
            // is disclosed rather than hidden behind a confident empty result.
            let body = result.scanWasTruncated
                ? "No conversation title matches “\(trimmed)” in your most recent \(ChatPersistenceStore.searchScanLimit) conversations. Older ones were not searched."
                : "No conversation title matches “\(trimmed)”."
            return .notice(Notice(tone: .info, body: body))
        }

        let active = session.activeConversationID
        var heading = "Matching “\(trimmed)”:"
        if result.scanWasTruncated {
            heading = "Matching “\(trimmed)” (newest \(ChatPersistenceStore.searchScanLimit) searched):"
        }

        return .chooser(Chooser(
            icon: "🔍",
            title: heading,
            options: result.rows.map { row in
                Chooser.Option(label: row.title, token: .switchConversation(row.id), isCurrent: row.id == active)
            },
            extraActions: [
                Chooser.Option(label: "📋 All Conversations", token: .action(.conversations)),
            ]
        ))
    }

    // MARK: - Clarification  (C8)

    /// The operation id of the clarification the bound conversation is parked on, if any.
    ///
    /// ⚠️ DERIVED FROM THE INTERACTION CENTER, NEVER STORED — and that distinction was a live
    /// blocker on two platforms. Telegram computes it this way and works. Discord and Slack each
    /// held a `private var awaitingClarification` that was **only ever assigned `false`**: no code
    /// path anywhere set it true. `ChatOpsCommand.parse` only returns `.clarificationResponse`
    /// inside `if awaitingClarification`, so on those two platforms a reply to a mirrored
    /// clarification could never be recognised — it parsed as free text and started a SECOND
    /// CONCURRENT RUN while the first stayed parked, indefinitely, with the prompt still telling
    /// the user to "Reply with your answer".
    ///
    /// ⚠️ The two parser tests that pass `awaitingClarification: true` directly
    /// (`ChatOpsCommandSlackTests`, `ChatOpsCommandDiscordTests`) were green the whole time — they
    /// prove the parser branch works and prove nothing about the wiring that can never reach it.
    func pendingClarificationOperationID() -> UUID? {
        guard let conversationID = session.activeConversationID else { return nil }
        return runControl?.pendingClarificationID(inConversation: conversationID)
    }

    /// Whether an inbound plain-text reply should be read as a clarification ANSWER rather than as a
    /// new message to the agent.
    var isAwaitingClarification: Bool { pendingClarificationOperationID() != nil }

    // MARK: - Shared failure copy

    /// One sentence for a dead store, so the three verbs cannot describe it three ways.
    private static func storeUnavailableNotice(while activity: String, logger: DGLogger, error: Error) -> RemoteView {
        logger.error("[CHATOPS] Failed \(activity): \(error.localizedDescription). CONSEQUENCE: the remote user is told the store is unavailable rather than being shown an empty list, which they would otherwise act on by creating a duplicate conversation.")
        return .notice(Notice(
            tone: .failure,
            body: "⚠️ Could not read your conversations — the Devgentic database is not available. Try again once the app has finished starting."
        ))
    }
}
