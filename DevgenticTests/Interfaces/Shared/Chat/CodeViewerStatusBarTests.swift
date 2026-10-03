// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeViewerStatusBarTests.swift
//  DevgenticTests
//
//  Covers Phase 3: Editor Status Bar logic:
//  - CodeViewerStatusBarState tracking line, column, selection length and reset.
//  - CodeViewerTab customLanguage override and effectiveLanguage resolution.
//  - CodeLanguage display names, common languages, and sorted collections.
//

import XCTest
import CodeEditSourceEditor
import CodeEditLanguages
@testable import devgentic

@MainActor
private final class MockChatStore: ChatPersistenceProtocol {
    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] { [] }
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

@MainActor
final class CodeViewerStatusBarTests: XCTestCase {

    // MARK: - Status Bar State Tests

    func testStatusBarStateDefaultValues() {
        let state = CodeViewerStatusBarState()
        XCTAssertEqual(state.line, 1)
        XCTAssertEqual(state.column, 1)
        XCTAssertEqual(state.selectionLength, 0)
    }

    func testStatusBarStateUpdatesFromCursorPosition() {
        let state = CodeViewerStatusBarState()
        let editorState = SourceEditorState(
            cursorPositions: [CursorPosition(line: 42, column: 15)]
        )

        state.update(from: editorState)

        XCTAssertEqual(state.line, 42)
        XCTAssertEqual(state.column, 15)
        XCTAssertEqual(state.selectionLength, 0)
    }

    func testStatusBarStateUpdatesSelectionLength() {
        let state = CodeViewerStatusBarState()
        let editorState = SourceEditorState(
            cursorPositions: [CursorPosition(range: NSRange(location: 100, length: 25))]
        )

        state.update(from: editorState)

        XCTAssertEqual(state.selectionLength, 25)
    }

    func testStatusBarStateReset() {
        let state = CodeViewerStatusBarState()
        let editorState = SourceEditorState(
            cursorPositions: [CursorPosition(line: 99, column: 30)]
        )
        state.update(from: editorState)
        XCTAssertEqual(state.line, 99)

        state.reset()
        XCTAssertEqual(state.line, 1)
        XCTAssertEqual(state.column, 1)
        XCTAssertEqual(state.selectionLength, 0)
    }

    // MARK: - Tab Language Override Tests

    func testCodeViewerTabCustomLanguageOverride() {
        let snippet = CodeSnippet(language: "swift", code: "print(\"hello\")")
        var tab = CodeViewerTab(snippet: snippet)

        XCTAssertEqual(tab.effectiveLanguage, "swift")
        XCTAssertEqual(tab.title, "Swift")

        tab.customLanguage = "python"
        XCTAssertEqual(tab.effectiveLanguage, "python")
        XCTAssertEqual(tab.title, "Python")
    }

    func testChatHistoryViewModelUpdateCodeViewerTabLanguage() {
        let snippet = CodeSnippet(language: "json", code: "{}")
        let tab = CodeViewerTab(snippet: snippet)
        let store = MockChatStore()
        let vm = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            )
        )
        vm.codeViewerTabs = [tab]
        vm.activeCodeViewerTabID = tab.id

        vm.updateCodeViewerTabLanguage(tabID: tab.id, language: "yaml")

        XCTAssertEqual(vm.codeViewerTabs.first?.customLanguage, "yaml")
        XCTAssertEqual(vm.codeViewerTabs.first?.effectiveLanguage, "yaml")
    }

    // MARK: - CodeLanguage Extensions Tests

    func testCodeLanguageDisplayNames() {
        XCTAssertEqual(CodeLanguage.swift.displayName, "Swift")
        XCTAssertEqual(CodeLanguage.typescript.displayName, "TypeScript")
        XCTAssertEqual(CodeLanguage.javascript.displayName, "JavaScript")
        XCTAssertEqual(CodeLanguage.python.displayName, "Python")
        XCTAssertEqual(CodeLanguage.default.displayName, "Plain Text")
        XCTAssertEqual(CodeLanguage.cpp.displayName, "C++")
        XCTAssertEqual(CodeLanguage.cSharp.displayName, "C#")
        XCTAssertEqual(CodeLanguage.html.displayName, "HTML")
        XCTAssertEqual(CodeLanguage.css.displayName, "CSS")
    }

    func testCommonLanguagesListContainsKeyLanguages() {
        let common = CodeLanguage.commonLanguages
        let ids = common.map(\.id)

        XCTAssertTrue(ids.contains(.swift))
        XCTAssertTrue(ids.contains(.typescript))
        XCTAssertTrue(ids.contains(.python))
        XCTAssertTrue(ids.contains(.plainText))
    }

    func testAllSortedLanguagesAreAlphabetized() {
        let all = CodeLanguage.allSortedLanguages
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.contains(where: { $0.id == .plainText }))

        // Verify strictly sorted
        for i in 0..<(all.count - 1) {
            let comparison = all[i].displayName.localizedCaseInsensitiveCompare(all[i + 1].displayName)
            XCTAssertTrue(comparison == .orderedAscending || comparison == .orderedSame,
                          "\(all[i].displayName) should appear before or equal to \(all[i + 1].displayName)")
        }
    }
}
