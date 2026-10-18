// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BundledDocumentView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = DGLogger(category: "BundledDocument")

/// A document that ships inside the app bundle: the privacy policy, the licence or the third-party notices. The
/// files are copied from the repo root by a build phase, so the copy the user reads is the published file.
enum BundledDocument: String, CaseIterable, Identifiable, Codable, Hashable {
    case privacyPolicy = "PRIVACY"
    case license = "LICENSE"
    case thirdPartyNotices = "THIRD_PARTY_NOTICES"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacyPolicy: return String(localized: "Privacy Policy")
        case .license: return String(localized: "License")
        case .thirdPartyNotices: return String(localized: "Third-Party Notices")
        }
    }

    /// `LICENSE` is the plain-text AGPL. Rendering it as Markdown would turn its numbered
    /// sections into lists and reflow its hand-aligned headings.
    var isMarkdown: Bool { self != .license }

    /// The window group every bundled document opens in, one window per document.
    static let windowGroupID = "bundled-document-window"

    var url: URL? {
        Bundle.main.url(forResource: rawValue, withExtension: isMarkdown ? "md" : nil)
    }

    /// The document's text, or nil if it is missing from the bundle (a broken build phase).
    func load() -> String? {
        guard let url else {
            logger.error("[DOCS] \(self.rawValue) is not in the app bundle. CONSEQUENCE: its window shows a 'missing' message — check the 'Copy licence notices into the bundle' build phase.")
            return nil
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.error("[DOCS] Could not read \(self.rawValue): \(error.localizedDescription). CONSEQUENCE: its window shows a 'missing' message.")
            return nil
        }
    }

    /// Plain text split at blank lines, so a `LazyVStack` can build it a paragraph at a time.
    static func paragraphs(of text: String) -> [String] {
        text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct BundledDocumentView: View {
    let document: BundledDocument
    /// Shown as a Done button when the view is presented in a sheet.
    var onDone: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme

    private enum Content {
        case markdown([ContentBlock])
        case plain([String])
    }
    @State private var content: Content?
    @State private var didLoad = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    switch content {
                    case .markdown(let blocks):
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(blocks) { block in
                                markdownBlock(block)
                            }
                        }
                    case .plain(let paragraphs):
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(verbatim: paragraph)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(theme.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    case nil:
                        if didLoad {
                            Label("This document is missing from the app. Please reinstall Devgentic.",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundColor(theme.secondaryText)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity)
            }

            if let onDone {
                Divider()
                HStack {
                    Spacer()
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .background(theme.primaryBackground)
        .navigationTitle(document.title)
        .task {
            guard !didLoad else { return }
            if let text = document.load() {
                content = document.isMarkdown ? .markdown(parseMarkdown(text)) : .plain(BundledDocument.paragraphs(of: text))
            }
            didLoad = true
        }
    }

    @ViewBuilder
    private func markdownBlock(_ block: ContentBlock) -> some View {
        if case .code(_, let code, _) = block.type {
            Text(verbatim: code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.secondaryBackground.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 12)
        } else {
            WorkflowMarkdownView(blocks: [block])
        }
    }
}
