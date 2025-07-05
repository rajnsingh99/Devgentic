//
//  GlobalConstants.swift
//  Devgentic
//
//  Created by Raj Singh 
//

import Foundation

enum BackendType: String, CaseIterable, Identifiable {
    
    case ollama = "Ollama"
    case agent = "Agent"

    var id: String { self.rawValue }
}
