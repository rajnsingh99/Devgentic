// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UserMessageView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit

struct UserMessageView: View {
    let text: String
    var searchQuery: String = ""
    var activeHighlightIndex: Int? = nil
    private let lineLimitCollapsed = 10
    @State private var isExpanded = false
    @State private var isTruncatable = false

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isTruncatable {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isExpanded.toggle()
                        }
                    }) {
                        Image(systemName: "chevron.down")
                            .font(.system(.caption, weight: .bold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .padding(6)
                            .background(theme.surfaceOverlayStrong)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse" : "Expand")
                    .accessibilityLabel(isExpanded ? "Collapse message" : "Expand message")
                }
            }

            if !searchQuery.isEmpty {
                Text(highlightedText)
                    .font(themeManager.chatFont)
                    .lineSpacing(themeManager.chatLineSpacing)
                    .lineLimit(isExpanded ? nil : lineLimitCollapsed)
                    .background(truncationProbe)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(text)
                    .font(themeManager.chatFont)
                    .lineSpacing(themeManager.chatLineSpacing)
                    .lineLimit(isExpanded ? nil : lineLimitCollapsed)
                    .background(truncationProbe)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .clipped()
    }

    /// Invisible background that drives `determineTruncation`, re-measuring on every width change and chat-font-size change,
    /// not only on appear, so a message that reflows past `lineLimitCollapsed` still gets its expand chevron.
    private var truncationProbe: some View {
        GeometryReader { geometry in
            Color.clear
                .onChange(of: geometry.size.width, initial: true) { _, width in
                    // The first measurement runs inline; later width changes are debounced, since each measurement builds two
                    // `NSHostingView`s over the full text on the main actor and a window drag would otherwise run it constantly.
                    scheduleMeasure(width: width, immediate: lastMeasuredWidth == 0)
                }
                .onChange(of: themeManager.chatFontSize) { _, _ in
                    // Debounced: a settings-slider drag emits one font-size change per step. The font size is part of the cache key
                    // (`lastMeasuredFontSize`), so a change is a cache miss and the width sentinel is not zeroed.
                    scheduleMeasure(width: geometry.size.width, immediate: false)
                }
                .onDisappear {
                    // A row scrolled out of the LazyVStack must not keep a pending measurement alive for an off-screen view.
                    measureTask?.cancel()
                    measureTask = nil
                }
        }
    }

    /// Pending debounced re-measure, cancelled by the next width change (see `truncationProbe`).
    @State private var measureTask: Task<Void, Never>?

    private var highlightedText: AttributedString {
        var attrString = AttributedString(text)
        attrString.font = themeManager.chatFont
        // Shared O(n) forward-cursor highlighter using theme hues.
        return SearchHighlighter.highlight(
            attrString,
            query: searchQuery,
            activeMatchIndex: activeHighlightIndex,
            base: theme.searchHighlight,
            active: theme.searchHighlightActive
        )
    }
    
    /// Cached width for which truncation was last computed, to avoid recreating expensive NSHostingViews per callback.
    /// 0 means never measured; keep it non-optional so a degenerate zero-width callback is not measured.
    @State private var lastMeasuredWidth: CGFloat = 0

    /// [bm-6] The font size the cached width was measured AT. Same width with different glyph
    /// metrics is a different answer, so it belongs in the key rather than being papered over by
    /// zeroing the width at the call site.
    @State private var lastMeasuredFontSize: CGFloat = 0

    /// [bm-6] The one scheduler both triggers use. `immediate` is true only for a first
    /// measurement, where a 120 ms delay would pop the chevron in late on every scroll-back.
    private func scheduleMeasure(width: CGFloat, immediate: Bool) {
        measureTask?.cancel()
        measureTask = nil
        guard !immediate else {
            determineTruncation(availableWidth: width)
            return
        }
        measureTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            determineTruncation(availableWidth: width)
        }
    }

    /// Whether the cached truncation answer is still valid. Pure and `nonisolated` so the cache key is testable.
    /// Width has a 2pt tolerance (drags emit a callback per point); font size is exact.
    nonisolated static func shouldRemeasure(availableWidth: CGFloat, lastMeasuredWidth: CGFloat,
                                            fontSize: CGFloat, lastMeasuredFontSize: CGFloat) -> Bool {
        abs(availableWidth - lastMeasuredWidth) > 2 || fontSize != lastMeasuredFontSize
    }

    private func determineTruncation(availableWidth: CGFloat) {
        // Skip re-computation if neither the width nor the glyph metrics moved meaningfully.
        guard Self.shouldRemeasure(availableWidth: availableWidth,
                                   lastMeasuredWidth: lastMeasuredWidth,
                                   fontSize: themeManager.chatFontSize,
                                   lastMeasuredFontSize: lastMeasuredFontSize) else { return }
        lastMeasuredWidth = availableWidth
        lastMeasuredFontSize = themeManager.chatFontSize

        // Fast path: a message that cannot reach `lineLimitCollapsed` lines is never truncatable, so the hosting views are
        // skipped. "Cannot reach" is decided per hard-break segment; see `needsMeasurement`.
        guard Self.needsMeasurement(text: text, availableWidth: availableWidth,
                                    fontSize: themeManager.chatFontSize,
                                    lineLimit: lineLimitCollapsed) else {
            isTruncatable = false
            return
        }

        let fullTextView = Text(text)
            .font(themeManager.chatFont)
            .lineSpacing(themeManager.chatLineSpacing)
            .frame(width: availableWidth, alignment: .leading)

        let truncatedTextView = Text(text)
            .font(themeManager.chatFont)
            .lineSpacing(themeManager.chatLineSpacing)
            .lineLimit(lineLimitCollapsed)
            .frame(width: availableWidth, alignment: .leading)

        let fullSize = NSHostingView(rootView: fullTextView).fittingSize
        let truncatedSize = NSHostingView(rootView: truncatedTextView).fittingSize

        isTruncatable = fullSize.height > truncatedSize.height + 2
    }

    /// Whether `text` might exceed `lineLimit` lines at `availableWidth` and `fontSize`; i.e. whether measuring is needed.
    /// `false` is a definite fit, so this is an upper bound: each hard-break segment is wrapped independently and summed.
    /// Glyph advance is half the point size, floored so a tiny width cannot give zero capacity.
    nonisolated static func needsMeasurement(
        text: String, availableWidth: CGFloat, fontSize: CGFloat, lineLimit: Int
    ) -> Bool {
        let capacity = max(1, Int(availableWidth / max(4, fontSize * 0.5)))
        var lines = 0
        // `Character.isNewline` treats "\r\n" as ONE break, matching how Text lays it out.
        for segment in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lines += max(1, Int((Double(segment.count) / Double(capacity)).rounded(.up)))
            if lines > lineLimit { return true }   // early out — no need to count the rest
        }
        // Strict: exactly `lineLimit` lines fits; only the line after it is clipped.
        return lines > lineLimit
    }
}

// MARK: - Shape & Style

struct UserBubbleModifier: ViewModifier {
    @Environment(\.surfaceStyle) private var surfaceStyle
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundColor(.primary) // Auto-adapts to light/dark
            .appSurface(
                in: .rect(cornerRadius: 16),
                elevation: .card,
                solidFillOverride: theme.surfaceOverlayStrong
            )
    }
}

extension View {
    func userBubbleStyle() -> some View {
        self.modifier(UserBubbleModifier())
    }
}
