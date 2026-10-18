// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  StructuredError.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The structured error value carried by `AgentStreamEvent.error`: a machine category (for telemetry and UI), an
/// optional related path and an optional remediation. String-literal and interpolation conformance lets legacy
/// `.error("message")` producers compile unchanged, defaulting to `.executionFailed`.
struct StructuredError: Error, Sendable, Hashable, Codable {
    /// Machine classification (drives severity, telemetry grouping, UI icon).
    var category: AgentErrorCategory
    /// Human-readable message.
    var message: String
    /// The file/resource path this error relates to, when applicable.
    var relatedPath: String?
    /// Optional actionable remediation hint shown to the user.
    var suggestion: String?

    init(
        category: AgentErrorCategory = .executionFailed,
        message: String,
        relatedPath: String? = nil,
        suggestion: String? = nil
    ) {
        self.category = category
        self.message = message
        self.relatedPath = relatedPath
        self.suggestion = suggestion
    }

    /// Unlabeled convenience for wrapping a plain message string variable
    /// (`.error(.init(msg))`) — generic `.executionFailed` category.
    init(_ message: String) {
        self.init(message: message)
    }

    /// Derived severity bucket (from the category).
    var severity: ErrorSeverity { category.severity }

    /// Human-readable category label (e.g. "File Not Found").
    var title: String { category.displayName }
}

// `\(structuredError)` interpolates to the message text, not a struct dump, so log lines and re-emitting producers
// stay unchanged.
extension StructuredError: CustomStringConvertible {
    var description: String { message }
}

// MARK: - Source compatibility with legacy `.error("…")` producers

// String literals and interpolations construct a `StructuredError` with the generic `.executionFailed` category.
// Bare `String` variables need an explicit `.init(...)`.
extension StructuredError: ExpressibleByStringInterpolation {
    init(stringLiteral value: String) {
        self.init(message: value)
    }

    init(stringInterpolation: DefaultStringInterpolation) {
        self.init(message: String(stringInterpolation: stringInterpolation))
    }
}
