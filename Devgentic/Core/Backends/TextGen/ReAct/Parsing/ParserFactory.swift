//
//  ParserFactory.swift
//  Devgentic
//
//  Step 3 (final): Factory that maps a ModelDialect to the correct concrete parser.
//  Used by dialect-specific generators to obtain their matching parser.
//
//  Created by Raj Singh on 06/03/26.
//

import OSLog

private let logger = DGLogger(category: "ParserFactory")

/// Creates the correct `CognitiveParserProtocol` implementation for a given dialect.
struct ParserFactory {

    /// Returns the concrete parser that matches the model's output dialect.
    ///
    /// - Parameter dialect: The dialect detected for the current model.
    /// - Returns: A stateless parser capable of handling that dialect's output format.
    static func createParser(for dialect: ModelDialect) -> any CognitiveParserProtocol {
        logger.info("🏗️ Creating Parser for dialect: \(String(describing: dialect))")
        switch dialect {
        case .nativeJSON:
            return NativeJSONParser()
        case .mistralXML:
            return MistralXMLParser()
        case .reactMarkdown:
            return ReActMarkdownParser()
        case .heuristicJson:
            return HeuristicCognitiveParser()
        case .qwenHermesToolCall:
            return QwenHermesJsonParser()
        case .llama3JsonSingle:
            return Llama3JsonParser()
        case .mistralV3Array:
            return MistralV3Parser()
        case .mistralV11Flat:
            return MistralV11Parser()
        case .phiFunctoolsBracket:
            return PhiFunctoolsParser()
        case .deepseekV3JsonFence:
            return DeepSeekV3Parser()
        case .pythonicBracketList:
            return PythonicListParser()
        case .graniteLegacyArray:
            return GraniteLegacyParser()
        case .granite4ToolCall:
            // Granite 4 emits `<tool_call>{JSON}</tool_call>` — identical shape to Qwen/Hermes.
            // Reuse the existing parser rather than duplicating logic.
            return QwenHermesJsonParser()
        case .commandRAction:
            return CommandRActionParser()
        case .commandR7BAction:
            return CommandR7BActionParser()
        case .qwen3CoderDeepXml:
            return Qwen3CoderDeepXMLParser()
        case .deepseekV31Flat:
            return DeepSeekV31Parser()
        case .deepseekV32Dsml:
            return DeepSeekV32Parser()
        }
    }

    /// Returns the appropriate parser for a drift-detected format.
    /// Used by `CognitiveParsePipeline` Stage 3 to route fallback parsing
    /// when the primary dialect parser fails and drift detection identifies
    /// an alternative format in the raw output.
    ///
    /// - Parameter format: The format detected by `FormatDriftDetector`.
    /// - Returns: A stateless parser capable of handling that specific leakage pattern.
    static func createFallbackParser(for format: DetectedFormat) -> any CognitiveParserProtocol {
        logger.info("🏗️ Creating Fallback Parser for drift format: \(format.rawValue)")
        switch format {
        case .pythonicTag:
            return PythonicTagParser()
        case .deepXML:
            return DeepXMLParser()
        case .bracketHash:
            return BracketHashParser()
        case .yamlInXML:
            return YAMLInXMLParser()
        case .genericToolsXML:
            return GenericToolsXMLParser()
        case .standardXML:
            return MistralXMLParser()       // Reuse existing XML parser
        case .reactMarkdown:
            return ReActMarkdownParser()    // Reuse existing markdown parser
        case .dynamicToolTag:
            return DynamicToolTagParser()   // <tool_name>{args}</tool_name> — Mistral native dynamic tags
        case .functionCallTag:
            return MistralXMLParser()       // Similar XML structure — reuse XML parser
        case .gorillaFunction:
            return HeuristicCognitiveParser() // No dedicated parser yet — fallback to heuristic
        case .arrayInversion, .flatJSONLeakage:
            return NativeJSONParser()       // JSON-based formats handled by existing JSON parser
        }
    }
}
