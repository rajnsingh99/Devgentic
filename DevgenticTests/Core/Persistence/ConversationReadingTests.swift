// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationReadingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class ConversationReadingTests: XCTestCase {

    // MARK: - Fixtures

    private func makeStore() throws -> ModelContainer {
        let container = try ModelContainer(
            for: ConversationSD.self, ChatMessageSD.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        ChatPersistenceStore.shared.configureContainer(container)
        return container
    }

    @discardableResult
    private func seed(
        in container: ModelContainer,
        title: String? = nil,
        firstMessage: String? = nil,
        at timestamp: Date = Date()
    ) -> UUID {
        let context = container.mainContext
        let conversation = ConversationSD(id: UUID(), timestamp: timestamp, userDefinedTitle: title)
        context.insert(conversation)
        if let firstMessage {
            let content = try! JSONEncoder().encode(MessageContent.plainText(firstMessage))
            let message = ChatMessageSD(
                id: UUID(),
                conversationId: conversation.id,
                timestamp: timestamp,
                senderType: SenderRole.user.rawValue,
                traceID: nil,
                contentData: content,
                agentResponseData: nil,
                timelineEventsData: nil
            )
            message.conversation = conversation
            context.insert(message)
        }
        try? context.save()
        return conversation.id
    }

    // MARK: - 1. The landmine this file exists to avoid

    /// ⚠️ THE HEADLINE TEST. "The store is not up" and "you have no conversations" must never be
    /// the same answer, because the second is what a remote user is shown when they ask what they
    /// can reach — and acting on it means creating a duplicate conversation.
    ///
    /// ⚠️ READ FROM SOURCE, AND HONESTLY SO. `ChatPersistenceStore` is a singleton whose
    /// `modelContainer` is `private(set)` and only ever written by `configureContainer`, so a test
    /// cannot un-configure it and the throwing branch is genuinely unreachable at runtime. Rather
    /// than dress a tautology up as a behavioural test — `XCTAssertNotEqual` on two description
    /// strings would pass no matter what the code did — this asserts the property that actually
    /// matters, on the text that actually implements it.
    ///
    /// Mutation that must turn this red: change either `throw ConversationReadError.storeUnavailable`
    /// to `return []` / `return nil`, i.e. adopt the `recentConversations` shape.
    /// ⚠️ PAGING MUST HAPPEN IN THE QUERY. Dropping rows in Swift would materialise every skipped
    /// conversation's `messages` relationship and derive every skipped title — `ConversationRow.init`
    /// sorts messages and JSON-decodes `contentData` to find the first non-empty one — so a request
    /// for page ten would pay for the ninety conversations it does not show.
    ///
    /// ⚠️ A SOURCE SCAN, and honestly so: exercising the real offset needs a live SwiftData
    /// container, which these tests deliberately do not stand up. This catches the removal, not a
    /// subtly wrong offset.
    ///
    /// Mutation that must turn this red: delete `descriptor.fetchOffset` from the conformance.
    /// ⚠️⚠️ INVARIANT 8's TERRITORY, AND THE SERVICE TESTS CANNOT REACH IT. `/history`'s ordering is
    /// exercised through a `ConversationReading` fake, and the fake produces its own order — so
    /// deleting the `.reversed()` from the real conformance left `testHistoryReadsOldestFirst`
    /// green. Same shape as the search predicate the fake was also answering for.
    ///
    /// ⚠️ BOTH HALVES ARE PINNED because either alone is wrong in a different direction. Sorting
    /// ASCENDING would make `fetchLimit` keep the conversation's OLDEST turns — `/history` would
    /// show the beginning of a long conversation forever. Sorting descending WITHOUT the reverse
    /// ships a transcript that reads backwards, which is the failure invariant 8 records: nothing
    /// about it looks like an error.
    ///
    /// Mutations that must turn this red: drop `.reversed()`; or change the sort to `.forward`.
    func testTheTranscriptFetchesNewestButReadsOldestFirst() throws {
        let file = try Self.readSource("Devgentic/Core/Persistence/SwiftData/ConversationReading.swift")
        guard let conformance = file.range(of: "extension ChatPersistenceStore: ConversationReading") else {
            return XCTFail("ChatPersistenceStore no longer conforms to ConversationReading")
        }
        let source = String(file[conformance.upperBound...])
        guard let start = source.range(of: "func recentMessages(inConversation") else {
            return XCTFail("the transcript read is gone from the implementation")
        }
        let body = String(source[start.upperBound...].prefix(1800))

        XCTAssertTrue(body.contains("order: .reverse"), """
            The transcript no longer fetches NEWEST first, so `fetchLimit` keeps the conversation's \
            oldest turns and `/history` shows its beginning rather than its end. Body:\n\(body)
            """)
        XCTAssertTrue(body.contains("rows.reversed()"), """
            The transcript no longer reverses, so it ships newest-first and reads as a conversation \
            happening backwards. Body:\n\(body)
            """)
    }

    // MARK: - Search predicate (slice 5)

    /// ⚠️ THIS TEST EXISTS BECAUSE THE SERVICE-LEVEL SEARCH TESTS COULD NOT SEE THIS CODE. They run
    /// against a `ConversationReading` fake, and the fake reimplemented the predicate — so a
    /// mutation making the real matcher case-sensitive left all of them green. Extracting the
    /// predicate and testing it directly is what closes that.
    ///
    /// Mutation that must turn this red: use `contains` instead of `localizedCaseInsensitiveContains`.
    func testTheSearchPredicateIsCaseInsensitiveSubstringMatching() {
        XCTAssertTrue(ConversationSearchPolicy.matches(title: "Release NOTES", query: "notes"))
        XCTAssertTrue(ConversationSearchPolicy.matches(title: "release notes", query: "NOTES"))
        XCTAssertTrue(ConversationSearchPolicy.matches(title: "Deploy checklist", query: "loy check"),
                      "substring, not prefix or token")
        XCTAssertFalse(ConversationSearchPolicy.matches(title: "Groceries", query: "notes"))
    }

    /// ⚠️ NOT DIACRITIC-INSENSITIVE, and that is inherited rather than chosen: it is what
    /// `ConversationSidebarView` does, and the remote search agreeing with the app's own search
    /// matters more than either one's folding rules. Pinned so the difference is a decision if it
    /// ever changes, taken for both surfaces at once.
    func testTheSearchPredicateFoldsCaseButNotDiacritics() {
        XCTAssertTrue(ConversationSearchPolicy.matches(title: "Café notes", query: "CAFÉ"))
        XCTAssertFalse(ConversationSearchPolicy.matches(title: "Café notes", query: "cafe"),
                       "`localizedStandardContains` would fold this; the sidebar does not use it")
    }

    /// ⚠️ The sidebar's `!searchText.isEmpty` guard means "show everything" for a blank query. The
    /// predicate means the opposite, and states it, because importing the sidebar's semantics
    /// wholesale would make `/search` with no query dump the entire conversation list.
    func testAnEmptyOrBlankQueryMatchesNothing() {
        for blank in ["", "   ", "\n"] {
            XCTAssertFalse(ConversationSearchPolicy.matches(title: "anything at all", query: blank))
        }
    }

    func testThePagedReadPagesInTheQueryRatherThanInSwift() throws {
        let file = try Self.readSource("Devgentic/Core/Persistence/SwiftData/ConversationReading.swift")
        guard let conformance = file.range(of: "extension ChatPersistenceStore: ConversationReading") else {
            return XCTFail("ChatPersistenceStore no longer conforms to ConversationReading")
        }
        let source = String(file[conformance.upperBound...])
        guard let start = source.range(of: "func conversationRows(limit:") else {
            return XCTFail("the paged read is gone from the implementation")
        }
        // ⚠️ 1400, NOT 900. The first draft used 900 and went red while the code was correct:
        // `descriptor.fetchOffset` sits 964 characters in, behind the doc comment explaining why it
        // pages the query. A window sized by guess reports a working feature as broken.
        let body = String(source[start.upperBound...].prefix(1400))

        XCTAssertTrue(body.contains("descriptor.fetchOffset"), """
            The paged read no longer offsets the FETCH. Whatever pages instead — `dropFirst` on the \
            results, or nothing at all — either costs the whole prefix or silently returns page one \
            forever. Body scanned:\n\(body)
            """)
        XCTAssertTrue(body.contains("descriptor.fetchLimit"), "the page size must bound the fetch too")
    }

    func testAnUnavailableStoreThrowsInsteadOfLookingLikeAnEmptyHistory() throws {
        let file = try Self.readSource("Devgentic/Core/Persistence/SwiftData/ConversationReading.swift")

        // ⚠️ Scope to the CONFORMANCE. Searching the whole file finds the protocol REQUIREMENT
        // first — it is declared above the implementation and has no body, so the scan below would
        // read the next declaration's doc comment and report "no container guard at all". That is
        // exactly what happened on the first run of this test.
        guard let conformance = file.range(of: "extension ChatPersistenceStore: ConversationReading") else {
            return XCTFail("ChatPersistenceStore no longer conforms to ConversationReading")
        }
        let source = String(file[conformance.upperBound...])

        for method in ["func conversationRows(limit:", "func reusableEmptyConversationID(preferring"] {
            guard let start = source.range(of: method) else {
                return XCTFail("\(method) is gone from the read seam's implementation")
            }
            // Joined body, not lines: the guard spans several.
            let guardBody = String(source[start.upperBound...].prefix(600))
            guard let containerCheck = guardBody.range(of: "modelContainer?.mainContext") else {
                return XCTFail("\(method) no longer guards on the container at all")
            }
            let afterGuard = String(guardBody[containerCheck.upperBound...].prefix(420))

            XCTAssertTrue(afterGuard.contains("throw ConversationReadError.storeUnavailable"), """
                \(method) no longer THROWS when the container is absent. Returning [] or nil there \
                makes "the store never came up" and "you have no conversations" the same answer — \
                the exact collapse recentConversations(limit:) documents living with, and on this \
                surface it means a remote user is told they have no conversations and `/new` \
                silently creates a duplicate on every invocation.
                """)
            XCTAssertFalse(afterGuard.contains("return []"), "\(method)'s unavailable path returns an empty list")
        }
    }

    /// The other half of the pair above: the configured path returns real rows, so a conformance
    /// that simply always threw could not pass both.
    func testAConfiguredStoreReturnsRows() throws {
        let container = try makeStore()
        seed(in: container, title: "Deploy checklist")

        let rows = try ChatPersistenceStore.shared.conversationRows(limit: 10, offset: 0)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, "Deploy checklist")
    }

    // MARK: - 2. The title trap

    /// An untitled conversation must take its title from its first message, not from the literal
    /// "New Conversation".
    ///
    /// Mutation that must turn this red: change `sd.toRowStruct().displayTitle` to
    /// `sd.displayTitle` — i.e. adopt the sidebar extension `recentConversations` uses.
    func testAnUntitledConversationTakesItsTitleFromTheFirstMessage() throws {
        let container = try makeStore()
        seed(in: container, title: nil, firstMessage: "Summarise the release notes")

        let rows = try ChatPersistenceStore.shared.conversationRows(limit: 10, offset: 0)

        XCTAssertEqual(rows.count, 1)
        let title = try XCTUnwrap(rows.first?.title)
        XCTAssertNotEqual(title, "New Conversation", """
            The row took its title from the ConversationSD.displayTitle SIDEBAR extension, which \
            has no first-message fallback. The bridges render toRowStruct().displayTitle, so every \
            untitled conversation would silently read "New Conversation" in the remote list.
            """)
        XCTAssertTrue(title.contains("Summarise"), "expected a title derived from the first message, got \(title)")
    }

    /// A user-defined title still wins over the derivation.
    func testAUserDefinedTitleWinsOverTheFirstMessage() throws {
        let container = try makeStore()
        seed(in: container, title: "Renamed by hand", firstMessage: "Summarise the release notes")

        let rows = try ChatPersistenceStore.shared.conversationRows(limit: 10, offset: 0)
        XCTAssertEqual(rows.first?.title, "Renamed by hand")
    }

    // MARK: - 3. Empty conversations are included

    /// Mutation that must turn this red: add `.filter { !$0.messages.isEmpty }` to
    /// `conversationRows`, i.e. copy `recentConversations`' behaviour.
    func testTheListIncludesEmptyConversationsUnlikeTheRecentsMenu() throws {
        let container = try makeStore()
        seed(in: container, title: "Has messages", firstMessage: "hello", at: Date().addingTimeInterval(-60))
        seed(in: container, title: "Brand new", at: Date())

        let rows = try ChatPersistenceStore.shared.conversationRows(limit: 10, offset: 0)

        XCTAssertEqual(rows.count, 2, """
            Empty conversations were dropped. `/new` reuses an empty conversation, so a list that \
            hides them shows the user everything EXCEPT the one they are about to be put into.
            """)
        XCTAssertEqual(rows.map(\.title), ["Brand new", "Has messages"], "rows must come back newest-first")
        XCTAssertEqual(rows.map(\.isEmpty), [true, false])
    }

    // MARK: - Reuse lookup

    func testReuseReturnsThePreferredConversationWhenItIsItselfEmpty() throws {
        let container = try makeStore()
        let older = seed(in: container, title: "Older empty", at: Date().addingTimeInterval(-600))
        let preferred = seed(in: container, title: "Current empty", at: Date().addingTimeInterval(-300))

        let reused = try ChatPersistenceStore.shared.reusableEmptyConversationID(preferring: preferred)

        XCTAssertEqual(reused, preferred, """
            The fast path must win. Reusing `older` instead would silently move the remote user out \
            of the conversation they are currently in.
            """)
        XCTAssertNotEqual(reused, older)
    }

    func testReuseFallsBackToTheMostRecentEmptyConversationWhenThePreferredOneIsNotEmpty() throws {
        let container = try makeStore()
        let emptyOne = seed(in: container, title: "Empty", at: Date().addingTimeInterval(-60))
        let busy = seed(in: container, title: "Busy", firstMessage: "hello", at: Date())

        let reused = try ChatPersistenceStore.shared.reusableEmptyConversationID(preferring: busy)
        XCTAssertEqual(reused, emptyOne)
    }

    func testReuseReturnsNilWhenEveryConversationHasMessages() throws {
        let container = try makeStore()
        seed(in: container, title: "Busy", firstMessage: "hello")

        let reused = try ChatPersistenceStore.shared.reusableEmptyConversationID(preferring: nil)
        XCTAssertNil(reused, "nil is the signal to CREATE a conversation; an arbitrary id here would hijack a real one")
    }

    // MARK: - The seam stays out of ChatPersistenceProtocol

    /// ⚠️ Thirty test files conform to `ChatPersistenceProtocol`. If these two members are ever
    /// moved onto it, they will have to be defaulted in an extension to avoid breaking all thirty
    /// — and a defaulted `[]` recreates exactly the collapse test 1 exists to prevent.
    ///
    /// Mutation that must turn this red: move either requirement onto `ChatPersistenceProtocol`.
    func testTheReadSeamIsNotOnChatPersistenceProtocol() throws {
        let source = try Self.readSource("Devgentic/Core/Persistence/SwiftData/ChatPersistenceStore.swift")

        // Joined body, not lines: a requirement can be wrapped across several.
        guard let protocolStart = source.range(of: "protocol ChatPersistenceProtocol"),
              let protocolEnd = source.range(of: "\n}", range: protocolStart.upperBound..<source.endIndex)
        else {
            return XCTFail("could not locate the ChatPersistenceProtocol body")
        }
        let body = String(source[protocolStart.upperBound..<protocolEnd.lowerBound])

        XCTAssertFalse(body.contains("conversationRows"), """
            `conversationRows` has been moved onto ChatPersistenceProtocol. Thirty test stubs \
            conform to it, so it will need a defaulted extension — and a defaulted [] makes an \
            unreadable store indistinguishable from an empty history. Keep it on ConversationReading.
            """)
        XCTAssertFalse(body.contains("reusableEmptyConversationID"), """
            `reusableEmptyConversationID` has been moved onto ChatPersistenceProtocol. Same reason: \
            a defaulted nil would make an unreadable store look like "nothing to reuse", and `/new` \
            would create a duplicate conversation on every invocation.
            """)
    }

    // MARK: - Helpers

    private static func readSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)   // …/DevgenticTests/Core/Persistence/<this>
            .deletingLastPathComponent()                 // …/Core/Persistence
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
