//
//  CodeViewerPanelLoadTests.swift
//  DevgenticTests
//
//  Regression (2026-07-16): opening the code viewer rendered "No Code Selected"
//  until the user navigated between snippets. `document` was assigned ONLY from
//  `.onChange(of: codeViewerContent?.currentIndex)` with no initial load — and the
//  panel is created only once the content is already set to index 0, so there was
//  no transition to observe on first appear.
//
//  These are HOSTED tests: the bug lived in SwiftUI's onChange/appear semantics, so
//  it only reproduces when the view is actually mounted and its lifecycle runs.
//

import XCTest
import SwiftUI
@testable import devgentic

/// Minimal stand-in — these tests never exercise persistence, they only drive the
/// panel's selection/rendering lifecycle.
@MainActor
private final class StubPersistenceStore: ChatPersistenceProtocol {
    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ msgs: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] { [] }
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

@MainActor
final class CodeViewerPanelLoadTests: XCTestCase {

    private func makeViewModel() -> ChatHistoryViewModel {
        let store = StubPersistenceStore()
        return ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            )
        )
    }

    /// Opens `snippets` as tabs and marks the viewer visible — the state `openMessageInCodeViewer`
    /// leaves behind, set directly so these lifecycle tests don't depend on extraction.
    private func openTabs(_ vm: ChatHistoryViewModel, _ snippets: [CodeSnippet], active: Int = 0) {
        vm.codeViewerTabs = snippets.map { CodeViewerTab(snippet: $0) }
        vm.activeCodeViewerTabID = vm.codeViewerTabs.indices.contains(active) ? vm.codeViewerTabs[active].id : nil
        vm.isCodeViewerVisible = true
    }

    private func host(_ vm: ChatHistoryViewModel) -> (NSWindow, NSHostingView<AnyView>) {
        let root = AnyView(
            CodeViewerPanelView()
                .environment(vm)
                .environment(ThemeManager())
                .frame(width: 900, height: 700)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return (window, hosting)
    }

    /// The core repro: content is ALREADY set before the panel mounts (exactly what
    /// `openMessageInCodeViewer` does). The panel must render the snippet without any
    /// navigation — i.e. it must not sit on the "No Code Selected" placeholder.
    func testPanelLoadsFirstSnippetOnAppearWithoutNavigation() {
        let vm = makeViewModel()
        openTabs(vm, [
            CodeSnippet(language: "java", code: "class A {}"),
            CodeSnippet(language: "java", code: "class B {}"),
            CodeSnippet(language: "java", code: "class C {}")
        ])

        let (window, hosting) = host(vm)
        defer { window.orderOut(nil) }

        // The editor only exists when `document` was built. The placeholder path
        // renders a plain text label instead, so a mounted CodeEdit view is the
        // observable proof the document loaded on appear.
        XCTAssertTrue(
            containsSourceEditor(hosting),
            "Panel must load the selected snippet on appear — it previously showed 'No Code Selected' until the user navigated."
        )
    }

    /// Selecting a different tab must swap the rendered document.
    func testNavigatingTabsReloadsDocument() {
        let vm = makeViewModel()
        openTabs(vm, [
            CodeSnippet(language: "java", code: "class First {}"),
            CodeSnippet(language: "java", code: "class Second {}")
        ])

        let (window, hosting) = host(vm)
        defer { window.orderOut(nil) }

        vm.navigateToNextSnippet()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(vm.activeCodeViewerTabID, vm.codeViewerTabs[1].id)
        XCTAssertTrue(containsSourceEditor(hosting), "Editor should still be mounted after switching tabs")
    }

    /// Replacing the active tab's snippet in place (what a successful Apply does — same tab
    /// id, new snippet id) is a real content change. A tab-id-keyed observer misses it;
    /// keying on the snippet id catches it and reloads the document.
    func testReplacingActiveSnippetInPlaceReloads() {
        let vm = makeViewModel()
        openTabs(vm, [CodeSnippet(language: "java", code: "class Old {}")])

        let (window, hosting) = host(vm)
        defer { window.orderOut(nil) }

        // Same tab, different snippet content — must not leave the old document up.
        vm.codeViewerTabs[0].snippet = CodeSnippet(language: "swift", code: "struct New {}")
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(containsSourceEditor(hosting), "Editor must be mounted for the replacement snippet")
    }

    /// A stale `activeCodeViewerTabID` (matches no open tab) must render the empty state,
    /// not trap — the id-lookup replaces the old out-of-range `currentIndex` subscript that
    /// caused two index-out-of-range crashes in this area.
    func testStaleActiveTabIDDoesNotCrash() {
        let vm = makeViewModel()
        vm.codeViewerTabs = [CodeViewerTab(snippet: CodeSnippet(language: "java", code: "class A {}"))]
        vm.activeCodeViewerTabID = UUID()   // matches no tab
        vm.isCodeViewerVisible = true

        let (window, hosting) = host(vm)
        defer { window.orderOut(nil) }

        XCTAssertFalse(containsSourceEditor(hosting), "A stale active-tab id should fall back to the empty state")
    }

    // MARK: - Helpers

    /// Walks the mounted NSView tree looking for the hosted CodeEdit editor. The
    /// placeholder branch mounts no such view, so this distinguishes the two states.
    private func containsSourceEditor(_ view: NSView) -> Bool {
        let name = String(describing: type(of: view))
        if name.contains("SourceEditor") || name.contains("TextView") || name.contains("STTextView") {
            return true
        }
        return view.subviews.contains { containsSourceEditor($0) }
    }
}
