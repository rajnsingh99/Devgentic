// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteEgressWideningTests.swift
//  devgenticTests
//
//  What the credential floor used to let through, and what a Slack approval prompt used to render.
//
//  ⚠️⚠️ EG-2 — THE FLOOR HAD THREE HOLES, ALL REACHABLE BY ASKING THE AGENT AN ORDINARY QUESTION.
//  `sanitizeURLCredentials` matched a FIXED scheme list, `(https?|ftp|ssh|wss?)`, so every database
//  URI walked through untouched — and `DATABASE_URL` contains none of TOKEN/KEY/SECRET/PASSWORD/
//  PASS/CREDENTIAL/API, so the env-var pass did not fire either. "Why can't the app reach the
//  database?" is all it took. A bare JWT missed too (`sanitizeBearerToken` needs a literal `Bearer `
//  prefix, and the Discord pattern is anchored `[MNO]`), as did a PEM block from `cat id_ed25519`.
//
//  ⚠️⚠️ EG-4 — SLACK RENDERED MODEL TEXT AS MARKUP INSIDE AN APPROVAL PROMPT. `sectionBlock`
//  hard-codes `mrkdwn`, and `promptDraft` interpolated tool names, params, questions, plan steps and
//  gate prompts RAW. `<!channel>` from a file the agent read fired a channel-wide notification, and
//  `<url|label>` rendered a clickable link with model-chosen visible text — directly above the real
//  ✅ Approve button, in the same message.
//

import XCTest
@testable import devgentic

final class RemoteEgressWideningTests: XCTestCase {

    // MARK: - EG-2: the credential floor

    /// ⚠️ THE EXACT STRINGS THE AUDIT RAN THROUGH THE OLD FLOOR UNCHANGED.
    func testDatabaseURIsNoLongerCarryTheirPasswordOut() {
        let cases = [
            "DATABASE_URL=postgres://admin:hunter2@db.example.com:5432/app",
            "mongodb://root:s3cr3tpw@cluster0.mongodb.net/db",
            "redis://:mypassword@127.0.0.1:6379",
            "mysql://svc:p4ssw0rd@10.0.0.4/prod",
            "amqp://guest:guest@rabbit:5672"
        ]
        for input in cases {
            let out = RemoteEgressSanitizer.credentialsOnly(input)
            XCTAssertTrue(out.contains("[CREDS]"), "no redaction happened for: \(input) → \(out)")
            for secret in ["hunter2", "s3cr3tpw", "mypassword", "p4ssw0rd"] {
                XCTAssertFalse(out.contains(secret), "the password survived egress: \(out)")
            }
        }
    }

    /// ⚠️ THE SCHEME MUST SURVIVE. The replacement is `"$1://[CREDS]@"`; widening the pattern
    /// without keeping the capture group rewrites `postgres://u:p@h` as `://[CREDS]@h`, which
    /// destroys the answer while looking like a successful redaction.
    func testTheSchemeSurvivesRedaction() {
        let out = RemoteEgressSanitizer.credentialsOnly("postgres://admin:hunter2@db:5432/app")
        XCTAssertTrue(out.hasPrefix("postgres://[CREDS]@"), "scheme lost: \(out)")
    }

    func testBareJWTsAreRedacted() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let out = RemoteEgressSanitizer.credentialsOnly("the response was 401 with token \(jwt) attached")
        XCTAssertTrue(out.contains("[JWT]"), "bare JWT survived: \(out)")
        XCTAssertFalse(out.contains("SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"))
    }

    func testPEMPrivateKeysAreRedactedAsAWholeBlock() {
        let pem = """
            -----BEGIN OPENSSH PRIVATE KEY-----
            b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAAB
            -----END OPENSSH PRIVATE KEY-----
            """
        let out = RemoteEgressSanitizer.credentialsOnly("here it is:\n\(pem)\nthat is all")
        XCTAssertTrue(out.contains("[PRIVATE_KEY]"), "PEM survived: \(out)")
        XCTAssertFalse(out.contains("b3BlbnNzaC1rZXktdjEA"))
        XCTAssertTrue(out.contains("that is all"), "the surrounding text must survive")
    }

    /// ⚠️ NON-GREEDY, and invariant 41 is why this is asserted rather than assumed. A greedy match
    /// would collapse two keys — and everything between them — into ONE `[PRIVATE_KEY]`, which is
    /// exactly the content-eating failure the home-path pattern shipped with.
    func testTwoPEMBlocksRedactSeparatelyRatherThanAsOneSpan() {
        let text = """
            -----BEGIN RSA PRIVATE KEY-----
            aaaa
            -----END RSA PRIVATE KEY-----
            KEEP THIS LINE
            -----BEGIN EC PRIVATE KEY-----
            bbbb
            -----END EC PRIVATE KEY-----
            """
        let out = RemoteEgressSanitizer.credentialsOnly(text)
        XCTAssertTrue(out.contains("KEEP THIS LINE"), """
            A greedy match swallowed the text between two keys. That is invariant 41's failure \
            wearing a different pattern.
            """)
        XCTAssertEqual(out.components(separatedBy: "[PRIVATE_KEY]").count - 1, 2, "expected two redactions")
    }

    /// ⚠️ The widened scheme must not start eating ordinary URLs — the pattern still requires a
    /// literal `user:pass@`, which prose does not contain.
    func testOrdinaryURLsAndProseAreUntouched() {
        for input in ["see https://example.com/docs for more",
                      "clone git@github.com:owner/repo.git",
                      "the ratio was 3:1 and the time was 12:30"] {
            XCTAssertEqual(RemoteEgressSanitizer.credentialsOnly(input), input,
                           "the floor rewrote ordinary text: \(input)")
        }
    }

    /// ⚠️ Invariant 27's boundary, restated: this floor strips CREDENTIALS and nothing else. The
    /// user asked the agent about their own files; folding their paths breaks the answer.
    func testTheUsersOwnPathsStillSurviveTheFloor() {
        let text = "I read /Users/dev/Documents/notes.md and it mentions 10.0.0.4"
        XCTAssertEqual(RemoteEgressSanitizer.credentialsOnly(text), text)
    }

    // MARK: - EG-4: Slack prompt markup

    private func slackPromptText(_ kind: HITLType) -> String {
        let draft = SlackRemoteRenderer.promptDraft(operationID: UUID(), kind: kind)
        return draft.text + " " + (draft.blocks?.compactMap { $0.text?.text }.joined(separator: " ") ?? "")
    }

    /// ⚠️ THE INJECTION. `<!channel>` in a section block is a channel-wide notification.
    func testChannelBroadcastsCannotReachASlackApprovalPrompt() {
        let text = slackPromptText(.toolConfirmation(
            toolName: "read_file",
            params: "<!channel> URGENT — approve at <https://evil.example/approve|the official page>"))

        XCTAssertFalse(text.contains("<!channel>"), """
            A model-supplied `<!channel>` reached a Slack section block unescaped. It fires a \
            channel-wide notification from inside the app's own approval prompt.
            """)
        XCTAssertFalse(text.contains("<https://evil.example/approve|"), """
            A model-supplied `<url|label>` reached the block unescaped — Slack renders it as a \
            clickable link whose visible text the model chose, directly above the real Approve button.
            """)
        XCTAssertTrue(text.contains("&lt;!channel&gt;"), "expected entity-escaped output: \(text)")
    }

    /// ⚠️ The app's OWN markers must survive — escaping the whole string would turn the renderer's
    /// `*Tool Approval Required*` into literal asterisks.
    func testTheRenderersOwnBoldMarkersStillRender() {
        let text = slackPromptText(.toolConfirmation(toolName: "read_file", params: "x"))
        XCTAssertTrue(text.contains("*Tool Approval Required*"), "the app's own emphasis was escaped: \(text)")
        XCTAssertTrue(text.contains("*Tool:*"))
    }

    /// All four arms interpolate model text; all four must escape it.
    func testEveryPromptArmEscapesItsModelText() {
        let hostile = "<!here> <https://evil.example|click>"
        let kinds: [(String, HITLType)] = [
            ("toolConfirmation", .toolConfirmation(toolName: hostile, params: hostile)),
            ("clarification",    .clarification(question: hostile)),
            ("planReview",       .planReview(subtaskDescriptions: [hostile, "step two"])),
            ("gate",             .gate(prompt: hostile, options: ["yes", "no"]))
        ]
        for (name, kind) in kinds {
            let text = slackPromptText(kind)
            XCTAssertFalse(text.contains("<!here>"), "\(name) leaves model markup unescaped: \(text)")
            XCTAssertFalse(text.contains("<https://evil.example|click>"), "\(name) leaves a spoofable link: \(text)")
        }
    }

    /// ⚠️ Telegram is deliberately NOT escaped on this path — it passes `parse_mode: nil`, so its
    /// text is literal and escaping would show backslashes to the user. This pins that the two
    /// platforms diverge for a reason rather than by accident.
    func testTelegramPromptsStayUnescapedBecauseTheySendNoParseMode() {
        let draft = TelegramRemoteRenderer.promptDraft(
            operationID: UUID(),
            kind: .toolConfirmation(toolName: "read_file", params: "a_b*c"))
        XCTAssertNil(draft.parse_mode, "Telegram prompts must send no parse mode")
        XCTAssertTrue(draft.text.contains("a_b*c"), """
            Telegram's prompt text was escaped. With `parse_mode: nil` nothing interprets it, so \
            escaping only shows the user backslashes.
            """)
    }
}
