// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  FileRetrievalError.swift
//  Devgentic
//
//  Typed failure for reading/extracting an attached or upstream file/image.
//  Replaces the silent `nil`/`try?` returns: every retrieval failure now carries
//  a precise cause, maps to an `AgentErrorCategory` for telemetry, and projects
//  to a `StructuredError` for reporting to the user.
//

import Foundation

enum FileRetrievalError: Error, Sendable {
    case notFound(path: String)
    case accessDenied(path: String)
    case tooLarge(path: String)
    case readFailed(path: String, underlying: String)
    case extractionFailed(path: String, underlying: String)
    case passwordProtected(path: String)
    case corrupted(path: String)
    case emptyDocument(path: String)
    case imageResolutionFailed(path: String, underlying: String)

    /// The file/resource path the failure relates to.
    var path: String {
        switch self {
        case .notFound(let p), .accessDenied(let p), .tooLarge(let p),
             .passwordProtected(let p), .corrupted(let p), .emptyDocument(let p):
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
        case .readFailed:           return .fileReadFailed
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
