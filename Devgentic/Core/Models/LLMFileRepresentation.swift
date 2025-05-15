//
//  LLMFileRepresentation.swift
//  Devgentic
//
//  Created by Raj Singh on 15/05/25.
//

import Foundation
import UniformTypeIdentifiers // For UTType

/// Represents the different ways a file can be prepared for an LLM.
enum LLMFileRepresentation {
    /// For small text files where the content is directly included in the prompt.
    case inlineContent(fileName: String, content: String, mimeType: String)

    /// For local LLMs that can access files via a file system path.
    case localPath(fileName: String, path: String, mimeType: String)

    /// For remote LLMs where a file has been uploaded and is referenced by an ID.
    /// `serviceName` helps identify the specific remote service (e.g., "Gemini", "OpenAI").
    case remoteReference(fileName: String, serviceFileId: String, serviceName: String, mimeType: String)

    /// For LLMs that can accept image data directly as a base64 encoded string in the prompt.
    /// (Currently a placeholder, can be expanded if needed for specific LLM capabilities)
    // case base64Image(fileName: String, base64Data: String, mimeType: String)

    /// Represents a file that could not be processed for the current LLM or operation.
    /// `reason` provides context for why the file is unprocessable.
    case unprocessable(fileName: String, reason: String, mimeType: String?)
}

// For debugging and logging purposes
extension LLMFileRepresentation: CustomStringConvertible {
    var description: String {
        switch self {
        case .inlineContent(let fileName, let content, let mimeType):
            return "InlineContent(fileName: \"\(fileName)\", mimeType: \"\(mimeType)\", content: \"\(content.prefix(50))...\")"
        case .localPath(let fileName, let path, let mimeType):
            return "LocalPath(fileName: \"\(fileName)\", path: \"\(path)\", mimeType: \"\(mimeType)\")"
        case .remoteReference(let fileName, let serviceFileId, let serviceName, let mimeType):
            return "RemoteReference(fileName: \"\(fileName)\", serviceFileId: \"\(serviceFileId)\", serviceName: \"\(serviceName)\", mimeType: \"\(mimeType)\")"
        // case .base64Image(let fileName, _, let mimeType):
        //     return "Base64Image(fileName: \"\(fileName)\", mimeType: \"\(mimeType)\", data: \"...\")"
        case .unprocessable(let fileName, let reason, let mimeType):
            return "Unprocessable(fileName: \"\(fileName)\", reason: \"\(reason)\", mimeType: \"\(mimeType ?? "unknown")\")"
        }
    }
}
