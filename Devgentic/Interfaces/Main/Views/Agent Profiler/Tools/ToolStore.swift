//
//  ToolStore.swift
//  Devgentic
//
//  Created by Raj Singh on 01/07/25.
//

import SwiftUI

@MainActor
class ToolStore: ObservableObject {
    @Published var availableTools: [ToolModel] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil

    private let toolConnect = ToolConnect()

    func fetchAvailableTools(baseURL: String) async {
        guard !baseURL.isEmpty, let _ = URL(string: baseURL) else {
            self.errorMessage = "Agent URL is not a valid URL."
            self.availableTools = []
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            self.availableTools = try await toolConnect.fetchTools(from: baseURL)
        } catch {
            self.errorMessage = "Error: \(error.localizedDescription)"
            self.availableTools = []
        }
        
        isLoading = false
    }
}
