//
//  OllamaCapabilityService.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//


import Foundation
import os

/// Service to determine which local Ollama models support Agentic capabilities (Tools).
class OllamaCapabilityService {
    
    static let shared = OllamaCapabilityService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OllamaCapabilityService")
    
    // Known families that define a baseline of support if template inspection fails/is ambiguous
    private let safeFamilies = ["llama3.1", "llama3.2", "llama3.3", "qwen2.5", "mistral-nemo", "nemotron"]
    
    private init() {}
    
    /// Fetches all local models and filters for those that support tools.
    func getAgentReadyModels(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) async -> [String] {
        do {
            // 1. Fetch list of all models
            let allModels = try await fetchLocalModelNames(baseURL: baseURL)
            var compatibleModels: [String] = []
            
            // 2. Inspect each model concurrently
            await withTaskGroup(of: (String, Bool).self) { group in
                for modelName in allModels {
                    group.addTask {
                        let isCompatible = await self.checkToolSupport(for: modelName, baseURL: baseURL)
                        return (modelName, isCompatible)
                    }
                }
                
                for await (name, isCompatible) in group {
                    if isCompatible {
                        compatibleModels.append(name)
                    }
                }
            }
            
            // Sort for consistent UI
            compatibleModels.sort()
            
            logger.info("Found \(compatibleModels.count) agent-ready models: \(compatibleModels)")
            return compatibleModels
            
        } catch {
            logger.error("Failed to fetch agent-ready models: \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - Private Helpers
    
    private func fetchLocalModelNames(baseURL: URL) async throws -> [String] {
        let url = baseURL.appendingPathComponent("/api/tags")
        let (data, _) = try await URLSession.shared.data(from: url)
        
        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        
        let response = try JSONDecoder().decode(TagsResponse.self, from: data)
        return response.models.map { $0.name }
    }
    
    private func checkToolSupport(for modelName: String, baseURL: URL) async -> Bool {
        // 1. Inspect Model Details (/api/show)
        do {
            let url = baseURL.appendingPathComponent("/api/show")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body = ["name": modelName]
            request.httpBody = try JSONEncoder().encode(body)
            
            let (data, _) = try await URLSession.shared.data(for: request)
            
            // Decode as Dictionary to access dynamic fields easily
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                // CHECK 1: Template Inspection (The most accurate method)
                // If the template contains logic for {{.Tools}}, it supports tools.
                if let template = json["template"] as? String {
                    if template.contains(".Tools") ||
                       template.contains("tool_calls") ||
                       template.contains("[TOOL_CALLS]") {
                        return true
                    }
                }
                
                // CHECK 2: Family Fallback
                // Sometimes custom fine-tunes don't expose the template explicitly but inherit architecture.
                if let details = json["details"] as? [String: Any],
                   let family = details["family"] as? String {
                    
                    // Check if the family is in our safe list
                    let lowerFamily = family.lowercased()
                    for safe in safeFamilies {
                        if lowerFamily.contains(safe) || modelName.lowercased().contains(safe) {
                            return true
                        }
                    }
                }
            }
            
            return false
            
        } catch {
            logger.warning("Could not inspect model \(modelName): \(error.localizedDescription)")
            // Conservative fallback: if we can't check, assume NO to prevent runtime errors.
            return false
        }
    }
}
