//
//  AgentConnect.swift
//  Devgentic
//
//  Created by Raj Singh on 21/05/25.
//

import Foundation
import os


private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentConnect")

struct AgentConnect {

    let baseURL: String
    let endpoint: String = GlobalConstants.agentEndpoint

    init(baseURL: String = "http://127.0.0.1:8000") { // Default base URL for the Python agent
        self.baseURL = baseURL
    }

    func postToAgentServer(payloadData: Data) async throws -> Data {
        guard let url = URL(string: baseURL + endpoint) else {
            logger.error("Invalid URL constructed for agent server: \(self.baseURL)\(endpoint)")
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("DevgenticApp/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120.0
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

}
