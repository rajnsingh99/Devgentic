//
//  OpenAIConnect.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OpenAIConnectService")

/// Service responsible for communicating with the OpenAI Assistants API.
/// This version is stateful and uses Threads to maintain conversation context.
class OpenAIConnect {

    private let apiKey: String
    private let urlSession: URLSession
    
    // A default Assistant configuration. In a real-world app, you might create
    // one assistant via the OpenAI dashboard and reuse its ID here.
    private let assistantID = "asst_..." // IMPORTANT: Replace with your Assistant ID

    init(apiKey: String) {
        self.apiKey = apiKey
        self.urlSession = URLSession.shared
        logger.info("OpenAIConnectService initialized for Assistants API.")
    }

    /// The main entry point for sending a message. It orchestrates the entire Assistants API flow.
    /// - Returns: A tuple containing the assistant's response messages and a new thread ID if one was created.
    func sendMessage(
        conversationID: UUID,
        userQuery: String,
        openAIThreadID: String?,
        modelName: String
    ) async throws -> (messages: [ChatMessage], newThreadID: String?) {
        
        // Step 1: Determine the thread to use, or create a new one.
        let (threadID, isNewThread) = try await getOrCreateThread(existingThreadID: openAIThreadID)
        let newThreadID = isNewThread ? threadID : nil

        // Step 2: Add the user's message to the thread.
        try await addMessage(to: threadID, text: userQuery)

        // Step 3: Create a Run and wait for it to complete.
        let run = try await createRun(for: threadID, modelName: modelName)
        guard try await pollRunStatus(for: run.id, in: threadID) else {
            throw OpenAIError.runFailed("The assistant's run did not complete successfully.")
        }

        // Step 4: Retrieve the latest messages from the assistant.
        let assistantMessages = try await retrieveLatestAssistantMessages(from: threadID)
        
        let chatMessages = assistantMessages.map {
            ChatMessage(conversationId: conversationID, sender: .agent, content: .markdownText($0))
        }
        
        return (messages: chatMessages, newThreadID: newThreadID)
    }

    // MARK: - Private API Workflow Methods

    private func getOrCreateThread(existingThreadID: String?) async throws -> (threadID: String, isNew: Bool) {
        if let existingThreadID = existingThreadID, !existingThreadID.isEmpty {
            logger.debug("Using existing OpenAI thread: \(existingThreadID)")
            return (existingThreadID, false)
        } else {
            logger.debug("No existing thread ID found, creating a new one.")
            let url = URL(string: "https://api.openai.com/v1/threads")!
            var request = makeRequest(url: url, method: "POST")
            
            let (data, response) = try await urlSession.data(for: request)
            try handleAPIError(response: response, data: data)
            
            let thread = try JSONDecoder().decode(OpenAIThread.self, from: data)
            logger.info("Successfully created new OpenAI thread: \(thread.id)")
            return (thread.id, true)
        }
    }

    private func addMessage(to threadID: String, text: String) async throws {
        let url = URL(string: "https://api.openai.com/v1/threads/\(threadID)/messages")!
        var request = makeRequest(url: url, method: "POST")
        let requestBody = OpenAIMessageRequest(role: "user", content: text)
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await urlSession.data(for: request)
        try handleAPIError(response: response, data: data)
        logger.debug("Successfully added message to thread \(threadID).")
    }

    private func createRun(for threadID: String, modelName: String) async throws -> OpenAIRun {
        let url = URL(string: "https://api.openai.com/v1/threads/\(threadID)/runs")!
        var request = makeRequest(url: url, method: "POST")
        // In a real app, you would use a pre-created assistant ID.
        // For this example, we pass the model and instructions with the run.
        let requestBody = OpenAIRunRequest(assistant_id: assistantID, model: modelName)
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await urlSession.data(for: request)
        try handleAPIError(response: response, data: data)
        
        let run = try JSONDecoder().decode(OpenAIRun.self, from: data)
        logger.info("Successfully created run \(run.id) for thread \(threadID).")
        return run
    }

    private func pollRunStatus(for runID: String, in threadID: String) async throws -> Bool {
        let url = URL(string: "https://api.openai.com/v1/threads/\(threadID)/runs/\(runID)")!
        let request = makeRequest(url: url, method: "GET")

        while true {
            let (data, response) = try await urlSession.data(for: request)
            try handleAPIError(response: response, data: data)
            
            let run = try JSONDecoder().decode(OpenAIRun.self, from: data)
            logger.trace("Polling run \(run.id), status: \(run.status)")

            switch run.status {
            case "completed":
                return true
            case "failed", "cancelled", "expired":
                logger.error("Run \(run.id) terminated with status: \(run.status).")
                return false
            case "requires_action":
                // This would be for implementing Function Calling, which is out of scope.
                logger.error("Run \(run.id) requires action, which is not implemented.")
                return false
            default:
                // "queued", "in_progress"
                try await Task.sleep(nanoseconds: 1_000_000_000) // Wait 1 second
            }
        }
    }

    private func retrieveLatestAssistantMessages(from threadID: String) async throws -> [String] {
        let url = URL(string: "https://api.openai.com/v1/threads/\(threadID)/messages")!
        let request = makeRequest(url: url, method: "GET")

        let (data, response) = try await urlSession.data(for: request)
        try handleAPIError(response: response, data: data)

        let messageList = try JSONDecoder().decode(OpenAIMessageList.self, from: data)
        
        // Filter for messages from the assistant and extract the text content.
        let assistantMessages = messageList.data
            .filter { $0.role == "assistant" }
            .flatMap { $0.content.compactMap { $0.text?.value } }

        logger.info("Retrieved \(assistantMessages.count) new message(s) from the assistant.")
        return assistantMessages
    }

    // MARK: - Helper Methods

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("assistants=v2", forHTTPHeaderField: "OpenAI-Beta")
        return request
    }

    private func handleAPIError(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data)
            let errorMessage = errorResponse?.error.message ?? "An unknown API error occurred."
            logger.error("OpenAI API Error (Code: \(statusCode)): \(errorMessage)")
            throw OpenAIError.apiError(errorMessage)
        }
    }
}

// MARK: - Codable Structs for OpenAI Assistants API

enum OpenAIError: Error, LocalizedError {
    case apiError(String)
    case runFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .apiError(let message): return "API Error: \(message)"
        case .runFailed(let message): return "Run Failed: \(message)"
        }
    }
}

struct OpenAIThread: Codable {
    let id: String
}

struct OpenAIMessageRequest: Codable {
    let role: String
    let content: String
}

struct OpenAIRunRequest: Codable {
    let assistant_id: String
    let model: String? // Optional: The model can be specified on the assistant itself
}

struct OpenAIRun: Codable {
    let id: String
    let status: String
}

struct OpenAIMessageList: Codable {
    let data: [OpenAIMessage]
}

struct OpenAIMessage: Codable {
    let role: String
    let content: [ContentPart]
    
    struct ContentPart: Codable {
        let type: String
        let text: TextContent?
        
        struct TextContent: Codable {
            let value: String
        }
    }
}

struct OpenAIErrorResponse: Codable {
    let error: ErrorDetail
    
    struct ErrorDetail: Codable {
        let message: String
        let type: String
    }
}
