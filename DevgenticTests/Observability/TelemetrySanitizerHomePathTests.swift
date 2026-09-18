// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TelemetrySanitizerHomePathTests.swift
//  devgenticTests
//
//  The redaction that ate 221 characters of an agent's answer.
//
//  ⚠️⚠️ THE FAILURE THIS PINS, OBSERVED IN A REAL LAUNCH LOG (2026-09-11). `sanitizeHomePath` matched
//  the username with `[^\/]+` — "anything that is not a slash". That is only the username when a
//  slash actually follows it, and in PROSE it does not. An agent reply beginning ``The home
//  directory (`/Users/dev`) contains both files and many folders.`` carries no forward slash for 221
//  characters after the username, so a single match swallowed the entire paragraph — newlines
//  included — and the log line read ``The home directory (`/[USER_PATH]/`, `Desktop/`.``
//
//  ⚠️ IT WAS INVISIBLE BECAUSE THE DAMAGE LOOKED LIKE REDACTION. `[USER_PATH]` is exactly what a
//  reader expects to see, so a line missing a paragraph reads as a line that was correctly
//  sanitised. The only reason it surfaced is that an UNSANITISED twin of the same string was printed
//  two lines later and did not match.
//
//  ⚠️ THIS IS THE FOURTH INSTANCE OF ONE CLASS IN THIS REPO: a transform that shape-matches a
//  payload and rewrites content it never intended to touch. See the path-normalisation corruption
//  register — the rule there was "key off the argument NAME, not the shape", and the rule here is
//  the same in miniature: match the token you mean, not everything that is not a delimiter.
//

import XCTest
@testable import devgentic

final class TelemetrySanitizerHomePathTests: XCTestCase {

    /// The exact string from the 2026-09-11 launch log, byte for byte.
    private let realAgentReply = """
        The home directory (`/Users/dev`) contains both files and many folders.

        Based on the listing, there are **2 files** directly in your home folder:

        *   `Google Drive` (65 bytes)

        The remaining contents are directories, including `Applications/`, `Desktop/`, `Documents/`.
        """

    // MARK: - The regression

    func testProseAfterAHomePathSurvivesRedaction() {
        let sanitized = TelemetrySanitizer.sanitizeHomePath(realAgentReply)

        XCTAssertTrue(sanitized.contains("[USER_PATH]"), "the home path must still be redacted")
        XCTAssertFalse(sanitized.contains("/Users/dev"), "the username must not survive")

        for fragment in ["contains both files and many folders",
                         "there are **2 files** directly in your home folder",
                         "`Google Drive` (65 bytes)",
                         "The remaining contents are directories"] {
            XCTAssertTrue(sanitized.contains(fragment), """
                Redaction ate content: `\(fragment)` is gone. The username class matched across \
                prose to the next slash. A log line missing a paragraph reads as one that was \
                correctly sanitised, which is why this went unnoticed.
                """)
        }
    }

    /// ⚠️ THE BLAST RADIUS, STATED AS A NUMBER. One match consumed 221 characters; anything less
    /// than "almost all of it survives" means the class is unbounded again.
    func testRedactionRemovesOnlyTheUsername() {
        let sanitized = TelemetrySanitizer.sanitizeHomePath(realAgentReply)
        let lost = realAgentReply.count - sanitized.count

        // "/Users/dev" (10) → "/[USER_PATH]" (12): the string should GROW slightly.
        XCTAssertLessThanOrEqual(lost, 0, """
            Sanitising shortened the text by \(lost) characters. Replacing `/Users/dev` with \
            `/[USER_PATH]` should lengthen it; any shortening means content was consumed.
            """)
    }

    // MARK: - Paths must still redact correctly

    func testOrdinaryPathsAreStillRedactedAndTheirTailPreserved() {
        let cases: [(String, String)] = [
            ("/Users/alice/Documents/foo.swift", "/[USER_PATH]/Documents/foo.swift"),
            ("/home/bob/x.log",                  "/[USER_PATH]/x.log"),
            ("/Users/john.doe/Library",          "/[USER_PATH]/Library"),
            ("cwd is /Users/dev",                "cwd is /[USER_PATH]")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TelemetrySanitizer.sanitizeHomePath(input), expected)
        }
    }

    /// ⚠️ THE REASON THIS USES AN EXCLUSION CLASS AND NOT `[A-Za-z0-9._-]+`. The allowlist describes
    /// a POSIX username exactly and would fix the corruption — but it UNDER-redacts every username
    /// it does not describe, which this file's header calls the worse failure of the two: "a stray
    /// path slipping into a bug report is a privacy regression; a filename accidentally showing as
    /// `[USER_PATH]/foo.swift` is annoying but safe."
    func testUnusualUsernamesAreFullyRedactedRatherThanPartially() {
        for input in ["/Users/CORP\\jsmith/Desktop", "/Users/josé/Music/a.mp3", "/Users/o'brien/x"] {
            let sanitized = TelemetrySanitizer.sanitizeHomePath(input)
            XCTAssertFalse(sanitized.contains("jsmith"), "leaked a domain-joined username: \(sanitized)")
            XCTAssertFalse(sanitized.contains("é"), "leaked a non-ASCII username tail: \(sanitized)")
            XCTAssertTrue(sanitized.contains("[USER_PATH]"), "did not redact at all: \(sanitized)")
        }
    }

    /// A path inside a quoted or bracketed span must stop at the delimiter, not run past it.
    func testRedactionStopsAtQuotesAndBrackets() {
        XCTAssertEqual(TelemetrySanitizer.sanitizeHomePath("path=\"/Users/dev\" then more text"),
                       "path=\"/[USER_PATH]\" then more text")
        XCTAssertEqual(TelemetrySanitizer.sanitizeHomePath("(/Users/dev) and words"),
                       "(/[USER_PATH]) and words")
    }

    // MARK: - The composed passes

    /// The bug shipped through `sanitizeFull(.standard)`, which is what DGLogger metadata and
    /// `BundleExporter` actually call — so the fix has to hold there too, not only in isolation.
    func testTheFullStandardPassAlsoPreservesProse() {
        let sanitized = TelemetrySanitizer.sanitizeFull(realAgentReply, level: .standard)
        XCTAssertTrue(sanitized.contains("The remaining contents are directories"), """
            `sanitizeFull(.standard)` still eats prose after a home path. This is the pass DGLogger \
            applies to metadata at buffer-write time and the one exported diagnostic bundles carry, \
            so a defect here reaches every bug report.
            """)
        XCTAssertFalse(sanitized.contains("/Users/dev"))
    }

    /// ⚠️ ChatOps egress deliberately does NOT fold home paths — invariant 27 records why (the user
    /// asked the agent about their own files; answering `[USER_PATH]/main.swift` breaks the answer).
    /// This pins that boundary, so a future "just reuse the telemetry sanitizer" does not erase it.
    func testRemoteEgressStillDoesNotFoldHomePaths() {
        let sanitized = RemoteEgressSanitizer.credentialsOnly(realAgentReply)
        XCTAssertTrue(sanitized.contains("/Users/dev"), """
            The remote egress floor has started folding home paths. It must not: the user asked the \
            agent about their own files, and redacting the answer they asked for teaches them to \
            route around the sanitiser. Credentials only — see RemoteEgressSanitizer's header.
            """)
    }
}
