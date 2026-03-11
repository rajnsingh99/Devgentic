//
//  PromptedFlatJSONParser.swift
//  Devgentic
//
//  Step 3.4: Parser for the .promptedFlatJSON dialect.
//  Target: Single flat JSON objects ({"tool_name": "ls", "arguments": {}}).
//  Decodes into a lightweight schema, then maps into ModernCognitiveStep.
//
//  Expected format:
//    {
//      "content": "I need to list the directory",
//      "tool_name": "list_directory",
//      "arguments": { "path": "/" }
//    }
//
//  Created by Raj Singh on 06/03/26.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PromptedFlatJSONParser")

struct PromptedFlatJSONParser: CognitiveParserProtocol {

    // Internal flat schema matching the prompted JSON mode output
    private struct SimpleCognitiveStep: Decodable {
        let content: String
        let tool_name: String?
        let arguments: [String: AnyCodable]?
    }

    func parse(rawResponse: String) -> ModernCognitiveStep {
        // Delegate entirely to HeuristicCognitiveParser — it already implements the
        // exact flat-JSON tiered strategy (markdown strip → brace extraction → sanitize → decode).
        // This parser is a clean semantic wrapper that satisfies CognitiveParserProtocol.
        logger.debug("PromptedFlatJSONParser: delegating to HeuristicCognitiveParser.")
        return HeuristicCognitiveParser.parseLegacyResponse(rawResponse)
    }
}
