// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillCommandTests.swift
//  devgenticTests
//
//  The `/` composer trigger: when it fires, and what it turns a message into.
//
//  ⚠️ The boundary rule is the whole risk here. `#` and `@` fire at the start of a line OR after
//  whitespace, which is right for a mention. `/` with that rule fires on ordinary prose and paths —
//  `cd /usr`, `and/or`, `24/7` — popping a picker over someone's sentence mid-thought. It is a
//  trigger at offset 0 of the message and nowhere else, and the tests that say so are the ones to
//  protect.
//

import XCTest
@testable import devgentic

final class SkillTriggerBoundaryTests: XCTestCase {

    private func analyze(_ text: String, at cursor: Int? = nil) -> TextTriggerAnalyzer.Result? {
        TextTriggerAnalyzer.analyze(text: text, cursorLocation: cursor ?? (text as NSString).length)
    }

    // MARK: - It fires where it should

    func testFiresAtTheVeryStartOfTheMessage() throws {
        let result = try XCTUnwrap(analyze("/code"))
        XCTAssertEqual(result.type, .skill)
        XCTAssertEqual(result.query, "code")
        XCTAssertEqual(result.range, NSRange(location: 0, length: 5))
    }

    func testABareSlashOpensThePickerWithAnEmptyQuery() throws {
        let result = try XCTUnwrap(analyze("/"))
        XCTAssertEqual(result.type, .skill)
        XCTAssertEqual(result.query, "")
    }

    func testHyphenatedNamesKeepMatching() throws {
        XCTAssertEqual(try XCTUnwrap(analyze("/code-rev")).query, "code-rev")
    }

    // MARK: - It must NOT fire anywhere else

    /// ⚠️ THE TESTS THIS FILE EXISTS FOR. Every one of these is a real thing people type.
    func testDoesNotFireInsideOrdinaryProse() {
        for text in [
            "cd /usr",                  // a shell path
            "look in /etc/hosts",       // a path mid-sentence
            "and/or",                   // a slash inside a word
            "24/7",                     // a ratio
            "read the docs /guide",     // a path-looking token after a space
            "line one\n/second"         // start of a LATER line — still not the message start
        ] {
            XCTAssertNil(TextTriggerAnalyzer.analyze(text: text, cursorLocation: (text as NSString).length),
                         "'\(text)' must not open the skill picker")
        }
    }

    /// The `#`/`@` rule is deliberately looser and must stay that way — a mention IS mid-sentence.
    func testTheLooserRuleStillAppliesToPromptAndFile() throws {
        XCTAssertEqual(try XCTUnwrap(analyze("some text #sum")).type, .prompt)
        XCTAssertEqual(try XCTUnwrap(analyze("attach @rep")).type, .file)
        XCTAssertEqual(try XCTUnwrap(analyze("line one\n#sum")).type, .prompt,
                       "a later line is still a valid boundary for #")
    }

    /// A space ends the command: once the user is typing arguments the picker must close, or it
    /// would sit over the message they are writing.
    func testTheQueryEndsAtTheFirstSpace() {
        XCTAssertNil(analyze("/code-review fix this"))
    }
}

// MARK: - Parsing and rewriting

final class SkillCommandParserTests: XCTestCase {

    func testParsesACommandWithArguments() {
        XCTAssertEqual(SkillCommandParser.parse("/code-review fix the tests"),
                       SkillCommand(skillName: "code-review", arguments: "fix the tests"))
    }

    func testParsesABareCommand() {
        XCTAssertEqual(SkillCommandParser.parse("/code-review"),
                       SkillCommand(skillName: "code-review", arguments: ""))
    }

    /// A real request is often multi-line; the newline ends the NAME, not the command.
    func testANewlineEndsTheNameAndTheRestIsArguments() {
        XCTAssertEqual(SkillCommandParser.parse("/code-review\nline one\nline two"),
                       SkillCommand(skillName: "code-review", arguments: "line one\nline two"))
    }

    /// ⚠️ Same offset-0 rule as the trigger. These two definitions must never drift apart.
    func testOnlyParsesAtTheStartOfTheMessage() {
        XCTAssertNil(SkillCommandParser.parse("please /code-review this"))
        XCTAssertNil(SkillCommandParser.parse(" /code-review"))
        XCTAssertNil(SkillCommandParser.parse("cd /usr"))
    }

    /// ⚠️ Shape-validated, so a path fragment cannot parse as a command and get someone's text
    /// rewritten. The charset is the same one every skill name passes at import.
    func testAPathLikeTokenIsNotACommand() {
        XCTAssertNil(SkillCommandParser.parse("/../../etc/passwd"))
        XCTAssertNil(SkillCommandParser.parse("/Users/alice/notes.md"))
        XCTAssertNil(SkillCommandParser.parse("/UPPER"))
        XCTAssertNil(SkillCommandParser.parse("//"))
    }

    // MARK: - Rendering

    func testRendersADirectiveWithTheRequestLast() throws {
        let rendered = SkillCommandParser.render(
            SkillCommand(skillName: "code-review", arguments: "fix the tests"),
            availableNames: ["code-review"])

        XCTAssertTrue(rendered.hasPrefix("Use the code-review skill"))
        XCTAssertTrue(rendered.contains("load_skill"))

        // ⚠️ ASSERTED AS TWO BLOCKS, not merely "ends with the request" — a mutation that folded the
        // request into the directive ("… The request: fix the tests") passed that weaker check,
        // because it also ends with the request. Splitting on the blank line is what actually pins
        // the property: a long request must stay its own paragraph, or it reads as one clause of an
        // instruction and gets summarised instead of done.
        let blocks = rendered.components(separatedBy: "\n\n")
        XCTAssertEqual(blocks.count, 2, "directive and request must be separate paragraphs")
        XCTAssertEqual(blocks.last, "fix the tests", "the user's own words, verbatim and alone")
        XCTAssertFalse(try XCTUnwrap(blocks.first).contains("fix the tests"),
                       "the request must not also appear inside the directive sentence")
    }

    /// ⚠️ "if it applies". `/` is the user POINTING at a skill, not asserting it fits; a model made
    /// to use a mismatched skill produces confidently wrong work.
    func testTheDirectiveLeavesTheModelRoomToDecline() {
        let rendered = SkillCommandParser.render(
            SkillCommand(skillName: "code-review", arguments: "x"), availableNames: ["code-review"])
        XCTAssertTrue(rendered.contains("if it applies"))
    }

    func testABareCommandRendersTheDirectiveAlone() {
        let rendered = SkillCommandParser.render(
            SkillCommand(skillName: "code-review", arguments: ""), availableNames: ["code-review"])
        XCTAssertFalse(rendered.contains("\n\n"), "no empty request paragraph")
    }

    /// ⚠️ AN UNKNOWN SKILL IS LEFT EXACTLY AS TYPED. Rewriting it would send an instruction the
    /// model cannot follow — it would apologise for a skill it never had — and would hide the typo
    /// from the one person who can fix it.
    func testAnUnavailableSkillIsNotRewritten() {
        XCTAssertEqual(
            SkillCommandParser.render(SkillCommand(skillName: "not-linked", arguments: "do it"),
                                      availableNames: ["code-review"]),
            "/not-linked do it")
        XCTAssertEqual(
            SkillCommandParser.render(SkillCommand(skillName: "not-linked", arguments: ""),
                                      availableNames: []),
            "/not-linked")
    }
}
