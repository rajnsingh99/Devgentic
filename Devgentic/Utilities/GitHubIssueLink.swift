// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitHubIssueLink.swift
//  Devgentic
//
//  Links into the public issue forms in `.github/ISSUE_TEMPLATE/`, pre-filled with the app version,
//  macOS version and Mac model — the report path that needs no diagnostic bundle.
//
//  ⚠️ THE QUERY KEYS ARE THE FORMS' FIELD `id`s. GitHub pre-fills an issue form field whose id
//  matches a query parameter, and silently ignores one that matches nothing — so renaming
//  `version`, `macos` or `hardware` in a template stops the pre-fill with no error anywhere.
//
//  ⚠️ PUBLIC DESTINATION. Only the app build, OS and hardware model travel in the URL — never
//  anything about the user, their files, models or configuration. The user reviews the issue
//  before submitting; nothing is sent by opening the link.
//

import AppKit
import Foundation

enum GitHubIssueLink {

    enum Kind {
        case bug
        case feature

        var template: String {
            switch self {
            case .bug: return "bug_report.yml"
            case .feature: return "feature_request.yml"
            }
        }
    }

    /// The pre-filled "new issue" URL for a form, or nil if the base URL is malformed.
    static func url(for kind: Kind) -> URL? {
        var comps = URLComponents(string: GlobalConstants.issueTrackerNewIssueURL)
        var items = [
            URLQueryItem(name: "template", value: kind.template),
            URLQueryItem(name: "version", value: versionDescription),
        ]
        if kind == .bug {
            items.append(URLQueryItem(name: "macos", value: macOSDescription))
            items.append(URLQueryItem(name: "hardware", value: hardwareDescription))
        }
        comps?.queryItems = items
        return comps?.url
    }

    /// Opens the form in the user's browser.
    static func open(_ kind: Kind) {
        if let url = url(for: kind) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Environment (app build, OS, hardware — nothing about the user)

    /// "0.9.0 (2026101301)" — read from the bundle, which `release.sh` stamps at archive time.
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var macOSDescription: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// "Mac15,6 · Apple silicon".
    static var hardwareDescription: String {
        #if arch(arm64)
        let arch = "Apple silicon"
        #else
        let arch = "Intel"
        #endif
        return "\(hardwareModel) · \(arch)"
    }

    private static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
