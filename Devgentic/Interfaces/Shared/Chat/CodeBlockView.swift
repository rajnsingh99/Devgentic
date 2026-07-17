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
    @State private var isCopied = false
    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    /// Content with trailing newlines stripped for DISPLAY — LLM fences usually end
    /// with "\n", which rendered as a phantom empty line inflating the block.
    /// Copy still delivers the original `content` verbatim.
    private var displayContent: String {
        var trimmed = content
        while trimmed.hasSuffix("\n") || trimmed.hasSuffix("\r") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private var lineCount: Int {
        displayContent.isEmpty ? 0 : displayContent.components(separatedBy: .newlines).count
    }

    /// Whether this block is tall enough to be worth scrolling instead of rendering whole.
    ///
    /// Estimated from the font's own line height rather than measured, because the answer
    /// is needed to CHOOSE the layout — measuring first would mean laying out twice.
    /// Wrapped lines aren't counted, so the estimate errs LOW: a block that wraps past the
    /// cap renders at full height (today's behaviour) rather than gaining a scrollbar it
    /// shouldn't have. Erring the other way would clip content.
    @MainActor
    private var exceedsHeightCap: Bool {
        let lineHeight = AsyncHighlightedCodeView.monoFont(size: fontSize).boundingRectForFont.height
        let estimated = CGFloat(lineCount) * lineHeight + 24  // + vertical padding
        return estimated > ChatUIConstants.codeBlockMaxHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Mac Window Header
            HStack {
                // Language Badge (Aligned Left)
                Text(language.isEmpty ? "plaintext" : language.lowercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)) // Fixed size: monospaced
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(theme.surfaceOverlay)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.leading, 4)

                if let fileName, !fileName.isEmpty {
                    Label(fileName, systemImage: "doc.text")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel("From file \(fileName)")
                }

                if lineCount > 1 {
                    Text("\(lineCount) lines")
                        .font(.system(size: 10, weight: .medium)) // Fixed size: header metadata
                        .foregroundColor(theme.tertiaryText)
                }

                Spacer()

                // Copy Button
                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(.caption2))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(.caption2, weight: .medium))
                    }
                    .foregroundColor(isCopied ? theme.successColor : theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isHovering ? theme.surfaceOverlay : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCopied ? "Copied" : "Copy code")
                .onHover { hovering in withAnimation { isHovering = hovering } }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.codeBlockHeaderBackground)

            Divider()
                .background(theme.surfaceOverlayStrong)

            // MARK: - Editor Content
            // Use the new async wrapper view, which handles highlighting in the background.
            //
            // The ScrollView is introduced ONLY for a block that genuinely exceeds the cap.
            // Wrapping unconditionally regressed `testCodeBlockHugsContentDespiteTallProposal`:
            // a ScrollView accepts the full proposed height, so a 3-line block inside the
            // viewport-tall newest chat row became 420pt of mostly empty space — the exact
            // greedy-height bug that test exists to prevent. Short blocks therefore keep the
            // original, unwrapped path byte for byte.
            if exceedsHeightCap {
                ScrollView(.vertical) {
                    AsyncHighlightedCodeView(language: language, code: displayContent, fontSize: fontSize)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(height: ChatUIConstants.codeBlockMaxHeight)
                .background(theme.codeBlockEditorBackground)
            } else {
                AsyncHighlightedCodeView(language: language, code: displayContent, fontSize: fontSize)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(theme.codeBlockEditorBackground)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusPanel))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusPanel)
                .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
        )
        .shadow(color: theme.shadowColor, radius: 6, x: 0, y: 3)
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

// MARK: - AsyncHighlightedCodeView
/// This new View wraps the NSViewRepresentable and handles the asynchronous highlighting.
/// It uses .task to initiate the background operation whenever the code content changes.
struct AsyncHighlightedCodeView: View {
    let language: String
    let code: String
    /// Point size for the mono font. Comes from `chatFontSize` so code scales with the
    /// rest of the conversation; it used to be baked into a `static let` at 12pt, which
    /// meant a reader at 20pt prose got 12pt code and no way to change it.
    var fontSize: CGFloat = ChatUIConstants.defaultCodeFontSize

    @State private var highlightedCode: NSAttributedString?
    @Environment(\.appTheme) private var theme

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

    var body: some View {
        // The representable just displays the result of the async operation.
        HighlightedCodeViewRepresentable(attributedString: highlightedCode, code: code, fontSize: fontSize)
            .task(id: HighlightKey(code: code, themeName: theme.codeHighlightThemeName, fontSize: fontSize)) {
                let result = await SyntaxHighlightService.shared.highlight(
                    code,
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
    }

    /// Applies the base mono font over Highlightr's colors.
    @MainActor
    private static func applyingBaseFont(_ highlighted: NSAttributedString, size: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: highlighted)
        result.addAttribute(.font, value: monoFont(size: size), range: NSRange(location: 0, length: result.length))
        return result
    }

    /// The monospaced font used for code rendering.
    ///
    /// Cached per size rather than as one `static let`: deriving a monospaced NSFont from a
    /// descriptor isn't free and this runs on every highlight, but the size now varies with
    /// `chatFontSize` so a single instance can't serve it. There are only ever a handful of
    /// distinct sizes, so the cache never grows.
    ///
    /// MainActor-isolated rather than lock-guarded: the only caller is the `.task` closure
    /// in `body`, which is already on the main actor.
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
                .font: AsyncHighlightedCodeView.monoFont(size: fontSize),
                .foregroundColor: NSColor.labelColor
            ]
            textToSet = NSAttributedString(string: code, attributes: attributes)
        }

        if nsView.textStorage != textToSet {
             nsView.textStorage?.setAttributedString(textToSet)
             nsView.invalidateIntrinsicContentSize()
        }
    }
}
