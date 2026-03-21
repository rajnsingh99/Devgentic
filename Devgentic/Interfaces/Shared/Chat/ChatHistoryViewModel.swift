//
//  ChatHistoryViewModel.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatHistoryViewModel")

@MainActor
class ChatHistoryViewModel: ObservableObject {

    // MARK: - Dependencies
    private let persistenceService: CoreDataServiceProtocol
    private let activeStreamManager: ActiveStreamManager

    // MARK: - Published State Properties for Code Viewer
    @Published var codeViewerContent: (snippets: [CodeSnippet], currentIndex: Int)? = nil
    @Published var isShowingDiff: Bool = false
    @Published var originalCodeForDiff: String? = nil

    // MARK: - Published State Properties for Chat History
    // OPTIMIZATION: Stores messages in Descending order (Newest -> Oldest).
    // This allows O(1) appending of history pages instead of O(n) insertion at index 0.
    @Published var currentChatMessages: [ChatMessage] = []
    
    @Published var isInitiallyLoadingConversation = false

    @Published var isLoadingPage = false
    @Published var canLoadMorePages = true
    private let initialPageSize = 20
    private let subsequentPageSize = 10

    @Published var isSending: Bool = false
    @Published var isUserMessagesOnlyFilterActive: Bool = false

    // MARK: - Initialization
    init(
        persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared,
        activeStreamManager: ActiveStreamManager
    ) {
        self.persistenceService = persistenceService
        self.activeStreamManager = activeStreamManager
        logger.info("ChatHistoryViewModel initialized.")
    }

    // MARK: - Code Viewer Panel Control
    
    func showCodeInViewer(language: String?, code: String) {
        let snippet = CodeSnippet(language: language, code: code)
        codeViewerContent = (snippets: [snippet], currentIndex: 0)
        logger.info("Code viewer content set for language: \(language ?? "nil")")
    }

    func hideCodeViewer() {
        withAnimation(.easeInOut(duration: 0.3)) {
            codeViewerContent = nil
            isShowingDiff = false
            originalCodeForDiff = nil
            logger.info("Code viewer content cleared.")
        }
    }
    
    func navigateToNextSnippet() {
        guard var content = codeViewerContent, content.currentIndex < content.snippets.count - 1 else { return }
        content.currentIndex += 1
        codeViewerContent = content
        isShowingDiff = false
        originalCodeForDiff = nil
    }
    
    func navigateToPreviousSnippet() {
        guard var content = codeViewerContent, content.currentIndex > 0 else { return }
        content.currentIndex -= 1
        codeViewerContent = content
        isShowingDiff = false
        originalCodeForDiff = nil
    }
    
    func toggleDiffView(for snippet: CodeSnippet) {
        if isShowingDiff {
            withAnimation {
                isShowingDiff = false
                originalCodeForDiff = nil
            }
            logger.info("Diff view toggled off.")
            return
        }
        
        guard let sourceMessageID = snippet.sourceMessageID,
              let sourceFileID = snippet.sourceFileID else {
            logger.warning("Attempted to toggle diff view for a snippet that has no source file link.")
            return
        }
        
        guard let originalMessage = self.currentChatMessages.first(where: { $0.id == sourceMessageID }) else {
            logger.error("Could not find the original message with ID \(sourceMessageID.uuidString) in the currently loaded history for diffing.")
            return
        }
        
        guard let originalFile = originalMessage.attachedTextFiles?.first(where: { $0.id == sourceFileID }) else {
            logger.error("Could not find the original file with ID \(sourceFileID.uuidString) in message \(sourceMessageID.uuidString).")
            return
        }
        
        self.originalCodeForDiff = originalFile.content
        withAnimation {
            self.isShowingDiff = true
        }
        logger.info("Diff view toggled on for snippet derived from file '\(originalFile.name)'.")
    }

    // MARK: - Message Actions

    func applyChanges(for snippet: CodeSnippet) {
        guard let sourceMessageID = snippet.sourceMessageID,
              let sourceFileID = snippet.sourceFileID else {
            logger.warning("Attempted to apply changes for a snippet with no source file link.")
            return
        }

        guard let originalMessage = self.currentChatMessages.first(where: { $0.id == sourceMessageID }),
              let sourceFile = originalMessage.attachedTextFiles?.first(where: { $0.id == sourceFileID }) else {
            logger.error("Could not find the source file to apply changes.")
            return
        }

        let fileURL = sourceFile.url
        let newContent = snippet.code

        do {
            let shouldAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if shouldAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
            logger.info("✅ Successfully applied changes to file: \(fileURL.path)")
            withAnimation {
                self.isShowingDiff = false
                self.originalCodeForDiff = nil
                if var content = self.codeViewerContent, content.snippets.indices.contains(content.currentIndex) {
                    let updatedSnippet = CodeSnippet(language: snippet.language, code: newContent, sourceMessageID: snippet.sourceMessageID, sourceFileID: snippet.sourceFileID)
                    content.snippets[content.currentIndex] = updatedSnippet
                    self.codeViewerContent = content
                }
            }
        } catch {
            logger.error("❌ Failed to write changes to file: \(fileURL.path). Error: \(error.localizedDescription)")
        }
    }

    func copyMessageContentToClipboard(message: ChatMessage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let content = message.content.textContent {
            pasteboard.setString(content, forType: .string)
            logger.info("Copied message \(message.id.uuidString) content to clipboard.")
        }
    }
    
    func openMessageInCodeViewer(message: ChatMessage, selectedSnippet: CodeSnippet? = nil) {
        DispatchQueue.main.async {
            var allSnippets: [CodeSnippet] = []

            switch message.content {
            case .codeBlock(let lang, let codeContent):
                allSnippets = [CodeSnippet(language: lang, code: codeContent)]
                
            case .markdownText(let text):
                let extractedInfos = CodeSnippetExtractor.extract(from: text)
                
                allSnippets = extractedInfos.map { info in
                    var snippet = CodeSnippet(language: info.language, code: info.code)
                    
                    if let fileName = info.potentialFileName {
                        if let sourceMessage = self.findMessageWithSourceFile(named: fileName) {
                            if let sourceFile = sourceMessage.attachedTextFiles?.first(where: { $0.name == fileName }) {
                                snippet.sourceMessageID = sourceMessage.id
                                snippet.sourceFileID = sourceFile.id
                                logger.info("✅ Successfully linked snippet for '\(fileName)' to source file ID \(sourceFile.id.uuidString).")
                            }
                        } else {
                            logger.warning("⚠️ Could not find any user message with attached file named '\(fileName)'.")
                        }
                    }
                    return snippet
                }
                
            default:
                allSnippets = []
            }

            guard !allSnippets.isEmpty else {
                logger.info("No code snippets found in the message to open in viewer.")
                return
            }
            
            let codeBlockLineLimit = 50
            let largeSnippets = allSnippets.filter {
                $0.code.components(separatedBy: .newlines).count > codeBlockLineLimit
            }
            
            let snippetsToShow = !largeSnippets.isEmpty ? largeSnippets : allSnippets

            var initialIndex = 0
            if let selected = selectedSnippet, let index = snippetsToShow.firstIndex(of: selected) {
                initialIndex = index
            }

            logger.info("Opening message in code viewer. Snippets to show: \(snippetsToShow.count), Selected index: \(initialIndex)")
            self.codeViewerContent = (snippets: snippetsToShow, currentIndex: initialIndex)
        }
    }
    
    private func findMessageWithSourceFile(named fileName: String) -> ChatMessage? {
        for message in currentChatMessages {
            if message.sender == .user {
                if let files = message.attachedTextFiles, files.contains(where: { $0.name == fileName }) {
                    return message
                }
            }
        }
        logger.warning("File '\(fileName)' not found in any user messages in the currently loaded chat history.")
        return nil
    }


    // MARK: - Paginated Message Loading

    func loadConversation(id: UUID?) async {
        guard let selectedID = id else {
            currentChatMessages = []
            return
        }

        logger.debug("Loading conversation \(selectedID.uuidString, privacy: .public), merging with active streams.")

        isInitiallyLoadingConversation = true

        do {
            try Task.checkCancellation()

            // Fetch persisted messages (returns newest-to-oldest).
            let persistedMessages = await persistenceService.fetchMessages(for: selectedID, offset: 0, limit: initialPageSize)

            try Task.checkCancellation()

            let activeStreamingMessages = activeStreamManager.activeStreams.values
                .filter { $0.conversationId == selectedID }

            var combinedMessages = activeStreamingMessages + persistedMessages
            let uniqueMessageIDs = Set(combinedMessages.map { $0.id })
            combinedMessages = uniqueMessageIDs.compactMap { id in
                combinedMessages.first { $0.id == id }
            }

            // Sort the combined list descending to ensure order.
            let sortedDescending = combinedMessages.sorted { $0.timestamp > $1.timestamp }

            // OPTIMIZATION: Keep messages in Descending Order (Newest -> Oldest).
            // We REMOVED .reversed() here. This aligns with the View's .reversed() loop.
            self.currentChatMessages = sortedDescending

            self.canLoadMorePages = persistedMessages.count >= initialPageSize

            logger.info("Successfully loaded and merged \(persistedMessages.count) persisted and \(activeStreamingMessages.count) active messages.")

            if isUserMessagesOnlyFilterActive {
                applyUserMessagesFilter()
            }
        } catch {
            logger.info("Conversation load for \(selectedID.uuidString) was cancelled.")
        }

        self.isInitiallyLoadingConversation = false
    }


    func loadMoreMessages() async {
        guard !isLoadingPage, canLoadMorePages, let selectedID = persistenceService.getConversation(withId: currentChatMessages.first?.conversationId ?? UUID())?.id else {
            return
        }
        
        isLoadingPage = true
        
        let offset = currentChatMessages.count
        logger.debug("Loading page with offset \(offset) for conversation \(selectedID.uuidString, privacy: .public).")
        
        // Fetches the next page of older messages, sorted newest-to-oldest.
        let olderMessages = await persistenceService.fetchMessages(for: selectedID, offset: offset, limit: subsequentPageSize)
        
        if olderMessages.isEmpty {
            canLoadMorePages = false
        } else {
            // OPTIMIZATION: Append to the end of the array (Newest...Oldest -> Append Older).
            // Since we are storing Descending, older messages go to the end (Index N).
            self.currentChatMessages.append(contentsOf: olderMessages)
            
            if isUserMessagesOnlyFilterActive {
                applyUserMessagesFilter()
            }
        }
        
        isLoadingPage = false
    }

    func toggleUserMessagesFilter() {
        isUserMessagesOnlyFilterActive.toggle()
        Task {
            await loadConversation(id: currentChatMessages.first?.conversationId)
        }
    }
    
    private func applyUserMessagesFilter() {
        if isUserMessagesOnlyFilterActive {
            currentChatMessages = currentChatMessages.filter { $0.sender == .user }
        }
    }
    
    func resetSendingState() async {
        self.isSending = false
        logger.info("✅ [Request Finished] Sending state has been reset.")
    }
}
