//
//  CodeBlockView.swift
//  Devgentic
//
//  Created by Raj Singh on 22/07/25.
//
//  REFACTORED: To use centralized UITheme for consistent styling.

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

            HighlightedCodeView(language: language, code: content)
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

// MARK: - SizingTextView
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

// MARK: - HighlightedCodeView
struct HighlightedCodeView: NSViewRepresentable {
    let language: String
    let code: String

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
        let highlightr = Highlightr()
        highlightr?.setTheme(to: "atom-one-dark")

        let baseFont = NSFont(descriptor: NSFont.systemFont(ofSize: 14, weight: .regular).fontDescriptor.withDesign(.monospaced)!, size: 14)!
        
        let attributedCode = highlightr?.highlight(code, as: language, fastRender: true) ?? NSAttributedString(string: code)
        
        let finalAttributedString = NSMutableAttributedString(attributedString: attributedCode)
        let fullRange = NSRange(location: 0, length: finalAttributedString.length)
        finalAttributedString.addAttribute(.font, value: baseFont, range: fullRange)

        nsView.textStorage?.setAttributedString(finalAttributedString)
        nsView.invalidateIntrinsicContentSize()
    }
}
