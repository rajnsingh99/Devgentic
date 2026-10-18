// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  VerbatimTextEditor.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit

/// A text field that returns exactly the characters typed, with smart quotes, dashes and text replacements disabled.
/// Needed where the value is source code, such as the approval banner's editable `write_file` content.
struct VerbatimTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 11
    var textColor: Color
    /// When true, Return is swallowed instead of inserting a newline — the single-line
    /// equivalent of a `TextField`, without the field editor's substitutions.
    var isSingleLine: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = !isSingleLine
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false            // no pasted fonts/colors, and no smart paste
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor(textColor)
        textView.textContainerInset = NSSize(width: 2, height: 3)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        // The whole reason this type exists.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // `isRichText = false` covers most of it, but these are independent switches and
        // NSTextView re-reads the system defaults on some transitions.
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        textView.string = text
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.textColor = NSColor(textColor)
        // Only when the binding changed underneath us — assigning unconditionally would
        // collapse the selection on every keystroke.
        guard textView.string != text else { return }
        let selected = textView.selectedRange()
        textView.string = text
        let clamped = min(selected.location, (text as NSString).length)
        textView.setSelectedRange(NSRange(location: clamped, length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: VerbatimTextEditor
        init(_ parent: VerbatimTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Swallow Return in single-line mode; everything else behaves normally.
            guard parent.isSingleLine else { return false }
            return selector == #selector(NSResponder.insertNewline(_:))
        }
    }
}
