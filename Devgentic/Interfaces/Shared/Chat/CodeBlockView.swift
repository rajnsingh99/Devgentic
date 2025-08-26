//
//  CodeBlockView.swift
//  Devgentic
//
//  Created by Raj Singh on 22/07/25.
//
//  REFACTORED: To use centralized UITheme for consistent styling.
//  REFACTORED: To perform syntax highlighting asynchronously to avoid blocking the main thread.

import SwiftUI
import Highlightr

struct CodeBlockView: View {
    let language: String
    let content: String
    @State private var isCopied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(UITheme.Fonts.codeCaption)
                    .foregroundColor(UITheme.Colors.secondaryText)
                    .padding(.leading, UITheme.Spacing.medium)
                
                Spacer()
                
                Button(action: copyToClipboard) {
                    HStack(spacing: UITheme.Spacing.xsmall) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "Copied" : "Copy")
                    }
                    .font(UITheme.Fonts.caption)
                }
                .buttonStyle(.borderless)
                .foregroundColor(isCopied ? UITheme.Colors.success : UITheme.Colors.secondaryText)
                .padding(.trailing, UITheme.Spacing.medium)
            }
            .padding(.vertical, UITheme.Spacing.small)
            .background(UITheme.Colors.textBackground.opacity(0.5))

            // Use the new async wrapper view, which handles highlighting in the background.
            AsyncHighlightedCodeView(language: language, code: content)
                .padding(UITheme.Spacing.medium)
        }
        .background(UITheme.Colors.textBackground)
        .cornerRadius(UITheme.CornerRadius.medium)
        .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        
        withAnimation {
            isCopied = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                isCopied = false
            }
        }
    }
}

// MARK: - AsyncHighlightedCodeView (NEW)
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
    
    /// Performs syntax highlighting on a background thread.
    private func highlightCodeAsync(language: String, code: String) async -> NSAttributedString {
        // Use Task.detached to ensure this doesn't run on a main-actor-bound context.
        return await Task.detached {
            // It's safe to create a new Highlightr instance here.
            let highlightr = Highlightr()!
            highlightr.setTheme(to: "atom-one-dark")

            // Define the base font for the code.
            let baseFont = NSFont(descriptor: NSFont.systemFont(ofSize: 12, weight: .regular).fontDescriptor.withDesign(.monospaced)!, size: 12)!
            
            // Perform the potentially slow highlighting operation.
            let attributedCode = highlightr.highlight(code, as: language, fastRender: true) ?? NSAttributedString(string: code)
            
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

// MARK: - HighlightedCodeViewRepresentable (REFACTORED)
/// Renamed from HighlightedCodeView. This NSViewRepresentable is now a "dumb" component.
/// It displays an NSAttributedString if one is provided, otherwise it shows the raw code
/// string as a placeholder.
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
            let baseFont = NSFont(descriptor: NSFont.systemFont(ofSize: 14, weight: .regular).fontDescriptor.withDesign(.monospaced)!, size: 14)!
            let attributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            textToSet = NSAttributedString(string: code, attributes: attributes)
        }
        
        // This check prevents resetting the text if it's already correct,
        // which avoids flickering and performance issues.
        if nsView.textStorage != textToSet {
             nsView.textStorage?.setAttributedString(textToSet)
             nsView.invalidateIntrinsicContentSize()
        }
    }
}
