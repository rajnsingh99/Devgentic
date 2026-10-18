// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AdvancedConfigEncoder.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Encodes an advanced-configuration struct into the `[String: JSONValue]` bag a provider reads
/// from `LLMProviderConfig.options`; usable off the main actor, unlike the instance-bound profile-service encoder.
enum AdvancedConfigEncoder {

    /// Encodes `config` into the provider-options dictionary shape.
    /// Returns `nil` only when encoding fails; callers treat that as "no options", as for an unconfigured profile.
    static func encode<T: Encodable>(_ config: T) -> [String: JSONValue]? {
        do {
            let data = try JSONEncoder().encode(config)
            guard let dictionary = try JSONSerialization.jsonObject(
                with: data, options: .allowFragments) as? [String: Any] else {
                DGLogger(category: "AdvancedConfigEncoder").error(
                    "[PROFILE] Encoded \(String(describing: T.self)) did not serialize to an "
                    + "object. CONSEQUENCE: the request proceeds with no advanced options, so the "
                    + "provider's own defaults apply instead of the preset the UI displays."
                )
                return nil
            }
            return dictionary.mapValues { JSONValue($0) ?? .null }
        } catch {
            DGLogger(category: "AdvancedConfigEncoder").error(
                "[PROFILE] Failed to encode \(String(describing: T.self)): "
                + "\(error.localizedDescription). CONSEQUENCE: the request proceeds with no "
                + "advanced options, so the provider's own defaults apply instead of the preset "
                + "the UI displays."
            )
            return nil
        }
    }
}
