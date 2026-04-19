//
//  UserPersonalBriefSource.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import os

/// A `MorningBriefSource` that provides User Personal profile context
/// to personalize morning brief insights.
///
/// When the user has a populated profile, this source contributes it
/// as a brief fragment so the IC can tailor summaries to the user's
/// known preferences, workflow patterns, and expertise areas.
final class UserPersonalBriefSource: MorningBriefSource, @unchecked Sendable {

    let id = "user_personal"
    let displayName = "User Profile"
    let icon = "person.text.rectangle.fill"

    private let logger = DGLogger(category: "UserPersonalBriefSource")

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.ciFeatureUserPersonalKey)
    }

    func gather() async -> [BriefFragment] {
        let profile = await MainActor.run {
            UserPersonalService.shared.profileMarkdown
        }

        // Only contribute if the profile has real content (not just placeholders)
        guard !profile.isEmpty,
              !profile.allSatisfy({ $0.isWhitespace || $0.isNewline }),
              // Check that at least one section has moved beyond the placeholder
              profile.components(separatedBy: "_No observations yet._").count < UserProfileSection.allCases.count + 1 else {
            logger.debug("[UserPersonalBriefSource] No meaningful profile content — skipping.")
            return []
        }

        logger.debug("[UserPersonalBriefSource] Contributing \(profile.count) chars of profile context.")

        return [BriefFragment(
            sourceID: id,
            title: "User Profile Context",
            detail: "Personalization data",
            priority: 10,  // Low priority — supplementary context
            rawContext: profile
        )]
    }
}
