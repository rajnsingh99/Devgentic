// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitHubIssueLinkTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class GitHubIssueLinkTests: XCTestCase {

    private func queryKeys(_ kind: GitHubIssueLink.Kind) throws -> [String: String] {
        let url = try XCTUnwrap(GitHubIssueLink.url(for: kind))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func templateSource(_ name: String) throws -> String {
        let root = try TestRepositorySource.root()
        return try String(contentsOf: root.appendingPathComponent(".github/ISSUE_TEMPLATE/\(name)"),
                          encoding: .utf8)
    }

    /// Every pre-filled key except `template` must be a field id declared in that form.
    private func assertEveryKeyIsAFieldID(_ kind: GitHubIssueLink.Kind,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let keys = try queryKeys(kind)
        let template = try XCTUnwrap(keys["template"], file: file, line: line)
        let source = try templateSource(template)
        for key in keys.keys where key != "template" {
            XCTAssertTrue(source.contains("id: \(key)\n"), """
                \(template) has no field with id '\(key)'. GitHub ignores the unknown query key, so \
                the app's pre-fill of '\(key)' silently stops working. Restore the id or update \
                GitHubIssueLink.
                """, file: file, line: line)
        }
    }

    func testTheBugLinkPrefillsFieldsTheBugFormDeclares() throws {
        try assertEveryKeyIsAFieldID(.bug)
        XCTAssertEqual(Set(try queryKeys(.bug).keys), ["template", "version", "macos", "hardware"])
    }

    func testTheFeatureLinkPrefillsFieldsTheFeatureFormDeclares() throws {
        try assertEveryKeyIsAFieldID(.feature)
        XCTAssertEqual(Set(try queryKeys(.feature).keys), ["template", "version"])
    }

    /// Only build, OS and hardware travel to the public tracker — never a free-text field the
    /// user has not seen.
    func testNothingButEnvironmentIsPrefilled() throws {
        for kind in [GitHubIssueLink.Kind.bug, .feature] {
            let keys = try queryKeys(kind)
            XCTAssertNil(keys["body"])
            XCTAssertNil(keys["what-happened"])
            XCTAssertNil(keys["title"])
        }
    }
}
