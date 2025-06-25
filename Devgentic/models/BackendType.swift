// Models/BackendType.swift
import Foundation

// Define the possible AI backend types
enum BackendType: String, CaseIterable, Identifiable {
    case ollama = "Ollama"
    case agent = "Agent"
   

    var id: String { self.rawValue }
}
