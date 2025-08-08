//
//  OllamaConnect.swift
//  Devgentic
//
//  Created by Raj Singh on 10/06/25.
//

import Foundation
import os

// Logger for OllamaConnect
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.Devgentic", category: "AIConnect")

// MARK: - Ollama Data Structures

/// Represents a single message in the Ollama chat history.
struct OllamaChatMessage: Codable {
    let role: String // "system", "user", or "assistant"
    let content: String
    // For multi-modal requests, not used in this implementation yet
    // let images: [String]?
}

/// Represents the payload for the `/api/chat` endpoint.
struct OllamaChatRequest: Codable {
    let model: String
    let messages: [OllamaChatMessage]
    let stream: Bool = false // Explicitly set to false for one-shot
}

/// Represents the response from a non-streaming `/api/chat` request.
struct OllamaChatResponse: Codable {
    let model: String
    let createdAt: String
    let message: OllamaChatMessage
    let done: Bool
    
    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case message
        case done
    }
}


// Define a struct to hold the progress information we'll pass back
struct ModelPullProgress {
    let status: String      // e.g., "downloading", "extracting"
    let total: Int64?       // Total bytes (optional, as not always provided)
    let completed: Int64?   // Completed bytes (optional)
    let percentage: Double? // Calculated percentage (optional)
    let error: String?      // Error message from a streamed error object (optional)
}

struct OllamaConnect {

    // Note: The 'baseURL' property here isn't used by the static methods below,
    // as they accept the base URL dynamically. Consider if this property is still needed
    // or if the service should always operate based on passed URLs.
    // We will keep it for now, but the new static methods will accept the URL.
    let baseURL: String

    init(baseURL: String = "http://localhost:11434") { // Default base URL (might not be used often now)
        self.baseURL = baseURL
    }

    // MARK: - Post Data (POST Request) - Base function

    /// Sends data to a specified endpoint using POST.
    /// Assumes the endpoint is relative to the provided baseURL.
    /// NOTE: This currently uses the instance's baseURL property.
    func postToLocalServer(endpoint: String, payload: [String: Any]) async throws -> Data {
        guard let url = URL(string: baseURL + endpoint) else {
            logger.error("Invalid URL constructed: \(self.baseURL)\(endpoint)")
            throw URLError(.badURL)
        }
        logger.debug("AIConnect attempting POST to: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            logger.error("Failed to serialize JSON payload: \(error)")
            throw error // Re-throw serialization error
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Did not receive a valid HTTP response."])
        }

        logger.debug("Received HTTP status code: \(httpResponse.statusCode)")

        // Allow specific handling of 404 in calling functions if needed
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Non-UTF8 response body"
            logger.error("HTTP Error \(httpResponse.statusCode). Body: \(responseBody)")
            // Include status code in userInfo for better error handling
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Server returned status \(httpResponse.statusCode).",
                "HTTPStatusCode": httpResponse.statusCode, // Add status code
                "ResponseData": data // Include response data for parsing errors
            ])
        }
        return data
    }


    // MARK: - Ollama Specific Checks and Actions
    
    /// Sends a one-shot (non-streaming) chat request to the Ollama server.
    /// - Parameters:
    ///   - baseURL: The base URL of the Ollama server.
    ///   - model: The name of the model to use for the chat.
    ///   - history: The message history to send to the model.
    /// - Returns: A `OllamaChatResponse` containing the model's reply.
    /// - Throws: An error for network issues, bad responses, or decoding failures.
    static func sendChatRequest(
        baseURL: String,
        model: String,
        history: [OllamaChatMessage]
    ) async throws -> OllamaChatResponse {
        let endpoint = "/api/chat"
        guard let url = URL(string: baseURL + endpoint) else {
            logger.error("Invalid URL for chat request: \(baseURL)\(endpoint)")
            throw URLError(.badURL)
        }
        logger.debug("Sending one-shot chat request to \(url.absoluteString) with model \(model)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = OllamaChatRequest(model: model, messages: history)

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            logger.error("Failed to encode OllamaChatRequest payload: \(error)")
            throw error
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Did not receive a valid HTTP response."])
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Non-UTF8 response body"
            logger.error("HTTP Error \(httpResponse.statusCode) from chat request. Body: \(responseBody)")
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Server returned status \(httpResponse.statusCode).",
                "HTTPStatusCode": httpResponse.statusCode,
                "ResponseData": data
            ])
        }

        do {
            let decoder = JSONDecoder()
            let chatResponse = try decoder.decode(OllamaChatResponse.self, from: data)
            logger.info("Successfully received and decoded one-shot chat response.")
            return chatResponse
        } catch {
            logger.error("Failed to decode OllamaChatResponse: \(error)")
            if let responseBody = String(data: data, encoding: .utf8) {
                logger.error("Raw response body on decode failure: \(responseBody)")
            }
            throw error
        }
    }


    /// Fetches the list of local Ollama models from the server.
    /// - Parameter baseURL: The base URL of the Ollama server (e.g., "http://localhost:11434").
    /// - Returns: An array of model names (Strings).
    /// - Throws: an error if the request fails or the response cannot be parsed.
    static func fetchLocalOllamaModels(baseURL: String) async throws -> [String] {
        let endpoint = "/api/tags"
        guard let url = URL(string: baseURL + endpoint) else {
            logger.error("Invalid URL constructed for fetching models: \(baseURL)\(endpoint)")
            throw URLError(.badURL)
        }
        logger.debug("Fetching local models from URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        // Use GET method as per observed behavior with user's Ollama instance
        request.httpMethod = "GET" // Changed from "POST"
        // No need to set Content-Type or httpBody for a simple GET request

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response received from fetching models: \(url.absoluteString)")
                throw URLError(.cannotParseResponse)
            }

            logger.debug("Received status code \(httpResponse.statusCode) from fetching models")

            guard (200..<300).contains(httpResponse.statusCode) else {
                 let responseBody = String(data: data, encoding: .utf8) ?? "Non-UTF8 response body"
                 logger.error("Bad server response (\(httpResponse.statusCode)) from fetching models. Body: \(responseBody)")
                 throw URLError(.badServerResponse, userInfo: ["HTTPStatusCode": httpResponse.statusCode, NSLocalizedDescriptionKey: "Server returned status \(httpResponse.statusCode).", "ResponseData": data]) // Include data
             }

            // Parse the JSON response
            // Expected structure: {"models": [{"name": "model1", ...}, {"name": "model2", ...}]}
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelsArray = json["models"] as? [[String: Any]] else {
                logger.error("Failed to parse models JSON response or 'models' key missing.")
                // Attempt to log raw data if parsing fails
                if let rawResponse = String(data: data, encoding: .utf8) {
                    logger.error("Raw response data: \(rawResponse)")
                }
                throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "Failed to parse model list from server response."])
            }

            // Extract model names
            let modelNames = modelsArray.compactMap { $0["name"] as? String }
            logger.info("Successfully fetched \(modelNames.count) local models.")
            logger.debug("Fetched model names: \(modelNames.joined(separator: ", "))")

            return modelNames

        } catch let error as URLError where error.code == .cannotFindHost || error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
             // Handle specific network connection errors clearly
             logger.error("Network error fetching local models: \(error.localizedDescription)")
             throw error // Re-throw network error
         } catch {
            logger.error("Error during local model fetch request: \(error.localizedDescription)")
            throw error // Re-throw other errors
        }
    }

    /// Initiates pulling (downloading) an Ollama model from the server with streaming progress.
    /// Increased timeout to accommodate large model downloads.
    /// - Parameters:
    ///   - name: The name of the model to pull (e.g., "llama3:latest").
    ///   - baseURL: The base URL of the Ollama server (e.g., "http://localhost:11434").
    ///   - progressHandler: A closure to call with progress updates (status, bytes, percentage).
    /// - Throws: An error if the request fails, the server returns an error status code, or parsing fails.
    static func pullOllamaModel(name: String, baseURL: String, progressHandler: @escaping (ModelPullProgress) -> Void) async throws {
        let endpoint = "/api/pull"
        guard let url = URL(string: baseURL + endpoint) else {
            logger.error("Invalid URL constructed for pulling model: \(baseURL)\(endpoint)")
            throw URLError(.badURL)
        }
        logger.debug("Attempting to pull model '\(name)' from URL: \(url.absoluteString) with streaming.")

        var request = URLRequest(url: url)
        request.httpMethod = "POST" // /api/pull uses POST
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // CHANGE: Set stream to true for streaming progress updates
        let payload: [String: Any] = ["name": name, "stream": true]
         do {
             request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
         } catch {
             logger.error("Failed to serialize JSON payload for /api/pull: \(error)")
             throw error // Re-throw serialization error
         }

        // --- INCREASE TIMEOUT FOR PULL REQUEST (Still relevant for connection/initial response) ---
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300.0 // 5 minutes
        // timeoutIntervalForResource is less critical with streaming as we process chunks,
        // but still good to have a final limit.
        config.timeoutIntervalForResource = 1800.0 // 30 minutes (ample time for very large models)


        // --- Use URLSession.bytes(for:) for streaming ---
        let session = URLSession(configuration: config)

        do {
            let (bytes, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response received from pulling model: \(url.absoluteString)")
                throw URLError(.cannotParseResponse)
            }

            logger.debug("Received status code \(httpResponse.statusCode) from pulling model stream")

            guard (200..<300).contains(httpResponse.statusCode) else {
                 // Attempt to read error response body from the stream if available
                 var errorResponseBody = ""
                 for try await line in bytes.lines {
                     errorResponseBody += line + "\n"
                 }
                 logger.error("Bad server response (\(httpResponse.statusCode)) from pulling model stream. Body: \(errorResponseBody.prefix(500))...")

                 throw URLError(.badServerResponse, userInfo: [
                     NSLocalizedDescriptionKey: "Server returned status \(httpResponse.statusCode).",
                     "HTTPStatusCode": httpResponse.statusCode,
                     "ResponseBody": errorResponseBody // Include collected error body
                 ])
             }

            logger.info("Starting to process streaming pull response for model '\(name)'.")

            // Process the streaming response line by line (each line is a JSON object)
            for try await line in bytes.lines {
                // Attempt to parse each line as a JSON object
                guard let data = line.data(using: .utf8) else {
                    logger.warning("Received non-UTF8 line from pull stream.")
                    continue // Skip invalid lines
                }

                // Use JSONDecoder for more robust parsing if needed, but JSONSerialization is fine for simple structures
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                     logger.warning("Failed to parse JSON from stream line: \(line.prefix(100))...")
                     continue // Skip lines that aren't valid JSON
                 }

                // Extract progress information from the JSON object
                let status = json["status"] as? String ?? "unknown status"
                let total = json["total"] as? Int64 // Bytes for current stage (e.g., download)
                let completed = json["completed"] as? Int64 // Bytes completed for current stage
                let digest = json["digest"] as? String // Digest when verifying
                let total_bytes = json["total_bytes"] as? Int64 // Total bytes for the *entire* pull (often in done: true message)

                // Determine which total/completed to use for percentage if both types are present
                let currentTotal = total ?? total_bytes
                let currentCompleted = completed

                // Calculate percentage if relevant byte counts are available
                let percentage: Double?
                if let currentTotal = currentTotal, let currentCompleted = currentCompleted, currentTotal > 0 {
                    percentage = Double(currentCompleted) / Double(currentTotal)
                } else {
                    percentage = nil // Percentage not available for this message
                }


                let errorMsg = json["error"] as? String // Ollama can stream error objects too

                // Create and send the progress update back via the handler
                let progress = ModelPullProgress(status: status, total: currentTotal, completed: currentCompleted, percentage: percentage, error: errorMsg)


                // Report progress using the provided closure
                // @escaping is needed because the async task might outlive the calling context
                progressHandler(progress)

                // Check for a streamed error message and throw an error if found
                 if let streamedError = errorMsg {
                     logger.error("Received streamed error during pull: \(streamedError)")
                     throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Ollama Stream Error: \(streamedError)"])
                 }

                // The stream ends when the pull is complete.
                // There might be a final JSON object with status "success" or similar,
                // or the connection might just close. The loop will finish when the stream ends.
                // We could look for a "completed" or "success" status here if needed,
                // but the loop completing is a strong indicator of success for streaming endpoints.
            }

            // If the loop finishes without throwing an error, the pull is considered successful
            logger.info("Streaming pull response for model '\(name)' finished.")

        } catch let error as URLError where error.code == .cannotFindHost || error.code == .cannotConnectToHost || error.code == .networkConnectionLost || error.code == .cancelled {
             // Handle specific network connection errors clearly, including cancellation
             logger.error("Network error during streaming pull of model '\(name)': \(error.localizedDescription)")
             throw error // Re-throw network error
         } catch {
            logger.error("Error during streaming pull request for '\(name)' or while processing stream: \(error.localizedDescription)")
            throw error // Re-throw other errors (like JSON parsing errors)
        }
    }

    /// Removes a local Ollama model from the server.
    /// - Parameters:
    ///   - name: The name of the model to remove (e.g., "llama3:latest").
    ///   - baseURL: The base URL of the Ollama server (e.g., "http://localhost:11434").
    /// - Throws: An error if the request fails or the server returns an error status code.
    static func removeOllamaModel(name: String, baseURL: String) async throws {
        let endpoint = "/api/delete"
        guard let url = URL(string: baseURL + endpoint) else {
            logger.error("Invalid URL constructed for removing model: \(baseURL)\(endpoint)")
            throw URLError(.badURL)
        }
        logger.debug("Attempting to remove model '\(name)' from URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        // Use DELETE method as per Ollama API documentation
        request.httpMethod = "DELETE" // Changed from POST if needed
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // The /api/delete endpoint requires the model name in the body
        let payload: [String: Any] = ["name": name]
         do {
             request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
         } catch {
             logger.error("Failed to serialize JSON payload for /api/delete: \(error)")
             throw error // Re-throw serialization error
         }

        // Use default session config, timeout isn't usually an issue for deletion
        let session = URLSession.shared


        do {
            // Use the shared session for the DELETE request
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response received from removing model: \(url.absoluteString)")
                throw URLError(.cannotParseResponse)
            }

            logger.debug("Received status code \(httpResponse.statusCode) from removing model")

            // Ollama returns 200 on successful deletion
            guard httpResponse.statusCode == 200 else {
                 let responseBody = String(data: data, encoding: .utf8) ?? "Non-UTF8 response body"
                 logger.error("Bad server response (\(httpResponse.statusCode)) from removing model. Body: \(responseBody)")

                 // Attempt to parse Ollama-specific error response from the body
                 if let ollamaError = parseOllamaErrorResponse(data: data) {
                     throw URLError(.badServerResponse, userInfo: [
                         NSLocalizedDescriptionKey: "Ollama Error \(httpResponse.statusCode): \(ollamaError)",
                         "HTTPStatusCode": httpResponse.statusCode,
                         "ResponseData": data // Include data
                     ])
                 }

                 throw URLError(.badServerResponse, userInfo: [
                     NSLocalizedDescriptionKey: "Server returned status \(httpResponse.statusCode) during deletion.",
                     "HTTPStatusCode": httpResponse.statusCode,
                     "ResponseData": data // Include data
                 ])
             }

             // If we reach here, the status code was 200, indicating success
             if let responseBody = String(data: data, encoding: .utf8) {
                 logger.info("Remove model '\(name)' successful. Response body: \(responseBody.prefix(200))...")
             } else {
                 logger.info("Remove model '\(name)' successful. No readable response body.")
             }


        } catch let error as URLError where error.code == .cannotFindHost || error.code == .cannotConnectToHost || error.code == .networkConnectionLost || error.code == .cancelled {
             // Handle specific network connection errors clearly, including cancellation
             logger.error("Network error removing model '\(name)': \(error.localizedDescription)")
             throw error // Re-throw network error
         } catch {
            logger.error("Error during remove model request for '\(name)': \(error.localizedDescription)")
            throw error // Re-throw other errors
        }
    }

    /// Checks if the Ollama server is reachable and responds with a basic status.
    /// Uses the /api/version endpoint for a lightweight check.
    /// - Parameter baseURL: The base URL of the Ollama server.
    /// - Returns: `true` if the server is reachable and responds successfully, `false` otherwise.
    static func checkOllamaServerStatus(baseURL: String) async -> Bool {
        let endpoint = "/api/version" // Lightweight endpoint to check
        guard let url = URL(string: baseURL + endpoint) else {
            logger.error("Invalid URL constructed for server status check: \(baseURL)\(endpoint)")
            return false // Cannot even form the URL
        }
        logger.debug("Checking Ollama server status at \(url.absoluteString)...")

        // Use a short timeout for this check
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0 // 5 seconds timeout

        let session = URLSession(configuration: config)

        do {
            // Use HEAD request if possible for speed, but GET to /api/version is also light
             var request = URLRequest(url: url)
             request.httpMethod = "GET" // Or "HEAD" if /api/version supports HEAD


            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                 logger.warning("Server status check received non-HTTP response.")
                 return false // Not an HTTP response
            }

            // Check for success status code
            if (200..<300).contains(httpResponse.statusCode) {
                logger.info("Ollama server status check successful (\(httpResponse.statusCode)).")
                return true // Success status
            } else {
                logger.warning("Ollama server status check received non-success status code: \(httpResponse.statusCode)")
                return false // Non-success status
            }

        } catch {
            // Log network errors during status check
            logger.error("Ollama server status check failed: \(error.localizedDescription)")
            if let urlError = error as? URLError {
                logger.error("Ollama server status check URLError code: \(urlError.code.rawValue)")
            }
            return false // Connection or other error
        }
    }


    // Helper to attempt parsing Ollama-specific error response
     private static func parseOllamaErrorResponse(data: Data) -> String? { // Made static
         guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String else {
             return nil
         }
         return error.trimmingCharacters(in: .whitespacesAndNewlines)
     }
}
