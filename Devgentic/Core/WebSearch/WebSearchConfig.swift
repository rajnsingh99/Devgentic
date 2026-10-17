// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WebSearchConfig.swift
//  Devgentic
//
//  Which provider `web_search` uses, plus the non-secret settings some providers need.
//
//  Secrets never live here — API keys are in the Keychain via `WebSearchKeyStore`. This holds the
//  choice of provider, Google's Search Engine ID (an identifier, not a credential) and the
//  SearXNG base URL. A struct over an injectable `UserDefaults` so tests never touch the real
//  domain.
//

import Foundation

struct WebSearchConfig: @unchecked Sendable {

    static let providerKey = "webSearch.provider"
    static let googleEngineIDKey = "webSearch.googleEngineID"
    static let searxngURLKey = "webSearch.searxngURL"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The provider used when the user has not chosen one.
    ///
    /// Defaulting is safe: every provider except SearXNG needs a credential before it sends
    /// anything, and Google (the default) needs a key AND an engine ID, so nothing leaves the
    /// machine until the user has configured it.
    static let defaultProvider: WebSearchProvider = .google

    /// The selected provider; `defaultProvider` until the user picks another.
    var provider: WebSearchProvider {
        get { defaults.string(forKey: Self.providerKey).flatMap(WebSearchProvider.init(rawValue:)) ?? Self.defaultProvider }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.providerKey) }
    }

    var googleEngineID: String {
        get { defaults.string(forKey: Self.googleEngineIDKey) ?? "" }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.googleEngineIDKey) }
    }

    var searxngURL: String {
        get { defaults.string(forKey: Self.searxngURLKey) ?? "" }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.searxngURLKey) }
    }

    /// What is missing for `provider` to work, or nil when it is ready. The sentence is shown to
    /// the model as the tool result, so it says where to fix it.
    func missingSetup(for provider: WebSearchProvider) -> String? {
        if provider.requiresAPIKey {
            switch WebSearchKeyStore.read(for: provider) {
            case .found: break
            case .notFound: return "no \(provider.displayName) API key is saved"
            case .failed: return "the \(provider.displayName) API key could not be read from the Keychain"
            }
        }
        if provider == .google, googleEngineID.isEmpty {
            return "no Google Search Engine ID (cx) is set"
        }
        if provider == .searxng, SearchEndpoint.baseURL(searxngURL) == nil {
            return "no valid SearXNG instance URL is set"
        }
        return nil
    }
}

extension WebSearchConfig {
    /// Why `web_search` cannot run yet, as a sentence for the Tool Library, or nil when ready.
    var setupBlocker: String? {
        guard let missing = missingSetup(for: provider) else { return nil }
        return String(localized: "Web search isn't set up: \(missing). Finish it in Settings → Web Search.")
    }
}

enum SearchEndpoint {
    /// A usable http(s) base URL with a host, or nil. SearXNG is routinely self-hosted on a LAN
    /// address over plain http, so http is allowed here (unlike the cloud providers).
    static func baseURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
