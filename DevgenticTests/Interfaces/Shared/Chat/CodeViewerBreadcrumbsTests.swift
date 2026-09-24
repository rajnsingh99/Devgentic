// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeViewerBreadcrumbsTests.swift
//  DevgenticTests
//
//  Covers Phase 4: Directory Breadcrumbs & Navigation:
//  - CodeViewerBreadcrumbItem.breadcrumbs generation for file-backed tabs.
//  - Home directory path normalization to "~/...".
//  - Attachment / relative path splitting for slash-separated filenames.
//  - Snippet fallback single-segment item generation.
//  - formatRelativePath helper normalization.
//  - codeViewerLanguageIcon symbol mappings.
//

import XCTest
@testable import devgentic

final class CodeViewerBreadcrumbsTests: XCTestCase {

    // MARK: - File-Backed Path Tests

    func testBreadcrumbsForFileInHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let filePath = "\(home)/Developer/Devgentic/Sources/App.swift"

        let snippet = CodeSnippet(language: "swift", code: "print(1)")
        let tab = CodeViewerTab(snippet: snippet, fileName: "App.swift", filePath: filePath)

        let items = CodeViewerBreadcrumbItem.breadcrumbs(for: tab)

        XCTAssertFalse(items.isEmpty)
        XCTAssertEqual(items.first?.name, "~")
        XCTAssertEqual(items.first?.isFolder, true)
        XCTAssertEqual(items.first?.isLast, false)

        XCTAssertEqual(items.last?.name, "App.swift")
        XCTAssertEqual(items.last?.isFolder, false)
        XCTAssertEqual(items.last?.isLast, true)
        XCTAssertEqual(items.last?.fullURL?.path, filePath)

        // Verify folder sequence: ~, Developer, Devgentic, Sources
        let names = items.map { $0.name }
        XCTAssertEqual(names, ["~", "Developer", "Devgentic", "Sources", "App.swift"])

        // Check cumulative paths
        for (i, item) in items.enumerated() {
            if i < items.count - 1 {
                XCTAssertTrue(item.isFolder)
                XCTAssertFalse(item.isLast)
            } else {
                XCTAssertFalse(item.isFolder)
                XCTAssertTrue(item.isLast)
            }
        }
    }

    func testBreadcrumbsForNonHomeFilePath() {
        let filePath = "/opt/homebrew/etc/nginx.conf"
        let snippet = CodeSnippet(language: "nginx", code: "server {}")
        let tab = CodeViewerTab(snippet: snippet, fileName: "nginx.conf", filePath: filePath)

        let items = CodeViewerBreadcrumbItem.breadcrumbs(for: tab)

        let names = items.map { $0.name }
        XCTAssertEqual(names, ["opt", "homebrew", "etc", "nginx.conf"])

        XCTAssertEqual(items.last?.name, "nginx.conf")
        XCTAssertEqual(items.last?.isFolder, false)
        XCTAssertEqual(items.last?.isLast, true)
        XCTAssertEqual(items.last?.fullURL?.path, filePath)
    }

    // MARK: - Slash-Separated Filename Tests (Attachment / Virtual Tabs)

    func testBreadcrumbsForSlashSeparatedFileNameWithoutFilePath() {
        let snippet = CodeSnippet(language: "typescript", code: "export const x = 1;")
        let tab = CodeViewerTab(snippet: snippet, fileName: "src/components/Button.tsx", filePath: nil)

        let items = CodeViewerBreadcrumbItem.breadcrumbs(for: tab)

        let names = items.map { $0.name }
        XCTAssertEqual(names, ["src", "components", "Button.tsx"])

        XCTAssertTrue(items[0].isFolder)
        XCTAssertFalse(items[0].isLast)
        XCTAssertEqual(items[0].id, "src")

        XCTAssertTrue(items[1].isFolder)
        XCTAssertFalse(items[1].isLast)
        XCTAssertEqual(items[1].id, "src/components")

        XCTAssertFalse(items[2].isFolder)
        XCTAssertTrue(items[2].isLast)
        XCTAssertEqual(items[2].id, "src/components/Button.tsx")
        XCTAssertNil(items[2].fullURL)
    }

    // MARK: - Flat Filename and Snippet Fallback Tests

    func testBreadcrumbsForFlatFileName() {
        let snippet = CodeSnippet(language: "python", code: "print('hello')")
        let tab = CodeViewerTab(snippet: snippet, fileName: "script.py", filePath: nil)

        let items = CodeViewerBreadcrumbItem.breadcrumbs(for: tab)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "script.py")
        XCTAssertEqual(items.first?.isFolder, false)
        XCTAssertEqual(items.first?.isLast, true)
    }

    func testBreadcrumbsForAdHocSnippetWithoutFileName() {
        let snippet = CodeSnippet(language: "rust", code: "fn main() {}")
        let tab = CodeViewerTab(snippet: snippet, fileName: nil, filePath: nil)

        let items = CodeViewerBreadcrumbItem.breadcrumbs(for: tab)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "Rust")
        XCTAssertEqual(items.first?.isFolder, false)
        XCTAssertEqual(items.first?.isLast, true)
    }

    // MARK: - Relative Path Formatter Tests

    func testFormatRelativePathWithHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fullPath = "\(home)/Documents/Notes.txt"
        let relative = formatRelativePath(for: fullPath)
        XCTAssertEqual(relative, "~/Documents/Notes.txt")
    }

    func testFormatRelativePathOutsideHome() {
        let outsidePath = "/Library/Logs/system.log"
        let relative = formatRelativePath(for: outsidePath)
        XCTAssertEqual(relative, "system.log")
    }

    // MARK: - Language Icon Helper Tests

    func testCodeViewerLanguageIcons() {
        XCTAssertEqual(codeViewerLanguageIcon(for: "swift"), "swift")
        XCTAssertEqual(codeViewerLanguageIcon(for: "python"), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(codeViewerLanguageIcon(for: "typescript"), "curlybraces")
        XCTAssertEqual(codeViewerLanguageIcon(for: "rust"), "gearshape.2")
        XCTAssertEqual(codeViewerLanguageIcon(for: "markdown"), "text.document")
        XCTAssertEqual(codeViewerLanguageIcon(for: "unknown_xyz"), "doc.text")
        XCTAssertEqual(codeViewerLanguageIcon(for: nil), "doc.text")
    }
}
