//
//  MLXLLMProvider.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import MLXLMCommon

/// Wraps the existing MLXService for on-device inference, adding support for tool calling.
struct MLXLLMProvider: LLMProvider {

    let modelName: String

    init(modelName: String) {
        self.modelName = modelName
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: [String: Any]?) async throws -> String {
        var fullText = ""
        let temperature: Float = 0.6
        let maxTokens = 2048

        // We use streamChat but collect all the output. 
        // MLXService.streamChat will yield BOTH text chunks and synthetic JSON tool call representations.
        let stream = await MLXService.shared.streamChat(
            messages: messages,
            tools: tools,
            maxTokens: maxTokens,
            temperature: temperature
        )

        for try await token in stream {
            fullText += token
        }

        return fullText
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        let temperature: Float = 0.6
        let maxTokens = 2048

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let tokenStream = await MLXService.shared.streamChat(
                        messages: messages,
                        tools: tools,
                        maxTokens: maxTokens,
                        temperature: temperature
                    )

                    for try await token in tokenStream {
                        continuation.yield(token)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
