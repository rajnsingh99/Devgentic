// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  UserFeedback.swift
//  Devgentic
//
//  The feedback a user attaches to a run's diagnostic-bundle export. Moved here
//  2026-08-22 from ReportViewModel.swift, deleted with the old Developer/User
//  report fork — the types outlived the view model because BundleExporter's
//  user_feedback/ section is built from them.
//

import Foundation

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
