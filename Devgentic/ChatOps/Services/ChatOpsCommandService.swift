// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsCommandService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Session context

// Why: a seam instead of the singleton, whose cursor writes the developer's real `UserDefaults` during tests
/// The two pieces of ChatOps configuration a read-only verb needs.
/// Satisfied by `ChatOpsConfigManager` with no extra code.
@MainActor
protocol ChatOpsSessionContext: AnyObject {
    /// Settable: `/new` and `switch:` move the cursor, and a fake can record the write to prove ordering.
    var activeConversationID: UUID? { get set }
    var securityTier: ChatOpsSecurityTier { get }
}

// Why: `activeConversationID` is the Telegram cursor, so a bare read would move Discord via Telegram's
/// Binds the shared config to one provider's cursor, writing through `ChatOpsConfigManager`'s provider property
/// so `withMutation(keyPath:)` still invalidates `@Observable`.
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

    /// Provider-scoped: the bare property would report Telegram's tier on Discord and Slack.
    var securityTier: ChatOpsSecurityTier { config.securityTier(for: provider) }
}

// MARK: - Profile reading

/// The picker-safe profile list, as a seam.
@MainActor
protocol ChatOpsProfileReading: AnyObject {
    /// Shared profiles only; `fetchSharedProfiles()` excludes node-owned rows at the query, before the 500-row cap.
    func sharedProfiles() -> [BackendProfileModel]

    // Why: must be an uncapped id-keyed read: scanning `sharedProfiles()` misses profiles outside its 500-row window
    /// One profile by id.
    func profile(id: UUID) -> BackendProfileModel?
}

extension BackendProfileStore: ChatOpsProfileReading {
    /// Swallows store errors, so a store failure reads as "no agent profile configured".
    func sharedProfiles() -> [BackendProfileModel] { (try? fetchSharedProfiles()) ?? [] }

    /// `fetchProfile(byId:)` is the uncapped single-row query, deliberately not `fetchProfiles()`.
    func profile(id: UUID) -> BackendProfileModel? { (try? fetchProfile(byId: id)) ?? nil }
}

// MARK: - Provider mapping

extension RemoteChannel.Provider {
    /// The origin enum owns the conversation title too (`bridgeTitle`), so the literal exists once.
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

    // Why: the bridges hold this service strongly, so a strong view-model reference closes a retain cycle
    /// Weak reference to the run controller; `submitTurn` routes all free text through this service on every provider.
    /// Both protocols are `AnyObject`-constrained and kept separate because tests inject two fakes.
    private weak var runControlRef: (any RemoteRunControlling)?
    private let conversations: any ConversationReading
    /// One service per provider: the provider decides the cursor, recorded origin and log attribution,
    /// and `session` must be scoped to the same one, so the bridge constructs both together.
    private let provider: RemoteChannel.Provider
    private var session: any ChatOpsSessionContext
    private weak var commandingRef: (any RemoteConversationCommanding)?

    /// Named so existing call sites read unchanged; the optionality is intentional.
    private var runControl: (any RemoteRunControlling)? { runControlRef }
    private var commanding: (any RemoteConversationCommanding)? { commandingRef }

    // Why: a bridge outlives the window it acts for, and a silent no-op reads as a bot that stopped answering
    /// What to post when the host is gone: the user is answered, never silently dropped.
    private func hostLost(_ verb: String) -> RemoteView {
        logger.error("[CHATOPS] A \(provider.rawValue) \(verb) could not run: the app's main view model was deallocated while this bridge was still listening. CONSEQUENCE: the command is REFUSED and the user is told, rather than silently doing nothing. The bridge has outlived the window it acts for and should have been stopped.")
        return .notice(Notice(tone: .failure,
                              body: "⚠️ Devgentic's main window is no longer available, so that command could not run. Reopen the app and try again."))
    }
    private let profiles: any ChatOpsProfileReading
    private let recordOrigin: (RemoteConversationOrigin, UUID) -> Void

    // Why: that property's protocol excludes `ConversationReading`, so an `as?` cast silently returns nil against stubs
    /// `conversations` is its own parameter, not reached through the view model's `persistenceService`.
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

    /// Conversations per page. Ten rows plus Previous, Next and New Conversation is thirteen buttons,
    /// within the tightest platform cap (Discord and Slack allow 25).
    static let conversationListLimit = 10

    /// offset: how many of the newest conversations to skip; zero is the first page.
    /// Required so every caller states which page it wants.
    func conversationList(offset: Int) -> RemoteView {
        let page: [ConversationRow]
        do {
            // Fetches one more row than shown; the extra tells whether a "Next" button belongs without a count query.
            page = try conversations.conversationRows(limit: Self.conversationListLimit + 1, offset: offset)
        } catch {
            return Self.storeUnavailableNotice(while: "listing your conversations", logger: logger, error: error)
        }

        let hasNextPage = page.count > Self.conversationListLimit
        let rows = Array(page.prefix(Self.conversationListLimit))

        // Why: a chooser with no options renders as its heading alone and would silently replace the empty-state copy
        // The empty case is a notice, not an empty chooser.
        guard !rows.isEmpty else {
            // An empty later page is not an empty list: a stale "Next" tap must not claim "No conversations yet".
            guard offset == 0 else {
                logger.info("[CHATOPS] A conversation page at offset \(offset) came back empty. CONSEQUENCE: the user is told the list has changed rather than that they have no conversations; this happens when a paging button outlives the rows it was posted for.")
                return .notice(Notice(
                    tone: .info,
                    body: "That page is empty now — the list has changed since this button was posted. Use /conversations to start again."))
            }
            return .notice(Notice(tone: .info, body: "No conversations yet. Use /new to create one."))
        }

        let active = session.activeConversationID

        // The range is shown only when paging; past the first page a list starting mid-way would look like lost rows.
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
                    // A flag, so bridges prepend "⭐ " to the label and Slack's `initial_option` stays reachable.
                    isCurrent: row.id == active
                )
            },
            extraActions: extras
        ))
    }

    // MARK: - /status

    /// The count's window: "Total Conversations" means of the 100 most recent.
    static let statusCountLimit = 100

    // Why: one literal, so `/status` never shows a real title beside an unavailable count or the reverse
    /// What a field reads when the store could not answer it.
    static let unavailable = "unavailable"

    func status() -> RemoteView {
        let activeID = session.activeConversationID

        // Conversation-scoped, not app-global: otherwise any busy conversation would report this one as streaming.
        let isStreaming = activeID.flatMap { runControl?.hasActiveRun(inConversation: $0) } ?? false
        let hitlPending = activeID.flatMap { runControl?.pendingClarificationID(inConversation: $0) } != nil

        // The active title cannot come from the list above: an older conversation would render as "None" while active.
        // "None" means no cursor, never a failed read; a failed read reads as unavailable.
        var activeTitle = activeID == nil ? "None" : Self.unavailable
        var totalConversations: String
        var storeAnswered = true
        do {
            if let activeID {
                // A successful read that finds nothing is still "None": a cursor outliving its deleted conversation is no outage.
                activeTitle = try conversations.conversationRow(id: activeID)?.title ?? "None"
            }
            totalConversations = String(try conversations.conversationRows(limit: Self.statusCountLimit, offset: 0).count)
        } catch {
            // A dead store reports "unavailable", not a count of 0 that would look like an empty history.
            logger.error("[CHATOPS] /status could not read conversations: \(error.localizedDescription). CONSEQUENCE: both the active conversation and the count read \"unavailable\" instead of \"None\" and 0, so the remote user is not told they have no history — or no active conversation — when the store is simply down.")
            totalConversations = Self.unavailable
            storeAnswered = false
        }

        // Why: resolved after the read and gated on it, so a down store does not show "Default" as if it were running
        // Which profile answers here, so a remote user can tell what `/new` picked.
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

    /// Lists commands from `ChatOpsVerb.presentationOrder`, so a verb added to the table is advertised automatically.
    /// `ChatOpsVerb.usage` emits the canonical name only, so aliases stay reachable and unlisted.
    func help() -> RemoteView {
        .notice(Notice(
            tone: .info,
            icon: "🤖",
            title: "Devgentic ChatOps",
            fields: [
                .spacer,
                .init(value: "Commands:", emphasis: true),
            ]
            // Derived from the verb table, not hand-written, so a shipped command cannot become undiscoverable.
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
                // AGPL section 13: everyone reaching the app over a network is offered its source, in the default reply
                // so modified builds inherit it. See `GlobalConstants.sourceCodeURL`.
                .init(label: "Source", value: "\(GlobalConstants.sourceCodeURL) · GNU AGPL v3", labelEmphasis: true),
            ]
        ))
    }

    // MARK: - /new  (C5b)

    // Why: reversing it lets a failed send leave the cursor unmoved after telling the user it moved
    /// Every state write happens before this returns: the cursor and Mac-window selection first, then the view.
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
            // No origin record on the reuse branch: the conversation keeps its provenance, and stamping would relabel it remote.
            logger.info("[ChatOps] Reused empty conversation \(reusedID.uuidString) instead of creating a new one, via \(provider.rawValue).")
            return .notice(Notice(
                tone: .success,
                body: "✅ Switched to existing empty conversation.",
                fields: [.init(value: "Just type your message to start.")]
            ))
        }

        let origin = provider.conversationOrigin

        // Why: the auto-title only fires for a nil or empty title, so a stamped constant would name every remote chat identically
        // Created with no title on purpose, so the auto-title from the user's first message applies.
        // Origin is recorded in a side store keyed by conversation id, not by title.
        guard let commanding else { return hostLost("/new") }
        let conversationID = commanding.createConversation(profile: profile, title: "")
        // Origin is recorded before anything can rename the conversation and before the cursor moves.
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

    /// Which profile a new remote conversation runs under: the composer's selection if still shared,
    /// else the first agent profile, else the first. `nonisolated static`, so the order is testable without a store.
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
            // A dead store reports a store-unavailable notice, not "not found", which would misstate the user's data.
            return Self.storeUnavailableNotice(while: "opening that conversation", logger: logger, error: error)
        }
        guard let row else {
            return .notice(Notice(tone: .warning, body: "⚠️ Conversation not found."))
        }

        session.activeConversationID = conversationID
        commanding?.focusConversationInMainWindow(conversationID)
        logger.info("[ChatOps] Mac UI navigated to conversation \(conversationID.uuidString).")
        logger.info("[ChatOps] Switched to conversation \(conversationID.uuidString) via \(provider.rawValue).")

        // The title is a field, not interpolated into `body`, because it is user-controlled and must be escaped;
        // `inline` keeps `✅ Switched to: *<title>*` on one line.
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

    /// `runControl.cancelRun` bundles read activity, cancel the stream, then clear any parked suspension,
    /// so this method cannot reorder them; the reply text depends on the activity read.
    func cancelRun() async -> RemoteView {
        guard let conversationID = session.activeConversationID else {
            return .notice(Notice(tone: .info, body: "No active conversation to cancel."))
        }

        let hadActiveRun = await runControl?.cancelRun(inConversation: conversationID) ?? false
        logger.info("[CHATOPS] /cancel via \(provider.rawValue) for conversation \(conversationID.uuidString) — hadActiveRun=\(hadActiveRun). CONSEQUENCE: the stream task itself was cancelled (not just the parked HITL), so the run stops instead of continuing after the bot claims it was cancelled.")

        // Not `.failure` on either branch: failure notices log at `.error`, and cancelling an idle conversation is normal.
        return .notice(Notice(
            tone: hadActiveRun ? .success : .info,
            body: hadActiveRun
                ? "🛑 Cancelled the active run for this conversation."
                : "No run is currently active for this conversation — cleared any pending approvals."
        ))
    }

    // MARK: - Profile binding  (C9)

    /// The profile a conversation runs under, read by id.
    /// Uses the uncapped id-keyed read, so a profile outside the 500-row recency window still resolves.
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

    // Why: decide, register the mirror, then submit is one method so the bridges cannot order the steps differently
    /// Admits or refuses a remote free-text turn, and submits it when admitted. attachMirror reports whether it attached;
    /// it is not called on a refusal. Returns `.admitted`, or `.refused` with copy the bridge must post.
    @discardableResult
    func submitTurn(prompt: String,
                    conversationID: UUID,
                    source: MessageSource,
                    config: BackendRequestConfig,
                    attachMirror: () -> Bool) -> RemoteTurnAdmission.Decision {

        let decision = RemoteTurnAdmission.decide(
            hasActiveRun: runControl?.hasActiveRun(inConversation: conversationID) ?? false,
            waitingOn: runControl?.pendingQuestionNoun(inConversation: conversationID)
        )

        guard case .admitted = decision else {
            logger.warning("[CHATOPS] A \(provider.rawValue) prompt for conversation \(conversationID.uuidString.prefix(8)) was REFUSED because a run is already streaming there. CONSEQUENCE: it was not submitted and the user was told to /cancel or wait; before this check a second prompt started a second root run in the same conversation, so two answers interleaved into one chat, /cancel silently killed both, and a clarification answer could resolve the wrong run's question.")
            return decision
        }

        // The submit is conditional on the mirror and checked before `submitRemote`, so a failed attachment costs nothing.
        guard attachMirror() else {
            logger.error("[CHATOPS] A \(provider.rawValue) prompt for conversation \(conversationID.uuidString.prefix(8)) was REFUSED because the mirror could not be attached — the transport or the mirror service was unavailable. CONSEQUENCE: nothing was submitted and the user was told, which is deliberate: submitting anyway would run the agent on the Mac, spend tokens and possibly run tools while the remote user watched a chat that never answered.")
            return RemoteTurnAdmission.mirrorUnavailable
        }

        // A lost host cannot submit, so the turn is refused rather than reported as started, like `attachMirror` above.
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

    /// The profiles a remote user may choose from; selection only, since create, edit and delete stay local.
    /// Only projected strings travel: `RemoteView` requires `Codable` and `BackendProfileSnapshot` is not.
    func profileList() -> RemoteView {
        // `sharedProfiles()` excludes node-owned rows at the query; `.code` is excluded here as in the composer picker.
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

    /// The one-line description under a profile's name, re-derived here rather than reused from the composer,
    /// whose version is unreachable and touches `WorkflowLayoutStore`. Kind and model suffice for a remote picker.
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
        // Exact match first, then a unique case-insensitive prefix; an ambiguous prefix is refused rather than guessed.
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

    /// The state write happens before the view is returned.
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
    /// The most it will show, whatever they ask for. A product bound, not a delivery limit:
    /// `RemoteTextBudget` enforces each platform's real limit and reports dropped lines.
    static let historyMaxCount = 20

    func conversationHistory(argument: String) -> RemoteView {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)

        let count: Int
        if trimmed.isEmpty {
            count = Self.historyDefaultCount
        } else if let requested = Int(trimmed), requested > 0 {
            // Clamped, and the user is told below when the clamp applied, so a capped list does not read as complete.
            count = min(requested, Self.historyMaxCount)
        } else {
            // A usage hint, not `.unknown`: a mistyped argument should not send the user hunting for the wrong problem.
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

        // `NoticeText.build` escapes both `body` and `fields`, which matters for hostile message text under Telegram Markdown.
        // Fields are used because a transcript is a list and each line stays addressable.
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
            // A usage hint, not the whole list: a missing query answered with every conversation would look ignored.
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
            // "Nothing matched" and "only the newest 200 were scanned" differ, so the scan bound is disclosed instead of hidden.
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
    /// Derived from the interaction center, never stored, so replies to mirrored clarifications are recognised everywhere.
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
