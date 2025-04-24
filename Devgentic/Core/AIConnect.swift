// /Users/alice/Documents/Workspace/mac-projects/devgentic-mac/AgenticDev/tools/AIConnect.swift
//
//  AIConnect.swift
//  AgenticDev
//
//  Created by Raj Singh on 20/04/25.
//

import Foundation
import os // Import os for logging

// Logger for AIConnect
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "AIConnect")

struct AIConnect {

    let baseURL: String // Make base URL configurable

    init(baseURL: String = "http://localhost:8080") { // Default base URL
        self.baseURL = baseURL
    }

    // MARK: - Fetch Data (GET Request)

    func fetchFromLocalServer(endpoint: String) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            logger.error("Invalid URL: \(self.baseURL)\(endpoint)")
            throw URLError(.badURL)
        }

        logger.debug("Fetching data from URL: \(url.absoluteString)")

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response received from \(url.absoluteString)")
                throw URLError(.cannotParseResponse) // Or a custom error
            }

            logger.debug("Received status code \(httpResponse.statusCode) from \(url.absoluteString)")

            guard 200..<300 ~= httpResponse.statusCode else {
                logger.error("Bad server response (\(httpResponse.statusCode)) from \(url.absoluteString)")
                // Optionally log response body for debugging errors
                if let responseBody = String(data: data, encoding: .utf8) {
                    logger.error("Error response body: \(responseBody)")
                }
                throw URLError(.badServerResponse)
            }

            return data
        } catch {
            logger.error("Network error fetching from \(url.absoluteString): \(error.localizedDescription)")
            throw error // Re-throw the caught error
        }
    }

    // MARK: - Post Data (POST Request)

    func postToLocalServer(baseURL: String, endpoint: String, payload: [String: Any]) async throws -> Data {
        guard let url = URL(string: baseURL + endpoint) else {
            // Handle invalid URL error appropriately
            throw URLError(.badURL) // Example error
        }
        logger.debug("AIConnect attempting POST to: \(url.absoluteString)") // Add logging here

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        // Add other headers if needed

        // Ensure payload serialization happens correctly
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            logger.error("Failed to serialize JSON payload: \(error)")
            throw error // Re-throw serialization error
        }


        // --- URLSession Request ---
        // Use shared session or a configured one
        let (data, response) = try await URLSession.shared.data(for: request)

        // --- Basic Response Validation ---
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Did not receive a valid HTTP response."])
        }

        logger.debug("Received HTTP status code: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            // Try to include response body in error for debugging
            let responseBody = String(data: data, encoding: .utf8) ?? "Non-UTF8 response body"
            logger.error("HTTP Error \(httpResponse.statusCode). Body: \(responseBody)")
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Server returned status \(httpResponse.statusCode).",
                "ResponseData": data // Include data for potential further inspection
            ])
        }
        // --------------------------------

        return data
    }
}
