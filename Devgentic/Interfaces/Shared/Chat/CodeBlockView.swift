// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeBlockView.swift
//  Devgentic
//
//  Created by Raj Singh on 22/07/25.
//
//  REFACTORED: To use centralized UITheme for consistent styling.
//  REFACTORED: Phase 3 - "IDE" Window Aesthetic.
//  UPDATED: Removed decorative traffic light buttons for a cleaner look.
//  THEME: Migrated to centralized AppTheme via @Environment(\.appTheme).

import SwiftUI
import Highlightr

private let logger = DGLogger(category: "CodeBlockView")

struct CodeBlockView: View {
    let language: String
    let content: String
    /// Source file this block came from, via the `--- Start of file: X ---` marker.
    ///
    /// Parsed all along and shown only on the >50-line CARD, so a short block from an
    /// attached file looked like anonymous code — the one thing you need to know before
    /// copying it back over the original.
    var fileName: String? = nil
    /// Code point size, passed down from `chatFontSize` so code scales with prose.
    var fontSize: CGFloat = ChatUIConstants.defaultCodeFontSize
    /// The message this block was rendered from, when the host knows it.
    ///
    /// Paired with `resolveOriginBlockIndex` it gives the "Viewer" button below the same
    /// origin identity the CARD path passes (`openMessageInCodeViewer`), so `openTab`'s
    /// origin-keyed branch can refresh the block's existing tab. Without it dedup fell
    /// through to exact-code equality — and this button is live on a STREAMING block, so
    /// opening one mid-stream and again once it finished left a second tab holding the
    /// truncated fragment. A block can also cross the 50-line card threshold while it
    /// streams, which is how one block gets opened from both paths.
    var originMessageID: UUID? = nil
    /// This block's ordinal among the message's code blocks, resolved ON TAP.
    ///
    /// A closure rather than a stored `Int` because deriving the ordinal costs a re-parse
    /// of the whole message, and this view re-renders on every streamed flush: the cost
    /// must be paid once per click, never in `body`. Returning nil (block not found) falls
    /// back to content-equality dedup, i.e. today's behaviour.
    var resolveOriginBlockIndex: (() -> Int?)? = nil
    /// [mc-17] The highlight lives HERE, not in the view that renders it.
    ///
    /// It used to be `@State` on `AsyncHighlightedCodeView`, which `body` instantiated in BOTH
    /// arms of the `exceedsHeightCap` if/else. The two arms are distinct structural positions,
    /// so crossing the height cap mid-stream destroyed that state and the block dropped back to
    /// `updateNSView`'s uncoloured `labelColor` placeholder for a full highlight round-trip
    /// (`SyntaxHighlightService` has no result cache). At 12 pt the cap falls at 22 lines —
    /// well inside the 50-line window where this view is used at all — so an ordinary streamed
    /// answer flickered from coloured to plain and back exactly once, mid-answer.
    ///
    /// `CodeBlockView` itself keeps its identity across that flip, so the highlight survives it.
    @State private var highlightedCode: NSAttributedString?
    @State private var isCopied = false
    @State private var isHovering = false
    @State private var isOpenHovering = false
    @Environment(\.appTheme) private var theme
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel: ChatHistoryViewModel?

    /// Content with trailing newlines stripped for DISPLAY — LLM fences usually end
    /// with "\n", which rendered as a phantom empty line inflating the block.
    /// Copy still delivers the original `content` verbatim.
    private var displayContent: String { Self.displayContent(of: content) }

    /// [mc-12] `nonisolated static` so the header badge's count can be composed exactly the way
    /// `body` composes it, in a test, without presenting the view.
    ///
    /// ⚠️ `last.isNewline`, NOT `hasSuffix("\n") || hasSuffix("\r")`. Swift's `"\r\n"` is ONE
    /// grapheme cluster, so BOTH of those suffix tests are false for a block ending in CRLF and
    /// the loop stopped immediately: a one-line block written with Windows line endings kept the
    /// phantom trailing line this function exists to remove, rendered a blank line under its
    /// code, and reported "3 lines" in the header (`components(separatedBy: .newlines)` splits
    /// CRLF at both characters). Found while pinning the counters; the defect predates [mc-12].
    /// `isNewline` is true for the CRLF cluster and for every separator `CharacterSet.newlines`
    /// splits on, so the trim and the count now agree on what a line ending is.
    nonisolated static func displayContent(of content: String) -> String {
        var trimmed = content
        while let last = trimmed.last, last.isNewline {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// ⚠️ [mc-12] `components(separatedBy: .newlines)`, matching `CodeSnippet.lineCount`
    /// EXACTLY. The two decide different things about the same block — this one the scroll
    /// cap and the header's "N lines", that one the card/inline boundary and
    /// `openMessageInCodeViewer`'s `largeSnippets` filter — and `CodeSnippet.isLarge`'s doc
    /// records what happens when they disagree: a block renders a card the viewer's filter
    /// then excludes, so the user's click cannot reach the snippet they clicked. A faster
    /// count is not equivalent: for "a\r\nb\r\nc" this yields 5 (CharacterSet splitting
    /// treats CRLF as two separators) where counting newline characters yields 3. Change
    /// BOTH or neither.
    ///
    /// ⚠️ Known, PRE-EXISTING divergence (found while pinning this, not introduced by it): the
    /// two normalise differently at the LEADING edge. `CodeSnippet.normalizedCode` trims
    /// whitespace at both ends; `displayContent(of:)` strips trailing newlines only, because it
    /// feeds the RENDERER and dropping a block's leading blank lines would change what is drawn.
    /// So a block that opens with blank lines reports more lines in this header than
    /// `CodeSnippet` counts. It is cosmetic: the card/inline boundary
    /// (`ContentBlockView`) and the viewer's `largeSnippets` filter BOTH use `CodeSnippet`, so
    /// they cannot disagree with each other, which is the failure `CodeSnippet.isLarge`'s doc
    /// warns about. Only the "N lines" badge and the scroll-cap estimate see the larger number,
    /// and the estimate erring HIGH means a scrollbar slightly early, never clipped content.
    nonisolated static func lineCount(of display: String) -> Int {
        display.isEmpty ? 0 : display.components(separatedBy: .newlines).count
    }

    /// Whether this block is tall enough to be worth scrolling instead of rendering whole.
    ///
    /// Estimated from the font's own line height rather than measured, because the answer
    /// is needed to CHOOSE the layout — measuring first would mean laying out twice.
    /// Wrapped lines aren't counted, so the estimate errs LOW: a block that wraps past the
    /// cap renders at full height (today's behaviour) rather than gaining a scrollbar it
    /// shouldn't have. Erring the other way would clip content.
    /// [mc-12] Takes the count rather than recomputing it: `body` needs the same number for
    /// the header badge and this decision, and it used to walk the whole (unbounded) block
    /// once for each — on every streaming flush.
    @MainActor
    private func exceedsHeightCap(lines: Int) -> Bool {
        let lineHeight = HighlightedCodeViewRepresentable.monoFont(size: fontSize).boundingRectForFont.height
        let estimated = CGFloat(lines) * lineHeight + 24  // + vertical padding
        return estimated > ChatUIConstants.codeBlockMaxHeight
    }

    var body: some View {
        // [mc-12] Both derived once per pass, then handed to every consumer below.
        let display = displayContent
        let lines = Self.lineCount(of: display)

        VStack(spacing: 0) {
            // MARK: - IDE Window Header
            HStack(spacing: 8) {
                // Language Badge (Aligned Left)
                Text(language.isEmpty ? "PLAINTEXT" : language.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.codeBlockHeaderText.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(theme.codeBlockHeaderText.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(theme.codeBlockHeaderText.opacity(0.14), lineWidth: 0.5)
                    )

                if let fileName, !fileName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 10))
                        Text(fileName)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.codeBlockHeaderText.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("From file \(fileName)")
                }

                if lines > 1 {
                    HStack(spacing: 4) {
                        if fileName != nil {
                            Text("•")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(theme.codeBlockHeaderSecondaryText.opacity(0.6))
                        }
                        Text("\(lines) lines")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.codeBlockHeaderSecondaryText)
                    }
                }

                Spacer()

                // Action Cluster: Open in Viewer + Copy Button
                HStack(spacing: 6) {
                    if let viewModel = chatHistoryViewModel {
                        Button {
                            let snippet = CodeSnippet(codeBlock: language, content: content)
                            // Origin is all-or-nothing: an id without an ordinal (or the
                            // reverse) never matches `openTab`'s origin branch, so pass
                            // neither and let content equality decide, as it did before.
                            let blockIndex = resolveOriginBlockIndex?()
                            if blockIndex == nil, originMessageID != nil {
                                logger.debug("[CodeViewer] Inline Viewer open could not place this block within its message — opening without an origin, so a later reopen of the same block may add a tab instead of refreshing one.")
                            }
                            viewModel.openTab(
                                for: snippet,
                                fileName: fileName,
                                originMessageID: blockIndex == nil ? nil : originMessageID,
                                originBlockIndex: originMessageID == nil ? nil : blockIndex
                            )
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Viewer")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            .foregroundColor(isOpenHovering ? theme.primaryText : theme.codeBlockHeaderText.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(theme.codeBlockHeaderText.opacity(isOpenHovering ? 0.14 : 0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(theme.codeBlockHeaderText.opacity(isOpenHovering ? 0.25 : 0.12), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in withAnimation(.easeInOut(duration: 0.15)) { isOpenHovering = hovering } }
                        .help("Open snippet in Code Viewer")
                    }

                    // Copy Button
                    Button(action: copyToClipboard) {
                        HStack(spacing: 4) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                            Text(isCopied ? "Copied" : "Copy")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundColor(isCopied ? theme.successColor : (isHovering ? theme.primaryText : theme.codeBlockHeaderText.opacity(0.85)))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isCopied ? theme.successColor.opacity(0.12) : theme.codeBlockHeaderText.opacity(isHovering ? 0.14 : 0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(isCopied ? theme.successColor.opacity(0.3) : theme.codeBlockHeaderText.opacity(isHovering ? 0.25 : 0.12), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCopied ? "Copied" : "Copy code")
                    .onHover { hovering in withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering } }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.codeBlockHeaderBackground)

            Rectangle()
                .fill(theme.dividerColor.opacity(0.4))
                .frame(height: 0.5)

            // MARK: - Editor Content
            if exceedsHeightCap(lines: lines) {
                ScrollView(.vertical) {
                    HighlightedCodeViewRepresentable(attributedString: highlightedCode, code: display, fontSize: fontSize)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(height: ChatUIConstants.codeBlockMaxHeight)
                .background(theme.codeBlockEditorBackground)
            } else {
                HighlightedCodeViewRepresentable(attributedString: highlightedCode, code: display, fontSize: fontSize)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(theme.codeBlockEditorBackground)
            }
        }
        // [mc-17] One highlight for the block, keyed on what it depends on — outside the
        // if/else, so crossing the height cap re-uses it instead of restarting it.
        .task(id: HighlightKey(code: display, themeName: theme.codeHighlightThemeName, fontSize: fontSize)) {
            let result = await SyntaxHighlightService.shared.highlight(
                display,
                language: language,
                themeName: theme.codeHighlightThemeName
            )
            // A streaming block supersedes this highlight on every flush. `.task(id:)`
            // cancels us then — drop the stale result instead of writing it back
            // (the previous code awaited a `Task.detached`, which ignores
            // cancellation entirely and let superseded work pile up).
            guard !Task.isCancelled else { return }
            highlightedCode = result.map { Self.applyingBaseFont($0, size: fontSize) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.45), lineWidth: 0.5)
        )
        .shadow(color: theme.shadowColor.opacity(0.22), radius: 5, x: 0, y: 2)
    }

    /// Re-highlight trigger. Holds the code by reference (Swift strings are COW) rather
    /// than the old `"\(isLight)\u{0}\(code)"` key, which allocated a full copy of the
    /// code on EVERY body pass just to compare it.
    ///
    /// Keyed on the THEME NAME, not a light/dark flag: switching Dracula → One Dark keeps
    /// `colorScheme == .dark`, so a boolean key left the old palette on screen.
    private struct HighlightKey: Equatable {
        let code: String
        let themeName: String
        let fontSize: CGFloat
    }

    /// Applies the base mono font over Highlightr's colors.
    @MainActor
    private static func applyingBaseFont(_ highlighted: NSAttributedString, size: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: highlighted)
        result.addAttribute(.font, value: HighlightedCodeViewRepresentable.monoFont(size: size), range: NSRange(location: 0, length: result.length))
        return result
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)

        withAnimation {
            isCopied = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { isCopied = false }
        }
    }
}

// MARK: - SizingTextView
/// A custom NSTextView that automatically adjusts its height to fit its content.
class SizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager = layoutManager, let textContainer = textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: usedRect.height)
    }
}

// MARK: - HighlightedCodeViewRepresentable
struct HighlightedCodeViewRepresentable: NSViewRepresentable {
    let attributedString: NSAttributedString?
    let code: String // Keep raw code for placeholder
    /// Size for the pre-highlight placeholder, so it doesn't reflow when the highlighted
    /// text lands at a different size.
    var fontSize: CGFloat = ChatUIConstants.defaultCodeFontSize

    func makeNSView(context: Context) -> NSTextView {
        let textView = SizingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        // An NSTextView is greedy: it accepts whatever height SwiftUI proposes. The
        // newest chat row proposes ~a full viewport (its reserved streaming space),
        // which this view used to absorb — a 3-line block rendered ~1000pt tall.
        // Required hugging + sizeThatFits below pin it to its content height.
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        return textView
    }

    /// Authoritative SwiftUI sizing: measure the laid-out text at the proposed width
    /// and claim exactly that height — never the (possibly viewport-sized) proposal.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layoutManager = nsView.layoutManager else {
            return nil
        }
        // For a nil/∞ width proposal (ideal-size query), measure unwrapped.
        let targetWidth: CGFloat = {
            if let width = proposal.width, width.isFinite, width > 0 { return width }
            return 100_000
        }()
        container.containerSize = NSSize(width: targetWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let width = (proposal.width?.isFinite == true) ? proposal.width! : ceil(used.width)
        return CGSize(width: width, height: ceil(used.height))
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        let textToSet: NSAttributedString
        if let attributedString = attributedString {
            // If highlighted text is available, use it.
            textToSet = attributedString
        } else {
            // Otherwise, show a plain text placeholder while loading.
            // labelColor adapts to light/dark (the old hardcoded 0.8-grey was
            // near-invisible on light backgrounds).
            // NB `[NSAttributedString.Key: Any]` — when `monoFont` became `monoFont(size:)`
            // this silently kept compiling as a FUNCTION REFERENCE boxed into `Any`, and
            // AppKit then sent `_isDefaultFace` to a __SwiftValue at render time. `Any`
            // means the compiler can't help here; the hosting tests caught it.
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.monoFont(size: fontSize),
                .foregroundColor: NSColor.labelColor
            ]
            textToSet = NSAttributedString(string: code, attributes: attributes)
        }

        if nsView.textStorage != textToSet {
             nsView.textStorage?.setAttributedString(textToSet)
             nsView.invalidateIntrinsicContentSize()
        }
    }

    /// The monospaced font used for code rendering.
    ///
    /// Cached per size rather than as one `static let`: deriving a monospaced NSFont from a
    /// descriptor isn't free and this runs on every highlight, but the size now varies with
    /// `chatFontSize` so a single instance can't serve it. There are only ever a handful of
    /// distinct sizes, so the cache never grows.
    ///
    /// MainActor-isolated rather than lock-guarded: every caller is on the main actor.
    /// [mc-17] Lives here rather than on the deleted `AsyncHighlightedCodeView` — this is the
    /// view that actually draws the text, and the placeholder branch below is its closest
    /// caller.
    @MainActor
    static func monoFont(size: CGFloat) -> NSFont {
        if let cached = fontCache[size] { return cached }
        let font: NSFont = {
            if let descriptor = NSFont.systemFont(ofSize: size, weight: .regular).fontDescriptor.withDesign(.monospaced),
               let font = NSFont(descriptor: descriptor, size: size) {
                return font
            }
            // Fallback: use Menlo or system font if monospaced design unavailable
            return NSFont(name: "Menlo", size: size) ?? NSFont.systemFont(ofSize: size)
        }()
        fontCache[size] = font
        return font
    }

    @MainActor private static var fontCache: [CGFloat: NSFont] = [:]
}
