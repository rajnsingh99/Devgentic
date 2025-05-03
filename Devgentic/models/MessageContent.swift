// Models/MessageContent.swift
import Foundation

enum MessageContent: Equatable {
    case plainText(String)
    case markdownText(String)
    case codeBlock(language: String?, code: String)
    // --- NEW CASE ---
    case error(title: String?, details: String) // Optional title, required details
    // ---------------

    // Future cases:
    // case image(url: URL, altText: String?)

    // Implement Equatable
    static func == (lhs: MessageContent, rhs: MessageContent) -> Bool {
        switch (lhs, rhs) {
        case (.plainText(let lText), .plainText(let rText)):
            return lText == rText
        case (.markdownText(let lText), .markdownText(let rText)):
            return lText == rText
        case (.codeBlock(let lLang, let lCode), .codeBlock(let rLang, let rCode)):
            return lLang == rLang && lCode == rCode
        // --- ADD EQUATABLE for error ---
        case (.error(let lTitle, let lDetails), .error(let rTitle, let rDetails)):
            return lTitle == rTitle && lDetails == rDetails
        // -------------------------------
        default:
             return false // Non-matching types are not equal
        }
    }
}
