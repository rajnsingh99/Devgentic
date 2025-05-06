// /Users/alice/Documents/Workspace/mac-projects/Devgentic/Devgentic/CustomTextEditor.swift
import SwiftUI
import AppKit
import os // Import os for logging

// Logger (Optional)
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "CustomTextEditor")

struct CustomTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void // Action to perform on Shift+Enter

    // --- Constraints passed from parent ---
    let minHeight: CGFloat
    let maxHeight: CGFloat
    // --------------------------------------

    // --- State to hold the calculated dynamic height ---
    @State private var dynamicHeight: CGFloat = 0
    // -------------------------------------------------

    // --- Define colors used for text ---
    private let textColor: NSColor = .labelColor // Use semantic color
    // -----------------------------------

    // Coordinator to handle delegate methods
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // Create the underlying NSTextView
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true // Keep scroller enabled
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false // Ensure no extra background
        scrollView.contentView.drawsBackground = false
        scrollView.backgroundColor = .clear // Explicitly clear background

        // Set scroller style on the ScrollView
        scrollView.scrollerStyle = .overlay

        // *** ADDED: Explicitly set style on the vertical scroller itself ***
        if let verticalScroller = scrollView.verticalScroller {
            verticalScroller.scrollerStyle = .overlay
            logger.debug("Explicitly set verticalScroller style to .overlay")
        } else {
            logger.warning("Could not access verticalScroller to set style.")
        }
        // ******************************************************************

        guard let textView = scrollView.documentView as? NSTextView else {
            logger.error("Failed to get NSTextView from NSScrollView.")
            return scrollView
        }

        // --- Basic Setup ---
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false

        // --- Appearance ---
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = textColor
        textView.backgroundColor = .clear // Ensure TextView background is clear
        textView.insertionPointColor = textColor

        // --- Padding & Insets ---
        textView.textContainer?.lineFragmentPadding = 5.0
        textView.textContainerInset = NSSize(width: 0, height: 5)

        // --- Resizing Behavior ---
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        // --- Initial State ---
        textView.string = text
        DispatchQueue.main.async {
             context.coordinator.updateDynamicHeight(for: textView)
             if self.dynamicHeight == 0 {
                 self.dynamicHeight = context.coordinator.calculateHeight(for: textView)
             }
             logger.debug("Initial dynamicHeight set to: \(self.dynamicHeight)")
        }

        return scrollView
    }

    // Update the NSTextView when the SwiftUI binding changes
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        // Update text if it differs from the binding
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            if selectedRange.location != NSNotFound && (selectedRange.location + selectedRange.length) <= (text as NSString).length {
                 textView.setSelectedRange(selectedRange)
            }
            logger.trace("Updating NSView due to external text change. Recalculating height.")
            context.coordinator.updateDynamicHeight(for: textView)
        }

        // Update text color if needed
        if textView.textColor != textColor {
            textView.textColor = textColor
            textView.insertionPointColor = textColor
        }

        // Ensure scroller style is maintained on updates (both ScrollView and specific Scroller)
        if nsView.scrollerStyle != .overlay {
             nsView.scrollerStyle = .overlay
             logger.warning("ScrollView scroller style was reset, reapplying .overlay")
        }
        if let verticalScroller = nsView.verticalScroller, verticalScroller.scrollerStyle != .overlay {
            verticalScroller.scrollerStyle = .overlay
            logger.warning("VerticalScroller style was reset, reapplying .overlay")
        }
    }

    // --- Communicate Ideal Size Back to SwiftUI ---
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let targetHeight = max(minHeight, min(dynamicHeight, maxHeight))
        let width = proposal.width ?? nsView.intrinsicContentSize.width

        guard targetHeight > 0 else {
             logger.warning("sizeThatFits returning nil as targetHeight is zero.")
             return nil
        }
        return CGSize(width: width, height: targetHeight)
    }

    // Coordinator class
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        // Calculate Required Height
        func calculateHeight(for textView: NSTextView) -> CGFloat {
             guard let layoutManager = textView.layoutManager,
                   let textContainer = textView.textContainer else {
                 logger.error("Cannot calculate height: Missing layoutManager or textContainer.")
                 return parent.minHeight
             }
             let usedRect = layoutManager.usedRect(for: textContainer)
             let totalInsetHeight = textView.textContainerInset.height * 2
             let calculatedHeight = ceil(usedRect.height + totalInsetHeight)
             return max(parent.minHeight, min(calculatedHeight, parent.maxHeight))
         }

        // Update State Variable
        func updateDynamicHeight(for textView: NSTextView) {
            let newHeight = calculateHeight(for: textView)
            if abs(newHeight - parent.dynamicHeight) > 1 {
                DispatchQueue.main.async {
                    self.parent.dynamicHeight = newHeight
                    logger.debug("Dynamic height updated to: \(newHeight)")
                }
            }
        }

        // Delegate Methods
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.parent.text = textView.string
            updateDynamicHeight(for: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSTextView.insertNewline(_:)) {
                if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                    if !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                         parent.onCommit()
                    }
                    return true
                } else {
                    return false
                }
            }
            return false
        }
    }
}
