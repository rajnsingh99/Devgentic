// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  UserMessageView.swift
//  Devgentic
//
//  Created by Raj Singh on 20/08/25.
//
//  Phase 4: Modern "Floating" User Bubble with Glassmorphism.

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

    /// Invisible background that drives `determineTruncation`. It re-asks the question on
    /// every width change AND on a chat-font-size change, not only on appear: the answer is
    /// a function of both, and with an `onAppear`-only trigger a message that reflowed past
    /// `lineLimitCollapsed` after the user raised the font (or narrowed the window) stayed
    /// clipped by `.lineLimit` with no chevron to expand it, because nothing ever measured
    /// it again (CF-1). `initial: true` keeps the on-appear measurement.
    private var truncationProbe: some View {
        GeometryReader { geometry in
            Color.clear
                .onChange(of: geometry.size.width, initial: true) { _, width in
                    // ⚠️ The FIRST measurement runs inline; every later width change is debounced.
                    // `determineTruncation` builds two `NSHostingView`s over the full message text
                    // on the main actor, and the ±2pt guard admits roughly one pair per 2pt of
                    // travel — so a window or split-view drag (the chat column tracks the window
                    // whenever it is narrower than the bubble's 600pt cap) would run that pair
                    // ~100 times per 200pt of drag, per visible long message. `onAppear` ran it
                    // once, so making the trigger correct also made it far more frequent; this
                    // keeps the correctness and pays for one measurement per settled width.
                    scheduleMeasure(width: width, immediate: lastMeasuredWidth == 0)
                }
                .onChange(of: themeManager.chatFontSize) { _, _ in
                    // ⚠️ [bm-6] DEBOUNCED, and it no longer zeroes the width sentinel.
                    //
                    // The only writer of `chatFontSize` is the settings slider, which emits one
                    // change per step — so a 12→22 drag fired ~10 SYNCHRONOUS measurement bursts,
                    // two NSHostingViews over the full message text each, for every long message
                    // in the transcript. All of it invisible: the settings pane is a layer ABOVE
                    // the chat, which is held at opacity 0 while it is open (still laid out, so
                    // the work still happens; just nothing to see).
                    //
                    // ⚠️ Zeroing `lastMeasuredWidth` here was the subtler half. That sentinel
                    // means "never measured, measure inline" to the width handler above, so
                    // between a font change and its re-measure ANY width callback took the
                    // immediate branch too — one slider step could cost four hosting-view
                    // layouts per row, not two. The font size is part of the cache KEY now
                    // (`lastMeasuredFontSize`), which makes a font change a genuine cache MISS
                    // with nothing to zero.
                    scheduleMeasure(width: geometry.size.width, immediate: false)
                }
                .onDisappear {
                    // A row scrolled out of the LazyVStack must not keep a pending measurement
                    // alive; it would fire against a view that is no longer on screen.
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
        // Shared O(n) forward-cursor highlighter with theme hues (previously an
        // O(matches·n) reversed pass with its own drifted colors).
        return SearchHighlighter.highlight(
            attrString,
            query: searchQuery,
            activeMatchIndex: activeHighlightIndex,
            base: theme.searchHighlight,
            active: theme.searchHighlightActive
        )
    }
    
    /// Cached width for which truncation was last computed — avoids re-creating
    /// expensive NSHostingViews on every GeometryReader callback.
    ///
    /// ⚠️ [bm-6] 0 still means "never measured": the first geometry callback can arrive before
    /// layout resolves, and `determineTruncation(availableWidth: 0)` is then short-circuited by
    /// the ±2pt guard below, leaving this at 0 so the first REAL width is still measured
    /// immediately. Do not replace that with an optional — it would make the degenerate callback
    /// a genuine measurement at `.frame(width: 0)`, which sets a bogus truncation flag AND makes
    /// the first real width take the debounced path.
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

    /// [bm-6] Whether the cached truncation answer is still valid. Pure and `nonisolated` so the
    /// cache KEY is testable: the rest of this path is `@State` behind a private method, and the
    /// defect was entirely in what the key did — and did not — include.
    ///
    /// ±2pt on the width, because a window drag emits a callback roughly every point and the
    /// answer cannot change that fast. EXACT on the font size: one step of the settings slider
    /// changes every glyph metric, so a tolerance there would silently serve a stale answer.
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

        // Heuristic fast-path: a message that cannot reach `lineLimitCollapsed` lines is
        // never truncatable, so skip the expensive hosting views. "Cannot reach" has to be
        // decided by wrapping each hard-break-separated segment — see `needsMeasurement`.
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

    /// Whether `text` might exceed `lineLimit` lines at `availableWidth` and `fontSize` — i.e.
    /// whether the NSHostingView measurement in `determineTruncation` is worth running.
    ///
    /// `false` is a definite "fits": the caller sets `isTruncatable = false` WITHOUT measuring,
    /// and `.lineLimit` then clips anything that does not fit with no chevron to expand it. So
    /// the estimate must be an UPPER BOUND on line count, never an average.
    ///
    /// ⚠️ Two earlier versions of this rule were not. The original compared `text.count` against
    /// `lineLimit * charsPerLine` and never looked at newlines, so a 12-line 300-character paste
    /// was clipped with no expand control (CF-1). The first fix added a hard-break count beside
    /// it — still wrong, because a TOTAL character count says nothing about how many lines the
    /// text occupies once each segment wraps independently: eight 100-character lines are 807
    /// characters (inside an 850 budget) and 7 breaks (inside a 10 limit), yet lay out as ~16
    /// lines. It was also blind to `chatFontSize`, which the user can raise to 22 — so the
    /// `.onChange(of: chatFontSize)` re-measure added by the same fix short-circuited right here
    /// and changed nothing.
    ///
    /// So: wrap EACH hard-break-separated segment independently and sum, which is what the text
    /// engine does. A segment of length 0 still occupies one line. The per-glyph advance is
    /// approximated at half the point size (system font, mixed case) and floored so a tiny width
    /// cannot produce a zero capacity.
    ///
    /// `nonisolated static` and pure so the rule is unit-testable without a view host
    /// (`UserMessageTruncationTests`); the `.onChange` plumbing that calls it is not.
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
        // ⚠️ STRICT. Exactly `lineLimit` lines FITS inside a `lineLimit`-line limit; only the
        // line after it is clipped. `>=` here made every 10-line message measure needlessly and
        // broke the two pre-existing boundary tests, which is how it was caught.
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
