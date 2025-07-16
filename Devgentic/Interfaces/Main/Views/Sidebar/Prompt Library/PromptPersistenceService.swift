//
//  PromptPersistenceService.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

// Services/PromptPersistenceService.swift
import Foundation
import os

/// Service responsible for saving and loading `Prompt` data to/from disk.
class PromptPersistenceService {
    private let fileName = "prompts.json"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PromptPersistenceService")

    /// URL for the prompts JSON file in the Application Support directory.
    private var fileURL: URL {
        guard let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // This should ideally not happen in a sandboxed app, but good to have a fallback.
            logger.critical("Unable to get Application Support directory. Using current directory as fallback (not recommended).")
            return URL(fileURLWithPath: fileName)
        }

        // Create a subdirectory for the app if it doesn't exist
        let appDir = appSupportDir.appendingPathComponent(Bundle.main.bundleIdentifier ?? "DevgenticApp")
        if !FileManager.default.fileExists(atPath: appDir.path) {
            do {
                try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
                logger.info("Created Application Support subdirectory: \(appDir.path)")
            } catch {
                logger.error("Error creating Application Support subdirectory \(appDir.path): \(error.localizedDescription)")
                // Fallback to appSupportDir directly if sub-directory creation fails
                return appSupportDir.appendingPathComponent(fileName)
            }
        }
        return appDir.appendingPathComponent(fileName)
    }

    /// Loads prompts from the JSON file.
    /// - Returns: An array of `Prompt` objects. Returns an empty array if loading fails or the file doesn't exist.
    func loadPrompts() -> [Prompt] {
        let path = fileURL.path
        logger.debug("Attempting to load prompts from: \(path)")

        guard FileManager.default.fileExists(atPath: path) else {
            logger.info("Prompts file does not exist at \(path). Returning empty array.")
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            // Date strategy for decoding
            decoder.dateDecodingStrategy = .iso8601 // Or .secondsSince1970, ensure it matches encoding
            let prompts = try decoder.decode([Prompt].self, from: data)
            logger.info("Successfully loaded \(prompts.count) prompts from \(path).")
            return prompts
        } catch {
            logger.error("Failed to load or decode prompts from \(path): \(error.localizedDescription)")
            return []
        }
    }

    /// Saves prompts to the JSON file.
    /// - Parameter prompts: An array of `Prompt` objects to save.
    func savePrompts(_ prompts: [Prompt]) {
        let path = fileURL.path
        logger.debug("Attempting to save \(prompts.count) prompts to: \(path)")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted // For human-readable JSON
            // Date strategy for encoding
            encoder.dateEncodingStrategy = .iso8601 // Or .secondsSince1970, ensure it matches decoding
            let data = try encoder.encode(prompts)
            try data.write(to: fileURL, options: .atomicWrite)
            logger.info("Successfully saved \(prompts.count) prompts to \(path).")
        } catch {
            logger.error("Failed to encode or save prompts to \(path): \(error.localizedDescription)")
        }
    }
}
