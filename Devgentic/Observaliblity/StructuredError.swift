//
//  StructuredError.swift
//  Devgentic
//
//  The single structured error value carried by `AgentStreamEvent.error`.
//  Replaces the prior bare `String` so every terminal error has a machine
//  category (for telemetry + UI affordance), an optional related path, and an
//  optional remediation suggestion — while staying source-compatible with the
//  many legacy `.error("message")` producers via string-literal/interpolation
//  conformance (those default to `.executionFailed`).
//

import Foundation

struct StructuredError: Error, Sendable, Hashable, Codable {
    /// Machine classification (drives severity, telemetry grouping, UI icon).
    var category: AgentErrorCategory
    /// Human-readable message (what `.error(String)` used to carry).
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

// `\(structuredError)` interpolates to the message text (not a struct dump), so
// legacy log lines and re-emitting producers (`.error("[\(name)] \(err)")`) stay
// behaviour-neutral.
extension StructuredError: CustomStringConvertible {
    var description: String { message }
}

// MARK: - Source compatibility with legacy `.error("…")` producers

// String literals and interpolations construct a `StructuredError` with the
// generic `.executionFailed` category, so existing `.error("msg")` /
// `.error("… \(x) …")` call sites compile unchanged. Bare `String` *variables*
// still need an explicit `.init(...)` (they are not literals).
extension StructuredError: ExpressibleByStringInterpolation {
    init(stringLiteral value: String) {
        self.init(message: value)
    }

    init(stringInterpolation: DefaultStringInterpolation) {
        self.init(message: String(stringInterpolation: stringInterpolation))
    }
}
