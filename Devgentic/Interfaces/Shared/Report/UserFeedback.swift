// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UserFeedback.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The feedback a user attaches to a run's diagnostic-bundle export; `BundleExporter` builds its user_feedback section.
enum FeedbackRating: String, Codable, CaseIterable {
    case positive = "positive"
    case negative = "negative"
}

struct UserFeedback: Codable {
    var messageText: String = ""
    var rating: FeedbackRating?
    var screenshotData: Data?

    var isEmpty: Bool { messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && rating == nil }
}
