// Models/MessageContent.swift
import Foundation

enum MessageContent: Equatable /* Codable conformance added below */ {
    case plainText(String)
    case markdownText(String)
    case codeBlock(language: String?, code: String)
    case error(title: String?, details: String)
    // Future: case image(url: URL, altText: String?)

    // Add Equatable conformance (as before)
    static func == (lhs: MessageContent, rhs: MessageContent) -> Bool {
        switch (lhs, rhs) {
        case (.plainText(let lText), .plainText(let rText)): return lText == rText
        case (.markdownText(let lText), .markdownText(let rText)): return lText == rText
        case (.codeBlock(let lLang, let lCode), .codeBlock(let rLang, let rCode)): return lLang == rLang && lCode == rCode
        case (.error(let lTitle, let lDetails), .error(let rTitle, let rDetails)): return lTitle == rTitle && lDetails == rDetails
        // Add future cases
        default: return false
        }
    }
}

// --- Manual Codable Conformance for MessageContent ---
extension MessageContent: Codable {

    // Define coding keys to represent the different cases and their associated values
    enum CodingKeys: String, CodingKey {
        case type // To distinguish the case (e.g., "plainText", "codeBlock")
        // Associated value keys
        case text
        case language
        case code
        case title
        case details
    }

    // Decoder implementation
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "plainText":
            let text = try container.decode(String.self, forKey: .text)
            self = .plainText(text)
        case "markdownText":
            let text = try container.decode(String.self, forKey: .text)
            self = .markdownText(text)
        case "codeBlock":
            let language = try container.decodeIfPresent(String.self, forKey: .language)
            let code = try container.decode(String.self, forKey: .code)
            self = .codeBlock(language: language, code: code)
        case "error":
            let title = try container.decodeIfPresent(String.self, forKey: .title)
            let details = try container.decode(String.self, forKey: .details)
            self = .error(title: title, details: details)
        // Add cases for future types here
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid MessageContent type: \(type)")
        }
    }

    // Encoder implementation
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .plainText(let text):
            try container.encode("plainText", forKey: .type)
            try container.encode(text, forKey: .text)
        case .markdownText(let text):
            try container.encode("markdownText", forKey: .type)
            try container.encode(text, forKey: .text)
        case .codeBlock(let language, let code):
            try container.encode("codeBlock", forKey: .type)
            try container.encodeIfPresent(language, forKey: .language)
            try container.encode(code, forKey: .code)
        case .error(let title, let details):
            try container.encode("error", forKey: .type)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(details, forKey: .details)
        // Add cases for future types here
        }
    }
}
// --- End Codable Conformance ---
