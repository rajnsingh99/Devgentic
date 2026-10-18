// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TrailingSidePanelAdoptionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class TrailingSidePanelAdoptionTests: XCTestCase {

    private let adopters = [
        "Devgentic/Interfaces/Shared/Chat/BackgroundTasksPanelView.swift",
        "Devgentic/Interfaces/Code/Git/GitChangesPanelView.swift",
    ]

    func testEveryTrailingPanelUsesTheSharedChrome() throws {
        for path in adopters {
            let code = try strippedSource(path)
            XCTAssertTrue(code.contains("TrailingSidePanel("), "\(path) does not use TrailingSidePanel")
            for duplicate in ["DragGesture(", "codeViewerLiveDragWidth =", "RoundedRectangle(cornerRadius: 16",
                              "keyboardShortcut(\"w\""] {
                XCTAssertFalse(code.contains(duplicate), "\(path) re-implements shared chrome (\(duplicate))")
            }
        }
    }

    /// The shared chrome still owns what the panels gave up — guards against it being hollowed out.
    func testTheSharedChromeOwnsTheDividerTheCardAndClose() throws {
        let code = try strippedSource("Devgentic/Interfaces/Shared/Chat/TrailingSidePanel.swift")
        XCTAssertTrue(code.contains("DragGesture("))
        XCTAssertTrue(code.contains("chatHistoryViewModel.codeViewerLiveDragWidth ="), "live drag width (CF-15)")
        XCTAssertTrue(code.contains("RoundedRectangle(cornerRadius: 16"))
        XCTAssertTrue(code.contains("keyboardShortcut(\"w\""))
    }

    private func strippedSource(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
