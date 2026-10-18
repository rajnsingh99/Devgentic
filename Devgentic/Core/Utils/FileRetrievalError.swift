// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileRetrievalError.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// A typed failure for reading or extracting an attached or upstream file or image.
/// Maps to an `AgentErrorCategory` for telemetry and projects to a `StructuredError` for the user.
enum FileRetrievalError: Error, Sendable {
    case notFound(path: String)
    case accessDenied(path: String)
    case tooLarge(path: String)
    case readFailed(path: String, underlying: String)
    /// The bytes aren't UTF-8 text (a `.class`, `.o`, archive…). Distinct from `readFailed`
    /// because the remedy differs: re-attaching a binary can never succeed.
    case notText(path: String)
    /// A folder reached a lane that sends file CONTENTS (direct injection). Distinct from
    /// `readFailed` for the same reason as `notText`: re-attaching it can never succeed (ATT-3).
    case isFolder(path: String)
    case extractionFailed(path: String, underlying: String)
    case passwordProtected(path: String)
    case corrupted(path: String)
    case emptyDocument(path: String)
    case imageResolutionFailed(path: String, underlying: String)

    /// The file/resource path the failure relates to.
    var path: String {
        switch self {
        case .notFound(let p), .accessDenied(let p), .tooLarge(let p),
             .passwordProtected(let p), .corrupted(let p), .emptyDocument(let p), .notText(let p),
             .isFolder(let p):
            return p
        case .readFailed(let p, _), .extractionFailed(let p, _), .imageResolutionFailed(let p, _):
            return p
        }
    }

    /// Canonical telemetry category.
    var category: AgentErrorCategory {
        switch self {
        case .notFound:             return .fileNotFound
        case .accessDenied:         return .fileAccessDenied
        case .tooLarge:             return .fileTooLarge
        case .readFailed,
             .notText,
             .isFolder:             return .fileReadFailed
        case .extractionFailed,
             .emptyDocument:        return .documentExtractionFailed
        case .passwordProtected:    return .documentPasswordProtected
        case .corrupted:            return .documentCorrupted
        case .imageResolutionFailed: return .imageResolutionFailed
        }
    }

    /// Short, user-facing message (the file name, not the full path, for readability).
    var message: String {
        let name = (path as NSString).lastPathComponent
        switch self {
        case .notFound:             return "Couldn't find '\(name)'."
        case .accessDenied:         return "No permission to read '\(name)'."
        case .tooLarge:             return "'\(name)' is too large to include."
        case .readFailed:           return "Couldn't read '\(name)'."
        case .notText:              return "'\(name)' is a binary file, not text."
        case .isFolder:             return "'\(name)' is a folder, so it wasn't sent."
        case .extractionFailed:     return "Couldn't extract text from '\(name)'."
        case .passwordProtected:    return "'\(name)' is password-protected."
        case .corrupted:            return "'\(name)' appears corrupted."
        case .emptyDocument:        return "'\(name)' has no extractable text."
        case .imageResolutionFailed: return "Couldn't load image '\(name)'."
        }
    }

    /// Optional actionable remediation hint.
    var suggestion: String? {
        switch self {
        case .notFound:             return "Check the file still exists at its path."
        case .accessDenied:         return "Grant access in System Settings › Privacy & Security, or re-attach the file."
        case .tooLarge:             return "Try a smaller file, or extract the relevant portion."
        case .readFailed:           return "Try re-attaching the file."
        case .notText:              return "Attach its source or a text export instead."
        case .isFolder:             return "This profile sends file contents. Attach the files inside it, or use an agent with read_file enabled."
        case .extractionFailed,
             .corrupted:            return "The document couldn't be parsed — it may be damaged."
        case .passwordProtected:    return "Remove the password/encryption, then re-attach."
        case .emptyDocument:        return nil
        case .imageResolutionFailed: return "Try re-attaching the image."
        }
    }

    /// Projection into the unified `StructuredError` carried by `AgentStreamEvent.error`.
    var structuredError: StructuredError {
        StructuredError(category: category, message: message, relatedPath: path, suggestion: suggestion)
    }

    /// Builds a `FileRetrievalError` from a thrown `DocumentExtractionError`.
    static func from(_ docError: DocumentExtractionError, path: String) -> FileRetrievalError {
        switch docError {
        case .fileNotFound:                 return .notFound(path: path)
        case .passwordProtected:            return .passwordProtected(path: path)
        case .corruptedFile:                return .corrupted(path: path)
        case .emptyDocument:                return .emptyDocument(path: path)
        case .unsupportedFormat(let fmt):   return .extractionFailed(path: path, underlying: "unsupported format: \(fmt)")
        case .extractionFailed(let fmt, let err):
            return .extractionFailed(path: path, underlying: "\(fmt): \(err?.localizedDescription ?? "unknown")")
        }
    }
}

extension FileRetrievalError: LocalizedError {
    var errorDescription: String? { message }
}
