// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  URLPathComparisonTests.swift
//  DevgenticTests
//
//  `URL` equality is not location equality, and four separate places in this codebase compared
//  file URLs with `==` after `standardizedFileURL` and got it wrong. These pin the two rules.
//
//  Found by writing a real test for A14's identity check — the assertion failed, and it was the
//  production code that was wrong, not the expectation.
//

import XCTest
@testable import devgentic

final class URLPathComparisonTests: XCTestCase {

    // MARK: - The trap itself

    /// The behaviour every one of these bugs rested on. If Foundation ever changes this, the
    /// helpers below become unnecessary and this test says so.
    func testStandardizedFileURLDoesNotNormalizeTheTrailingSlash() {
        let plain = URL(fileURLWithPath: "/models/mlx-community/Phi-4", isDirectory: false)
        let dir = URL(fileURLWithPath: "/models/mlx-community/Phi-4", isDirectory: true)

        XCTAssertNotEqual(
            plain.standardizedFileURL, dir.standardizedFileURL,
            "if these are equal, `URL` equality is safe and the helpers are redundant"
        )
        XCTAssertEqual(plain.standardizedFileURL.path, dir.standardizedFileURL.path,
                       "…but their paths agree, which is why the helpers compare `.path`")
    }

    // MARK: - Lexical

    func testDirectoryFlavourIsIgnored() {
        let plain = URL(fileURLWithPath: "/models/mlx-community/Phi-4", isDirectory: false)
        let dir = URL(fileURLWithPath: "/models/mlx-community/Phi-4", isDirectory: true)

        XCTAssertTrue(plain.sameLocationLexically(as: dir))
        XCTAssertTrue(dir.sameLocationLexically(as: plain))
    }

    /// The flavours the real code actually produces: `deletingLastPathComponent()` yields a
    /// directory URL, `appendingPathComponent` does not. This is the exact pair that made
    /// `container(expecting:)` refuse a correctly-loaded model.
    func testTheTwoFlavoursTheAppActuallyProducesAgree() {
        let root = URL(fileURLWithPath: "/models/models/mlx-community")
        let viaAppending = root.appendingPathComponent("Phi-4-mini-instruct-4bit")
        let viaDeleting = root
            .appendingPathComponent("Phi-4-mini-instruct-4bit/config.json")
            .deletingLastPathComponent()

        XCTAssertTrue(
            viaAppending.sameLocationLexically(as: viaDeleting),
            "scanDisk and HubApi's resolver must agree on the same model folder"
        )
    }

    func testDotSegmentsAreResolved() {
        let direct = URL(fileURLWithPath: "/models/mlx-community/Phi-4")
        let indirect = URL(fileURLWithPath: "/models/other/../mlx-community/./Phi-4")
        XCTAssertTrue(direct.sameLocationLexically(as: indirect))
    }

    func testDifferentLocationsDoNotMatch() {
        let a = URL(fileURLWithPath: "/models/mlx-community/Phi-4")
        let b = URL(fileURLWithPath: "/models/mlx-community/Phi-5")
        XCTAssertFalse(a.sameLocationLexically(as: b))
        XCTAssertFalse(a.sameLocation(as: b))
    }

    /// A prefix is not a match — the guard must not treat a parent as the same folder.
    func testAParentDirectoryIsNotTheSameLocation() {
        let parent = URL(fileURLWithPath: "/models/mlx-community")
        let child = URL(fileURLWithPath: "/models/mlx-community/Phi-4")
        XCTAssertFalse(parent.sameLocationLexically(as: child))
        XCTAssertFalse(parent.sameLocation(as: child))
    }

    // MARK: - Symlinks

    /// ⚠️ Measured, not assumed. `resolvingSymlinksInPath()` does NOT rewrite `/var` to
    /// `/private/var` on macOS — it does the reverse, STRIPPING a `/private` prefix, and
    /// `standardizedFileURL` strips it too. So the `/var` ↔ `/private/var` pair was never the
    /// problem, and `QuickAccessScreenCaptureService.isCaptureTempFile` was NOT broken.
    ///
    /// A real, user-created symlink is a different matter: it diverges lexically and only
    /// `sameLocation` sees through it. That is the whole difference between the two helpers,
    /// so it is what this pins.
    func testARealSymlinkIsOnlyResolvedByTheNonLexicalComparison() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("url-cmp-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertFalse(
            link.sameLocationLexically(as: real),
            "the lexical comparison cannot see through a symlink — that is its documented limit"
        )
        XCTAssertTrue(
            link.sameLocation(as: real),
            "sameLocation resolves symlinks; this is the only reason to pay for the filesystem access"
        )
    }

    /// The `/private` prefix — the case it would be easy to assume is broken. It is not:
    /// both helpers already handle it, because `standardizedFileURL` strips `/private`.
    func testThePrivatePrefixIsNormalizedByBothComparisons() {
        let tmp = FileManager.default.temporaryDirectory
        let privateForm = URL(fileURLWithPath: "/private" + tmp.path, isDirectory: true)

        XCTAssertTrue(tmp.sameLocationLexically(as: privateForm))
        XCTAssertTrue(tmp.sameLocation(as: privateForm))
    }

    /// The capture sweep's real predicate, including the `/private` form a caller might hand it.
    func testACaptureTempFileIsRecognisedInEitherFormOfTheTempPath() {
        let name = QuickAccessScreenCaptureService.captureFilePrefix + "test.png"
        let tmp = FileManager.default.temporaryDirectory
        let direct = tmp.appendingPathComponent(name)
        let privateForm = URL(fileURLWithPath: "/private" + tmp.path, isDirectory: true)
            .appendingPathComponent(name)

        XCTAssertTrue(QuickAccessScreenCaptureService.isCaptureTempFile(direct))
        XCTAssertTrue(
            QuickAccessScreenCaptureService.isCaptureTempFile(privateForm),
            "either spelling of the temp path must be swept — a miss leaves a secret-bearing screenshot behind"
        )
    }

    /// …and the guard still confines deletion to our own files.
    func testNonCaptureFilesAreNotClaimed() {
        let tmp = FileManager.default.temporaryDirectory
        XCTAssertFalse(
            QuickAccessScreenCaptureService.isCaptureTempFile(tmp.appendingPathComponent("someone-elses.png")),
            "the prefix check is what keeps this from deleting unrelated temp files"
        )
        XCTAssertFalse(
            QuickAccessScreenCaptureService.isCaptureTempFile(
                URL(fileURLWithPath: "/Users/someone/Documents/"
                    + QuickAccessScreenCaptureService.captureFilePrefix + "decoy.png")
            ),
            "the prefix alone must not qualify a file outside the temporary directory"
        )
    }
}
