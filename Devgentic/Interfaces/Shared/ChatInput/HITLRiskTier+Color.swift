// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HITLRiskTier+Color.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Single source of truth for the tool-risk-tier accent color, shared by the main banner stack and QuickAccess.
/// Lives in the Interfaces layer to keep SwiftUI/Theme out of Core's Foundation-only `HITLRiskTier`.
extension HITLRiskTier {
    /// Banner accent for this risk tier, resolved against the current theme.
    func color(in theme: any Theme) -> Color {
        switch self {
        case .safe:        return theme.secondaryText
        case .moderate:    return theme.warningColor
        case .destructive: return theme.errorColor
        }
    }
}
