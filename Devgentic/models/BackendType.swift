//
//  BackendType.swift
//  Devgentic
//
//  Created by Raj Singh
//

import Foundation

/// Defines the available backend types for processing user requests.
enum BackendType: String, CaseIterable, Identifiable {
    
    /// The Agent backend processes requests through a custom Python server.
    case agent = "Agent"
    
    /// The Ollama backend communicates directly with a local Ollama instance.
    case ollama = "Ollama"
    
    /// The Remote backend communicates with a third-party API (e.g., OpenAI, Google).
    case remote = "Remote"
    
    /// Represents a state where no backend is selected.
    case none = "None"

    var id: String { self.rawValue }
}
