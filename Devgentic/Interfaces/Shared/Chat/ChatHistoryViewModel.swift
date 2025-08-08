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

// MODIFIED: CodeSnippet now correctly implements Equatable and Hashable based on its content.
// This ensures that we can accurately find and compare snippets.
struct CodeSnippet: Identifiable, Hashable {
    let id = UUID() // Kept for SwiftUI's Identifiable conformance.
    let language: String?
    let code: String

    // Custom Hashable conformance based on content.
    func hash(into hasher: inout Hasher) {
        hasher.combine(language)
        hasher.combine(code)
    }

    // Custom Equatable conformance based on content.
    static func == (lhs: CodeSnippet, rhs: CodeSnippet) -> Bool {
        return lhs.language == rhs.language && lhs.code == rhs.code
    }
}


// NEW: A utility to extract code snippets from markdown text
struct CodeSnippetExtractor {
    static func extract(from markdown: String) -> [CodeSnippet] {
        var snippets: [CodeSnippet] = []
        // IMPROVED REGEX: This is more robust for various markdown code block formats.
        let codeBlockRegex = "```(?:\\s*([a-zA-Z0-9\\+\\-\\_]*))?\\n([\\s\\S]+?)\\n```"
        
        do {
            let regex = try NSRegularExpression(pattern: codeBlockRegex, options: [])
            let nsrange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
            let matches = regex.matches(in: markdown, options: [], range: nsrange)
            
            // LOGGING: Added to see how many matches are found
            logger.debug("CodeSnippetExtractor found \(matches.count) potential code blocks.")
            
            for (index, match) in matches.enumerated() {
                // There are 3 ranges: full match, optional language, and the code itself.
                if match.numberOfRanges == 3 {
                    let languageRange = match.range(at: 1)
                    let codeRange = match.range(at: 2)
                    
                    if let codeRange = Range(codeRange, in: markdown) {
                        let language = Range(languageRange, in: markdown).flatMap { String(markdown[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
                        let code = String(markdown[codeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        if !code.isEmpty {
                           let finalLanguage = (language?.isEmpty ?? true) ? nil : language
                           snippets.append(CodeSnippet(language: finalLanguage, code: code))
                           // LOGGING: Log details of each extracted snippet
                           logger.debug("Extracted snippet \(index + 1): Language='\(finalLanguage ?? "none")', Code length=\(code.count)")
                        }
                    }
                }
            }
        } catch {
            logger.error("Failed to create regex for code block extraction: \(error)")
        }
        
        return snippets
    }
}


@MainActor
class ChatHistoryViewModel: ObservableObject {

    // MARK: - Dependencies
    private let persistenceService: CoreDataServiceProtocol

    // MARK: - Published State Properties for Code Viewer
    // MODIFIED: Now holds an array of snippets and the current index
    @Published var codeViewerContent: (snippets: [CodeSnippet], currentIndex: Int)? = nil

    // MARK: - Published State Properties for Chat History
    @Published var currentChatMessages: [ChatMessage] = []
    @Published var isInitiallyLoadingConversation = false

    // --- Pagination State ---
    @Published var isLoadingPage = false
    @Published var canLoadMorePages = true
    private let initialPageSize = 20
    private let subsequentPageSize = 10

    @Published var streamingMessage: ChatMessage? = nil
    @Published var streamingTriggerID: UUID? = nil

    // --- Placeholder for one-shot responses to show thinking indicator ---
    @Published var oneShotThinkingMessage: ChatMessage? = nil
    
    @Published var isSending: Bool = false // Indicates if a message is currently being sent/streamed
    @Published var isUserMessagesOnlyFilterActive: Bool = false

    private var streamingTask: Task<Void, Never>? // Task for managing ongoing streaming

    // MARK: - Initialization
    init(persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared) {
        self.persistenceService = persistenceService
        logger.info("ChatHistoryViewModel initialized.")
    }

    // MARK: - Code Viewer Panel Control
    
    /// Shows the code viewer panel with a single code snippet.
    /// - Parameters:
    ///   - language: The programming language of the code.
    ///   - code: The code content to display.
    func showCodeInViewer(language: String?, code: String) {
        let snippet = CodeSnippet(language: language, code: code)
        codeViewerContent = (snippets: [snippet], currentIndex: 0)
        logger.info("Code viewer content set for language: \(language ?? "nil")")
    }

    /// Hides the code viewer panel.
    func hideCodeViewer() {
        withAnimation(.easeInOut(duration: 0.3)) {
            codeViewerContent = nil
            logger.info("Code viewer content cleared.")
        }
    }
    
    // NEW: Navigates to the next snippet in the viewer
    func navigateToNextSnippet() {
        guard var content = codeViewerContent, content.currentIndex < content.snippets.count - 1 else { return }
        content.currentIndex += 1
        codeViewerContent = content
    }
    
    // NEW: Navigates to the previous snippet in the viewer
    func navigateToPreviousSnippet() {
        guard var content = codeViewerContent, content.currentIndex > 0 else { return }
        content.currentIndex -= 1
        codeViewerContent = content
    }

    // MARK: - Message Actions

    /// Copies the text content of a message to the system clipboard.
    /// - Parameter message: The `ChatMessage` to copy.
    func copyMessageContentToClipboard(message: ChatMessage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let content = message.content.textContent {
            pasteboard.setString(content, forType: .string)
            logger.info("Copied message \(message.id.uuidString) content to clipboard.")
        }
    }
    
    /// REFACTORED: This function now implements the smart navigation logic.
    /// It correctly identifies large code blocks and ensures the side panel navigator
    /// only shows those, starting with the one the user selected.
    func openMessageInCodeViewer(message: ChatMessage, selectedSnippet: CodeSnippet? = nil) {
        // FIX: Dispatch the entire operation asynchronously to the main thread.
        // This resolves the "Modifying state during view update" warning by ensuring
        // the view has finished its current rendering pass before we process the data
        // and trigger a new state change.
        DispatchQueue.main.async {
            let allSnippets: [CodeSnippet]

            switch message.content {
            case .codeBlock(let lang, let codeContent):
                allSnippets = [CodeSnippet(language: lang, code: codeContent)]
            case .markdownText(let text):
                // Use the global `parseMarkdown` function to ensure consistency.
                let contentBlocks = parseMarkdown(text)
                allSnippets = contentBlocks.compactMap { block in
                    guard case .code(let language, let content) = block else { return nil }
                    return CodeSnippet(language: language.isEmpty ? nil : language, code: content)
                }
            default:
                allSnippets = []
            }

            guard !allSnippets.isEmpty else {
                logger.info("No code snippets found in the message to open in viewer.")
                return
            }

            // NEW: Add detailed logging to verify filtering logic.
            logger.debug("--- Verifying Code Block Filtering ---")
            allSnippets.enumerated().forEach { index, snippet in
                let lineCount = snippet.code.components(separatedBy: .newlines).count
                logger.debug("Snippet \(index + 1) (\(snippet.language ?? "unknown")): \(lineCount) lines.")
            }
            
            let codeBlockLineLimit = 50

            // First, identify all the large code blocks in the message.
            let largeSnippets = allSnippets.filter {
                $0.code.components(separatedBy: .newlines).count > codeBlockLineLimit
            }
            
            // NEW: Log the result of the filtering.
            logger.debug("Found \(largeSnippets.count) snippets with more than \(codeBlockLineLimit) lines.")

            let snippetsToShow: [CodeSnippet]

            // If the message contains any large snippets, the navigator should ONLY show those.
            if !largeSnippets.isEmpty {
                snippetsToShow = largeSnippets
            } else {
                // Otherwise (if there are only small snippets), show all of them.
                snippetsToShow = allSnippets
            }

            // Default to the first snippet if none was explicitly selected.
            var initialIndex = 0
            // Find the index of the user-selected snippet within the final list to be shown.
            if let selected = selectedSnippet, let index = snippetsToShow.firstIndex(of: selected) {
                initialIndex = index
            }

            logger.info("Opening message in code viewer. Total snippets: \(allSnippets.count), Snippets to show: \(snippetsToShow.count), Selected index: \(initialIndex)")

            // Update the state to show the code viewer.
            self.codeViewerContent = (snippets: snippetsToShow, currentIndex: initialIndex)
        }
    }


    // MARK: - Paginated Message Loading

    /// Loads the initial set of messages for a given conversation ID.
    /// - Parameter id: The UUID of the conversation to load.
    func loadConversation(id: UUID?) async {
        guard let selectedID = id else {
            currentChatMessages = []
            return
        }
        
        logger.debug("Loading initial page for conversation \(selectedID.uuidString, privacy: .public).")
        
        isInitiallyLoadingConversation = true
        
        do {
            // Check for cancellation before fetching
            try Task.checkCancellation()
            
            let messages = await persistenceService.fetchMessages(for: selectedID, offset: 0, limit: initialPageSize)
            
            // Check for cancellation before updating state
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

    /// Loads more messages for the currently selected conversation, used for pagination.
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

    /// Toggles the filter to show only user messages.
    func toggleUserMessagesFilter() {
        isUserMessagesOnlyFilterActive.toggle()
        // Reload messages to apply filter
        Task {
            await loadConversation(id: currentChatMessages.first?.conversationId)
        }
    }
    
    /// Applies the user messages filter to the current chat messages.
    private func applyUserMessagesFilter() {
        if isUserMessagesOnlyFilterActive {
            currentChatMessages = currentChatMessages.filter { $0.sender == .user }
        }
    }

    // MARK: - Streaming Message Handling

    /// Appends a new token to the currently streaming message.
    /// - Parameter token: The new text token to append.
    func appendTokenToStreamingMessage(_ token: String) {
        guard var message = self.streamingMessage else {
            logger.warning("appendTokenToStreamingMessage called but streamingMessage is nil.")
            return
        }

        if var currentText = message.content.textContent {
            currentText += token
            message.content = .markdownText(currentText)
        }

        self.streamingMessage = message
        
        if let index = self.currentChatMessages.firstIndex(where: { $0.id == message.id }) {
            self.currentChatMessages[index] = message
            logger.trace("Appended token and updated message in UI array.")
        } else {
            logger.warning("Could not find streaming message in currentChatMessages to update UI.")
        }
    }
    
    /// Finalizes the streaming response, marking it as complete and persisting it.
    /// - Parameters:
    ///   - conversationID: The ID of the conversation the message belongs to.
    ///   - error: An optional error if the streaming failed.
    func finalizeResponse(conversationID: UUID, error: Error?) async {
        logger.info("Finalizing response for conversation \(conversationID.uuidString).")
        guard var finalMessage = self.streamingMessage ?? self.oneShotThinkingMessage else {
            logger.warning("finalizeResponse called but no streaming or one-shot message was found. Resetting state.")
            await resetSendingState()
            return
        }

        finalMessage.isStreaming = false
        logger.debug("Marked message \(finalMessage.id.uuidString) as no longer streaming.")

        if let error = error {
            logger.error("Finalizing response with error: \(error.localizedDescription)")
            finalMessage.content = .error(title: "Response Error", details: error.localizedDescription)
        } else {
            logger.info("Response finalized successfully with full text.")
        }

        if let index = self.currentChatMessages.firstIndex(where: { $0.id == finalMessage.id }) {
            self.currentChatMessages[index] = finalMessage
            logger.debug("Updated final message in currentChatMessages array.")
        }

        if let targetEntity = persistenceService.getConversation(withId: conversationID) {
            await persistenceService.addMessage(finalMessage, to: targetEntity)
            logger.info("Persisted final message \(finalMessage.id.uuidString).")
        } else {
            logger.error("Could not find conversation entity \(conversationID.uuidString) to persist final message.")
        }

        await resetSendingState()
    }
    
    /// Resets the sending state, clearing temporary messages and flags.
    func resetSendingState() async {
        self.isSending = false
        self.streamingTriggerID = nil
        self.streamingMessage = nil
        self.oneShotThinkingMessage = nil
        self.streamingTask?.cancel() // Ensure any ongoing task is cancelled
        self.streamingTask = nil
        logger.info("✅ [Request Finished] Sending state has been reset.")
    }

    /// Sets the streaming task for cancellation.
    /// - Parameter task: The `Task` representing the ongoing streaming operation.
    func setStreamingTask(_ task: Task<Void, Never>?) {
        self.streamingTask = task
    }

    /// Cancels the ongoing streaming operation.
    func cancelStreaming() {
        if streamingTriggerID != nil {
            logger.info("Streaming cancelled by user via ChatHistoryViewModel.")
            streamingTask?.cancel()
            Task {
                await resetSendingState()
            }
        }
    }
}
