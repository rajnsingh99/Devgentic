// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ErrorHandling.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "ErrorHandling")

struct ErrorHandling {

    /// Generates a user-friendly error message string from an Error object.
    /// - Parameter error: The error to parse.
    /// - Parameter backendType: The backend type, used for context in some messages.
    /// - Returns: A string describing the error.
    static func generateUserFriendlyMessage(for error: Error, backendType: BackendType? = nil) -> String {
        if let urlError = error as? URLError {
            let httpStatusCode = urlError.userInfo["HTTPStatusCode"] as? Int
            let responseData = urlError.userInfo["ResponseData"] as? Data
            let statusString = httpStatusCode.map { " (Status: \($0))" } ?? ""
            let backendName = backendType?.rawValue ?? "server"

            if let data = responseData, backendType == .ollama, let ollamaError = parseOllamaErrorResponse(data: data) {
                return "Ollama Error\(statusString): \(ollamaError)"
            }
            
            let responseBodyPreview = responseData.flatMap { String(data: $0, encoding: .utf8)?.prefix(150) } ?? "No additional details"

            switch urlError.code {
            case .cannotConnectToHost:
                return "Error: Could not connect to the \(backendName)\(statusString). Check if it's running and the URL/Port is correct."
            case .networkConnectionLost:
                return "Error: Network connection lost."
            case .notConnectedToInternet:
                return "Error: Not connected to the internet."
            case .badServerResponse:
                return "Error: Bad server response\(statusString). Details: \(responseBodyPreview)"
            case .cannotFindHost:
                return "Error: Cannot find the \(backendName) host. Check address/DNS."
            case .timedOut:
                return "Error: The request to the \(backendName) timed out."
            case .cancelled:
                return "Request cancelled."
            case URLError.Code(rawValue: 1): // Often CFNetworkErrors.cfErrorHTTPConnectionLost or similar permissions issues
                return "Error: Operation not permitted\(statusString). Check network permissions or firewall."
            default:
                logger.warning("Unhandled URLError code: \(urlError.code.rawValue) - \(urlError.localizedDescription)")
                return "Error: Network request failed\(statusString). (\(urlError.localizedDescription))"
            }
        } else if let decodingError = error as? DecodingError {
            logger.warning("Decoding error: \(decodingError.localizedDescription). Context: \(decodingError)")
            return "Error: Failed to understand the server's response. (\(decodingError.localizedDescription))"
        }
        
        // General fallback
        logger.warning("Unhandled error type: \(type(of: error)) - \(error.localizedDescription)")
        return "Error: \(error.localizedDescription)"
    }

    /// Parses an Ollama-specific error response from data.
    /// - Parameter data: The Data object, expected to be JSON.
    /// - Returns: The error message string if parsing is successful, otherwise nil.
    static func parseOllamaErrorResponse(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? String else {
            return nil
        }
        return error.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
