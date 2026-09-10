// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  KnowledgeSourceRow.swift
//  Devgentic
//
//  Created on 07/08/26.
//
//  One attached reference document, as shown in the agent and bot editors.
//
//  ⚠️ Register A65. The icon was `source.exists ? warningColor : errorColor` — so a file that is
//  perfectly FINE was drawn in the warning colour, and "this file is healthy" (orange) sat one shade
//  away from "this file is missing" (red). Both read as alarm states, and on the icon the colour was
//  the only thing separating them.
//
//  The fix changes the SYMBOL as well as the colour, so the two states are distinguishable without
//  perceiving colour at all — which matters here beyond taste: the same panel is the subject of A61
//  (every control unlabeled to VoiceOver), and colour-only status is the same class of defect.
//
//  ⚠️ Extracted because the two editors held byte-identical copies of this row and had already
//  drifted — the bot's used a hardcoded `.orange` where the agent's used `theme.warningColor`, so
//  the two panels rendered the same state in two different oranges. Same duplication that produced
//  A60 in the importer directly above it.
//

import SwiftUI

struct KnowledgeSourceRow: View {
    let source: KnowledgeSource
    let theme: any Theme
    let onRemove: () -> Void

    /// `doc.text.fill` for a healthy document, a warning triangle for a missing one.
    ///
    /// Deliberately a SHAPE difference, not just a tint — see the file comment. Exposed (rather than
    /// inlined into `body`) so that intent is assertable: a SwiftUI body is not reachable from a
    /// test, and "the two states differ by more than colour" is exactly the property that silently
    /// regresses when someone tidies two symbols into one.
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
                    .font(theme.fontCallout)
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
            source.exists ? theme.dividerColor : theme.errorColor.opacity(0.3), lineWidth: 1
        ))
        // Announce the state in words. Without this the missing-file case reaches VoiceOver as a
        // filename and a stray "File not found" label with nothing tying them together.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(source.exists
            ? Text("Reference document \(source.fileName)")
            : Text("Reference document \(source.fileName), file not found"))
    }
}
