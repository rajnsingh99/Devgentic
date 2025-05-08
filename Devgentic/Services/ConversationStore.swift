// Stores/ConversationStore.swift
import Foundation
import Combine // For @Published
import os     // For logging

class ConversationStore: ObservableObject {
    // MARK: - Singleton Instance
    static let shared = ConversationStore()

    // MARK: - Published Properties
    /// The master list of all conversations, automatically announces changes.
    @Published var conversations: [Conversation] = []

    // MARK: - Private Properties
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ConversationStore")
    private let persistenceService = PersistenceService.self // Using static methods from PersistenceService
    private let quickAccessKey = SettingsKeys.quickAccessOverlayConversationId
    private let defaultQuickAccessTitle = "Quick Access Chat" // Define default title

    // MARK: - Initialization
    /// Private initializer to enforce singleton pattern and load data.
    private init() {
        logger.info("ConversationStore initializing...")
        loadConversationsFromDisk()
        logger.info("ConversationStore initialized with \(self.conversations.count) conversations.")
    }

    // MARK: - Private Core Data Handling Methods

    /// Loads conversations from disk using PersistenceService and sorts them.
    private func loadConversationsFromDisk() {
        self.conversations = persistenceService.loadConversations()
        sortConversations() // Ensure they are sorted after loading
    }

    /// Saves the current state of all conversations to disk.
    private func saveConversationsToDisk() {
        logger.debug("Saving \(self.conversations.count) conversations to disk.")
        persistenceService.saveConversations(self.conversations)
    }

    /// Sorts the conversations array, typically by timestamp descending.
    private func sortConversations() {
        self.conversations.sort { $0.timestamp > $1.timestamp }
        logger.trace("Conversations sorted by timestamp.")
    }

    // MARK: - Public Conversation Management Methods

    /// Returns all conversations, sorted by timestamp.
    func getAllConversations() -> [Conversation] {
        return self.conversations
    }

    /// Retrieves a specific conversation by its ID.
    /// - Parameter id: The UUID of the conversation to retrieve.
    /// - Returns: The `Conversation` object if found, otherwise `nil`.
    func getConversation(withId id: UUID) -> Conversation? {
        return conversations.first { $0.id == id }
    }

    /// Adds a new conversation to the store.
    /// - Parameter conversation: The `Conversation` object to add.
    func addConversation(_ conversation: Conversation) {
        guard !conversations.contains(where: { $0.id == conversation.id }) else {
            logger.warning("Attempted to add a conversation with an existing ID: \(conversation.id.uuidString). Updating instead.")
            updateConversation(conversation)
            return
        }
        conversations.append(conversation)
        sortConversations()
        saveConversationsToDisk()
        logger.info("Added new conversation with ID: \(conversation.id.uuidString)")
    }

    /// Updates an existing conversation in the store.
    /// If the conversation does not exist, it will be added.
    /// The timestamp of the conversation is automatically updated.
    /// **Also updates the title of the Quick Access chat based on the first user message.**
    /// - Parameter conversation: The `Conversation` object to update.
    func updateConversation(_ updatedConversation: Conversation) {
        var conversationToUpdate = updatedConversation
        conversationToUpdate.timestamp = Date() // Always update timestamp on modification

        // --- Logic to set Quick Access title from first user query ---
        let userDefaults = UserDefaults.standard
        // Check if it's the current Quick Access conversation
        if let qaIdString = userDefaults.string(forKey: quickAccessKey),
           let qaId = UUID(uuidString: qaIdString),
           conversationToUpdate.id == qaId {

            // Check if the title is still the default or nil
            if conversationToUpdate.userDefinedTitle == nil || conversationToUpdate.userDefinedTitle == defaultQuickAccessTitle {
                // Find the first user message in the *updated* message list
                if let firstUserMessage = conversationToUpdate.messages.first(where: { $0.sender == .user }) {
                    // Extract text content
                    var titleText: String?
                    switch firstUserMessage.content {
                    case .plainText(let text), .markdownText(let text):
                        titleText = text
                    // Add other cases if relevant (e.g., alt text from image?)
                    default:
                        break // Don't set title based on non-text content
                    }

                    if let text = titleText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        // Generate title preview (similar to Conversation.displayTitle logic)
                        let previewLength = 30 // Max length for the title preview
                        let prefix = String(text.prefix(previewLength))
                        let finalTitle = text.count > previewLength ? prefix + "..." : prefix
                        
                        conversationToUpdate.userDefinedTitle = finalTitle // Set the title
                        logger.info("Set Quick Access conversation (\(qaId.uuidString)) title to: '\(finalTitle)'")
                    }
                }
            }
        }
        // --- End title setting logic ---

        // Find and update/add in the main array
        if let index = conversations.firstIndex(where: { $0.id == conversationToUpdate.id }) {
            conversations[index] = conversationToUpdate
            logger.info("Updated conversation with ID: \(conversationToUpdate.id.uuidString)")
        } else {
            logger.warning("Conversation with ID \(conversationToUpdate.id.uuidString) not found for update. Adding as new.")
            conversations.append(conversationToUpdate)
        }
        sortConversations()
        saveConversationsToDisk()
    }

    /// Deletes a conversation from the store by its ID.
    /// - Parameter id: The UUID of the conversation to delete.
    func deleteConversation(withId id: UUID) {
        let initialCount = conversations.count
        conversations.removeAll(where: { $0.id == id }) // This modifies the array in place
        
        if conversations.count < initialCount {
            saveConversationsToDisk()
            logger.info("Deleted conversation with ID: \(id.uuidString)")
        } else {
            logger.warning("Attempted to delete non-existent conversation or no match found for ID: \(id.uuidString)")
        }
    }
    
    /// Deletes multiple conversations from the store by their IDs.
    /// - Parameter ids: A `Set` of UUIDs of the conversations to delete.
    func deleteConversations(withIds ids: Set<UUID>) {
        let initialCount = self.conversations.count // Use self. for clarity if preferred
        self.conversations.removeAll { ids.contains($0.id) }
        
        // Explicitly use self.conversations.count if compiler still infers capture issues
        if self.conversations.count < initialCount {
            saveConversationsToDisk()
            // Use self.conversations.count here as well for consistency if required by compiler
            logger.info("Deleted \(initialCount - self.conversations.count) conversations.")
        } else {
            logger.info("No conversations found matching IDs for deletion, or ID set was empty.")
        }
    }

    /// Deletes all conversations from the store.
    func deleteAllConversations() {
        guard !conversations.isEmpty else {
            logger.info("No conversations to delete.")
            return
        }
        conversations.removeAll()
        saveConversationsToDisk()
        logger.info("Deleted all conversations.")
    }

    // MARK: - Quick Access Overlay Conversation Management

    /// Retrieves the dedicated Quick Access overlay conversation.
    /// If it doesn't exist (either no ID in UserDefaults or ID not found in current conversations),
    /// it creates a new one with the default title, saves it, and updates UserDefaults.
    /// - Returns: The dedicated `Conversation` for the Quick Access overlay.
    func getOrCreateQuickAccessConversation() -> Conversation {
        let userDefaults = UserDefaults.standard
        var quickAccessConversation: Conversation?
        var madeChanges = false // Flag to track if we need to save

        // 1. Check UserDefaults for an existing ID
        if let existingIdString = userDefaults.string(forKey: quickAccessKey),
           let existingId = UUID(uuidString: existingIdString) {
            // 2a. Try to find a conversation with this ID in self.conversations
            if let foundConversation = self.conversations.first(where: { $0.id == existingId }) {
                logger.info("Found existing Quick Access conversation in store with ID: \(existingId.uuidString)")
                quickAccessConversation = foundConversation
            } else {
                // 2c. ID exists in UserDefaults, but not in store. Recreate it.
                logger.warning("Quick Access conversation ID \(existingId.uuidString) found in UserDefaults but not in store. Recreating.")
                let newConversation = Conversation(
                    id: existingId,
                    messages: [],
                    timestamp: Date(),
                    userDefinedTitle: defaultQuickAccessTitle // Use default title
                )
                self.conversations.append(newConversation) // Add to current list
                quickAccessConversation = newConversation
                madeChanges = true // We added a conversation
            }
        }

        // 3. If no valid ID in UserDefaults or conversation not found by ID
        if quickAccessConversation == nil {
            logger.info("No valid Quick Access conversation ID in UserDefaults or conversation not found. Creating a new one.")
            let newId = UUID()
            userDefaults.set(newId.uuidString, forKey: quickAccessKey) // 3b. Store new ID

            let newConversation = Conversation( // 3c. Create new conversation
                id: newId,
                messages: [],
                timestamp: Date(),
                userDefinedTitle: defaultQuickAccessTitle // Use default title
            )
            self.conversations.append(newConversation) // 3d. Add to current list
            quickAccessConversation = newConversation
            madeChanges = true // We added a conversation
        }
        
        if madeChanges {
            sortConversations()
            saveConversationsToDisk() // Save only if changes were made
            logger.info("Quick Access conversation created/recreated and persisted.")
        }

        return quickAccessConversation! // Should always have a conversation by this point
    }

    /// Starts a new Quick Access conversation session, reusing the current one if it's empty.
    /// If the current Quick Access conversation has messages, or doesn't exist,
    /// this generates a new UUID, stores it in UserDefaults as the active Quick Access ID,
    /// and then ensures this new conversation (with the default title) exists in the store.
    /// - Returns: The active `Conversation` for the Quick Access overlay (either reused or newly created).
    func startNewQuickAccessConversationSession() -> Conversation {
        logger.info("Attempting to start a new Quick Access conversation session.")
        let userDefaults = UserDefaults.standard
        
        // --- Check if current QA chat exists and is empty ---
        if let currentIdString = userDefaults.string(forKey: quickAccessKey),
           let currentId = UUID(uuidString: currentIdString),
           let currentQAConversation = self.conversations.first(where: { $0.id == currentId }) {
            
            if currentQAConversation.messages.isEmpty {
                logger.info("Current Quick Access conversation (\(currentId.uuidString)) is empty. Reusing it.")
                // Ensure its timestamp is updated if desired when reused
                // updateConversation(currentQAConversation) // Optional: uncomment to update timestamp on reuse
                return currentQAConversation // Return the existing empty conversation
            } else {
                logger.info("Current Quick Access conversation (\(currentId.uuidString)) has messages. A new session is required.")
            }
        } else {
             logger.info("No existing Quick Access conversation ID found in UserDefaults or conversation missing. A new session is required.")
        }
        // --- End check ---

        // If the check above didn't return, proceed to create a new session ID
        logger.info("Generating new ID for Quick Access session.")
        let newId = UUID()
        userDefaults.set(newId.uuidString, forKey: quickAccessKey)
        logger.info("Generated and set new Quick Access conversation ID in UserDefaults: \(newId.uuidString)")

        // getOrCreateQuickAccessConversation will now pick up this new ID,
        // create the conversation object (with the default title) if it doesn't exist,
        // add it, save, and return it.
        return getOrCreateQuickAccessConversation()
    }
}
