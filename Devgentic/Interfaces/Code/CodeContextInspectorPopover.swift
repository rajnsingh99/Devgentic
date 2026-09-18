// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeContextInspectorPopover.swift
//  Devgentic
//
//  Interactive inspector popover for inspecting, copying, and navigating
//  the active project's .devgentic/context.md file injected into Code sessions.
//

import SwiftUI
import AppKit

struct CodeContextInspectorPopover: View {
    let projectURL: URL?
    let contextContent: String?

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var isCopied: Bool = false

    private var contextFileURL: URL? {
        projectURL?.appendingPathComponent(".devgentic").appendingPathComponent("context.md")
    }

    private var estimatedTokens: Int {
        guard let content = contextContent, !content.isEmpty else { return 0 }
        return max(1, content.count / 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.surfaceOverlayStrong)
                        .frame(width: 32, height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.dividerColor.opacity(0.3), lineWidth: 0.8)
                        )

                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Project Structure")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text(".devgentic/context.md")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                if let content = contextContent, !content.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(content.count) chars")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                        Text("~\(estimatedTokens) tokens")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(theme.surfaceOverlay)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .opacity(0.4)

            // Content Area
            if let content = contextContent, !content.isEmpty {
                ScrollView {
                    Text(content)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(theme.primaryText.opacity(0.9))
                        .lineSpacing(3)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.secondaryBackground.opacity(0.5))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(theme.secondaryText.opacity(0.5))

                    Text("No Project Structure File Yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Devgentic reads .devgentic/context.md in your project root to provide workspace structure, file tree, architecture, and guidelines to the code model.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.secondaryBackground.opacity(0.3))
            }

            Divider()
                .opacity(0.4)

            // Footer Actions
            HStack(spacing: 10) {
                if let fileURL = contextFileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                    Button(action: revealInFinder) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                            Text("Reveal in Finder")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

                Spacer()

                if let content = contextContent, !content.isEmpty {
                    Button(action: copyToClipboard) {
                        HStack(spacing: 6) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .semibold))
                            Text(isCopied ? "Copied" : "Copy Structure")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(isCopied ? .green : theme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.surfaceOverlay)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 380, height: 380)
        .background(theme.primaryBackground)
    }

    private func copyToClipboard() {
        guard let content = contextContent, !content.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        withAnimation(.easeInOut(duration: 0.15)) {
            isCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.2)) {
                isCopied = false
            }
        }
    }

    private func revealInFinder() {
        guard let fileURL = contextFileURL else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
