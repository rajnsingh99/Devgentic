// CustomTextEditor.swift
import SwiftUI
import AppKit
import os

// Make sure AttributedStringKeys.swift is available

struct CustomTextEditor: NSViewRepresentable {
    // MARK: - Bindings and Properties
    @Binding var text: String // Plain text representation
    var onCommit: (NSAttributedString) -> Void
    var minHeight: CGFloat
    var maxHeight: CGFloat

    // --- Prompt Suggestion Properties ---
    @Binding var showPromptSuggestions: Bool
    @Binding var suggestionQuery: String
    @Binding var activePromptTriggerRange: NSRange?
    var onPromptTagTapped: ((UUID) -> Void)?

    // --- File Mention Suggestion Properties (for @ trigger) ---
    @Binding var showFileSuggestions: Bool
    @Binding var fileSuggestionQuery: String
    @Binding var activeFileMentionTriggerRange: NSRange?
    // REMOVED: var onFileTagTapped: ((URL) -> Void)? - No longer inserting tappable file tags from @-mentions

    // --- Common Attributed Text Insertion ---
    @Binding var attributedTextInsertion: AttributedTextInsertionAction?

    var textViewRef: ((CustomTextEditor.CustomNSTextView?) -> Void)?

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.CustomTextEditor", category: "CustomTextEditorRefactored")

    struct AttributedTextInsertionAction: Equatable {
        let id = UUID()
        let range: NSRange
        let attributedString: NSAttributedString
        static func == (lhs: AttributedTextInsertionAction, rhs: AttributedTextInsertionAction) -> Bool {
            return lhs.id == rhs.id
        }
    }
    
    private var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
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
        
        textView.textColor = NSColor.textColor
        textView.insertionPointColor = NSColor.labelColor
        
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.lineFragmentPadding = 5
        textView.typingAttributes = defaultTypingAttributes
        textView.delegate = context.coordinator
        
        if !text.isEmpty {
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
            self.textViewRef?(textView)
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
        
        if context.coordinator.lastKnownTextViewInstance !== textView {
            self.textViewRef?(textView)
            context.coordinator.lastKnownTextViewInstance = textView
        }

        if let action = self.attributedTextInsertion {
            let actionToProcess = action
            self.attributedTextInsertion = nil // Clear the action immediately

            if context.coordinator.lastProcessedInsertionID == actionToProcess.id {
                logger.warning("NSTextView: Attributed text insertion ID \(actionToProcess.id.uuidString) was already processed. Skipping.")
                return
            }

            logger.debug("NSTextView: Processing attributed text insertion. ID: \(actionToProcess.id.uuidString), Range: \(actionToProcess.range), Text: \"\(actionToProcess.attributedString.string.prefix(30))\"")
            context.coordinator.lastProcessedInsertionID = actionToProcess.id
            
            if let textStorage = textView.textStorage {
                context.coordinator.isProgrammaticallyChangingText = true

                let validRangeStart = min(actionToProcess.range.location, textStorage.length)
                var validLength = actionToProcess.range.length
                // If range.length is 0, it's an insertion. If >0, it's a replacement.
                // Ensure length doesn't exceed bounds if it's a replacement.
                if actionToProcess.range.length > 0 {
                     validLength = min(actionToProcess.range.length, textStorage.length - validRangeStart)
                }
                
                let actualRangeToReplace = NSRange(location: validRangeStart, length: validLength)

                textStorage.replaceCharacters(in: actualRangeToReplace, with: actionToProcess.attributedString)
                
                let newCursorPosition = actualRangeToReplace.location + actionToProcess.attributedString.length
                textView.setSelectedRange(NSRange(location: newCursorPosition, length: 0))
                
                // Ensure typing attributes are reset after programmatic change, especially if inserting empty string
                textView.typingAttributes = defaultTypingAttributes
                textView.textColor = NSColor.textColor // Ensure text color is also reset
                
                context.coordinator.isProgrammaticallyChangingText = false
                // Update the binding after programmatic change
                // This was missing and could cause de-sync if the binding isn't updated after deletion
                DispatchQueue.main.async {
                    if self.text != textView.string {
                        self.text = textView.string
                    }
                }

            } else {
                logger.error("NSTextView: textStorage is nil for attributed insertion ID: \(actionToProcess.id.uuidString).")
            }
            return // Return after processing an insertion action
        } else {
            // Reset lastProcessedInsertionID if there's no current action to prevent stale ID issues
            if context.coordinator.lastProcessedInsertionID != nil {
                 context.coordinator.lastProcessedInsertionID = nil
            }
        }

        // Update from binding if text differs and no other operations are in progress
        if textView.string != self.text && !context.coordinator.isTyping && !context.coordinator.isProgrammaticallyChangingText {
             logger.debug("Updating NSTextView from plain text binding. Current NSTextView: \"\(textView.string.prefix(50))\", New binding value: \"\(self.text.prefix(50))\"")
             let currentSelectedRange = textView.selectedRange()
             context.coordinator.isProgrammaticallyChangingText = true
             
             textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: textView.string.count), with: self.text)
                                                                                                
             context.coordinator.isProgrammaticallyChangingText = false
             
             let newLocation = min(currentSelectedRange.location, self.text.count)
             textView.setSelectedRange(NSRange(location: newLocation, length: 0))
             
             textView.textColor = NSColor.textColor
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
        Coordinator(self, defaultTypingAttributes: defaultTypingAttributes)
    }

    class CustomNSTextView: NSTextView {
        weak var coordinator: Coordinator?
        
        init(coordinator: Coordinator?) {
            self.coordinator = coordinator
            let textStorage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            textStorage.addLayoutManager(layoutManager)
            let textContainer = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
            textContainer.widthTracksTextView = true
            layoutManager.addTextContainer(textContainer)
            
            super.init(frame: .zero, textContainer: textContainer)
            commonInit()
        }
        
        required init?(coder: NSCoder) {
            self.coordinator = nil // Should be set by makeNSView if used this way
            super.init(coder: coder)
            commonInit()
        }
        
        private func commonInit() {
            self.isVerticallyResizable = true
            self.isHorizontallyResizable = false
            self.autoresizingMask = [.width]
            
            self.textContainer?.lineFragmentPadding = 5
            self.textContainer?.widthTracksTextView = true
            self.textContainer?.heightTracksTextView = false // Important for intrinsicContentSize

            self.minSize = NSSize(width: 0, height: 0)
            self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        override var intrinsicContentSize: NSSize {
            guard let textContainer = self.textContainer, let layoutManager = self.layoutManager else {
                return NSSize(width: NSView.noIntrinsicMetric, height: coordinator?.parent.minHeight ?? super.intrinsicContentSize.height)
            }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            // Add textContainerInset height (top and bottom) to the usedRect height
            let idealHeight = ceil(usedRect.height + self.textContainerInset.height * 2)
            let finalHeight = max(coordinator?.parent.minHeight ?? 0, idealHeight)
            return NSSize(width: NSView.noIntrinsicMetric, height: finalHeight)
        }

        override func didChangeText() {
            super.didChangeText()
            invalidateIntrinsicContentSize() // Crucial for dynamic height
            // The enclosingScrollView's intrinsicContentSize also needs to be invalidated
            // if the CustomTextEditor is the documentView of an NSScrollView managed by SwiftUI.
            // This is often handled by the SwiftUI layout system, but explicit invalidation can help.
            enclosingScrollView?.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { // Ensure UI updates are on the main thread
                if self.window != nil { // Only scroll if the view is part of a window
                    self.scrollRangeToVisible(self.selectedRange())
                }
            }
        }
        
        override func setFrameSize(_ newSize: NSSize) {
            // Adjust text container width based on the new frame size
            if textContainer?.widthTracksTextView == true {
                // Calculate available width for text container excluding insets and padding
                let horizontalInsetsAndPadding = (textContainerInset.width * 2) + (textContainer?.lineFragmentPadding ?? 0) * 2
                let containerWidth = max(0, newSize.width - horizontalInsetsAndPadding)
                if textContainer?.containerSize.width != containerWidth {
                    textContainer?.containerSize = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
                }
            }
            super.setFrameSize(newSize)
        }
        
        override func keyDown(with event: NSEvent) {
            let suggestionsActive = coordinator?.parent.showPromptSuggestions == true || coordinator?.parent.showFileSuggestions == true
            
            // Option + Return for newline
            if event.modifierFlags.contains(.option), event.keyCode == 36 { // 36 is Return key
                insertNewline(nil); return
            }
            // Shift + Return to send message
            if event.modifierFlags.contains(.shift), event.keyCode == 36 {
                coordinator?.parent.onCommit(self.attributedString()); return
            }
            // Return to send message (only if suggestions are not active)
            if event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty, event.keyCode == 36 {
                if suggestionsActive {
                    // If suggestions are active, let NSTextView handle it (e.g., select suggestion)
                    // or pass to super if default behavior is desired.
                    super.keyDown(with: event)
                } else {
                    // No suggestions active, commit the message
                    coordinator?.parent.onCommit(self.attributedString())
                }
                return // Prevent further processing or inserting newline
            }
            super.keyDown(with: event)
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event) // Call super first
            let pointInView = self.convert(event.locationInWindow, from: nil)
            
            // Ensure layout manager, text container, and text storage are available
            guard let layoutManager = self.layoutManager,
                  let textContainer = self.textContainer,
                  let textStorage = self.textStorage else { return }

            let charIndex = layoutManager.characterIndex(for: pointInView, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            
            if charIndex < textStorage.length {
                // Check for PromptID taps
                if let promptIDVal = textStorage.attribute(NSAttributedString.Key.promptID, at: charIndex, effectiveRange: nil) as? UUID {
                    coordinator?.parent.logger.debug("Clicked on text with promptID: \(promptIDVal.uuidString)")
                    coordinator?.promptTagTapped(with: promptIDVal)
                    return // Return to prevent further processing if a tag was handled
                }
                // REMOVED: Logic for devgenticFileURL taps
                // if let fileURLVal = textStorage.attribute(NSAttributedString.Key.devgenticFileURL, at: charIndex, effectiveRange: nil) as? URL {
                //     coordinator?.parent.logger.debug("Clicked on text with devgenticFileURL: \(fileURLVal.path)")
                //     coordinator?.fileTagTapped(with: fileURLVal) // This method will be removed from Coordinator
                //     return
                // }
            }
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        weak var textView: CustomNSTextView? // Keep a reference to the NSTextView instance
        weak var lastKnownTextViewInstance: CustomNSTextView? // For updateNSView textViewRef

        var isTyping: Bool = false // To differentiate user typing from programmatic changes
        var isProgrammaticallyChangingText: Bool = false // Flag to prevent feedback loops
        var lastProcessedInsertionID: UUID? // To prevent processing the same insertion multiple times
        let defaultTypingAttributes: [NSAttributedString.Key: Any]

        init(_ parent: CustomTextEditor, defaultTypingAttributes: [NSAttributedString.Key: Any]) {
            self.parent = parent
            self.defaultTypingAttributes = defaultTypingAttributes
        }

        func textDidBeginEditing(_ notification: Notification) { isTyping = true }
        func textDidEndEditing(_ notification: Notification) {
            isTyping = false
            // Sync back to SwiftUI binding if text changed
            if let tv = notification.object as? NSTextView, parent.text != tv.string {
                 parent.text = tv.string // Update the plain text binding
            }
        }
        
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let textStorage = textView.textStorage else { return true }

            // Handle atomic deletion for Prompt tags
            if replacementString?.isEmpty ?? false && affectedCharRange.length == 1 { // Check for single character deletion (Backspace)
                let deletionLocation = affectedCharRange.location
                if deletionLocation >= 0 && deletionLocation < textStorage.length {
                    var effectiveRange = NSRange()
                    // Check for promptID attribute
                    if textStorage.attribute(NSAttributedString.Key.promptID, at: deletionLocation, effectiveRange: &effectiveRange) != nil {
                        parent.logger.debug("Atomic deletion triggered for prompt tag at range: \(effectiveRange)")
                        performAtomicDeletion(for: effectiveRange, in: textStorage, textView: textView)
                        return false // Prevent default deletion, we handled it
                    }
                    
                    // REMOVED: Atomic deletion logic for devgenticFileURL
                    // effectiveRange = NSRange() // Reset for next check
                    // if textStorage.attribute(NSAttributedString.Key.devgenticFileURL, at: deletionLocation, effectiveRange: &effectiveRange) != nil {
                    //     parent.logger.debug("Atomic deletion triggered for file tag at range: \(effectiveRange)")
                    //     performAtomicDeletion(for: effectiveRange, in: textStorage, textView: textView)
                    //     return false
                    // }
                }
            }
            return true // Allow other changes
        }

        private func performAtomicDeletion(for range: NSRange, in textStorage: NSTextStorage, textView: NSTextView) {
            isProgrammaticallyChangingText = true
            textStorage.replaceCharacters(in: range, with: "")
            textView.setSelectedRange(NSRange(location: range.location, length: 0)) // Move cursor to deletion point
            // Reset typing attributes to default after deleting a special tag
            textView.typingAttributes = defaultTypingAttributes
            isProgrammaticallyChangingText = false
            parent.text = textStorage.string // Update the plain text binding
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = self.textView, !isProgrammaticallyChangingText else { return }
            
            let currentPlainText = textView.string
            let currentSelectedRange = textView.selectedRange()
            
            // Update the plain text binding in the parent SwiftUI view
            DispatchQueue.main.async { // Ensure UI updates are on the main thread
                if self.parent.text != currentPlainText {
                    self.parent.text = currentPlainText
                }
            }

            // Suggestion logic (Prompt and File)
            // Only one suggestion type should be active at a time.
            // If file suggestions are active, don't check for prompt suggestions, and vice-versa.

            if !parent.showFileSuggestions { // If file suggestions are NOT active, check for prompts
                handlePromptSuggestionLogic(currentText: currentPlainText, cursorPosition: currentSelectedRange.location)
            } else {
                // If file suggestions ARE active, ensure prompt suggestions are cleared
                if parent.showPromptSuggestions { clearPromptSuggestions() }
            }

            if !parent.showPromptSuggestions { // If prompt suggestions are NOT active, check for files
                handleFileMentionSuggestionLogic(currentText: currentPlainText, cursorPosition: currentSelectedRange.location)
            } else {
                // If prompt suggestions ARE active, ensure file suggestions are cleared
                if parent.showFileSuggestions { clearFileMentionSuggestions() }
            }
            
            // Reset typing attributes if cursor moves out of a tagged segment or into an empty area
            if !parent.showPromptSuggestions && !parent.showFileSuggestions {
                resetTypingAttributesIfNeeded(at: currentSelectedRange, in: textView)
            }
        }
        
        private func handlePromptSuggestionLogic(currentText: String, cursorPosition: Int) {
            // Check if the character immediately before the cursor is '#'
            // and if it's preceded by a space/newline or is at the beginning of the text.
            if cursorPosition > 0 {
                let charBeforeCursorIndex = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 1)
                if currentText[charBeforeCursorIndex] == "#" {
                    let isAtStart = (cursorPosition - 1 == 0)
                    var isPrecededBySpaceOrNewline = false
                    if cursorPosition - 2 >= 0 { // Check character before '#'
                        let preCharIdx = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 2)
                        if currentText[preCharIdx].isWhitespace || currentText[preCharIdx].isNewline {
                            isPrecededBySpaceOrNewline = true
                        }
                    }

                    if isAtStart || isPrecededBySpaceOrNewline {
                        // Potential trigger found
                        let triggerRange = NSRange(location: cursorPosition - 1, length: 1) // Range of the '#'
                        if !parent.showPromptSuggestions || parent.activePromptTriggerRange != triggerRange {
                            parent.logger.debug("Activating prompt suggestions for '#'. Range: \(triggerRange)")
                            parent.showPromptSuggestions = true
                            parent.suggestionQuery = "" // Start with an empty query
                            parent.activePromptTriggerRange = triggerRange
                            if parent.showFileSuggestions { clearFileMentionSuggestions() } // Ensure file suggestions are off
                            return // Exit early as we've activated suggestions
                        }
                    }
                }
            }

            // If prompt suggestions are active, update the query or dismiss
            if parent.showPromptSuggestions, var activeRange = parent.activePromptTriggerRange {
                // Ensure the '#' is still there
                guard activeRange.location < currentText.count,
                      currentText[currentText.index(currentText.startIndex, offsetBy: activeRange.location)] == "#" else {
                    parent.logger.debug("Dismissing prompt suggestions: '#' removed or changed.")
                    clearPromptSuggestions()
                    return
                }

                // Dismiss if cursor moves before the '#'
                if cursorPosition < activeRange.location {
                    parent.logger.debug("Dismissing prompt suggestions: Cursor moved before '#'.")
                    clearPromptSuggestions()
                    return
                }

                let queryLength = cursorPosition - (activeRange.location + 1)
                if queryLength < 0 { // Cursor is at '#'
                    if parent.suggestionQuery != "" { parent.suggestionQuery = "" }
                    activeRange.length = 1 // The '#' itself
                    parent.activePromptTriggerRange = activeRange
                    return
                }
                
                // Update active range length to include the query
                activeRange.length = queryLength + 1 // +1 for the '#'
                parent.activePromptTriggerRange = activeRange

                // Extract the query string
                let queryStartIndex = currentText.index(currentText.startIndex, offsetBy: activeRange.location + 1)
                let queryEndIndex = currentText.index(queryStartIndex, offsetBy: queryLength)
                let query = (queryLength > 0) ? String(currentText[queryStartIndex..<queryEndIndex]) : ""

                // Dismiss if query contains space or newline (tags are single words)
                if query.contains(" ") || query.contains("\n") {
                    parent.logger.debug("Dismissing prompt suggestions: Query contains space/newline.")
                    clearPromptSuggestions()
                    return
                }

                // Update the suggestion query if it changed
                if parent.suggestionQuery != query {
                    parent.suggestionQuery = query
                    parent.logger.trace("Prompt suggestion query updated: '\(query)'")
                }
            } else if parent.showPromptSuggestions { // If suggestions were shown but conditions no longer met
                clearPromptSuggestions()
            }
        }

        private func handleFileMentionSuggestionLogic(currentText: String, cursorPosition: Int) {
            // Similar logic to prompt suggestions, but for '@'
            if cursorPosition > 0 {
                let charBeforeCursorIndex = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 1)
                if currentText[charBeforeCursorIndex] == "@" {
                    let isAtStart = (cursorPosition - 1 == 0)
                    var isPrecededBySpaceOrNewline = false
                    if cursorPosition - 2 >= 0 {
                        let preCharIdx = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 2)
                        if currentText[preCharIdx].isWhitespace || currentText[preCharIdx].isNewline {
                            isPrecededBySpaceOrNewline = true
                        }
                    }

                    if isAtStart || isPrecededBySpaceOrNewline {
                        let triggerRange = NSRange(location: cursorPosition - 1, length: 1)
                        if !parent.showFileSuggestions || parent.activeFileMentionTriggerRange != triggerRange {
                            parent.logger.debug("Activating file suggestions for '@'. Range: \(triggerRange)")
                            parent.showFileSuggestions = true
                            parent.fileSuggestionQuery = ""
                            parent.activeFileMentionTriggerRange = triggerRange
                            if parent.showPromptSuggestions { clearPromptSuggestions() } // Ensure prompt suggestions are off
                            return
                        }
                    }
                }
            }

            if parent.showFileSuggestions, var activeRange = parent.activeFileMentionTriggerRange {
                guard activeRange.location < currentText.count,
                      currentText[currentText.index(currentText.startIndex, offsetBy: activeRange.location)] == "@" else {
                    parent.logger.debug("Dismissing file suggestions: '@' removed or changed.")
                    clearFileMentionSuggestions()
                    return
                }

                if cursorPosition < activeRange.location {
                    parent.logger.debug("Dismissing file suggestions: Cursor moved before '@'.")
                    clearFileMentionSuggestions()
                    return
                }

                let queryLength = cursorPosition - (activeRange.location + 1)
                if queryLength < 0 {
                    if parent.fileSuggestionQuery != "" { parent.fileSuggestionQuery = "" }
                    activeRange.length = 1
                    parent.activeFileMentionTriggerRange = activeRange
                    return
                }
                
                activeRange.length = queryLength + 1
                parent.activeFileMentionTriggerRange = activeRange

                let queryStartIndex = currentText.index(currentText.startIndex, offsetBy: activeRange.location + 1)
                let queryEndIndex = currentText.index(queryStartIndex, offsetBy: queryLength)
                let query = (queryLength > 0) ? String(currentText[queryStartIndex..<queryEndIndex]) : ""

                if query.contains(" ") || query.contains("\n") {
                    parent.logger.debug("Dismissing file suggestions: Query contains space/newline.")
                    clearFileMentionSuggestions()
                    return
                }

                if parent.fileSuggestionQuery != query {
                    parent.fileSuggestionQuery = query
                    parent.logger.trace("File suggestion query updated: '\(query)'")
                }
            } else if parent.showFileSuggestions {
                 clearFileMentionSuggestions()
            }
        }
        
        private func resetTypingAttributesIfNeeded(at range: NSRange, in textView: NSTextView) {
            // This function ensures that if the user moves the cursor outside of a specially formatted
            // segment (like a prompt tag) or into an empty area, the typing attributes
            // (font, color, etc.) are reset to default. This prevents the user from accidentally
            // continuing to type with the special formatting of the tag.

            if range.length == 0 { // Only care about cursor position (no selection)
                var cursorIsInsideTaggedSegment = false
                
                // Check character before cursor (if cursor is not at the beginning)
                if range.location > 0 {
                    if textView.textStorage?.attribute(NSAttributedString.Key.promptID, at: range.location - 1, effectiveRange: nil) != nil {
                        // REMOVED: Check for devgenticFileURL
                        // || textView.textStorage?.attribute(NSAttributedString.Key.devgenticFileURL, at: range.location - 1, effectiveRange: nil) != nil {
                        cursorIsInsideTaggedSegment = true
                    }
                }
                
                // Check character at cursor position (if cursor is not at the end)
                // This is important if the cursor is at the very beginning of a tag.
                if !cursorIsInsideTaggedSegment && range.location < textView.string.count {
                     if textView.textStorage?.attribute(NSAttributedString.Key.promptID, at: range.location, effectiveRange: nil) != nil {
                        // REMOVED: Check for devgenticFileURL
                        // || textView.textStorage?.attribute(NSAttributedString.Key.devgenticFileURL, at: range.location, effectiveRange: nil) != nil {
                        cursorIsInsideTaggedSegment = true
                    }
                }

                // If cursor is NOT inside a tagged segment, check if typing attributes need reset
                if !cursorIsInsideTaggedSegment {
                    let currentTypingAttrs = textView.typingAttributes
                    var needsReset = false
                    
                    // Check if any custom tag attributes are present in typingAttributes
                    if currentTypingAttrs[NSAttributedString.Key.promptID] != nil {
                        // REMOVED: Check for devgenticFileURL
                        // || currentTypingAttrs[NSAttributedString.Key.devgenticFileURL] != nil {
                        needsReset = true
                    }
                    // Also check if font or color differs from default (could happen after pasting styled text)
                    else if (currentTypingAttrs[.font] as? NSFont) != (defaultTypingAttributes[.font] as? NSFont) {
                        needsReset = true
                    }
                    else if (currentTypingAttrs[.foregroundColor] as? NSColor) != (defaultTypingAttributes[.foregroundColor] as? NSColor) {
                        needsReset = true
                    }
                    
                    if needsReset {
                        textView.typingAttributes = defaultTypingAttributes
                        parent.logger.debug("Reset typing attributes to default.")
                    }
                }
            }
        }

        func clearPromptSuggestions() {
            if parent.showPromptSuggestions || parent.activePromptTriggerRange != nil || !parent.suggestionQuery.isEmpty {
                parent.logger.debug("Clearing prompt suggestions.")
                parent.showPromptSuggestions = false
                parent.suggestionQuery = ""
                parent.activePromptTriggerRange = nil
            }
        }

        func clearFileMentionSuggestions() {
            if parent.showFileSuggestions || parent.activeFileMentionTriggerRange != nil || !parent.fileSuggestionQuery.isEmpty {
                parent.logger.debug("Clearing file mention suggestions.")
                parent.showFileSuggestions = false
                parent.fileSuggestionQuery = ""
                parent.activeFileMentionTriggerRange = nil
            }
        }

        func promptTagTapped(with id: UUID) {
            parent.logger.debug("Coordinator: Prompt tag tapped with ID: \(id.uuidString)")
            parent.onPromptTagTapped?(id)
        }

        // REMOVED: func fileTagTapped(with url: URL)
        // This was for inline @-mention tags, which are no longer created.
    }
}

// MARK: - Preview
struct CustomTextEditor_Previews_Refactor_P2: PreviewProvider { // Renamed preview
    @State static var textContent: String = "Test #SampleTag here." // Removed @FileMention from default
    @State static var showPrompts: Bool = false
    @State static var promptQuery: String = ""
    @State static var promptRange: NSRange? = nil
    @State static var showFiles: Bool = false // For @-suggestions
    @State static var fileQuery: String = ""   // For @-suggestions
    @State static var fileRange: NSRange? = nil  // For @-suggestions
    @State static var insertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil
    
    static var previews: some View {
        CustomTextEditor(
            text: $textContent,
            onCommit: { attrString in print("Commit with attributed string: \(attrString.string.prefix(30))") },
            minHeight: 40, maxHeight: 120,
            showPromptSuggestions: $showPrompts,
            suggestionQuery: $promptQuery,
            activePromptTriggerRange: $promptRange,
            onPromptTagTapped: { uuid in print("Tapped prompt: \(uuid)") },
            showFileSuggestions: $showFiles, // Still needed for suggestion UI trigger
            fileSuggestionQuery: $fileQuery, // Still needed for suggestion UI trigger
            activeFileMentionTriggerRange: $fileRange, // Still needed for suggestion UI trigger
            // onFileTagTapped is removed
            attributedTextInsertion: $insertionRequest,
            textViewRef: { nsTextView in
                print("NSTextView instance received in preview: \(nsTextView != nil)")
            }
        )
        .padding()
        .frame(width: 350, height: 100)
        .previewDisplayName("CustomTextEditor (Refactored @-Mention)")
        .preferredColorScheme(.dark)
    }
}
