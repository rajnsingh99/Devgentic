// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WebSearchService.swift
//  Devgentic
//
//  Created by Raj Singh on 28/07/25.
//

import Foundation
import os

private let logger = DGLogger(category: "WebSearchService")

/// A service responsible for interacting with the Google Custom Search API.
/// This includes validating API keys and eventually performing searches.
struct WebSearchService {

    /// Validates a given Google Search API key by making a lightweight test request to the API Discovery Service.
    ///
    /// - Parameter apiKey: The user-provided API key to validate.
    /// - Returns: A tuple containing a `Bool` indicating if the key is valid, and a `String` with a status message.
    func validate(apiKey: String) async -> (isValid: Bool, message: String) {
        logger.debug("Attempting to validate API key.")
        
        // We validate the key by requesting the discovery document for the Custom Search API.
        // This is a lightweight, public endpoint that requires a valid key but no other parameters like 'cx'.
        // A successful response (200) means the key is valid and has the necessary API enabled.
        // An error response (400/403) indicates an invalid key or that the Custom Search API is not enabled for it.
        guard var urlComponents = URLComponents(string: "https://www.googleapis.com/discovery/v1/apis/customsearch/v1/rest") else {
            let errorMessage = String(localized: "Failed to create URL components.")
            logger.error("\(errorMessage)")
            return (false, errorMessage)
        }
        
        urlComponents.queryItems = [
            URLQueryItem(name: "key", value: apiKey)
        ]
        
        guard let url = urlComponents.url else {
            let errorMessage = String(localized: "Failed to construct validation URL.")
            logger.error("\(errorMessage)")
            return (false, errorMessage)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // ⚠️ The key stays in the query string here, unlike the Gemini calls that were moved to
        // `x-goog-api-key`: this is the Custom Search discovery endpoint, whose documented auth is
        // the `key` parameter, and switching it unverified would risk breaking key validation
        // outright. What IS fixed is the durable half — without this the response is written to
        // URLSession's shared on-disk cache keyed by the full URL, leaving the secret in
        // ~/Library/Caches/<bundle-id>/ indefinitely. Revisit if Custom Search is confirmed to
        // accept a header credential.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                let errorMessage = String(localized: "Invalid response from server.")
                logger.error("\(errorMessage)")
                return (false, errorMessage)
            }
            
            // A 200 OK response means the key is valid and the API is enabled.
            if httpResponse.statusCode == 200 {
                logger.info("API Key validation successful with status code 200.")
                return (true, String(localized: "API Key is valid."))
            } else {
                // If the status code is not 200, try to decode the standard Google API error.
                let decoder = JSONDecoder()
                do {
                    let errorResponse = try decoder.decode(GoogleSearchErrorResponse.self, from: data)
                    let errorMessage = errorResponse.error.message
                    logger.warning("API Key validation failed with status code \(httpResponse.statusCode). Reason: \(errorMessage)")
                    return (false, String(localized: "Invalid API Key. Please ensure it is correct and the Custom Search API is enabled in your Google Cloud project."))
                } catch {
                    let errorMessage = String(localized: "Invalid API Key or configuration error. (Status code: \(httpResponse.statusCode))")
                    logger.error("Could not decode Google error response. Status code: \(httpResponse.statusCode).")
                    return (false, errorMessage)
                }
            }
            
        } catch {
            let errorMessage = String(localized: "Network request failed: \(error.localizedDescription)")
            logger.error("\(errorMessage)")
            return (false, errorMessage)
        }
    }
}


// MARK: - Codable Structs for Google API Error Response

/// Decodes the top-level error object from a failed Google API request.
private struct GoogleSearchErrorResponse: Codable {
    let error: ErrorDetail
}

/// Decodes the detailed error information.
private struct ErrorDetail: Codable {
    let code: Int
    let message: String
    let errors: [ErrorItem]
    let status: String
}

/// Decodes the specific reason for the error.
private struct ErrorItem: Codable {
    let message: String
    let domain: String
    let reason: String
}
