// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  KnowledgeSourceRow.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// One attached reference document, as shown in the agent and bot editors.
/// Healthy and missing files differ by symbol as well as colour, so the states read without perceiving colour.
struct KnowledgeSourceRow: View {
    let source: KnowledgeSource
    let theme: any Theme
    /// Set when the profile will send only part of this source (or none of it) — see
    /// `KnowledgeSourceList`, which computes it from the backend's own plan.
    var warning: DeliveryWarning? = nil
    let onRemove: () -> Void

    /// `doc.text.fill` for a healthy document, a warning triangle for a missing one.
    /// A shape difference, not just a tint; exposed rather than inlined into `body` so a test can assert it.
    static func iconName(forExistingFile exists: Bool) -> String {
        exists ? "doc.text.fill" : "exclamationmark.triangle.fill"
    }

    private var iconName: String { Self.iconName(forExistingFile: source.exists) }

    /// A present file is unremarkable, so it takes the same accent the folder rows use. Only a
    /// genuine problem gets an alarm colour.
    private var iconColor: Color {
        source.exists ? theme.accentColor : theme.errorColor
    }

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                // The icon carries the status, so it must not be decorative to VoiceOver.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.fileName)
                    .font(theme.fontFootnote.weight(.medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                if source.exists {
                    Text(source.location)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("File not found")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.errorColor)
                }

                if let warning {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(warning.problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(theme.warningColor)
                        Text(warning.reason)
                            .foregroundColor(theme.secondaryText)
                        Label(warning.suggestion, systemImage: "lightbulb")
                            .foregroundColor(theme.secondaryText)
                    }
                    .font(theme.fontCaption2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(source.fileName)")
        }
        .padding(10)
        .background(theme.secondaryBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
            !source.exists ? theme.errorColor.opacity(0.3)
                : warning != nil ? theme.warningColor.opacity(0.4) : theme.dividerColor,
            lineWidth: 1
        ))
        // Announce the state in words. Without this the missing-file case reaches VoiceOver as a
        // filename and a stray "File not found" label with nothing tying them together.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(source.exists
            ? Text("Reference document \(source.fileName)\(warning.map { ". \($0.problem)" } ?? "")")
            : Text("Reference document \(source.fileName), file not found"))
    }
}

/// The knowledge-source rows of an agent or bot editor, each warned when the profile will send only part of it.
/// Warnings come from `DeliveryWarnings.outcomes`, the backend's own read and plan, so a row says what the next
/// send does. Recomputed when the sources or the profile's file strategy / tools / type change.
struct KnowledgeSourceList: View {
    @Binding var sources: [KnowledgeSource]
    let profile: BackendProfileModel
    let theme: any Theme

    @State private var warnings: [String: DeliveryWarning] = [:]

    /// Knowledge is injected unless the strategy is stateless — which then ALWAYS sends a path
    /// manifest (with or without read_file), unlike attachments.
    private var injects: Bool { profile.resolvedFileContextStrategy != .stateless }

    private var recomputeKey: String {
        "\(sources.map(\.location).joined(separator: "|"))#\(injects)#\(profile.profileType.rawValue)"
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(sources) { source in
                KnowledgeSourceRow(source: source, theme: theme, warning: warnings[source.location]) {
                    sources.removeAll { $0.id == source.id }
                }
            }
        }
        .task(id: recomputeKey) {
            guard injects else { warnings = [:]; return }
            let candidates = sources.filter(\.exists).map {
                DeliveryWarnings.Candidate(name: $0.fileName, path: $0.location, url: $0.url)
            }
            let outcomes = await DeliveryWarnings.outcomes(for: candidates, lane: .knowledge, reader: FileProcessorService())
            guard !Task.isCancelled else { return }
            let list = DeliveryWarnings.warnings(for: outcomes, lane: .knowledge,
                                                 remedy: .forProfileType(profile.profileType))
            warnings = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
}
