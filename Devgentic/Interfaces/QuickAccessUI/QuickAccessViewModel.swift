// ViewModels/QuickAccessViewModel.swift
import SwiftUI
import Combine
import os
import Markdown // Requires Markdown library

// BackendType and SettingsKeys are now expected to be defined in their own files.
// ConversationStore is also expected to be defined.

@MainActor // Ensure UI updates happen on the main thread
class QuickAccessViewModel: ObservableObject {

    // MARK: - Published Properties
    @Published var messages: [ChatMessage] = []
    @Published var isSending: Bool = false
    
    // MARK: - Dependencies
    private let aiConnect = AIConnect()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "QuickAccessViewModel")
    
    // MARK: - Properties for ConversationStore Integration
    private let store = ConversationStore.shared // Use the singleton store
    private var targetConversationId: UUID!      // ID of the current Quick Access conversation
    private var cancellables = Set<AnyCancellable>() // To observe changes from the store

    // MARK: - Initialization
    init() {
        logger.info("QuickAccessViewModel initializing with ConversationStore integration.")
        setupQuickAccessConversation()
        observeStoreChanges()
    }

    // MARK: - Private Initialization and Setup Helpers

    /// Sets up the initial Quick Access conversation by getting or creating it from the store.
    private func setupQuickAccessConversation() {
        let qaConversation = store.getOrCreateQuickAccessConversation()
        self.targetConversationId = qaConversation.id
        self.messages = qaConversation.messages.sorted { $0.timestamp < $1.timestamp } // Ensure sorted
        logger.info("Quick Access ViewModel setup with conversation ID: \(self.targetConversationId.uuidString)")
    }

    /// Observes changes in the ConversationStore's active Quick Access conversation.
    private func observeStoreChanges() {
        store.$conversations
            .receive(on: DispatchQueue.main) // Ensure updates are on the main thread
            .sink { [weak self] updatedConversationsList in
                guard let self = self else { return }
                
                // Check if our targetConversationId still exists and if its messages have changed
                if let updatedConversation = updatedConversationsList.first(where: { $0.id == self.targetConversationId }) {
                    let sortedNewMessages = updatedConversation.messages.sorted { $0.timestamp < $1.timestamp }
                    // Only update if the messages are actually different to avoid unnecessary UI refreshes / loops
                    if self.messages != sortedNewMessages {
                        self.logger.trace("Detected change in target conversation (\(self.targetConversationId.uuidString)) from store. Updating local messages.")
                        self.messages = sortedNewMessages
                    }
                } else {
                    // The target conversation was deleted or changed ID (e.g., by startNewChatSession).
                    // Re-sync with the current QA conversation from the store.
                    self.logger.warning("Target Quick Access conversation (\(self.targetConversationId?.uuidString ?? "nil")) no longer found or relevant in store. Re-initializing UI state.")
                    self.setupQuickAccessConversation() // Re-establish the correct QA conversation state
                }
            }
            .store(in: &cancellables)
    }


    // MARK: - Core Logic

    /// Submits a query from the user to the configured AI backend.
    func submitQuery(query: String) {
        // Capture the conversation ID *before* any async operation
        guard let originalConversationId = self.targetConversationId else {
             logger.error("submitQuery failed: targetConversationId is nil.")
             return
        }
        
        logger.debug("Quick Access submitQuery called with: \"\(query, privacy: .public)\" for conversation ID: \(originalConversationId.uuidString)")
        guard !isSending else {
            logger.warning("Quick Access submitQuery aborted: Already sending a request.")
            return
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            logger.info("Quick Access submitQuery aborted: Input query is empty.")
            return
        }

        // 1. Create user message
        let userMessage = ChatMessage(
            conversationId: originalConversationId, // Use captured ID
            sender: .user,
            content: .plainText(trimmedQuery)
        )
        
        // 2. Append locally for immediate UI update (if this is the current chat)
        // This assumes the UI should show the user message immediately.
        // The observer will correct this if the conversation changes rapidly,
        // but appending here gives instant feedback.
        if self.targetConversationId == originalConversationId {
            self.messages.append(userMessage)
        } else {
             logger.warning("User message created for \(originalConversationId.uuidString) but view model target is now \(self.targetConversationId.uuidString). Not appending locally.")
        }

        // 3. Update the conversation in the store immediately with the user message
        updateConversationInStore(conversationId: originalConversationId, appending: [userMessage])

        // 4. Start background task for agent response
        isSending = true // Set sending state for the current UI

        Task {
            var resultingAgentMessages: [ChatMessage] = []
            let modelName = UserDefaults.standard.string(forKey: SettingsKeys.llmModelName) ?? "gemma:2b"
            let baseURLString = self.aiConnect.baseURL

            // --- Perform API Call ---
            let isConnected = await AIConnect.checkOllamaServerStatus(baseURL: baseURLString)
            guard isConnected else {
                let errorMsg = "Quick Access: Cannot connect to Ollama server at \(baseURLString)."
                logger.error("\(errorMsg)")
                let errorMessageContent = MessageContent.error(title: "Connection Error", details: errorMsg)
                // Create error message for the *original* conversation
                let errorChatMessage = ChatMessage(conversationId: originalConversationId, sender: .agent, content: errorMessageContent)
                resultingAgentMessages.append(errorChatMessage)
                
                // Update store immediately with error, handle UI update separately
                self.handleAgentResponse(messages: resultingAgentMessages, conversationId: originalConversationId)
                
                // Only update sending state if the error belongs to the *currently viewed* chat
                if self.targetConversationId == originalConversationId {
                    self.isSending = false
                }
                return // Exit Task
            }

            let payload: [String: Any] = [ "model": modelName, "prompt": trimmedQuery, "stream": false ]
            let endpoint = "/api/generate"

            do {
                logger.debug("Quick Access sending task via AIConnect instance to \(baseURLString, privacy: .public)\(endpoint, privacy: .public) for conversation \(originalConversationId.uuidString)")
                let responseData = try await self.aiConnect.postToLocalServer(endpoint: endpoint, payload: payload)
                let responseText = self.parseOllamaResponseData(data: responseData)
                let parsedContents = self.parseAgentResponseString(responseText)

                for content in parsedContents {
                    let agentMessage = ChatMessage(
                        conversationId: originalConversationId, // Use captured ID
                        sender: .agent,
                        content: content
                    )
                    resultingAgentMessages.append(agentMessage)
                }

            } catch {
                logger.error("Quick Access error during API call or parsing for \(originalConversationId.uuidString): \(error.localizedDescription, privacy: .public)")
                let errorText = self.generateSimplifiedErrorMessage(error: error)
                let errorMessageContent = MessageContent.error(title: "Processing Error", details: errorText)
                let errorChatMessage = ChatMessage(conversationId: originalConversationId, sender: .agent, content: errorMessageContent)
                resultingAgentMessages.append(errorChatMessage)
            }
            // --- End API Call ---

            // 5. Handle the response, passing the originalConversationId
            self.handleAgentResponse(messages: resultingAgentMessages, conversationId: originalConversationId)
            
            // 6. Update sending state only if the response was for the currently viewed chat
            if self.targetConversationId == originalConversationId {
                 self.isSending = false
            }
        } // End Task
    }

    /// Starts a new Quick Access conversation session.
    func startNewChatSession() {
        logger.info("Starting new Quick Access chat session request.")
        
        let newConversation = store.startNewQuickAccessConversationSession()
        
        // Check if the ID actually changed (store might have reused an empty chat)
        if newConversation.id != self.targetConversationId {
            self.targetConversationId = newConversation.id
            self.messages = newConversation.messages.sorted { $0.timestamp < $1.timestamp } // Should be empty
            self.isSending = false // Reset sending state for the new chat UI
            logger.info("Quick Access ViewModel reset for new session ID: \(self.targetConversationId.uuidString)")
        } else {
             logger.info("Reusing existing empty Quick Access session ID: \(self.targetConversationId.uuidString)")
             // Ensure local state is consistent if reusing
             self.messages = newConversation.messages.sorted { $0.timestamp < $1.timestamp }
             self.isSending = false
        }
    }

    // MARK: - Private Helpers

    /// Handles incoming agent messages (or errors), appending them to the correct conversation in the store
    /// and updating the local UI state only if the message belongs to the currently viewed conversation.
    /// - Parameters:
    ///   - messages: An array of new agent ChatMessages to add.
    ///   - conversationId: The specific ID of the conversation these messages belong to.
    private func handleAgentResponse(messages newMessages: [ChatMessage], conversationId: UUID) {
        guard !newMessages.isEmpty else { return }
        
        // Update the specific conversation in the store
        updateConversationInStore(conversationId: conversationId, appending: newMessages)
        
        // Update local state only if the response matches the currently viewed conversation
        if self.targetConversationId == conversationId {
            self.messages.append(contentsOf: newMessages)
            // Ensure sorting after appending multiple messages
            self.messages.sort { $0.timestamp < $1.timestamp }
            logger.debug("Appended \(newMessages.count) agent messages locally for conversation \(conversationId.uuidString)")
        } else {
             logger.info("Agent response received for background conversation \(conversationId.uuidString). Store updated, but not updating local UI messages for current target \(self.targetConversationId?.uuidString ?? "nil").")
        }
    }
    
    /// Fetches a specific conversation from the store, appends new messages, and saves it back.
    /// - Parameters:
    ///   - conversationId: The ID of the conversation to update.
    ///   - newMessages: An array of `ChatMessage` objects to append.
    private func updateConversationInStore(conversationId: UUID, appending newMessages: [ChatMessage]) {
        guard !newMessages.isEmpty else {
             logger.warning("updateConversationInStore called with empty messages for \(conversationId.uuidString).")
             return
        }
        
        // Get the specific conversation from the store
        guard var conversationToUpdate = store.getConversation(withId: conversationId) else {
            logger.error("Cannot update conversation in store: Conversation ID \(conversationId.uuidString) not found.")
            // Optionally: Handle error, maybe try to recreate if appropriate?
            return
        }
        
        // Append new messages
        conversationToUpdate.messages.append(contentsOf: newMessages)
        // Timestamp is updated automatically by store.updateConversation
        
        // Update in the store
        store.updateConversation(conversationToUpdate)
        logger.trace("Updated conversation \(conversationId.uuidString) in ConversationStore with \(newMessages.count) new messages.")
    }
    
    // Removed updateConversationInStore() helper that took no parameters, as logic is now in the version above.
    
    // --- Parsing logic (remains the same as in the previous version) ---
    private func parseOllamaResponseData(data: Data) -> String {
         do {
             guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let reply = json["response"] as? String else {
                 logger.warning("Quick Access: Ollama response data was not valid JSON or missing 'response' key.")
                 return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Error: Could not decode non-JSON Ollama response."
             }
             logger.debug("Quick Access successfully parsed Ollama response data.")
             return reply.trimmingCharacters(in: .whitespacesAndNewlines)
         } catch {
             logger.error("Quick Access: Failed to parse Ollama JSON response data: \(error.localizedDescription, privacy: .public)")
             return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Error: Could not decode Ollama server response data."
         }
    }

    private func parseAgentResponseString(_ responseText: String) -> [MessageContent] {
        logger.debug("Quick Access parsing agent response string (length: \(responseText.count))...")
        var contentBlocks: [MessageContent] = []
        let document = Document(parsing: responseText)

        for block in document.children {
            processMarkdownBlock(block, into: &contentBlocks)
        }
        
        if contentBlocks.isEmpty && !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
             logger.debug("No Markdown blocks found, treating as plain text.")
             return [.plainText(responseText)]
         }
        logger.debug("Parsed agent response into \(contentBlocks.count) content blocks.")
        return contentBlocks
    }

    private func processMarkdownBlock(_ block: Markup, into contentBlocks: inout [MessageContent]) {
         switch block {
            case let codeBlock as CodeBlock:
                 let codeContent = codeBlock.code.trimmingCharacters(in: .whitespacesAndNewlines)
                 if !codeContent.isEmpty {
                     contentBlocks.append(.codeBlock(language: codeBlock.language, code: codeContent))
                     logger.trace("Processed CodeBlock (lang: \(codeBlock.language ?? "nil", privacy: .public)).")
                 }
            case let paragraph as Paragraph:
                let childrenArray = Array(paragraph.children)
                if childrenArray.count == 1, let imageNode = childrenArray.first as? Markdown.Image {
                    processImageNode(imageNode, into: &contentBlocks)
                } else {
                    appendAsMarkdown(paragraph, into: &contentBlocks)
                }
            case let imageNode as Markdown.Image:
                processImageNode(imageNode, into: &contentBlocks)
            case let blockquote as BlockQuote:
                 let quoteContent = blockquote.format().trimmingCharacters(in: .whitespacesAndNewlines)
                 if !quoteContent.isEmpty {
                     contentBlocks.append(.markdownText(quoteContent))
                     logger.trace("Processed BlockQuote.")
                 }
            default:
                appendAsMarkdown(block, into: &contentBlocks)
            }
    }

    private func processImageNode(_ imageNode: Markdown.Image, into contentBlocks: inout [MessageContent]) {
        let urlString = imageNode.source
        let altText = imageNode.plainText
        if let S_urlString = urlString, !S_urlString.isEmpty {
            let url = URL(string: S_urlString)
            contentBlocks.append(.image(url: url, alt: altText))
            logger.trace("Processed ImageNode (url: \(S_urlString, privacy: .public)).")
        } else {
            logger.warning("Quick Access: Skipping Image Node with missing or empty source URL.")
        }
    }

    private func appendAsMarkdown(_ block: Markup, into contentBlocks: inout [MessageContent]) {
         let markdownContent = block.format().trimmingCharacters(in: .whitespacesAndNewlines)
         if !markdownContent.isEmpty {
             contentBlocks.append(.markdownText(markdownContent))
             logger.trace("Processed generic Markup as MarkdownText (type: \(type(of: block), privacy: .public)).")
         }
     }
     
    private func generateSimplifiedErrorMessage(error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "Not connected to the internet. Please check your connection."
            case .cannotFindHost, .cannotConnectToHost:
                return "Cannot connect to the server. Please ensure it's running and accessible."
            default:
                return "A network error occurred: \(urlError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
    
    deinit {
        logger.info("QuickAccessViewModel deinitialized.")
        cancellables.forEach { $0.cancel() }
    }
}
