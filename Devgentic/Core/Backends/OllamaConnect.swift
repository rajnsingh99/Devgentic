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

/// Represents the payload for a STREAMING `/api/chat` request.
struct OllamaStreamingChatRequest: Codable {
    let model: String
    let messages: [OllamaChatMessage]
    let stream: Bool = true
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

/// Represents a single chunk from a streaming `/api/chat` response.
struct OllamaChatStreamResponse: Codable {
    let model: String
    let createdAt: String
    /// The message part of the response, may be absent in the final chunk.
    let message: OllamaChatMessage?
    /// Indicates if this is the final chunk.
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

// Represents the full details of a single model from the /api/show endpoint
struct OllamaShowResponse: Codable {
    let license: String?
    let modelfile: String?
    let parameters: String?
    let template: String?
    let details: OllamaModelDetails?
}

// Represents the detailed information about a model.
struct OllamaModelDetails: Codable, Hashable {
    let format: String?
    let family: String?
    let families: [String]?
    let parameterSize: String?
    let quantizationLevel: String?
    
    // Computed properties to determine capabilities
    var supportsVision: Bool {
        // A simple heuristic: if the model family is 'clip', it likely supports vision.
        // A more robust check might involve looking at the modelfile content for specific keywords.
        return family?.lowercased() == "clip" || families?.contains("clip") ?? false
    }
    
    var supportsToolUse: Bool {
        // This is a placeholder. Determining tool use support might require
        // inspecting the 'modelfile' or 'template' for specific instructions or syntax.
        // For now, we'll default to false.
        return false
    }

    enum CodingKeys: String, CodingKey {
        case format, family, families
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
    }
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

    /// Sends a streaming chat request to the Ollama server.
    /// - Parameters:
    ///   - baseURL: The base URL of the Ollama server.
    ///   - model: The name of the model to use for the chat.
    ///   - history: The message history to send to the model.
    /// - Returns: An `AsyncThrowingStream` that yields string tokens from the model.
    /// - Throws: An error for network issues or bad initial responses.
    static func streamChatRequest(
        baseURL: String,
        model: String,
        history: [OllamaChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                let endpoint = "/api/chat"
                guard let url = URL(string: baseURL + endpoint) else {
                    let error = URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Invalid URL for streaming chat request: \(baseURL)\(endpoint)"])
                    logger.error("\(error.localizedDescription)")
                    continuation.finish(throwing: error)
                    return
                }
                logger.debug("Starting streaming chat request to \(url.absoluteString) with model \(model)")

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")

                let payload = OllamaStreamingChatRequest(model: model, messages: history)

                do {
                    request.httpBody = try JSONEncoder().encode(payload)
                } catch {
                    logger.error("Failed to encode OllamaStreamingChatRequest payload: \(error)")
                    continuation.finish(throwing: error)
                    return
                }

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Did not receive a valid HTTP response."])
                    }
                    
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        var errorBody = ""
                        for try await byte in bytes { errorBody.append(Character(UnicodeScalar(byte))) }
                        logger.error("HTTP Error \(httpResponse.statusCode) from streaming chat request. Body: \(errorBody)")
                        throw URLError(.badServerResponse, userInfo: [
                            NSLocalizedDescriptionKey: "Server returned status \(httpResponse.statusCode).",
                            "HTTPStatusCode": httpResponse.statusCode,
                            "ResponseBody": errorBody
                        ])
                    }
                    
                    let decoder = JSONDecoder()

                    for try await line in bytes.lines {
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        
                        do {
                            let streamResponse = try decoder.decode(OllamaChatStreamResponse.self, from: data)
                            
                            if let token = streamResponse.message?.content {
                                continuation.yield(token)
                            }
                            
                            if streamResponse.done {
                                logger.info("Streaming finished successfully (done: true received).")
                                continuation.finish()
                                return
                            }
                        } catch {
                            logger.error("Failed to decode streaming chunk: '\(line)'. Error: \(error.localizedDescription)")
                            // Continue to the next line, as some streams might have intermittent non-JSON lines.
                        }
                    }
                    
                    // If the loop finishes without a `done: true` packet (e.g., stream cut off), finish here.
                    logger.info("Streaming finished because the byte stream ended.")
                    continuation.finish()

                } catch {
                    logger.error("Error during streaming chat request: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
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
    /// This now returns a `Task` that can be cancelled.
    @discardableResult // Add this to avoid warnings if the returned task is not used
    static func pullOllamaModel(name: String, baseURL: String, progressHandler: @escaping (ModelPullProgress) -> Void) -> Task<Void, Error> {
        let task = Task {
            let endpoint = "/api/pull"
            guard let url = URL(string: baseURL + endpoint) else {
                logger.error("Invalid URL constructed for pulling model: \(baseURL)\(endpoint)")
                throw URLError(.badURL)
            }
            logger.debug("Attempting to pull model '\(name)' from URL: \(url.absoluteString) with streaming.")

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = ["name": name, "stream": true]
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            } catch {
                logger.error("Failed to serialize JSON payload for /api/pull: \(error)")
                throw error
            }

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300.0
            config.timeoutIntervalForResource = 1800.0

            let session = URLSession(configuration: config)

            do {
                let (bytes, response) = try await session.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    logger.error("Invalid response received from pulling model: \(url.absoluteString)")
                    throw URLError(.cannotParseResponse)
                }

                logger.debug("Received status code \(httpResponse.statusCode) from pulling model stream")

                guard (200..<300).contains(httpResponse.statusCode) else {
                    var errorResponseBody = ""
                    for try await line in bytes.lines {
                        errorResponseBody += line + "\n"
                    }
                    logger.error("Bad server response (\(httpResponse.statusCode)) from pulling model stream. Body: \(errorResponseBody.prefix(500))...")

                    throw URLError(.badServerResponse, userInfo: [
                        NSLocalizedDescriptionKey: "Server returned status \(httpResponse.statusCode).",
                        "HTTPStatusCode": httpResponse.statusCode,
                        "ResponseBody": errorResponseBody
                    ])
                }

                logger.info("Starting to process streaming pull response for model '\(name)'.")

                for try await line in bytes.lines {
                    try Task.checkCancellation() // Check for cancellation at the start of each loop iteration

                    guard let data = line.data(using: .utf8) else {
                        logger.warning("Received non-UTF8 line from pull stream.")
                        continue
                    }

                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        logger.warning("Failed to parse JSON from stream line: \(line.prefix(100))...")
                        continue
                    }

                    let status = json["status"] as? String ?? "unknown status"
                    let total = json["total"] as? Int64
                    let completed = json["completed"] as? Int64
                    let digest = json["digest"] as? String
                    let total_bytes = json["total_bytes"] as? Int64

                    let currentTotal = total ?? total_bytes
                    let currentCompleted = completed

                    let percentage: Double?
                    if let currentTotal = currentTotal, let currentCompleted = currentCompleted, currentTotal > 0 {
                        percentage = Double(currentCompleted) / Double(currentTotal)
                    } else {
                        percentage = nil
                    }

                    let errorMsg = json["error"] as? String
                    let progress = ModelPullProgress(status: status, total: currentTotal, completed: currentCompleted, percentage: percentage, error: errorMsg)

                    progressHandler(progress)

                    if let streamedError = errorMsg {
                        logger.error("Received streamed error during pull: \(streamedError)")
                        throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Ollama Stream Error: \(streamedError)"])
                    }
                }

                logger.info("Streaming pull response for model '\(name)' finished.")

            } catch let error as URLError where error.code == .cancelled {
                logger.info("Model pull for '\(name)' was cancelled.")
                throw error // Re-throw cancellation error so the caller can handle it
            } catch {
                logger.error("Error during streaming pull request for '\(name)' or while processing stream: \(error.localizedDescription)")
                throw error
            }
        }
        return task
    }
    
    // NEW: Fetches detailed information for a specific model.
    static func fetchModelDetails(name: String, baseURL: String) async throws -> OllamaShowResponse {
        let endpoint = "/api/show"
        guard let url = URL(string: baseURL + endpoint) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["name": name]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let details = try JSONDecoder().decode(OllamaShowResponse.self, from: data)
        return details
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
