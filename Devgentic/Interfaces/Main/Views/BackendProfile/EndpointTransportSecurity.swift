// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EndpointTransportSecurity.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Whether a profile's endpoint carries its credential in the clear (plain `http` to a non-loopback host).
/// Describes a risk and does not gate an action: local setups such as Ollama (`http://localhost:11434`) and
/// LM Studio are legitimate.
enum EndpointTransportSecurity {

    enum Verdict: Equatable {
        /// TLS, a loopback address, or no endpoint to judge.
        case fine
        /// Plain HTTP to a host that is not this machine, with a credential attached — the key
        /// itself travels in the clear.
        case credentialInClear(host: String)
        /// Plain HTTP to a host that is not this machine, with no credential configured. The
        /// traffic (prompts and replies) is still readable in transit.
        case trafficInClear(host: String)
    }

    /// Hosts that never leave the machine, so plain HTTP to them is not a transport risk. `.local` is
    /// deliberately not here: mDNS names resolve to real LAN addresses.
    private static let loopbackHosts: Set<String> = ["localhost", "::1", "[::1]", "0.0.0.0"]

    static func evaluate(baseURL: String?, apiKey: String?) -> Verdict {
        guard let baseURL, !baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
              let parsed = URL(string: baseURL.trimmingCharacters(in: .whitespaces)),
              parsed.scheme?.lowercased() == "http",
              let host = parsed.host?.lowercased(),
              !isLoopback(host)
        else { return .fine }

        let hasKey = (apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        return hasKey ? .credentialInClear(host: host) : .trafficInClear(host: host)
    }

    static func isLoopback(_ host: String) -> Bool {
        if loopbackHosts.contains(host) { return true }
        // The whole 127.0.0.0/8 block, not just 127.0.0.1 — 127.0.1.1 and friends are equally local.
        return host.hasPrefix("127.")
    }

    /// The sentence shown to the user. Nil when there is nothing to say.
    static func warning(for verdict: Verdict) -> String? {
        switch verdict {
        case .fine:
            return nil
        case .credentialInClear(let host):
            return String(localized: "This endpoint uses http://, so your API key is sent to \(host) unencrypted. Anything on the network path can read it. Use https:// unless \(host) is on a network you control.")
        case .trafficInClear(let host):
            return String(localized: "This endpoint uses http://, so prompts and replies travel to \(host) unencrypted. Use https:// unless \(host) is on a network you control.")
        }
    }
}
