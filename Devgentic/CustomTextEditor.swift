// /Users/alice/Documents/Workspace/mac-projects/Devgentic/Devgentic/CustomTextEditor.swift
import SwiftUI
import AppKit

struct CustomTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void // Action to perform on Shift+Enter
    // var placeholder: String = "" // REMOVED - Will be handled by SwiftUI overlay

    // --- Define colors used for text ---
    private let textColor: NSColor = .white
    // -----------------------------------

    // Coordinator to handle delegate methods
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // Create the underlying NSTextView
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = textColor // Set text color directly
        textView.backgroundColor = NSColor.clear
        textView.insertionPointColor = textColor
        textView.string = text // Initial text

        // --- Add Internal Padding ---
        textView.textContainer?.lineFragmentPadding = 8.0

        // Allow vertical resizing
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 5) 

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false

        return scrollView
    }

    // Update the NSTextView when the SwiftUI binding changes
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        // Update if text differs
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            // Restore selection safely
            if selectedRange.location != NSNotFound && (selectedRange.location + selectedRange.length) <= (text as NSString).length {
                 textView.setSelectedRange(selectedRange)
            }
        }
    }

    // Coordinator class
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        // private var isEditing = false // REMOVED - No longer needed for placeholder

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        // --- REMOVED Placeholder Logic ---
        // func showPlaceholder...
        // func hidePlaceholder...
        // func updatePlaceholder...
        // ---------------------------------

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Update binding directly (consider if async is truly needed - usually not if delegate is on main thread)
            // DispatchQueue.main.async { // Removed async for simplicity, monitor if needed
                 self.parent.text = textView.string
            // }
        }

        // --- REMOVED textDidBeginEditing / textDidEndEditing for placeholder ---
        // func textDidBeginEditing...
        // func textDidEndEditing...
        // ---------------------------------------------------------------------

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSTextView.insertNewline(_:)) {
                if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                    parent.onCommit()
                    return true // Handled Shift+Enter
                } else {
                    // Allow normal newline insertion
                    return false
                }
            }
            return false // Not handled
        }
    }
}
