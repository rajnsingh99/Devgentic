// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RemoteEgressSanitizerTests.swift
//  DevgenticTests
//
//  Slice 6: the credential floor on everything leaving for a chat service.
//

import XCTest
@testable import devgentic

final class RemoteEgressSanitizerTests: XCTestCase {

    private let key = "sk-ant-api03-DEADBEEFCAFE1234567890"

    // MARK: - The policy

    /// Mutation that must turn this red: drop any of the credential passes.
    func testCredentialsAreStrippedOnTheWayOut() {
        for secret in [
            "here is the key sk-ant-api03-DEADBEEFCAFE1234567890 use it",
            "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abcdefghijklmnop",
            "clone https://user:hunter2@github.com/acme/repo.git",
            #"{"apiKey": "sk-live-9f8e7d6c5b4a3210fedcba98"}"#,
            "export OPENAI_API_KEY=sk-proj-ABCDEFGHIJKLMNOPQRSTUV",
        ] {
            let cleaned = RemoteEgressSanitizer.credentialsOnly(secret)
            XCTAssertNotEqual(cleaned, secret, "nothing was redacted in: \(secret)")
        }
    }

    /// ⚠️ THE DELIBERATE DIFFERENCE FROM `TelemetrySanitizer.sanitize`, and the reason this type
    /// exists at all. `.standard` also folds home paths, IPs and emails — right for a diagnostic
    /// bundle, destructive for the agent's reply. The user asked about their own files; answering
    /// `[USER_PATH]/main.swift` turns a correct answer into a broken-looking one, and redaction that
    /// damages what the user asked for teaches them to route around it.
    ///
    /// Mutation that must turn this red: call `TelemetrySanitizer.sanitize` instead of composing
    /// the credential passes.
    func testTheUsersOwnPathsAndAddressesSurvive() {
        let answer = "I edited /Users/alice/Devgentic/main.swift and emailed alice@example.com from 192.168.1.4"
        XCTAssertEqual(RemoteEgressSanitizer.credentialsOnly(answer), answer, """
            The agent's own answer must survive intact. This is the line between "the user asked \
            for this" and "the user never intended to transmit this".
            """)

        // And the harsher policy really would have changed it — proving the two differ.
        XCTAssertNotEqual(TelemetrySanitizer.sanitize(answer), answer,
                          "if this stops differing, the two policies have collapsed into one")
    }

    /// A credential inside an otherwise ordinary sentence must go, and the sentence must stay.
    func testOnlyTheCredentialIsRemoved() {
        let cleaned = RemoteEgressSanitizer.credentialsOnly("Set it to \(key) in your config")
        XCTAssertFalse(cleaned.contains(key))
        XCTAssertTrue(cleaned.contains("Set it to"))
        XCTAssertTrue(cleaned.contains("in your config"))
    }

    // MARK: - The view walk

    /// ⚠️ A CONVERSATION TITLE IS AUTO-SET TO THE USER'S FIRST PROMPT, so a prompt containing a key
    /// becomes a BUTTON LABEL in `/conversations`. Sanitising rendered text alone would never have
    /// touched it — this is why the walk happens on the view.
    ///
    /// Mutation that must turn this red: stop cleaning `Chooser.Option.label`.
    func testAKeyInAConversationTitleNeverReachesAButtonLabel() {
        let view = RemoteView.chooser(Chooser(
            icon: "📋",
            title: "Your Conversations:",
            options: [Chooser.Option(label: "debug \(key) failing", token: .switchConversation(UUID()))],
            extraActions: [Chooser.Option(label: "➕ New Conversation", token: .action(.new))]
        ))
        guard case .chooser(let cleaned) = view.sanitizedForEgress() else { return XCTFail("shape changed") }
        XCTAssertFalse(cleaned.options[0].label.contains(key), "got: \(cleaned.options[0].label)")
        XCTAssertEqual(cleaned.extraActions[0].label, "➕ New Conversation", "our own literals are untouched")
    }

    /// ⚠️ THE MOST EXPOSED STRINGS IN THE APP: a tool confirmation carries the tool's raw ARGUMENTS,
    /// which is exactly where a key read out of a `.env` appears — on its way to a chat service,
    /// for a user who only wanted to approve a file write.
    ///
    /// Mutation that must turn this red: stop cleaning `HITLType.toolConfirmation`'s params.
    func testAKeyInToolArgumentsNeverReachesAnApprovalPrompt() {
        let view = RemoteView.prompt(
            operationID: UUID(),
            kind: .toolConfirmation(toolName: "write_file", params: #"{"body":"KEY=\#(key)"}"#)
        )
        guard case .prompt(_, let kind) = view.sanitizedForEgress(),
              case .toolConfirmation(let name, let params) = kind else {
            return XCTFail("shape changed")
        }
        XCTAssertEqual(name, "write_file")
        XCTAssertFalse(params.contains(key), "got: \(params)")
    }

    /// Every string-bearing case is walked — a new one must be considered rather than silently
    /// passing content through unsanitised.
    func testEveryViewCaseIsWalked() {
        let id = UUID()
        for view: RemoteView in [
            .notice(Notice(tone: .info, icon: "🔑\(key)", title: "t \(key)", body: "b \(key)",
                           fields: [.init(label: "l \(key)", value: "v \(key)")])),
            .prompt(operationID: id, kind: .clarification(question: "which \(key)?")),
            .prompt(operationID: id, kind: .planReview(subtaskDescriptions: ["step \(key)"])),
            .prompt(operationID: id, kind: .gate(prompt: "go? \(key)", options: ["yes \(key)"])),
        ] {
            let dumped = String(describing: view.sanitizedForEgress())
            XCTAssertFalse(dumped.contains(key), "a key survived the walk in: \(dumped)")
        }
    }

    /// ⚠️ CALLBACK TOKENS ARE NOT TEXT. They are ids and fixed verbs this app mints, and rewriting
    /// one would break the round trip that makes the button work.
    func testTokensAreLeftAlone() {
        let conversation = UUID()
        let view = RemoteView.chooser(Chooser(
            title: "x", options: [Chooser.Option(label: "y", token: .switchConversation(conversation))]))
        guard case .chooser(let cleaned) = view.sanitizedForEgress() else { return XCTFail("shape changed") }
        XCTAssertEqual(cleaned.options[0].token, .switchConversation(conversation))
    }

    // MARK: - Wiring

    /// ⚠️ THE TEST THAT MATTERS. Everything above passes with the floor sitting unused. Every path
    /// that puts text on the wire must pass through it — and there are four per transport, which is
    /// exactly the kind of set where one gets forgotten.
    ///
    /// Mutation that must turn this red: remove the sanitiser from any transport send path.
    func testEveryTransportSendPathPassesThroughTheFloor() throws {
        for name in ["TelegramTransport", "DiscordTransport", "SlackTransport"] {
            let source = try Self.readSource("Devgentic/ChatOps/Services/\(name).swift")

            // The view walk covers render's text, blocks and button labels in one place.
            XCTAssertTrue(source.contains("view.sanitizedForEgress()"),
                          "\(name).render posts a view that was never sanitised")

            // The three raw-string paths each carry the mirror's agent output or a status edit.
            for path in ["func sendTextMessage(", "func sendChunkedMessage(", "func editMessage("] {
                guard let start = source.range(of: path) else {
                    return XCTFail("\(name) no longer has \(path)")
                }
                // ⚠️ BOUNDED TO THE METHOD, NOT A CHARACTER COUNT. A fixed window read PAST the end
                // of `sendChunkedMessage` into `editMessage` — which still sanitised — so removing
                // the floor from one method left this test green. A source scan that spills into
                // the next declaration answers for code it was not asked about.
                let rest = source[start.upperBound...]
                let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
                let body = String(rest[..<end])
                XCTAssertTrue(body.contains("RemoteEgressSanitizer.credentialsOnly"), """
                    \(name)'s \(path) reaches the wire without the credential floor. \
                    Body scanned:\n\(body)
                    """)
            }
        }
    }

    private static func readSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(relativePath) not reachable — running outside a checkout")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
