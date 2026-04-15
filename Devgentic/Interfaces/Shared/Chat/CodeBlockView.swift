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
    @State private var isCopied = false
    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

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
                    .background(isHovering ? Color.white.opacity(0.1) : Color.clear)
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
            AsyncHighlightedCodeView(language: language, code: content)
                .padding(12)
                .background(theme.codeBlockEditorBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
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

    @State private var highlightedCode: NSAttributedString?

    var body: some View {
        // The representable just displays the result of the async operation.
        HighlightedCodeViewRepresentable(attributedString: highlightedCode, code: code)
            .task(id: code) {
                // When the code changes, start highlighting in the background.
                // The result is automatically posted to the @State property on the main thread.
                highlightedCode = await highlightCodeAsync(language: language, code: code)
            }
    }

    /// The monospaced font used for code rendering, computed once and cached.
    static let monoFont: NSFont = {
        if let descriptor = NSFont.systemFont(ofSize: 12, weight: .regular).fontDescriptor.withDesign(.monospaced),
           let font = NSFont(descriptor: descriptor, size: 12) {
            return font
        }
        // Fallback: use Menlo or system font if monospaced design unavailable
        return NSFont(name: "Menlo", size: 12) ?? NSFont.systemFont(ofSize: 12)
    }()

    /// Performs syntax highlighting on a background thread.
    private func highlightCodeAsync(language: String, code: String) async -> NSAttributedString {
        let baseFont = Self.monoFont
        // Use Task.detached to ensure this doesn't run on a main-actor-bound context.
        return await Task.detached {
            // Highlightr() can return nil if resources are missing — fall back to plain text.
            let attributedCode: NSAttributedString
            if let highlightr = Highlightr() {
                highlightr.setTheme(to: "atom-one-dark") // Enforce dark theme for IDE look
                attributedCode = highlightr.highlight(code, as: language, fastRender: true) ?? NSAttributedString(string: code)
            } else {
                attributedCode = NSAttributedString(string: code)
            }

            // Apply the base font to the entire string, preserving the colors from Highlightr.
            let finalAttributedString = NSMutableAttributedString(attributedString: attributedCode)
            let fullRange = NSRange(location: 0, length: finalAttributedString.length)
            finalAttributedString.addAttribute(.font, value: baseFont, range: fullRange)

            return finalAttributedString
        }.value
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

    func makeNSView(context: Context) -> NSTextView {
        let textView = SizingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        let textToSet: NSAttributedString
        if let attributedString = attributedString {
            // If highlighted text is available, use it.
            textToSet = attributedString
        } else {
            // Otherwise, show a plain text placeholder while loading.
            let attributes: [NSAttributedString.Key: Any] = [
                .font: AsyncHighlightedCodeView.monoFont,
                .foregroundColor: NSColor(calibratedRed: 0.8, green: 0.8, blue: 0.8, alpha: 1.0) // Light grey text for dark mode
            ]
            textToSet = NSAttributedString(string: code, attributes: attributes)
        }

        if nsView.textStorage != textToSet {
             nsView.textStorage?.setAttributedString(textToSet)
             nsView.invalidateIntrinsicContentSize()
        }
    }
}
