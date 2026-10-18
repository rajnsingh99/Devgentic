// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AboutSettingsView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import AppKit
import SwiftUI

/// Settings About pane: version, updates, links, licences and a copyable environment summary.
/// Version and build number are read from the bundle; licence documents open from the bundled copies.
struct AboutSettingsView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var softwareUpdater = SoftwareUpdater.shared

    @State private var copiedEnvironment = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                SettingsCard(title: "Updates", icon: "arrow.triangle.2.circlepath", theme: theme) {
                    SettingsRow(title: "Software Update", description: updateStatusDescription, theme: theme) {
                        Button("Check for Updates…") { softwareUpdater.checkForUpdates() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!softwareUpdater.canCheckForUpdates)
                    }
                }

                SettingsCard(title: "Project", icon: "link", theme: theme) {
                    linkRow("Website", "Downloads, documentation and release announcements.",
                            GlobalConstants.homepageURL, systemImage: "globe")
                    divider
                    linkRow("Source Code", "The full source, under the GNU AGPL v3. A star on GitHub helps others find it.",
                            GlobalConstants.sourceCodeURL, systemImage: "chevron.left.forwardslash.chevron.right")
                    divider
                    linkRow("Release Notes", "What changed in each version.",
                            GlobalConstants.sourceCodeURL + "/releases", systemImage: "doc.text")
                }

                SettingsCard(title: "Feedback", icon: "bubble.left.and.exclamationmark.bubble.right", theme: theme) {
                    issueRow("Report a Bug", "Opens a short form on GitHub with your app version and Mac filled in. No diagnostic bundle needed; nothing is sent until you submit.",
                             .bug, label: "Report…")
                    divider
                    issueRow("Request a Feature", "Suggest an idea or an improvement on GitHub.",
                             .feature, label: "Request…")
                }

                if GlobalConstants.supportLink != nil {
                    SettingsCard(title: "Support", icon: "heart", theme: theme) {
                        linkRow("Support Development", "Devgentic is free and open source. If it saves you time, you can sponsor it on GitHub. Entirely optional.",
                                GlobalConstants.supportURL, systemImage: "heart")
                    }
                }

                SettingsCard(title: "Licences & Privacy", icon: "doc.plaintext", theme: theme) {
                    documentRow("License", "Devgentic is free software under the GNU Affero General Public License v3.", .license)
                    divider
                    documentRow("Third-Party Notices", "Licences of the open-source components and bundled models this app includes.", .thirdPartyNotices)
                    divider
                    documentRow("Privacy Policy", "Local-first: no telemetry, no account. Your conversations stay on this Mac.", .privacyPolicy)
                }

                SettingsCard(title: "Environment", icon: "info.circle", theme: theme) {
                    SettingsRow(title: "For Bug Reports", description: LocalizedStringKey(environmentSummary), theme: theme) {
                        Button(copiedEnvironment ? "Copied" : "Copy") { copyEnvironment() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
                    Text(copyright)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            Text("Devgentic")
                .font(theme.fontTitle1.weight(.bold))
                .foregroundColor(theme.primaryText)
            Text("Local-first AI agents for your Mac")
                .font(theme.fontFootnote)
                .foregroundColor(theme.secondaryText)
            Text(Self.versionLine)
                .font(theme.fontCaption.monospacedDigit())
                .foregroundColor(theme.secondaryText)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Rows

    private var divider: some View {
        Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
    }

    private func linkRow(_ title: LocalizedStringKey, _ description: LocalizedStringKey,
                         _ urlString: String, systemImage: String) -> some View {
        SettingsRow(title: title, description: description, theme: theme) {
            if let url = URL(string: urlString) {
                Link(destination: url) {
                    Label("Open", systemImage: systemImage)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func issueRow(_ title: LocalizedStringKey, _ description: LocalizedStringKey,
                          _ kind: GitHubIssueLink.Kind, label: LocalizedStringKey) -> some View {
        SettingsRow(title: title, description: description, theme: theme) {
            Button(label) { GitHubIssueLink.open(kind) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func documentRow(_ title: LocalizedStringKey, _ description: LocalizedStringKey,
                             _ document: BundledDocument) -> some View {
        SettingsRow(title: title, description: description, theme: theme) {
            Button("View") { openWindow(id: BundledDocument.windowGroupID, value: document) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: - Version & environment

    static var versionLine: String { "Version \(GitHubIssueLink.versionDescription)" }

    private var updateStatusDescription: LocalizedStringKey {
        let automatic = softwareUpdater.automaticallyChecksForUpdates
            ? "Checks automatically about once a day."
            : "Automatic checks are off — change this in Settings → General → Updates."
        guard let last = softwareUpdater.lastUpdateCheckDate else {
            return LocalizedStringKey("Not checked yet. \(automatic)")
        }
        let when = last.formatted(.relative(presentation: .named))
        return LocalizedStringKey("Last checked \(when). \(automatic)")
    }

    /// One block a user can paste into an issue. App build, OS and hardware only — nothing about
    /// the user, their files, models or configuration.
    private var environmentSummary: String {
        "\(Self.versionLine)\nmacOS \(GitHubIssueLink.macOSDescription)\n\(GitHubIssueLink.hardwareDescription)"
    }

    private func copyEnvironment() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(environmentSummary, forType: .string)
        copiedEnvironment = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedEnvironment = false
        }
    }
}
