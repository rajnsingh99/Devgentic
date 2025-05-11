// CustomTextEditor.swift
import SwiftUI
import AppKit
import os // For logging

struct CustomTextEditor: NSViewRepresentable {
    // MARK: - Bindings and Properties
    @Binding var text: String
    var onCommit: () -> Void
    var minHeight: CGFloat
    var maxHeight: CGFloat

    @Binding var showPromptSuggestions: Bool
    @Binding var suggestionQuery: String
    @Binding var activePromptTriggerRange: NSRange?
    @Binding var attributedTextInsertion: AttributedTextInsertionAction?

    var onPromptTagTapped: ((UUID) -> Void)?

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.CustomTextEditor", category: "CustomTextEditorRefactored")

    struct AttributedTextInsertionAction: Equatable {
        let id = UUID()
        let range: NSRange
        let attributedString: NSAttributedString
        static func == (lhs: AttributedTextInsertionAction, rhs: AttributedTextInsertionAction) -> Bool {
            return lhs.id == rhs.id
        }
    }
    
    // Defines the default style for normal text.
    // Crucially, .promptID is omitted here.
    private var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
            // Any other default attributes like .paragraphStyle can be added here.
            // .promptID is intentionally omitted to ensure it's not part of default typing.
        ]
    }

    // MARK: - NSViewRepresentable Methods
    func makeNSView(context: Context) -> NSScrollView {
        let textView = CustomNSTextView(coordinator: context.coordinator)

        textView.isRichText = true
        textView.allowsImageEditing = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.backgroundColor = NSColor.clear
        textView.textColor = NSColor.labelColor // Default text color for the view
        textView.insertionPointColor = NSColor.labelColor
        
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.lineFragmentPadding = 5

        // Set initial typing attributes to default.
        textView.typingAttributes = defaultTypingAttributes
        
        textView.delegate = context.coordinator
        
        // Initial text setup from binding
        if !text.isEmpty {
             // If initial text might contain attributes, it should be an NSAttributedString.
             // For plain text, this is fine.
             textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        } else {
            textView.string = ""
        }
        
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false

        if let clipView = scrollView.contentView as? NSClipView {
            clipView.drawsBackground = false
            clipView.backgroundColor = .clear
        }

        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        
        context.coordinator.textView = textView

        DispatchQueue.main.async {
            textView.invalidateIntrinsicContentSize()
            scrollView.invalidateIntrinsicContentSize()
        }
        
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CustomNSTextView else {
            logger.error("Failed to get CustomNSTextView from scrollView in updateNSView.")
            return
        }

        // 1. Handle Attributed Text Insertion
        if let action = self.attributedTextInsertion {
            let actionToProcess = action
            self.attributedTextInsertion = nil // Nil out binding immediately

            // Check if this action was already processed
            if context.coordinator.lastProcessedInsertionID == actionToProcess.id {
                logger.warning("NSTextView: Attributed text insertion ID \(actionToProcess.id) was already processed. Skipping.")
                return
            }

            logger.debug("NSTextView: Processing attributed text insertion. ID: \(actionToProcess.id)")
            context.coordinator.lastProcessedInsertionID = actionToProcess.id // Mark as processed
            
            if let textStorage = textView.textStorage {
                context.coordinator.isProgrammaticallyChangingText = true

                let validRangeStart = min(actionToProcess.range.location, textStorage.length)
                let validLength = min(actionToProcess.range.length, textStorage.length - validRangeStart)
                let actualRangeToReplace = NSRange(location: validRangeStart, length: validLength)

                textStorage.replaceCharacters(in: actualRangeToReplace, with: actionToProcess.attributedString)
                
                let newCursorPosition = actualRangeToReplace.location + actionToProcess.attributedString.length
                textView.setSelectedRange(NSRange(location: newCursorPosition, length: 0))
                
                // CRITICAL: Reset typing attributes to default after insertion.
                textView.typingAttributes = defaultTypingAttributes
                
                context.coordinator.isProgrammaticallyChangingText = false
            } else {
                logger.error("NSTextView: textStorage is nil for attributed insertion ID: \(actionToProcess.id).")
            }
            // Return to ensure this pass only handles the insertion.
            // Subsequent sync of `text` binding will happen in a new `updateNSView` call.
            return
        } else {
            // If no insertion request is active, clear the last processed ID.
            if context.coordinator.lastProcessedInsertionID != nil {
                 context.coordinator.lastProcessedInsertionID = nil
            }
        }

        // 2. Synchronize NSTextView with the `text` binding if it changed externally
        if textView.string != self.text && !context.coordinator.isTyping {
             logger.debug("Updating NSTextView from binding. Current: \"\(textView.string.prefix(50))\", New: \"\(self.text.prefix(50))\"")
             let currentSelectedRange = textView.selectedRange()
             context.coordinator.isProgrammaticallyChangingText = true
             // This replaces the entire content. If `self.text` is plain, attributes are lost.
             // If `self.text` needs to preserve attributes, it should be an NSAttributedString binding.
             textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: textView.string.count), with: self.text)
             context.coordinator.isProgrammaticallyChangingText = false
             
             // Restore selection
             if currentSelectedRange.location <= self.text.count {
                 textView.setSelectedRange(NSRange(location: currentSelectedRange.location, length: currentSelectedRange.length))
             } else {
                 textView.setSelectedRange(NSRange(location: self.text.count, length: 0))
             }
             // After this kind of full replacement, ensure typing attributes are default.
             textView.typingAttributes = defaultTypingAttributes
        }
    }
    
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scrollView.documentView as? CustomNSTextView else {
            return CGSize(width: proposal.width ?? minHeight, height: minHeight)
        }
        let textViewIntrinsicHeight = textView.intrinsicContentSize.height
        let clampedHeight = max(self.minHeight, min(textViewIntrinsicHeight, self.maxHeight))
        return CGSize(width: proposal.width ?? NSView.noIntrinsicMetric, height: clampedHeight)
    }

    func makeCoordinator() -> Coordinator {
        // Pass the defaultTypingAttributes to the Coordinator
        Coordinator(self, defaultTypingAttributes: defaultTypingAttributes)
    }

    // MARK: - Custom NSTextView Subclass
    class CustomNSTextView: NSTextView {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator?) {
            self.coordinator = coordinator
            let textStorage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            textStorage.addLayoutManager(layoutManager)
            let textContainer = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
            layoutManager.addTextContainer(textContainer)
            super.init(frame: .zero, textContainer: textContainer)
            commonInit()
        }
        
        required init?(coder: NSCoder) {
            self.coordinator = nil
            super.init(coder: coder)
            commonInit()
        }
        
        private func commonInit() {
            self.isVerticallyResizable = true; self.isHorizontallyResizable = false
            self.autoresizingMask = [.width]; self.textContainer?.widthTracksTextView = true
            self.textContainer?.heightTracksTextView = false; self.minSize = .zero
            self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        override var intrinsicContentSize: NSSize {
            guard let tc = textContainer, let lm = layoutManager else {
                return NSSize(width: NSView.noIntrinsicMetric, height: coordinator?.parent.minHeight ?? super.intrinsicContentSize.height)
            }
            lm.ensureLayout(for: tc); let usedRect = lm.usedRect(for: tc)
            let idealHeight = ceil(usedRect.height + (textContainerInset.height * 2))
            return NSSize(width: NSView.noIntrinsicMetric, height: max(coordinator?.parent.minHeight ?? 0, idealHeight))
        }

        override func didChangeText() {
            super.didChangeText(); invalidateIntrinsicContentSize(); enclosingScrollView?.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { if self.window != nil { self.scrollRangeToVisible(self.selectedRange()) } }
        }
        
        override func setFrameSize(_ newSize: NSSize) {
            if textContainer?.widthTracksTextView == true {
                let hInset = (textContainerInset.width*2) + (textContainer?.lineFragmentPadding ?? 0)*2
                let cWidth = max(0, newSize.width - hInset)
                if textContainer?.containerSize.width != cWidth { textContainer?.containerSize = NSSize(width: cWidth, height: .greatestFiniteMagnitude) }
            }
            super.setFrameSize(newSize)
        }
        
        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.contains(.option), event.keyCode == 36 { insertNewline(nil); return }
            if event.modifierFlags.contains(.shift), event.keyCode == 36 { coordinator?.parent.onCommit(); return }
            if event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty, event.keyCode == 36 {
                if coordinator?.parent.showPromptSuggestions == true { super.keyDown(with: event) } else { coordinator?.parent.onCommit() }
                return
            }
            super.keyDown(with: event)
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            let pointInView = self.convert(event.locationInWindow, from: nil)
            if let layoutManager = self.layoutManager,
               let textContainer = self.textContainer,
               let textStorage = self.textStorage {
                let charIndex = layoutManager.characterIndex(for: pointInView, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
                if charIndex < textStorage.length {
                    if let promptID = textStorage.attribute(.promptID, at: charIndex, effectiveRange: nil) as? UUID {
                        coordinator?.parent.logger.debug("Clicked on text with promptID: \(promptID.uuidString)")
                        coordinator?.promptTagTapped(with: promptID)
                        return
                    }
                }
            }
        }
    }

    // MARK: - Coordinator Class
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        weak var textView: CustomNSTextView?
        var isTyping: Bool = false
        var isProgrammaticallyChangingText: Bool = false
        var lastProcessedInsertionID: UUID?
        let defaultTypingAttributes: [NSAttributedString.Key: Any] // Store default attributes

        init(_ parent: CustomTextEditor, defaultTypingAttributes: [NSAttributedString.Key: Any]) {
            self.parent = parent
            self.defaultTypingAttributes = defaultTypingAttributes
        }

        func textDidBeginEditing(_ notification: Notification) { isTyping = true }
        func textDidEndEditing(_ notification: Notification) {
            isTyping = false
            if let tv = notification.object as? NSTextView, parent.text != tv.string { parent.text = tv.string }
        }
        
        // Handles atomic deletion of prompt tags and normal text input.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let textStorage = textView.textStorage else { return true }

            // Check for atomic deletion of prompt tags
            if replacementString?.isEmpty ?? false && affectedCharRange.length == 1 { // Indicates a single character deletion (Backspace/Delete)
                let deletionLocation = affectedCharRange.location
                
                // Check if the character being deleted is part of a prompt tag
                if deletionLocation >= 0 && deletionLocation < textStorage.length {
                    var effectiveRange = NSRange() // Will be filled with the range of the attribute
                    // Check for the .promptID attribute specifically
                    if let _ = textStorage.attribute(.promptID, at: deletionLocation, effectiveRange: &effectiveRange) {
                        // If a promptID attribute exists, delete the entire effective range of that attribute
                        parent.logger.debug("Atomic deletion triggered for prompt tag at range: \(effectiveRange)")
                        
                        isProgrammaticallyChangingText = true
                        textStorage.replaceCharacters(in: effectiveRange, with: "")
                        textView.setSelectedRange(NSRange(location: effectiveRange.location, length: 0)) // Move cursor to start of deleted range
                        textView.typingAttributes = defaultTypingAttributes // Reset typing attributes
                        isProgrammaticallyChangingText = false
                        
                        // Manually update the parent's text binding
                        // as returning false prevents the normal textDidChange flow for this specific change.
                        parent.text = textStorage.string
                        return false // Prevent default character-by-character deletion
                    }
                }
            }
            // For all other cases (typing, non-atomic deletion, etc.), allow the change.
            return true
        }

        // Called after text has changed.
        func textDidChange(_ notification: Notification) {
            guard let textView = self.textView else { return }
            
            let currentText = textView.string
            
            // Update SwiftUI binding if text differs.
            // This needs to be on main thread for UI updates.
            DispatchQueue.main.async {
                if self.parent.text != currentText {
                    self.parent.text = currentText
                }
            }

            // Logic to reset typingAttributes if cursor is not within a prompt tag.
            let currentSelectedRange = textView.selectedRange()
            if currentSelectedRange.length == 0 { // Only if it's a cursor, not a selection
                var cursorIsInsidePromptTag = false
                
                // Check character to the left of the cursor
                if currentSelectedRange.location > 0 {
                    if textView.textStorage?.attribute(.promptID, at: currentSelectedRange.location - 1, effectiveRange: nil) != nil {
                        cursorIsInsidePromptTag = true
                    }
                }
                // Check character at the cursor location (if not at the end of text and not already confirmed inside)
                if !cursorIsInsidePromptTag && currentSelectedRange.location < textView.string.count {
                     if textView.textStorage?.attribute(.promptID, at: currentSelectedRange.location, effectiveRange: nil) != nil {
                        cursorIsInsidePromptTag = true
                    }
                }

                if !cursorIsInsidePromptTag {
                    // If cursor is not inside a prompt tag, check if current typing attributes need reset.
                    let currentTypingAttrs = textView.typingAttributes
                    var needsReset = false
                    if currentTypingAttrs[.promptID] != nil { // If .promptID is somehow set
                        needsReset = true
                    } else if (currentTypingAttrs[.font] as? NSFont) != (defaultTypingAttributes[.font] as? NSFont) {
                        needsReset = true
                    } else if (currentTypingAttrs[.foregroundColor] as? NSColor) != (defaultTypingAttributes[.foregroundColor] as? NSColor) {
                        needsReset = true
                    }
                    // Add checks for other attributes if necessary

                    if needsReset {
                        // parent.logger.debug("Resetting typingAttributes in textDidChange at location \(currentSelectedRange.location)")
                        textView.typingAttributes = defaultTypingAttributes
                    }
                }
            }
            
            // --- Logic for showing/updating prompt suggestions (remains largely the same) ---
            let cursorPosition = currentSelectedRange.location
            // (Suggestion logic as previously provided - condensed for brevity here, ensure it's complete in your file)
            if cursorPosition > 0 {
                let charBeforeCursorIndex = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 1)
                if currentText[charBeforeCursorIndex] == "#" {
                    let isAtStart = (cursorPosition - 1 == 0)
                    var isPrecededBySpace = false
                    if cursorPosition - 2 >= 0 {
                        let preCharIdx = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 2)
                        if currentText[preCharIdx].isWhitespace || currentText[preCharIdx].isNewline { isPrecededBySpace = true }
                    }
                    let triggerRange = NSRange(location: cursorPosition - 1, length: 1)
                    if isAtStart || isPrecededBySpace {
                        if !parent.showPromptSuggestions || parent.activePromptTriggerRange != triggerRange {
                            parent.showPromptSuggestions = true; parent.suggestionQuery = ""; parent.activePromptTriggerRange = triggerRange
                            return
                        }
                    }
                }
            }

            if parent.showPromptSuggestions, var activeRange = parent.activePromptTriggerRange {
                if activeRange.location >= currentText.count || currentText[currentText.index(currentText.startIndex, offsetBy: activeRange.location)] != "#" {
                    clearSuggestions(); return
                }
                if cursorPosition < activeRange.location { clearSuggestions(); return }

                let queryLen = cursorPosition - (activeRange.location + 1)
                if queryLen < 0 {
                    if parent.suggestionQuery != "" { parent.suggestionQuery = "" }
                    activeRange.length = 1; parent.activePromptTriggerRange = activeRange
                    return
                }
                activeRange.length = queryLen + 1; parent.activePromptTriggerRange = activeRange
                let queryStartIdx = currentText.index(currentText.startIndex, offsetBy: activeRange.location + 1)
                let queryEndIdx = currentText.index(queryStartIdx, offsetBy: queryLen)
                let query = (queryLen > 0) ? String(currentText[queryStartIdx..<queryEndIdx]) : ""
                if query.contains(" ") || query.contains("\n") { clearSuggestions(); return }
                if parent.suggestionQuery != query { parent.suggestionQuery = query }
                return
            }
            if parent.showPromptSuggestions { clearSuggestions() }
        }
        
        func clearSuggestions() {
            if parent.showPromptSuggestions || parent.activePromptTriggerRange != nil || !parent.suggestionQuery.isEmpty {
                parent.showPromptSuggestions = false; parent.suggestionQuery = ""; parent.activePromptTriggerRange = nil
            }
        }

        func promptTagTapped(with id: UUID) {
            parent.logger.debug("Coordinator: Prompt tag tapped with ID: \(id.uuidString)")
            parent.onPromptTagTapped?(id)
        }
    }
}



// MARK: - Preview (Simplified for brevity)
struct CustomTextEditor_Previews_RefactoredSizing: PreviewProvider {
    @State static var textContent: String = "Test #SampleTag here."
    @State static var showSuggestions: Bool = false
    @State static var query: String = ""
    @State static var range: NSRange? = nil
    @State static var insertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil
    
    static var previews: some View {
        CustomTextEditor(
            text: $textContent,
            onCommit: { print("Commit") },
            minHeight: 40, maxHeight: 120,
            showPromptSuggestions: $showSuggestions,
            suggestionQuery: $query,
            activePromptTriggerRange: $range,
            attributedTextInsertion: $insertionRequest
        )
        .padding()
        .frame(width: 300, height: 100)
    }
}
