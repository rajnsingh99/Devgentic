// Services/AIConnect.swift

import Foundation
import os // Import os for logging

// Logger for AIConnect
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.Devgentic", category: "AIConnect")

struct AIConnect {

    // Note: The 'baseURL' property here isn't used by the static methods below,
    // as they accept the base URL dynamically. Consider if this property is still needed
    // or if the service should always operate based on passed URLs.
    let baseURL: String

    init(baseURL: String = "http://localhost:11434") { // Default base URL (might not be used often now)
        self.baseURL = baseURL
    }

    // MARK: - Fetch Data (GET Request) - Used for basic connection test

    /// Fetches data from a specified endpoint using GET.
    /// Assumes the endpoint is relative to the provided baseURL.
    func fetchFromLocalServer(endpoint: String) async throws -> Data {
        // Use the baseURL passed during initialization for constructing the URL
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            logger.error("Invalid URL constructed: \(self.baseURL)\(endpoint)")
            throw URLError(.badURL)
        }

        logger.debug("Fetching data from URL: \(url.absoluteString)")

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response received from \(url.absoluteString)")
                throw URLError(.cannotParseResponse)
            }

            logger.debug("Received status code \(httpResponse.statusCode) from \(url.absoluteString)")

            guard (200..<300).contains(httpResponse.statusCode) else {
                logger.error("Bad server response (\(httpResponse.statusCode)) from \(url.absoluteString)")
                if let responseBody = String(data: data, encoding: .utf8) {
                    logger.error("Error response body: \(responseBody)")
                }
                // Throw specific error based on status code if needed, otherwise generic bad response
                throw URLError(.badServerResponse, userInfo: ["HTTPStatusCode": httpResponse.statusCode])
            }

            return data
        } catch {
            logger.error("Network error fetching from \(url.absoluteString): \(error.localizedDescription)")
            // Log underlying error if available
            if let nsError = error as NSError? {
                logger.error("Underlying error: \(nsError)")
            }
            throw error // Re-throw the caught error
        }
    }

    // MARK: - Post Data (POST Request) - Base function

    /// Sends data to a specified endpoint using POST.
    /// Assumes the endpoint is relative to the provided baseURL.
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
                "ResponseData": data
            ])
        }
        return data
    }


    // MARK: - Ollama Specific Checks <-- NEW FUNCTION -->

    /// Checks if a specific Ollama model exists on the server using the /api/show endpoint.
    /// - Parameters:
    ///   - baseURL: The base URL of the Ollama server (e.g., "http://localhost:11434").
    ///   - modelName: The name of the model to check.
    /// - Returns: `true` if the model exists (responds with 200), `false` if the model does not exist (responds with 404).
    /// - Throws: An error for network issues or other non-200/404 HTTP status codes.
    static func checkOllamaModelExists(baseURL: String, modelName: String) async throws -> Bool {
        let endpoint = "/api/show"
        guard let url = URL(string: baseURL + endpoint) else {
            logger.error("Invalid URL constructed for model check: \(baseURL)\(endpoint)")
            throw URLError(.badURL)
        }
        logger.debug("Checking for model '\(modelName)' at URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["name": modelName]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            logger.error("Failed to serialize JSON payload for model check: \(error)")
            throw error
        }

        // Perform the request
        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                 logger.error("Invalid response received from model check: \(url.absoluteString)")
                 throw URLError(.cannotParseResponse)
            }

            logger.debug("Model check for '\(modelName)' received status code \(httpResponse.statusCode)")

            if httpResponse.statusCode == 200 {
                logger.info("Model '\(modelName)' exists.")
                return true // Model exists
            } else if httpResponse.statusCode == 404 {
                logger.warning("Model '\(modelName)' not found (404).")
                return false // Model does not exist
            } else {
                // Other unexpected status code
                logger.error("Unexpected status code \(httpResponse.statusCode) during model check for '\(modelName)'.")
                throw URLError(.badServerResponse, userInfo: ["HTTPStatusCode": httpResponse.statusCode])
            }
        } catch let error as URLError where error.code == .cannotFindHost || error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
             // Handle specific network connection errors clearly
             logger.error("Network error checking model '\(modelName)': \(error.localizedDescription)")
             throw error // Re-throw network error
        } catch {
            // Handle other potential errors during URLSession.shared.data(for:)
            logger.error("Error during model check request for '\(modelName)': \(error.localizedDescription)")
            throw error // Re-throw other errors
        }
    }
}
