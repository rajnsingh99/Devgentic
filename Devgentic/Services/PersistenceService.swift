// Services/PersistenceService.swift
import Foundation
import os // For logging

struct PersistenceService {

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "PersistenceService")

    // MARK: - File Path Management

    /// Gets the URL for the directory where conversation data will be stored.
    /// Creates the directory if it doesn't exist.
    private static func getAppSupportDirectory() -> URL? {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            logger.error("Could not find Application Support directory.")
            return nil
        }

        // Append your app's name (or bundle ID) to create a dedicated folder
        let bundleID = Bundle.main.bundleIdentifier ?? "DevgenticApp"
        let appDirectoryURL = appSupportURL.appendingPathComponent(bundleID, isDirectory: true)

        // Create the directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: appDirectoryURL, withIntermediateDirectories: true, attributes: nil)
            logger.debug("Ensured app support directory exists at: \(appDirectoryURL.path)")
            return appDirectoryURL
        } catch {
            logger.error("Could not create app support directory at \(appDirectoryURL.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Gets the full URL for the conversations JSON file.
    private static func getConversationsFileURL() -> URL? {
        guard let appDirURL = getAppSupportDirectory() else {
            return nil
        }
        // Define the filename
        let fileName = "conversations.json"
        return appDirURL.appendingPathComponent(fileName)
    }

    // MARK: - Saving Logic

    /// Saves the array of conversations to a JSON file.
    /// - Parameter conversations: The array of `Conversation` objects to save.
    static func saveConversations(_ conversations: [Conversation]) {
        guard let fileURL = getConversationsFileURL() else {
            logger.error("Failed to get file URL for saving conversations.")
            return
        }

        logger.info("Attempting to save \(conversations.count) conversations to \(fileURL.path)...")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted // Makes the JSON human-readable (optional)
        encoder.dateEncodingStrategy = .iso8601   // Use standard date format

        do {
            let data = try encoder.encode(conversations)
            try data.write(to: fileURL, options: .atomic) // Atomic write is safer
            logger.info("Successfully saved conversations.")
        } catch let encodingError as EncodingError {
            logger.error("Failed to encode conversations: \(encodingError.localizedDescription)")
            // Log more details about the encoding error if possible
            // switch encodingError { ... }
        } catch {
            logger.error("Failed to write conversations file: \(error.localizedDescription)")
        }
    }

    // MARK: - Loading Logic

    /// Loads the array of conversations from the JSON file.
    /// - Returns: An array of `Conversation` objects, or an empty array if loading fails or file doesn't exist.
    static func loadConversations() -> [Conversation] {
        guard let fileURL = getConversationsFileURL() else {
            logger.error("Failed to get file URL for loading conversations.")
            return []
        }

        // Check if the file exists before attempting to read
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.info("Conversations file not found at \(fileURL.path). Returning empty array.")
            return []
        }

        logger.info("Attempting to load conversations from \(fileURL.path)...")

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601 // Match encoding strategy

            let conversations = try decoder.decode([Conversation].self, from: data)
            logger.info("Successfully loaded \(conversations.count) conversations.")
            return conversations.sorted { $0.timestamp > $1.timestamp } // Ensure loaded data is sorted initially
        } catch let decodingError as DecodingError {
             logger.error("Failed to decode conversations: \(decodingError.localizedDescription)")
             // Log more details about the specific decoding error
             // switch decodingError { ... }
             Self.handleCorruptedFile(fileURL: fileURL) // Attempt to handle corrupted file
             return [] // Return empty on decoding error
        } catch {
            logger.error("Failed to read conversations file: \(error.localizedDescription)")
            return [] // Return empty on other reading errors
        }
    }

    // MARK: - Error Handling (Optional)

    /// Handles a potentially corrupted conversations file (e.g., rename it).
    private static func handleCorruptedFile(fileURL: URL) {
         logger.warning("Conversation file might be corrupted at \(fileURL.path). Attempting to back it up.")
         let backupURL = fileURL.appendingPathExtension("corrupted-\(Int(Date().timeIntervalSince1970)).json")
         do {
             try FileManager.default.moveItem(at: fileURL, to: backupURL)
             logger.info("Backed up corrupted file to \(backupURL.path)")
         } catch {
             logger.error("Failed to back up corrupted file: \(error.localizedDescription)")
         }
     }

}
