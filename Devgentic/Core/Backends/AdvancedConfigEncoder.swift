// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  AdvancedConfigEncoder.swift
//  Devgentic
//
//  Created on 07/08/26.
//
//  Encodes an advanced-configuration struct into the `[String: JSONValue]` bag a provider reads
//  from `LLMProviderConfig.options`.
//
//  ⚠️ WHY THIS EXISTS. `BackendProfileService.encodeConfig` already does this, but it is
//  `@MainActor` and instance-bound — unusable from `AgentConnect.initializeModel`, which needs the
//  same conversion to resolve the preset a profile was SHOWN but never had persisted (register
//  A24/A25). Duplicating the JSONSerialization dance at that call site would have put two
//  independently-drifting encoders on either side of the same contract, which is how the panel and
//  the executor came to disagree in the first place.
//

import Foundation

enum AdvancedConfigEncoder {

    /// Encodes `config` into the provider-options dictionary shape.
    ///
    /// Returns `nil` only when encoding genuinely fails; callers treat that as "no options",
    /// which is the pre-existing behaviour for an unconfigured profile.
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
