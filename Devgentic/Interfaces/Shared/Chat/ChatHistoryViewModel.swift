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

    // MARK: - Published State Properties for Code Viewer
    @Published var codeViewerContent: (snippets: [CodeSnippet], currentIndex: Int)? = nil
    @Published var isShowingDiff: Bool = false
    @Published var originalCodeForDiff: String? = nil

    // MARK: - Published State Properties for Chat History
    @Published var currentChatMessages: [ChatMessage] = []
    @Published var isInitiallyLoadingConversation = false

    @Published var isLoadingPage = false
    @Published var canLoadMorePages = true
    private let initialPageSize = 20
    private let subsequentPageSize = 10

    @Published var isSending: Bool = false
    @Published var isUserMessagesOnlyFilterActive: Bool = false

    private var streamingTask: Task<Void, Never>?

    // MARK: - Initialization
    init(persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared) {
        self.persistenceService = persistenceService
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
        
        if isSending && currentChatMessages.contains(where: { $0.conversationId == selectedID && $0.isStreaming }) {
            logger.info("Race condition avoided: `loadConversation` called for a new chat while sending. Skipping DB fetch to preserve placeholder message.")
            return
        }
        
        logger.debug("Loading initial page for conversation \(selectedID.uuidString, privacy: .public).")
        
        isInitiallyLoadingConversation = true
        
        do {
            try Task.checkCancellation()
            
            let messages = await persistenceService.fetchMessages(for: selectedID, offset: 0, limit: initialPageSize)
            
            try Task.checkCancellation()
            
            self.currentChatMessages = messages
            self.canLoadMorePages = messages.count >= initialPageSize
            
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
        
        let olderMessages = await persistenceService.fetchMessages(for: selectedID, offset: offset, limit: subsequentPageSize)
        
        if olderMessages.isEmpty {
            canLoadMorePages = false
        } else {
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

    // MARK: - Streaming Message Handling

    func appendTokenToStreamingMessage(_ token: String) {
        // MARK: - LOGGING ADDED
        logger.debug("STREAM_TRACE: appendTokenToStreamingMessage called with token: '\(token)'")
        
        // Find the streaming message placeholder in the array.
        guard let index = self.currentChatMessages.firstIndex(where: { $0.isStreaming }) else {
            logger.warning("appendTokenToStreamingMessage called but no streaming message placeholder was found in the chat history.")
            return
        }

        var message = self.currentChatMessages[index]
        
        if var currentText = message.content.textContent {
            currentText += token
            message.content = .markdownText(currentText)
        }

        self.currentChatMessages[index] = message
        logger.trace("Appended token and updated message in UI array.")
    }
    
    func finalizeResponse(conversationID: UUID, error: Error?) async {
        logger.info("Finalizing response for conversation \(conversationID.uuidString).")
        
        // Find the streaming message placeholder in the array.
        guard let index = self.currentChatMessages.firstIndex(where: { $0.isStreaming }) else {
            logger.warning("finalizeResponse called but no streaming message placeholder was found. Resetting state.")
            await resetSendingState()
            return
        }
        
        var finalMessage = self.currentChatMessages[index]
        finalMessage.isStreaming = false
        logger.debug("Marked message \(finalMessage.id.uuidString) as no longer streaming.")

        if let error = error {
            logger.error("Finalizing response with error: \(error.localizedDescription)")
            finalMessage.content = .error(title: "Response Error", details: error.localizedDescription)
        } else {
            logger.info("Response finalized successfully with full text.")
        }

        self.currentChatMessages[index] = finalMessage
        logger.debug("Updated final message in currentChatMessages array.")

        if let targetEntity = persistenceService.getConversation(withId: conversationID) {
            await persistenceService.addMessage(finalMessage, to: targetEntity)
            logger.info("Persisted final message \(finalMessage.id.uuidString).")
        } else {
            logger.error("Could not find conversation entity \(conversationID.uuidString) to persist final message.")
        }

        await resetSendingState()
    }
    
    func resetSendingState() async {
        self.isSending = false
        self.streamingTask?.cancel()
        self.streamingTask = nil
        logger.info("✅ [Request Finished] Sending state has been reset.")
    }

    func setStreamingTask(_ task: Task<Void, Never>?) {
        self.streamingTask = task
    }

    func cancelStreaming() {
        // Find if there is a streaming message in progress.
        if self.currentChatMessages.contains(where: { $0.isStreaming }) {
            logger.info("Streaming cancelled by user via ChatHistoryViewModel.")
            streamingTask?.cancel()
            // The `finalizeResponse` with a cancellation error will be called by the sending logic.
            // We can also force a state reset here if needed.
            Task {
                // Finalize with a generic cancellation error.
                if let conversationID = self.currentChatMessages.first?.conversationId {
                    let cancellationError = NSError(domain: "UserCancellation", code: -999, userInfo: [NSLocalizedDescriptionKey: "The user cancelled the request."])
                    await self.finalizeResponse(conversationID: conversationID, error: cancellationError)
                } else {
                    await self.resetSendingState()
                }
            }
        }
    }
}
