// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WebSearchProvider.swift
//  Devgentic
//
//  The search backends the `web_search` tool can talk to.
//
//  Deliberately a short, closed list. Each case is a real implementation with its own request
//  shape and response parser in `WebSearchClient`, so adding one means adding a case here and
//  the compiler pointing at every switch that has to learn it.
//

import Foundation

enum WebSearchProvider: String, CaseIterable, Identifiable, Sendable {
    case brave
    case tavily
    case google
    case searxng

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .brave:   return "Brave Search"
        case .tavily:  return "Tavily"
        case .google:  return "Google Programmable Search"
        case .searxng: return "SearXNG (self-hosted)"
        }
    }

    /// One line on why a user would pick it, shown under the picker.
    var summary: String {
        switch self {
        case .brave:   return String(localized: "Independent index with a free tier. Good general-purpose default.")
        case .tavily:  return String(localized: "Built for AI agents: results arrive as clean, relevance-ranked text.")
        case .google:  return String(localized: "Google results. Needs an API key and a Search Engine ID (cx).")
        case .searxng: return String(localized: "Your own metasearch instance. No account, no API key, queries stay with you.")
        }
    }

    /// Whether a secret has to be stored for this provider. SearXNG authenticates by network
    /// reachability, not a key.
    var requiresAPIKey: Bool { self != .searxng }

    /// Where the user gets a key (or, for SearXNG, the project's setup docs).
    var signupURL: URL {
        switch self {
        case .brave:   return URL(string: "https://brave.com/search/api/")!
        case .tavily:  return URL(string: "https://app.tavily.com/")!
        case .google:  return URL(string: "https://developers.google.com/custom-search/v1/overview")!
        case .searxng: return URL(string: "https://docs.searxng.org/admin/installation.html")!
        }
    }
}
