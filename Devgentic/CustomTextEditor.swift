// CustomTextEditor.swift

import SwiftUI
import AppKit

struct CustomTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void // Action to perform on Shift+Enter

    // Coordinator to handle delegate methods
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // Create the underlying NSTextView
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView() // Use scrollable for multi-line

        guard let textView = scrollView.documentView as? NSTextView else {
            // Fallback in case something goes wrong, though unlikely
            return scrollView
        }

        textView.delegate = context.coordinator // Set the delegate
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false // We want plain text
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize) // Match system font or customize
        textView.textColor = NSColor.white // Match your UI style
        textView.backgroundColor = NSColor.clear // Match your UI style
        textView.insertionPointColor = NSColor.white // Match your UI style
        textView.string = text // Initial text

        // Allow vertical resizing
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false // Usually false for chat inputs
        textView.autoresizingMask = [.width] // Resize width with scroll view

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        return scrollView
    }

    // Update the NSTextView when the SwiftUI binding changes
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        // Only update if the text is actually different to avoid feedback loops
        if textView.string != text {
            // Preserve cursor position if possible (simple implementation)
            let selectedRange = textView.selectedRange()
            textView.string = text
            // Check if the range is valid before setting it
            if selectedRange.location != NSNotFound && (selectedRange.location + selectedRange.length) <= (text as NSString).length {
                 textView.setSelectedRange(selectedRange)
            }
        }
    }

    // Coordinator class
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        // Update the SwiftUI binding when the text view's content changes
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Use DispatchQueue to avoid modifying state during view update cycle
            DispatchQueue.main.async {
                // Ensure parent is still valid if text changes rapidly after view disappears
                // (Though less likely in this specific setup)
                // Optional: Add weak self check if needed in complex scenarios
                self.parent.text = textView.string
            }
        }

        // Intercept key commands
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Check if the command is 'insertNewline:' (Enter key)
            if commandSelector == #selector(NSTextView.insertNewline(_:)) {
                // Check if the Shift key is pressed using the current event
                if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                    // Shift + Enter: Trigger the commit action
                    parent.onCommit()
                    return true // Command was handled, don't insert newline
                } else {
                    // Just Enter: Allow default behavior (insert newline)
                    return false // Let NSTextView handle inserting the newline
                }
            }
            // For any other command, let NSTextView handle it
            return false
        }
    }
}
