//
//  ToolService.swift
//  Devgentic
//
//  Created by Raj Singh on 01/07/25.
//

import Foundation

class ToolConnect {
    
    func fetchTools(from baseURL: String) async throws -> [ToolModel] {
        guard let url = URL(string: "\(baseURL)/utils/list_tools") else {
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "The provided agent URL is invalid."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15 // 15-second timeout for the request

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch tools. Server responded with status code: \(statusCode)"])
        }

        do {
            let decoder = JSONDecoder()
            let tools = try decoder.decode([ToolModel].self, from: data)
            return tools
        } catch {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "Failed to decode the tool list from the server's response."])
        }
    }
}
