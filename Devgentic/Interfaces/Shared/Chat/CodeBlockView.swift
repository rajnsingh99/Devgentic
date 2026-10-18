// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeBlockView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import Highlightr

private let logger = DGLogger(category: "CodeBlockView")

/// Renders a code block with a header (line count, copy, Viewer button), syntax highlighting and a scroll cap.
struct CodeBlockView: View {
    let language: String
    let content: String
    /// Source file this block came from, via the `--- Start of file: X ---` marker.
    var fileName: String? = nil
    /// Code point size, passed down from `chatFontSize` so code scales with prose.
    var fontSize: CGFloat = ChatUIConstants.defaultCodeFontSize
    /// The message this block was rendered from, when the host knows it.
    /// Paired with `resolveOriginBlockIndex`, it lets `openTab` refresh the block's existing tab, not open a duplicate
    /// (a streaming block can be opened mid-stream and again once finished).
    var originMessageID: UUID? = nil
    /// This block's ordinal among the message's code blocks, resolved on tap.
    /// A closure because deriving it re-parses the whole message and `body` re-renders on every streamed flush;
    /// nil (block not found) falls back to content-equality dedup.
    var resolveOriginBlockIndex: (() -> Int?)? = nil
    // Why: a child view's state resets when the block crosses the height cap mid-stream, flickering from coloured to plain.
    /// The syntax-highlighted code, held here rather than in the view that renders it.
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

    // Why: trim with `last.isNewline`: CRLF is one grapheme cluster, so `hasSuffix` tests miss it and leave a phantom line.
    /// Strips trailing newlines from a block's content for display.
    /// `nonisolated static` so the header badge's count can be composed in a test without presenting the view.
    nonisolated static func displayContent(of content: String) -> String {
        var trimmed = content
        while let last = trimmed.last, last.isNewline {
            trimmed.removeLast()
        }
        return trimmed
    }

    // Why: change both counters or neither: CRLF counts as two separators here, so a faster newline-character count disagrees.
    /// Counts lines with `components(separatedBy: .newlines)`, matching `CodeSnippet.lineCount` exactly.
    /// Display content keeps leading blank lines (only trailing newlines are stripped), so the badge may exceed it.
    nonisolated static func lineCount(of display: String) -> Int {
        display.isEmpty ? 0 : display.components(separatedBy: .newlines).count
    }

    /// Whether this block is tall enough to be worth scrolling instead of rendering whole.
    /// Estimated from the font's line height, not measured, since the answer chooses the layout.
    /// Wrapped lines are not counted, so it errs low rather than clipping. Takes the count to avoid re-walking the block.
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
                            // Origin is all-or-nothing: an id without an ordinal (or the reverse) never matches `openTab`'s origin branch,
                            // so pass neither and let content equality decide.
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
            // A streaming block supersedes this highlight on every flush; `.task(id:)` cancels us, so drop the stale result
            // instead of writing it back.
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

    /// Re-highlight trigger. Holds the code by reference (Swift strings are COW) so comparing it never copies the code.
    /// Keyed on the theme name, not a light/dark flag: switching between two dark themes keeps `colorScheme == .dark`.
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
        // An NSTextView accepts whatever height SwiftUI proposes, and the newest chat row proposes about a full viewport;
        // required hugging and `sizeThatFits` pin it to its content height.
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
            // Why: `[NSAttributedString.Key: Any]` cannot catch a function reference boxed in place of a font; AppKit crashes at render.
            // Otherwise show a plain text placeholder while loading; `labelColor` adapts to light and dark.
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

    /// The monospaced font used for code rendering, cached per size.
    /// Deriving a monospaced NSFont is not free and the size varies with `chatFontSize`; only a handful of sizes occur.
    /// MainActor-isolated rather than lock-guarded: every caller is on the main actor.
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
