// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UserPersonalWidget.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Personal profile summary card, gated behind the Core-Intelligence
/// "user personal" feature flag.
struct UserPersonalWidget: WelcomeWidget {
    let id = "user_personal"
    let priority = 20

    func isVisible() -> Bool {
        let isICEnabled = UserDefaults.standard.bool(forKey: AppSettings.isIntelligenceCoreEnabledKey)
        let isUserPersonalEnabled = UserDefaults.standard.bool(forKey: AppSettings.ciFeatureUserPersonalKey)
        return isICEnabled && isUserPersonalEnabled
    }

    func makeBody() -> AnyView {
        AnyView(UserPersonalWelcomeCard())
    }
}
