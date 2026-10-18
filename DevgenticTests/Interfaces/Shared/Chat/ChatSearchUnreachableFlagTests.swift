// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatSearchUnreachableFlagTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class ChatSearchUnreachableFlagTests: XCTestCase {

    private func searchVM(query: String) -> ChatSearchViewModel {
        let vm = ChatSearchViewModel()
        vm.searchQuery = query
        let message = ChatMessage(conversationId: UUID(), sender: .user, content: .plainText("an error here"))
        vm.performSearch(in: [ChatSearchDecomposition.document(for: message)])
        return vm
    }

    func testFlagStartsClear() {
        XCTAssertFalse(ChatSearchViewModel().currentMatchUnreachable)
    }

    /// Editing the query produces a new match set; the old verdict must not label the new
    /// first match before the view has even tried to scroll to it.
    func testQueryEditClearsTheFlag() {
        let vm = searchVM(query: "error")
        vm.currentMatchUnreachable = true

        vm.searchQuery = "erro"

        XCTAssertFalse(vm.currentMatchUnreachable)
    }

    /// `didSet` is change-gated: re-assigning the same query is not an edit and must not
    /// clear a verdict the view just set.
    func testReassigningTheSameQueryKeepsTheFlag() {
        let vm = searchVM(query: "error")
        vm.currentMatchUnreachable = true

        vm.searchQuery = "error"

        XCTAssertTrue(vm.currentMatchUnreachable)
    }

    /// No matches → nothing can be unreachable. Covers the debounced empty-query run that
    /// lands AFTER the edit already cleared the flag once.
    func testEmptyQuerySearchClearsTheFlag() {
        let vm = searchVM(query: "error")
        vm.searchQuery = ""
        vm.currentMatchUnreachable = true   // as if set between the edit and the debounced run

        vm.performSearch(in: [])

        XCTAssertFalse(vm.currentMatchUnreachable)
        XCTAssertTrue(vm.matches.isEmpty, "sanity: the empty query cleared the matches")
    }

    func testDismissClearsTheFlag() {
        let vm = searchVM(query: "error")
        vm.currentMatchUnreachable = true

        vm.dismiss()

        XCTAssertFalse(vm.currentMatchUnreachable)
    }
}
