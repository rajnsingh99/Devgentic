//
//  OpenAIConnect.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OpenAIConnectService")

/// Service responsible for communicating with the OpenAI API.
class OpenAIConnect {

    private let apiKey: String
    private let urlSession: URLSession
    
    private let assistantID = "asst_..." // IMPORTANT: Replace with your Assistant ID

    init(apiKey: String) {
        self.apiKey = apiKey
        self.urlSession = URLSession.shared
        logger.info("OpenAIConnectService initialized.")
    }

    /// Establishes a streaming connection to the OpenAI Chat Completions API.
    func streamMessage(
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        modelName: String,
        context: TraceContext
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                let apiContext = context.newSpan()
                logger.info("API Call Start: OpenAI. traceID: \(apiContext.traceID), spanID: \(apiContext.spanID)")
                
                let apiStartTime = Date()
                var firstTokenTime: Date? = nil

                do {
                    guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
                        throw OpenAIError.invalidURL
                    }
                    
                    var request = self.makeRequest(url: url, method: "POST")
                    
                    let apiMessages = history.map { OpenAIMessage(from: $0) } + [OpenAIMessage(role: "user", content: userQuery)]
                    let requestBody = OpenAIStreamRequest(model: modelName, messages: apiMessages, stream: true)
                    
                    request.httpBody = try JSONEncoder().encode(requestBody)
                    logRequestPayload(requestBody, for: "streamMessage")

                    let (bytes, response) = try await self.urlSession.bytes(for: request)
                    
                    try self.handleAPIError(response: response, data: nil)

                    var isFirstToken = true
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            if isFirstToken {
                                firstTokenTime = Date()
                                isFirstToken = false
                            }
                            let jsonString = String(line.dropFirst(6))
                            if jsonString == "[DONE]" {
                                break // Exit loop, proceed to metrics
                            }
                            if let data = jsonString.data(using: .utf8),
                               let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data),
                               let token = chunk.choices.first?.delta.content {
                                continuation.yield(token)
                            }
                        }
                    }
                    
                    // --- Metrics Recording ---
                    let apiEndTime = Date()
                    if let firstTokenTime = firstTokenTime {
                        let ttftDuration = firstTokenTime.timeIntervalSince(apiStartTime)
                        await MetricsManager.shared.record(duration: ttftDuration, for: "time_to_first_token", context: apiContext)
                    }
                    let totalDuration = apiEndTime.timeIntervalSince(apiStartTime)
                    await MetricsManager.shared.record(duration: totalDuration, for: "api_call_duration", context: apiContext)
                    logger.info("API Call Finished: OpenAI. traceID: \(apiContext.traceID), spanID: \(apiContext.spanID)")
                    // --- End Metrics ---

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Sends a message using the Assistants API (non-streaming).
    func sendMessage(
        conversationID: UUID,
        userQuery: String,
        openAIThreadID: String?,
        modelName: String
    ) async throws -> (messages: [ChatMessage], newThreadID: String?) {
        
        let (threadID, isNewThread) = try await getOrCreateThread(existingThreadID: openAIThreadID)
        let newThreadID = isNewThread ? threadID : nil

        try await addMessage(to: threadID, text: userQuery)

        let run = try await createRun(for: threadID, modelName: modelName)
        guard try await pollRunStatus(for: run.id, in: threadID) else {
            throw OpenAIError.runFailed("The assistant's run did not complete successfully.")
        }

        let assistantMessages = try await retrieveLatestAssistantMessages(from: threadID)
        
        let chatMessages = assistantMessages.map {
            ChatMessage(conversationId: conversationID, sender: .agent, content: .markdownText($0))
        }
        
        return (messages: chatMessages, newThreadID: newThreadID)
    }

    // MARK: - Private API Workflow Methods

    private func getOrCreateThread(existingThreadID: String?) async throws -> (threadID: String, isNew: Bool) {
        if let existingThreadID = existingThreadID, !existingThreadID.isEmpty {
            logger.debug("[OpenAIConnect] Using existing thread ID: \(existingThreadID)")
            return (existingThreadID, false)
        } else {
            logger.debug("[OpenAIConnect] Creating new thread.")
            let url = URL(string: "https://api.openai.com/v1/threads")!
            let request = makeAssistantsRequest(url: url, method: "POST")
            // No body for thread creation, so no payload to log.
            let (data, response) = try await urlSession.data(for: request)
            try handleAPIError(response: response, data: data)
            let thread = try JSONDecoder().decode(OpenAIThread.self, from: data)
            logger.info("[OpenAIConnect] Created new thread with ID: \(thread.id)")
            return (thread.id, true)
        }
    }

    private func addMessage(to threadID: String, text: String) async throws {
        let url = URL(string: "https://api.openai.com/v1/threads/\(threadID)/messages")!
        var request = makeAssistantsRequest(url: url, method: "POST")
        let requestBody = OpenAIMessageRequest(role: "user", content: text)
        request.httpBody = try JSONEncoder().encode(requestBody)
        logRequestPayload(requestBody, for: "addMessage")
        
        let (_, response) = try await urlSession.data(for: request)
        try handleAPIError(response: response, data: nil)
    }

    private func createRun(for threadID: String, modelName: String) async throws -> OpenAIRun {
        let url = URL(string: "https://api.openai.com/v1/threads/\(threadID)/runs")!
        var request = makeAssistantsRequest(url: url, method: "POST")
        let requestBody = OpenAIRunRequest(assistant_id: assistantID, model: modelName)
        request.httpBody = try JSONEncoder().encode(requestBody)
        logRequestPayload(requestBody, for: "createRun")

        let (data, response) = try await urlSession.data(for: request)
        try handleAPIError(response: response, data: data)
        return try JSONDecoder().decode(OpenAIRun.self, from: data)
    }

    private func pollRunStatus(for runID: String, in threadID: String) async throws -> Bool {
        let url = URL(string: "https://api.openai.com/v1/threads/\(threadID)/runs/\(runID)")!
        let request = makeAssistantsRequest(url: url, method: "GET")
        while true {
            let (data, response) = try await urlSession.data(for: request)
            try handleAPIError(response: response, data: data)
            let run = try JSONDecoder().decode(OpenAIRun.self, from: data)
            switch run.status {
            case "completed": return true
            case "failed", "cancelled", "expired": return false
            default: try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func retrieveLatestAssistantMessages(from threadID: String) async throws -> [String] {
        let url = URL(string: "https://api.openai.com/v1/threads/\(threadID)/messages")!
        let request = makeAssistantsRequest(url: url, method: "GET")
        let (data, response) = try await urlSession.data(for: request)
        try handleAPIError(response: response, data: data)
        let messageList = try JSONDecoder().decode(OpenAIMessageList.self, from: data)
        return messageList.data.filter { $0.role == "assistant" }.flatMap { $0.content.compactMap { $0.text?.value } }
    }

    // MARK: - Helper Methods

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }
    
    private func makeAssistantsRequest(url: URL, method: String) -> URLRequest {
        var request = makeRequest(url: url, method: method)
        request.setValue("assistants=v2", forHTTPHeaderField: "OpenAI-Beta")
        return request
    }

    private func handleAPIError(response: URLResponse, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            var errorMessage = "An unknown API error occurred."
            if let data = data, let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
                errorMessage = errorResponse.error.message
            }
            throw OpenAIError.apiError("API Error (Code: \(statusCode)): \(errorMessage)")
        }
    }
    
    /// Encodes a `Codable` request body to a pretty-printed JSON string and logs it.
    /// - Parameters:
    ///   - payload: The `Codable` object to be logged.
    ///   - functionName: The name of the calling function, for context in logs.
    private func logRequestPayload<T: Codable>(_ payload: T, for functionName: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(payload)
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.debug("""
                [OpenAIConnect] Request Payload for \(functionName):
                ---
                \(jsonString)
                ---
                """)
            }
        } catch {
            logger.error("[OpenAIConnect] Failed to encode request payload for logging: \(error.localizedDescription)")
        }
    }
}

// MARK: - Codable Structs

enum OpenAIError: Error, LocalizedError {
    case invalidURL
    case apiError(String)
    case runFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The OpenAI API URL is invalid."
        case .apiError(let message): return message
        case .runFailed(let message): return message
        }
    }
}

// Streaming
private struct OpenAIStreamRequest: Codable { let model: String; let messages: [OpenAIMessage]; let stream: Bool }
private struct OpenAIMessage: Codable { let role: String; let content: String; init(role: String, content: String) { self.role = role; self.content = content }; init(from message: ChatMessage) { self.role = message.sender.rawValue; self.content = message.content.textContent ?? "" } }
private struct OpenAIStreamChunk: Decodable { let choices: [Choice]; struct Choice: Decodable { let delta: Delta }; struct Delta: Decodable { let content: String? } }

// Assistants
struct OpenAIThread: Codable { let id: String }
struct OpenAIMessageRequest: Codable { let role: String; let content: String }
struct OpenAIRunRequest: Codable { let assistant_id: String; let model: String? }
struct OpenAIRun: Codable { let id: String; let status: String }
struct OpenAIMessageList: Codable { let data: [MessageData]; struct MessageData: Codable { let role: String; let content: [ContentPart] } }
struct ContentPart: Codable { let type: String; let text: TextContent?; struct TextContent: Codable { let value: String } }
struct OpenAIErrorResponse: Codable { let error: ErrorDetail; struct ErrorDetail: Codable { let message: String; let type: String } }
