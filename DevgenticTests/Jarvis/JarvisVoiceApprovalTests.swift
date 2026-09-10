// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisVoiceApprovalTests.swift
//  DevgenticTests
//
//  [Phase 6 · F2] The security tests for the spoken approval channel.
//
//  ⚠️ These are deny-by-default assertions. A failure here is not a cosmetic regression: it means
//  a misheard word can commit an action the user never saw. Read `JarvisApprovalPolicy`'s header
//  before changing any expectation in this file.
//

import XCTest
@testable import devgentic

final class JarvisVoiceApprovalPolicyTests: XCTestCase {

    private func confirmation(tool: String = "read_file",
                              risk: HITLRiskTier = .safe,
                              serverDeclared: Bool? = nil,
                              arguments: JSONValue? = .object(["path": .string("/Users/alice/src/Config.swift")])) -> PendingHITL {
        PendingHITL(
            id: UUID(),
            origin: HITLOrigin(interface: .chat, conversationID: UUID(), title: "Permission required"),
            kind: .toolConfirmation(PendingToolConfirmation(
                toolName: tool, params: "{}", risk: risk,
                arguments: arguments, riskIsServerDeclared: serverDeclared))
        )
    }

    // MARK: - The one shape that is allowed

    func testAReadOnlyToolWithReadableArgumentsIsVoiceApprovable() {
        guard case .voiceApprovable(_, let name, let spoken) = JarvisApprovalPolicy.decision(for: confirmation()) else {
            return XCTFail("A safe tool with readable arguments is the one case this channel exists for.")
        }
        XCTAssertEqual(name, "read_file")
        XCTAssertTrue(spoken.contains("Config.swift"), "The read-back must name the file: \(spoken)")
        XCTAssertFalse(spoken.contains("/Users/"), "A full path read aloud is unusable: \(spoken)")
    }

    // MARK: - Everything else is refused

    /// ⚠️ THE CENTRAL ASSERTION. `HITLRiskTier.classify` returns `.moderate` by DEFAULT, so every
    /// unknown tool and every MCP tool lands there. A `!= .destructive` gate would make an unknown
    /// third-party tool voice-approvable; only `.safe` is an explicit allowlist.
    func testOnlyTheSafeTierIsEverVoiceApprovable() {
        for risk in HITLRiskTier.allCases {
            let decision = JarvisApprovalPolicy.decision(for: confirmation(risk: risk))
            if risk == .safe {
                guard case .voiceApprovable = decision else { return XCTFail("safe must pass") }
            } else {
                guard case .screenOnly = decision else {
                    return XCTFail("\(risk) must NEVER be voice-approvable — an unknown tool defaults to .moderate.")
                }
            }
        }
    }

    func testAToolThatRunsArbitraryCodeIsNeverVoiceApprovable() {
        // Belt and braces: `classify` escalates these to .destructive, but the policy asserts the
        // capability directly so a future re-tiering cannot reopen the hole.
        for tool in ["execute_shell", "run_applescript"] where ToolCapability.executesArbitraryCode(tool) {
            guard case .screenOnly = JarvisApprovalPolicy.decision(for: confirmation(tool: tool, risk: .safe)) else {
                return XCTFail("\(tool) executes arbitrary code and must never be approvable by voice.")
            }
        }
    }

    /// An MCP server's self-reported risk is an unverified third-party claim. The banner is
    /// required to render "(server-declared)" beside it; a voice can render nothing.
    func testAServerDeclaredSafeRatingIsNotTrustedByVoice() {
        guard case .screenOnly = JarvisApprovalPolicy.decision(for: confirmation(serverDeclared: true)) else {
            return XCTFail("A server's own claim that it is safe must not unlock the voice channel.")
        }
    }

    /// ⚠️ Optional-compared to `true`: pre-SE3 persisted confirmations decode as nil, and `== false`
    /// would wrongly exclude every one of them.
    func testAnUnknownServerDeclarationIsTreatedAsNative() {
        guard case .voiceApprovable = JarvisApprovalPolicy.decision(for: confirmation(serverDeclared: nil)) else {
            return XCTFail("nil means 'not server-declared', not 'unknown, refuse'.")
        }
    }

    func testAReadBackThatCannotBeProducedRefuses() {
        for args in [JSONValue?.none, .some(.object([:])), .some(.array([.string("x")])),
                     .some(.object(["nested": .object(["a": .string("b")])]))] {
            guard case .screenOnly = JarvisApprovalPolicy.decision(for: confirmation(arguments: args)) else {
                return XCTFail("A read-back you cannot produce is not a read-back: \(String(describing: args))")
            }
        }
    }

    /// Deliberate v1 scope cut, stated as a test so it is a decision and not an oversight.
    func testNonToolInteractionsAreScreenOnly() {
        let clarification = PendingHITL(id: UUID(), origin: HITLOrigin(interface: .chat, conversationID: UUID(), title: "Permission required"),
                                        kind: .clarification(PendingClarification(question: "Which branch?")))
        guard case .screenOnly = JarvisApprovalPolicy.decision(for: clarification) else {
            return XCTFail("A clarification answer steers a later tool call — an indirect authorization channel.")
        }
    }

    func testTheTokenOnlyExistsForAnApprovableDecision() {
        XCTAssertNotNil(JarvisApprovalPolicy.token(for: confirmation()))
        XCTAssertNil(JarvisApprovalPolicy.token(for: confirmation(risk: .destructive)))
        XCTAssertNil(JarvisApprovalPolicy.token(for: confirmation(arguments: nil)))
    }
}

final class JarvisApprovalGrammarTests: XCTestCase {

    /// ⚠️ The vocabulary is passed explicitly because the parser requires it — a defaulted list
    /// would be a call site quietly matching "approve" after the user chose another word.
    private func parse(_ text: String, queue: Int = 3) -> JarvisApprovalUtterance? {
        JarvisApprovalPolicy.parseApprovalUtterance(
            text, queueSize: queue, approveKeywords: ["approve"], denyKeywords: ["deny"])
    }

    func testOrdinalsAreParsedAsWordsAndDigits() {
        XCTAssertEqual(parse("approve one and three"), .approve([1, 3]))
        XCTAssertEqual(parse("approve 1 and 3"), .approve([1, 3]))
        XCTAssertEqual(parse("deny second"), .deny([2]))
        XCTAssertEqual(parse("what's number two"), .describe(2))
        // ⚠️ Dictation emits a typographic apostrophe as often as an ASCII one.
        XCTAssertEqual(parse("what\u{2019}s number two"), .describe(2))
    }

    /// ⚠️ THE SWALLOWING TEST. A sentence ABOUT approving is not an approval. Matching it as a
    /// command would execute something the user was only talking about.
    func testASentenceContainingAControlWordIsNotACommand() {
        XCTAssertNil(parse("can you approve the change to the readme"))
        XCTAssertNil(parse("I was going to deny that pull request"))
        XCTAssertNil(parse("tell me what approve means"))
    }

    /// ⚠️ "All" is exactly the word a television supplies, and its blast radius is the whole queue.
    func testThereIsNoApproveAll() {
        XCTAssertNil(parse("approve all"))
        XCTAssertNil(parse("approve everything"))
        // Denying all fails closed — the worst case is being asked again.
        XCTAssertEqual(parse("deny all"), .denyAll)
    }

    /// Out of range is DROPPED, never clamped: "approve seven" with three pending must not
    /// quietly become "approve three".
    func testOutOfRangeOrdinalsAreDroppedNotClamped() {
        XCTAssertNil(parse("approve seven", queue: 3))
        XCTAssertEqual(parse("approve two and nine", queue: 3), .approve([2]))
    }

    func testAnEmptyQueueParsesNothing() {
        XCTAssertNil(parse("approve one", queue: 0))
    }

    func testDuplicateOrdinalsCollapse() {
        XCTAssertEqual(parse("approve one and one"), .approve([1]))
    }

    // MARK: - The commit word

    /// ⚠️ Only an EXACT whole-utterance match commits. Treating "uh, sure, maybe" as consent is
    /// the entire failure mode of voice approval — and a substring match would make
    /// "don't approve that" an approval.
    func testOnlyAnExactKeywordConfirms() {
        let approve = ["approve"]
        for yes in ["approve", "Approve.", "  approve  ", "APPROVE"] {
            XCTAssertTrue(JarvisApprovalPolicy.isConfirmation(yes, keywords: approve), "\(yes) should confirm")
        }
        for notYes in ["approve that", "don't approve", "yeah maybe", "sure I guess", "", "unapprove"] {
            XCTAssertFalse(JarvisApprovalPolicy.isConfirmation(notYes, keywords: approve), "\(notYes) must NOT confirm")
        }
    }

    func testDenialUsesItsOwnKeywords() {
        XCTAssertTrue(JarvisApprovalPolicy.isDenial("deny", keywords: ["deny"]))
        XCTAssertFalse(JarvisApprovalPolicy.isDenial("approve", keywords: ["deny"]))
    }
}

/// ⚠️ These pin the rules protecting the one setting where a careless value has teeth: the word
/// that commits a tool call.
final class JarvisApprovalKeywordTests: XCTestCase {

    func testTheDefaultsAreApproveAndDeny() {
        let resolved = JarvisApprovalKeywords.resolve(approveRaw: "approve", denyRaw: "deny")
        XCTAssertEqual(resolved.approve, ["approve"])
        XCTAssertEqual(resolved.deny, ["deny"])
        XCTAssertTrue(resolved.problems.isEmpty)
    }

    func testSeveralKeywordsCanShareOneField() {
        XCTAssertEqual(JarvisApprovalKeywords.parse("approve, yes, go ahead"), ["approve", "yes", "go ahead"])
    }

    /// What is shown in Settings must be what matches at the microphone. Anything else produces a
    /// keyword that looks correct and silently never fires.
    func testKeywordsAreNormalizedTheSameWayTheMicrophonePathIs() {
        XCTAssertEqual(JarvisApprovalKeywords.parse("  Approve. , YES  "), ["approve", "yes"])
        XCTAssertEqual(JarvisApprovalKeywords.parse("go    ahead"), ["go ahead"])
    }

    /// ⚠️ Speech recognition emits stray one-letter tokens constantly; any of them would be a
    /// commit.
    func testSingleCharacterKeywordsAreDropped() {
        XCTAssertEqual(JarvisApprovalKeywords.parse("a, ok, k"), ["ok"])
    }

    func testDuplicatesCollapse() {
        XCTAssertEqual(JarvisApprovalKeywords.parse("approve, Approve, approve."), ["approve"])
    }

    /// ⚠️ A cleared field must not leave the channel armed and inert — the orb would give no clue
    /// that an empty text box is why nothing works.
    func testAnEmptyFieldFallsBackToTheDefault() {
        let resolved = JarvisApprovalKeywords.resolve(approveRaw: "   ", denyRaw: "")
        XCTAssertEqual(resolved.approve, ["approve"])
        XCTAssertEqual(resolved.deny, ["deny"])
    }

    /// A field with only invalid entries is a different case: the user typed something, and it was
    /// all discarded, so they must be told.
    func testAFieldOfOnlyInvalidEntriesReportsTheProblem() {
        let resolved = JarvisApprovalKeywords.resolve(approveRaw: "a, b", denyRaw: "deny")
        XCTAssertEqual(resolved.approve, ["approve"])
        XCTAssertTrue(resolved.problems.contains(.allDropped(kept: "approve")))
    }

    /// ⚠️⚠️ THE ONE THAT MATTERS. A word in both lists makes the outcome of a tool-running
    /// decision a coin toss. It must resolve to DENY, never to approve.
    func testACollidingKeywordResolvesToDeny() {
        let resolved = JarvisApprovalKeywords.resolve(approveRaw: "go, approve", denyRaw: "go")
        XCTAssertFalse(resolved.approve.contains("go"), "A colliding word must not approve: \(resolved.approve)")
        XCTAssertTrue(resolved.deny.contains("go"))
        XCTAssertTrue(resolved.problems.contains(.collided(["go"])))
    }

    /// The pathological case: the user sets the SAME single word for both. Resolving the collision
    /// must not leave the approve list empty and must not re-create the collision.
    func testIdenticalSingleKeywordsStillLeaveAWorkingChannel() {
        let resolved = JarvisApprovalKeywords.resolve(approveRaw: "go", denyRaw: "go")
        XCTAssertFalse(resolved.approve.isEmpty)
        XCTAssertTrue(resolved.deny.contains("go"))
        XCTAssertTrue(Set(resolved.approve).isDisjoint(with: Set(resolved.deny)),
                      "Approve and deny must never share a word: \(resolved)")
    }

    func testApproveAndDenyAreAlwaysDisjointForAnyInput() {
        for (a, d) in [("approve", "deny"), ("yes, no", "no"), ("deny", "deny"), ("", ""), ("x", "y")] {
            let resolved = JarvisApprovalKeywords.resolve(approveRaw: a, denyRaw: d)
            XCTAssertTrue(Set(resolved.approve).isDisjoint(with: Set(resolved.deny)),
                          "approve=\(a) deny=\(d) produced overlap: \(resolved)")
            XCTAssertFalse(resolved.approve.isEmpty)
            XCTAssertFalse(resolved.deny.isEmpty)
        }
    }
}

/// ⚠️ A SOURCE-READING TEST, following the precedent of the tool-capability guard. It fails the
/// build if Jarvis ever grows a path to a DURABLE grant. A comment saying "don't do this" stops
/// working the moment someone adds a call site; this does not.
final class JarvisDurableGrantGuardTests: XCTestCase {

    func testJarvisNeverCreatesADurableApprovalGrant() throws {
        let jarvisDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Jarvis
            .deletingLastPathComponent()      // devgenticTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Devgentic/Jarvis")

        let files = try FileManager.default
            .contentsOfDirectory(at: jarvisDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "Guard is worthless if it scans nothing — check the path.")

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Comments explain WHY the call is absent; only real calls matter.
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///"), !code.hasPrefix("*") else { continue }
                XCTAssertFalse(code.contains("SessionToolApprovals.shared.allow("),
                               """
                               \(file.lastPathComponent):\(index + 1) creates a DURABLE approval grant. \
                               A grant made from a misheard word survives the conversation AND the app \
                               restart. Jarvis approvals must be one-shot (`submitToolApproval`).
                               """)
            }
        }
    }
}

/// [Audit Batch 5] The read-back is the entire justification for letting a microphone commit an
/// action, so what it omits is a security property, not a phrasing choice.
final class JarvisApprovalReadBackTests: XCTestCase {

    /// ⚠️⚠️ THE ONE THAT MATTERED. The old read-back reduced every path to its last component, so
    /// `/Users/alice/.ssh/id_rsa` was spoken as "id_rsa" — and `read_file` returns file CONTENTS.
    /// The directory is exactly what distinguishes a harmless note from a private key.
    func testTheDirectoryIsNeverDroppedFromASpokenPath() {
        let spoken = JarvisApprovalPolicy.spokenPath("/Users/alice/.ssh/id_rsa")
        XCTAssertTrue(spoken.contains("ssh"), "The directory is the security-relevant half: \(spoken)")
        XCTAssertTrue(spoken.contains("id_rsa"))
    }

    func testHomeIsAbbreviatedButNothingElseIsDropped() {
        let home = NSHomeDirectory()
        let spoken = JarvisApprovalPolicy.spokenPath("\(home)/Documents/taxes/2026.pdf")
        XCTAssertTrue(spoken.hasPrefix("home"), "\(spoken)")
        for component in ["Documents", "taxes", "2026.pdf"] {
            XCTAssertTrue(spoken.contains(component), "\(component) was dropped: \(spoken)")
        }
    }

    /// A path outside home keeps every component — that is where the surprising ones live.
    func testASystemPathIsSpokenInFull() {
        let spoken = JarvisApprovalPolicy.spokenPath("/etc/ssh/sshd_config")
        for component in ["etc", "ssh", "sshd_config"] {
            XCTAssertTrue(spoken.contains(component), "\(component) was dropped: \(spoken)")
        }
    }

    func testSeparatorsAreAudible() {
        // Heard, a path with no separators is one long unintelligible word.
        XCTAssertTrue(JarvisApprovalPolicy.spokenPath("/etc/hosts").contains("slash"))
    }

    /// ⚠️ Truncation must be admitted. A silent clip loses the tail of an argument, which is where
    /// a suffix or a query string lives.
    func testALongArgumentSaysThatItWasTruncated() {
        let long = String(repeating: "a", count: 300)
        let confirmation = PendingToolConfirmation(
            toolName: "read_file", params: "{}", risk: .safe,
            arguments: .object(["note": .string(long)]))
        let spoken = JarvisApprovalPolicy.spokenArguments(confirmation)
        XCTAssertNotNil(spoken)
        XCTAssertTrue(spoken!.contains("and more"), "Truncation must be audible: \(spoken!)")
    }
}

/// [Audit Batch 5 · #57] The collision resolver's last-resort substitution was never re-checked,
/// so Jarvis could instruct the user to say a word that denies.
final class JarvisApprovalKeywordFallbackTests: XCTestCase {

    func testAFallbackIsNeverAWordThatDenies() {
        // The pathological input: every natural approve word claimed for denial.
        let resolved = JarvisApprovalKeywords.resolve(
            approveRaw: "approve",
            denyRaw: "approve, confirm, go ahead, accept, affirmative"
        )
        XCTAssertTrue(Set(resolved.approve).isDisjoint(with: Set(resolved.deny)),
                      "Jarvis would tell the user to say a word that denies: \(resolved)")
        XCTAssertFalse(resolved.approve.isEmpty)
    }

    func testTheOriginalReportedCase() {
        // "approve, confirm" in deny used to produce approve = ["confirm"] — overlapping.
        let resolved = JarvisApprovalKeywords.resolve(approveRaw: "approve", denyRaw: "approve, confirm")
        XCTAssertFalse(resolved.approve.contains("confirm"), "\(resolved)")
        XCTAssertTrue(Set(resolved.approve).isDisjoint(with: Set(resolved.deny)))
    }

    func testTheLadderPrefersNaturalWordsBeforeTheUnusableOne() {
        let resolved = JarvisApprovalKeywords.resolve(approveRaw: "approve", denyRaw: "approve")
        XCTAssertEqual(resolved.approve, ["confirm"], "The next natural candidate should win: \(resolved)")
    }
}
