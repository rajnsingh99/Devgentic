//
//  MessagePart.swift
//  Devgentic
//
//  Created by Raj Singh on 15/05/25.
//

import Foundation

/// Represents a segment of the message to be sent to the LLM, which can be either text or a file representation.
struct MessagePart {
    enum PartType {
        case text
        case file
    }

    let type: PartType
    /// For `text` type, this is the actual text content.
    /// For `file` type, this can be empty or hold auxiliary information like the original filename placeholder,
    /// though `fileRepresentation` is the primary source for file details.
    let content: String
    let fileRepresentation: LLMFileRepresentation?

    /// Static factory method for creating a text part.
    /// - Parameter text: The text content.
    /// - Returns: A `MessagePart` of type text.
    static func text(_ text: String) -> MessagePart {
        return MessagePart(type: .text, content: text, fileRepresentation: nil)
    }

    /// Static factory method for creating a file part.
    /// - Parameter representation: The `LLMFileRepresentation` for the file.
    /// - Returns: A `MessagePart` of type file.
    static func file(_ representation: LLMFileRepresentation) -> MessagePart {
        // Extracting filename for the 'content' field for logging/debugging if needed,
        // otherwise, it can be an empty string.
        let contentString: String
        switch representation {
        case .inlineContent(let fileName, _, _):
            contentString = fileName
        case .localPath(let fileName, _, _):
            contentString = fileName
        case .remoteReference(let fileName, _, _, _):
            contentString = fileName
        // case .base64Image(let fileName, _, _):
        //     contentString = fileName
        case .unprocessable(let fileName, _, _):
            contentString = fileName
        }
        return MessagePart(type: .file, content: contentString, fileRepresentation: representation)
    }
}

// For debugging and logging purposes
extension MessagePart: CustomStringConvertible {
    var description: String {
        switch type {
        case .text:
            return "TextPart(content: \"\(content.prefix(100))...\")"
        case .file:
            if let fileRep = fileRepresentation {
                return "FilePart(representation: \(fileRep.description))"
            } else {
                return "FilePart(representation: nil)"
            }
        }
    }
}
