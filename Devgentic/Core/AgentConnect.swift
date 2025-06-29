//
//  AgentConnect.swift
//  Devgentic
//
//  Created by Raj Singh on 21/05/25.
//

import Foundation
import os

// Logger for AgentConnect
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentConnect")

struct AgentConnect {

    let baseURL: String

    init(baseURL: String = "http://127.0.0.1:8000") { // Default base URL for the Python agent
        self.baseURL = baseURL
    }

    // MARK: - Post Data to Agent (POST Request)

    func postToAgentServer(endpoint: String, payloadData: Data) async throws -> Data {
        guard let url = URL(string: baseURL + endpoint) else {
            logger.error("Invalid URL constructed for agent server: \(self.baseURL)\(endpoint)")
            throw URLError(.badURL)
        }
        logger.debug("AgentConnect attempting POST to: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120.0 // Increased timeout for potentially long-running agent tasks

        request.httpBody = payloadData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response received from agent server \(url.absoluteString)")
                throw URLError(.cannotParseResponse)
            }

            logger.debug("Received HTTP status code: \(httpResponse.statusCode) from agent server \(url.absoluteString)")

            guard (200..<300).contains(httpResponse.statusCode) else {
                let responseBody = String(data: data, encoding: .utf8) ?? "Non-UTF8 response body"
                logger.error("Agent server HTTP Error \(httpResponse.statusCode). Body: \(responseBody)")
                throw URLError(.badServerResponse, userInfo: [
                    NSLocalizedDescriptionKey: "Agent server returned status \(httpResponse.statusCode).",
                    "HTTPStatusCode": httpResponse.statusCode,
                    "ResponseData": data
                ])
            }
            return data
        } catch let urlError as URLError {
            logger.error("Network error posting to agent server \(url.absoluteString): \(urlError.localizedDescription), code: \(urlError.code.rawValue)")
            throw urlError
        } catch {
            logger.error("Unexpected error posting to agent server \(url.absoluteString): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Agent Server Health Check

    /// Checks if the Python agent server is reachable and responds to the health check endpoint.
    /// - Parameter baseURL: The base URL of the agent server.
    /// - Returns: `true` if the server is reachable and reports "ok" or "degraded", `false` otherwise.
    static func checkAgentServerStatus(baseURL: String) async -> Bool {
        // MODIFIED: Endpoint updated to /utils/health_check
        let endpoint = "/utils/health_check"
        guard let url = URL(string: baseURL + endpoint) else {
            logger.error("Invalid URL constructed for agent server health check: \(baseURL)\(endpoint)")
            return false
        }
        logger.debug("Checking agent server status at \(url.absoluteString)...")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0

        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                logger.warning("Agent server health check received non-success status code.")
                return false
            }

            // The health check response has a top-level "overall_status" key
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["overall_status"] as? String else {
                logger.warning("Failed to parse agent health check JSON response or 'overall_status' key missing.")
                return false
            }

            logger.info("Agent server health status: '\(status)'")
            return status.lowercased() == "ok" || status.lowercased() == "degraded"

        } catch {
            logger.error("Agent server health check failed: \(error.localizedDescription)")
            return false
        }
    }
}
