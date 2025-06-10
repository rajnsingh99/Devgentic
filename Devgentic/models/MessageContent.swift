// Models/MessageContent.swift
import Foundation

// Add the new image case
enum MessageContent: Equatable /* Codable conformance updated below */ {
    case plainText(String)
    case markdownText(String)
    case codeBlock(language: String?, code: String)
    case error(title: String?, details: String)
    case image(url: URL?, alt: String?) // <<< New Case

    // Update Equatable conformance
    static func == (lhs: MessageContent, rhs: MessageContent) -> Bool {
        switch (lhs, rhs) {
        case (.plainText(let lText), .plainText(let rText)): return lText == rText
        case (.markdownText(let lText), .markdownText(let rText)): return lText == rText
        case (.codeBlock(let lLang, let lCode), .codeBlock(let rLang, let rCode)): return lLang == rLang && lCode == rCode
        case (.error(let lTitle, let lDetails), .error(let rTitle, let rDetails)): return lTitle == rTitle && lDetails == rDetails
        case (.image(let lUrl, let lAlt), .image(let rUrl, let rAlt)): return lUrl == rUrl && lAlt == rAlt // <<< Compare new case
        default: return false
        }
    }
}

// --- Manual Codable Conformance for MessageContent ---
extension MessageContent: Codable {

    // Define coding keys
    enum CodingKeys: String, CodingKey {
        case type // To distinguish the case
        // Associated value keys
        case text
        case language
        case code
        case title
        case details
        case imageUrl // <<< New Key for Image URL
        case imageAlt // <<< New Key for Image Alt Text
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
        case "image": // <<< Handle new case decoding
            let urlString = try container.decodeIfPresent(String.self, forKey: .imageUrl)
            let alt = try container.decodeIfPresent(String.self, forKey: .imageAlt)
            // Attempt to create URL from string, okay if it remains nil
            let url = urlString.flatMap { URL(string: $0) }
            self = .image(url: url, alt: alt)
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
        case .image(let url, let alt): // <<< Handle new case encoding
            try container.encode("image", forKey: .type)
            // Encode URL as its absolute string, handle nil
            try container.encodeIfPresent(url?.absoluteString, forKey: .imageUrl)
            try container.encodeIfPresent(alt, forKey: .imageAlt)
        }
    }
}
