//
//  OllamaConnect.swift
//  Devgentic
//
//  Refactored to pure API Client.
//  Handles server status, model management, and VRAM memory lifecycle.
//

import Foundation
import os

// MARK: - Logger
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OllamaConnect")

// MARK: - Ollama Data Structures

/// Represents the progress information during a model pull.
struct ModelPullProgress {
    let status: String
    let total: Int64?
    let completed: Int64?
    let percentage: Double?
    let error: String?
}

/// Represents the full details of a single model from the `/api/show` endpoint.
struct OllamaShowResponse: Codable {
    let license: String?
    let modelfile: String?
    let parameters: String?
    let template: String?
    let details: OllamaModelDetails?
    
    /// Evaluates the model's true capabilities by inspecting the template and modelfile.
    /// This dictates whether the frontend will flag the model as supporting Native Tool Calling.
    var supportsToolUse: Bool {
        let templateStr = template?.lowercased() ?? ""
        let modelfileStr = modelfile?.lowercased() ?? ""
        
        // Look for common tool-calling markers in the model's template
        let hasTemplateTools = templateStr.contains("{{.tools}}") ||
                               templateStr.contains("{{ .tools }}") ||
                               templateStr.contains("[available_tools]") ||
                               templateStr.contains("<tool>") ||
                               templateStr.contains("<tools>") ||
                               templateStr.contains("tool_call")
        
        // Fallback: Check if the modelfile explicitly mentions tools/functions
        let hasModelfileTools = modelfileStr.contains("tool") ||
                                modelfileStr.contains("function")
        
        return hasTemplateTools || hasModelfileTools
    }
}

/// Represents the detailed information about a model's capabilities.
struct OllamaModelDetails: Codable, Hashable {
    let format: String?
    let family: String?
    let families: [String]?
    let parameterSize: String?
    let quantizationLevel: String?
    
    // Computed properties to determine capabilities
    var supportsVision: Bool {
        return family?.lowercased() == "clip" || families?.contains("clip") ?? false
    }
    
    // Note: supportsToolUse was relocated to OllamaShowResponse because
    // it requires access to the model 'template' property to accurately evaluate.

    enum CodingKeys: String, CodingKey {
        case format, family, families
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
    }
}

// MARK: - API Client

struct OllamaConnect {
    
    // MARK: - Core Server Status

    static func checkOllamaServerStatus(baseURL: String) async -> Bool {
        logger.debug("Checking Ollama server status at \(baseURL)...")
        do {
            let (_, response) = try await performRequest(
                endpoint: "/api/version",
                method: "GET",
                baseURL: baseURL,
                timeout: 5.0
            )
            return (200..<300).contains(response.statusCode)
        } catch {
            logger.error("Server status check failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Model Management

    static func fetchLocalOllamaModels(baseURL: String) async throws -> [String] {
        let (data, response) = try await performRequest(endpoint: "/api/tags", method: "GET", baseURL: baseURL)
        
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsArray = json["models"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }

        return modelsArray.compactMap { $0["name"] as? String }
    }

    static func fetchModelDetails(name: String, baseURL: String) async throws -> OllamaShowResponse {
        let (data, response) = try await performRequest(
            endpoint: "/api/show",
            method: "POST",
            baseURL: baseURL,
            payload: ["name": name]
        )
        
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(OllamaShowResponse.self, from: data)
    }

    static func removeOllamaModel(name: String, baseURL: String) async throws {
        let (data, response) = try await performRequest(
            endpoint: "/api/delete",
            method: "DELETE",
            baseURL: baseURL,
            payload: ["name": name]
        )
        
        guard response.statusCode == 200 else {
            if let errorMsg = parseOllamaErrorResponse(data: data) {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Ollama Error: \(errorMsg)"])
            }
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - VRAM / Lifecycle Management

    static func fetchRunningModels(baseURL: String) async throws -> [String] {
        let (data, response) = try await performRequest(endpoint: "/api/ps", method: "GET", baseURL: baseURL)
        
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        // Minimal decoder for /api/ps response
        struct ProcessResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        
        let processResponse = try JSONDecoder().decode(ProcessResponse.self, from: data)
        return processResponse.models.map { $0.name }
    }

    static func unloadModel(name: String, baseURL: String) async throws {
        let payload: [String: Any] = [
            "model": name,
            "keep_alive": 0
        ]
        
        let (_, response) = try await performRequest(
            endpoint: "/api/chat", // The chat endpoint handles memory lifecycle when generating is skipped
            method: "POST",
            baseURL: baseURL,
            payload: payload
        )
        
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        logger.info("Successfully sent unload request for model '\(name)'.")
    }

    // MARK: - Streaming Operations (Pull Model)

    @discardableResult
    static func pullOllamaModel(name: String, baseURL: String, progressHandler: @escaping (ModelPullProgress) -> Void) -> Task<Void, Error> {
        return Task {
            guard let url = URL(string: baseURL + "/api/pull") else {
                throw URLError(.badURL)
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "stream": true])

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300.0
            config.timeoutIntervalForResource = 1800.0
            let session = URLSession(configuration: config)

            let (bytes, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            for try await line in bytes.lines {
                try Task.checkCancellation()

                guard let data = line.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                let status = json["status"] as? String ?? "unknown status"
                let total = json["total"] as? Int64 ?? json["total_bytes"] as? Int64
                let completed = json["completed"] as? Int64
                let errorMsg = json["error"] as? String

                var percentage: Double? = nil
                if let t = total, let c = completed, t > 0 {
                    percentage = Double(c) / Double(t)
                }

                progressHandler(ModelPullProgress(status: status, total: total, completed: completed, percentage: percentage, error: errorMsg))

                if let streamedError = errorMsg {
                    throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: streamedError])
                }
            }
        }
    }

    // MARK: - Internal Networking Helpers
    
    /// A central helper to reduce boilerplate for standard REST requests
    private static func performRequest(
        endpoint: String,
        method: String,
        baseURL: String,
        payload: [String: Any]? = nil,
        timeout: TimeInterval = 30.0
    ) async throws -> (Data, HTTPURLResponse) {
        
        guard let url = URL(string: baseURL + endpoint) else {
            logger.error("Invalid URL: \(baseURL)\(endpoint)")
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        
        if let payload = payload {
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP Response received."])
        }
        
        return (data, httpResponse)
    }

    private static func parseOllamaErrorResponse(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? String else {
            return nil
        }
        return error.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
