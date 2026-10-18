// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BundledDocumentTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class BundledDocumentTests: XCTestCase {

    private let repoFile: [BundledDocument: String] = [
        .privacyPolicy: "PRIVACY.md",
        .license: "LICENSE",
        .thirdPartyNotices: "THIRD_PARTY_NOTICES.md",
    ]

    /// Each shipped copy is the repo file, byte for byte — the build phase copies them on every
    /// build, so there is no second version to drift. Fails if the build phase stops copying one.
    func testEveryDocumentShipsInTheAppUnchanged() throws {
        XCTAssertEqual(Set(BundledDocument.allCases), Set(repoFile.keys), "a document without a repo file")
        for document in BundledDocument.allCases {
            let shipped = try XCTUnwrap(document.load(), "\(document.rawValue) is not in the app bundle")
            let repo = try source(repoFile[document]!)
            XCTAssertEqual(shipped, repo, "the bundled \(document.rawValue) differs from the repo's")
        }
    }

    /// The AGPL is plain text: as Markdown its numbered sections would become lists.
    func testOnlyTheLicenseIsRenderedAsPlainText() {
        XCTAssertFalse(BundledDocument.license.isMarkdown)
        XCTAssertTrue(BundledDocument.privacyPolicy.isMarkdown)
        XCTAssertTrue(BundledDocument.thirdPartyNotices.isMarkdown)
    }

    func testPlainTextSplitsIntoParagraphsWithoutLosingText() throws {
        let text = try XCTUnwrap(BundledDocument.license.load())
        let paragraphs = BundledDocument.paragraphs(of: text)
        XCTAssertGreaterThan(paragraphs.count, 50, "the licence should split into many paragraphs for lazy rendering")
        let squash = { (s: String) in s.filter { !$0.isWhitespace } }
        XCTAssertEqual(squash(paragraphs.joined()), squash(text), "splitting dropped text")
    }

    /// Wiring: every document is in the Help menu, there is a window to open them in, and the setup
    /// assistant's Privacy step links the policy.
    func testEveryDocumentIsReachableFromTheApp() throws {
        let app = try source("Devgentic/DevgenticApp.swift")
        for document in BundledDocument.allCases {
            let caseName = String(describing: document)
            XCTAssertTrue(app.contains("openWindow(id: BundledDocument.windowGroupID, value: BundledDocument.\(caseName))"),
                          "no Help menu item for \(caseName)")
        }
        XCTAssertTrue(app.contains("WindowGroup(\"Document\", id: BundledDocument.windowGroupID, for: BundledDocument.self)"),
                      "no window to open them in")
        let onboarding = try source("Devgentic/Interfaces/Onboarding/Views/OnboardingPrivacyView.swift")
        XCTAssertTrue(onboarding.contains("BundledDocumentView(document: .privacyPolicy)"), "the Privacy step no longer links the policy")
        let policy = try source("PRIVACY.md")
        XCTAssertTrue(policy.contains("**Help → Privacy Policy**"), "the policy says where to find it in the app")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text
    }
}
