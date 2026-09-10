// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  HITLRiskTier+Color.swift
//  Devgentic
//
//  [Q3] Single source of truth for the tool-risk-tier accent color, shared by the main
//  window's InteractionBannerStack and the QuickAccess panel's QuickAccessHITLBanner (their
//  local copies had already diverged, so the same tool showed different colors per surface).
//  Lives in the Interfaces layer — HITLRiskTier is declared in Core (AgentStreamEvent.swift,
//  Foundation-only), and this keeps SwiftUI/Theme out of that model file.
//

import SwiftUI

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
