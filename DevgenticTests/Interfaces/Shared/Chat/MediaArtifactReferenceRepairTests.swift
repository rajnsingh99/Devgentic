// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MediaArtifactReferenceRepairTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class MediaArtifactReferenceRepairTests: XCTestCase {

    // MARK: - The repair

    /// The row's case: a `file://` URL that the legacy shim labelled `.remoteURL`. It is a disk
    /// path however it got labelled.
    func testFileURLLabelledRemoteIsReadAsADiskPath() {
        let url = URL(fileURLWithPath: "/tmp/devgentic-legacy-image.png")

        let repaired = MediaArtifactImageView.resolvableReference(for: .remoteURL(url))

        XCTAssertEqual(repaired, .diskPath(url))
    }

    /// A genuinely remote reference is left exactly as it was. Rewriting it to `.diskPath`
    /// would turn a clear refusal into a nonsense filesystem read of "https:/example.com/…".
    func testHTTPURLIsLeftAlone() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/picture.png"))

        XCTAssertEqual(MediaArtifactImageView.resolvableReference(for: .remoteURL(url)), .remoteURL(url))
    }

    /// The other two cases pass through untouched — the repair is scoped to the one shape the
    /// legacy shim produces.
    func testDiskPathAndEphemeralDataArePassedThrough() {
        let url = URL(fileURLWithPath: "/tmp/already-a-disk-path.png")
        let bytes = Data([0xDE, 0xAD])

        XCTAssertEqual(MediaArtifactImageView.resolvableReference(for: .diskPath(url)), .diskPath(url))
        XCTAssertEqual(MediaArtifactImageView.resolvableReference(for: .ephemeralData(bytes)), .ephemeralData(bytes))
    }

    // MARK: - Which failures may offer a Retry

    /// Only a genuinely remote reference is a dead end. This is what removes the Retry button
    /// and swaps the card's title to "Image not available".
    func testOnlyANonFileRemoteReferenceIsUnresolvable() throws {
        let remote = try XCTUnwrap(URL(string: "https://example.com/picture.png"))

        XCTAssertTrue(MediaArtifactImageView.isUnresolvable(.remoteURL(remote)))
        XCTAssertFalse(MediaArtifactImageView.isUnresolvable(.diskPath(URL(fileURLWithPath: "/tmp/x.png"))))
        XCTAssertFalse(MediaArtifactImageView.isUnresolvable(.ephemeralData(Data([0x01]))))
    }

    /// A missing file keeps its Retry: `resolve()` can succeed on a later read (the file can be
    /// back, or a permission can be granted). Losing that would turn a transient disk failure
    /// into a permanent "Image not available" the user cannot dismiss or re-attempt.
    func testAMissingFileIsStillRetriable() {
        let absent = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).png")

        XCTAssertFalse(MediaArtifactImageView.isUnresolvable(.diskPath(absent)))
    }

    /// The composed contract the view relies on: repair first, then ask. A `file://` reference
    /// must come out of that pair as retriable, or the repair buys nothing — the card would
    /// still refuse to try.
    func testARepairedFileReferenceIsNotTreatedAsADeadEnd() {
        let reference = MediaArtifactImageView.resolvableReference(
            for: .remoteURL(URL(fileURLWithPath: "/tmp/devgentic-legacy-image.png")))

        XCTAssertFalse(MediaArtifactImageView.isUnresolvable(reference))
    }

    // MARK: - End to end

    /// The row's user-visible claim, exercised against a real file: bytes that were unreachable
    /// through the raw reference are reachable through the repaired one.
    func testRepairedReferenceActuallyReadsTheBytesOffDisk() async throws {
        let bytes = Data("legacy generated image".utf8)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cf26-\(UUID().uuidString).png")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let legacy = MediaReference.remoteURL(url)

        // Core's rule is unchanged — the repair is the renderer's, not `MediaReference`'s.
        do {
            _ = try await legacy.resolve()
            XCTFail("`.remoteURL` must still be refused by MediaReference itself")
        } catch {
            XCTAssertTrue(error is MediaReferenceError, "Expected the documented refusal, got \(error)")
        }

        let loaded = try await MediaArtifactImageView.resolvableReference(for: legacy).resolve()
        XCTAssertEqual(loaded, bytes, "The picture was readable on disk the whole time")
    }
}
