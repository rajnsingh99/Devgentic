// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ReasoningReplayAndImageShapeTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ReasoningReplayAndImageShapeTests: XCTestCase {

    private let call = PendingToolCall(id: "toolu_1", name: "read_file", arguments: ["path": .string("a.swift")])

    // MARK: - CR-23 Claude

    private let claudeContent: [[String: Any]] = [
        ["type": "thinking", "thinking": "Need the file first.", "signature": "SIG-abc123"],
        ["type": "redacted_thinking", "data": "ENCRYPTED"],
        ["type": "text", "text": "Reading it."],
        ["type": "tool_use", "id": "toolu_1", "name": "read_file", "input": ["path": "a.swift"]],
    ]

    func testClaudeThinkingBlocksAreCapturedVerbatimWithTheirSignatures() throws {
        guard case .array(let blocks)? = ClaudeLLMProvider.thinkingReplay(in: claudeContent) else { return XCTFail() }
        XCTAssertEqual(blocks.count, 2, "thinking AND redacted_thinking, nothing else")
        let first = try XCTUnwrap(blocks.first?.rawValue as? [String: Any])
        XCTAssertEqual(first["signature"] as? String, "SIG-abc123", "the signature is what makes a replayed block valid")
        XCTAssertNil(ClaudeLLMProvider.thinkingReplay(in: [["type": "text", "text": "x"]]))
    }

    /// ⚠️⚠️ THE CR-23 PROPERTY: the replayed assistant turn leads with the thinking blocks, unchanged.
    func testTheClaudeAssistantTurnLeadsWithTheReplayedThinking() throws {
        let replay = ClaudeLLMProvider.thinkingReplay(in: claudeContent)
        let turn = ClaudeToolTurnAdapter().assistantTurn(toolCalls: [call], reasoning: "Reading it.", replay: replay)
        let content = try XCTUnwrap(turn["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["thinking", "redacted_thinking", "text", "tool_use"])
        XCTAssertEqual(content[0]["signature"] as? String, "SIG-abc123")
        XCTAssertEqual(content[1]["data"] as? String, "ENCRYPTED")
    }

    /// The control: no replay ⇒ exactly the turn it always was.
    func testWithoutReplayTheClaudeTurnIsUnchanged() throws {
        let plain = ClaudeToolTurnAdapter().assistantTurn(toolCalls: [call], reasoning: "r")
        let none = ClaudeToolTurnAdapter().assistantTurn(toolCalls: [call], reasoning: "r", replay: nil)
        XCTAssertEqual(NSDictionary(dictionary: plain), NSDictionary(dictionary: none))
    }

    // MARK: - CR-23 Gemini

    func testGeminiSignaturesAreAttachedToTheMatchingFunctionCallParts() throws {
        let parts: [[String: Any]] = [
            ["text": "Looking."],
            ["functionCall": ["name": "read_file", "args": ["path": "a"]], "thoughtSignature": "GSIG-1"],
            ["functionCall": ["name": "read_file", "args": ["path": "b"]]],
        ]
        let replay = GeminiLLMProvider.thoughtSignatureReplay(in: parts)
        let calls = [call, PendingToolCall(id: "2", name: "read_file", arguments: ["path": .string("b")])]
        let turn = GeminiToolTurnAdapter().assistantTurn(toolCalls: calls, reasoning: "Looking.", replay: replay)
        let out = try XCTUnwrap(turn["parts"] as? [[String: Any]])
        let callParts = out.filter { $0["functionCall"] != nil }
        XCTAssertEqual(callParts.count, 2)
        XCTAssertEqual(callParts[0]["thoughtSignature"] as? String, "GSIG-1")
        XCTAssertNil(callParts[1]["thoughtSignature"], "a part that had none gets none")
        XCTAssertNil(GeminiLLMProvider.thoughtSignatureReplay(in: [["functionCall": ["name": "x"]]]), "nothing to replay")
    }

    // MARK: - CR-23 wiring

    func testEveryCognitiveDecoderFillsTheReplay() throws {
        let claude = try Self.read("Devgentic/Core/Backends/ClaudeLLMProvider.swift")
        XCTAssertEqual(claude.components(separatedBy: "reasoningReplay: pendingTools.isEmpty ? nil : Self.thinkingReplay(in: contentBlocks)").count - 1, 2,
                       "both Claude cognitive paths (text and native-turn) must capture thinking for replay")
        let gemini = try Self.read("Devgentic/Core/Backends/GeminiLLMProvider.swift")
        XCTAssertEqual(gemini.components(separatedBy: "reasoningReplay: pendingTools.isEmpty ? nil : Self.thoughtSignatureReplay(in: parts)").count - 1, 2)
        let executor = try Self.read("Devgentic/Core/Backends/TextGen/ReAct/ReActAgentExecutor.swift")
        XCTAssertTrue(executor.contains("replay: step.reasoningReplay"), "the executor must hand the replay to the adapter")
    }

    // MARK: - CR-24 OpenAI image request shape

    /// ⚠️⚠️ THE CR-24 DEFECT: every non-square ratio built a size gpt-image rejects.
    func testGPTImageOnlyEverGetsSizesItAccepts() {
        for model in ["gpt-image-1", "gpt-image-1-mini", "some-future-image-model"] {
            for ratio in ImageAspectRatio.allCases {
                let shape = OpenAIImageGenService.requestShape(model: model, aspectRatio: ratio, quality: .standard)
                XCTAssertTrue(["1024x1024", "1536x1024", "1024x1536"].contains(shape.size), "\(model) \(ratio): \(shape.size)")
                XCTAssertFalse(shape.sendsResponseFormat, "\(model) always returns base64 and rejects response_format")
            }
            XCTAssertEqual(OpenAIImageGenService.requestShape(model: model, aspectRatio: .square, quality: .hd).quality, "high")
            XCTAssertNil(OpenAIImageGenService.requestShape(model: model, aspectRatio: .square, quality: .standard).quality)
        }
        XCTAssertEqual(OpenAIImageGenService.requestShape(model: "gpt-image-1", aspectRatio: .landscape, quality: .standard).size, "1536x1024")
        XCTAssertEqual(OpenAIImageGenService.requestShape(model: "gpt-image-1", aspectRatio: .portrait, quality: .standard).size, "1024x1536")
    }

    func testTheDALLEFamiliesGetTheirOwnRules() {
        for ratio in ImageAspectRatio.allCases {
            let two = OpenAIImageGenService.requestShape(model: "dall-e-2", aspectRatio: ratio, quality: .hd)
            XCTAssertEqual(two.size, "1024x1024", "dall-e-2 is square-only")
            XCTAssertNil(two.quality, "dall-e-2 takes no quality")
            let three = OpenAIImageGenService.requestShape(model: "dall-e-3", aspectRatio: ratio, quality: .hd)
            XCTAssertTrue(["1024x1024", "1792x1024", "1024x1792"].contains(three.size), "\(ratio): \(three.size)")
            XCTAssertEqual(three.quality, "hd")
        }
    }

    func testBothImageRequestsUseTheShape() throws {
        let source = try Self.read("Devgentic/Core/Backends/ImageGen/Providers/OpenAIImageGenService.swift")
        XCTAssertEqual(source.components(separatedBy: "Self.requestShape(model: modelName, aspectRatio: options.aspectRatio, quality: options.quality)").count - 1, 2,
                       "generate AND edit must both build from the shape")
        XCTAssertFalse(source.contains("\"\\(dimensions.width)x\\(dimensions.height)\""), "a raw aspect-ratio size came back")
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return try String(contentsOf: candidate, encoding: .utf8) }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath)")
    }
}
