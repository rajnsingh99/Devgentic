// CustomTextEditor.swift
import SwiftUI
import AppKit
import os

struct CustomTextEditor: NSViewRepresentable {
    // MARK: - Bindings and Properties
    @Binding var text: String
    var onCommit: (NSAttributedString) -> Void
    var minHeight: CGFloat
    var maxHeight: CGFloat

    @Binding var showPromptSuggestions: Bool
    @Binding var suggestionQuery: String
    @Binding var activePromptTriggerRange: NSRange?

    @Binding var showFileSuggestions: Bool
    @Binding var fileSuggestionQuery: String
    @Binding var activeFileMentionTriggerRange: NSRange?

    @Binding var attributedTextInsertion: AttributedTextInsertionAction?
    var textViewRef: ((CustomTextEditor.CustomNSTextView?) -> Void)?

    // Enhanced logger for debugging this specific issue
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.CustomTextEditor", category: "CustomTextEditor_ClearIssueDebug")

    struct AttributedTextInsertionAction: Equatable {
        let id = UUID()
        let range: NSRange
        let attributedString: NSAttributedString
        static func == (lhs: AttributedTextInsertionAction, rhs: AttributedTextInsertionAction) -> Bool {
            lhs.id == rhs.id
        }
    }
    
    private var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ]
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CustomNSTextView(coordinator: context.coordinator)
        textView.isRichText = true
        textView.allowsImageEditing = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.backgroundColor = NSColor.clear
        textView.textColor = NSColor.textColor // Use standard text color
        textView.insertionPointColor = NSColor.labelColor
        textView.textContainerInset = NSSize(width: 0, height: 3) // Consistent with existing
        textView.textContainer?.lineFragmentPadding = 5
        textView.typingAttributes = defaultTypingAttributes
        textView.delegate = context.coordinator
        
        // Programmatically set initial text
        context.coordinator.isProgrammaticallyChangingText = true
        textView.string = text // Set initial text from binding
        context.coordinator.isProgrammaticallyChangingText = false
        
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        if let clipView = scrollView.contentView as? NSClipView {
            clipView.drawsBackground = false
            clipView.backgroundColor = .clear
        }
        scrollView.scrollerStyle = .overlay // Use overlay scrollers
        scrollView.autohidesScrollers = true // Autohide scrollers
        
        context.coordinator.textView = textView
        DispatchQueue.main.async { // Ensure textViewRef is called after setup
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
        
        // Update textViewRef if the instance changes (though unlikely for a simple view)
        if context.coordinator.lastKnownTextViewInstance !== textView {
            self.textViewRef?(textView)
            context.coordinator.lastKnownTextViewInstance = textView
        }

        var textWasChangedByInsertionRequest = false

        // 1. Process any pending attributed text insertion requests
        if let action = self.attributedTextInsertion {
            let actionToProcess = action
            self.attributedTextInsertion = nil // Clear the request immediately

            // Prevent reprocessing the exact same insertion action
            if context.coordinator.lastProcessedInsertionID == actionToProcess.id &&
               actionToProcess.attributedString.string == context.coordinator.lastProcessedInsertionString {
                logger.warning("NSTextView: Insertion ID \(actionToProcess.id.uuidString) with same string already processed. Skipping.")
                // Even if skipped, check if the binding self.text needs to reflect textView.string
                // This might happen if an external change to self.text occurred concurrently.
            } else {
                logger.log("NSTextView: Processing insertion. ID: \(actionToProcess.id.uuidString), RangeToReplace: \(NSStringFromRange(actionToProcess.range)), InsertText: \"\(actionToProcess.attributedString.string.prefix(50))\", CurrentTextViewLength: \(textView.string.count)")
                context.coordinator.lastProcessedInsertionID = actionToProcess.id
                context.coordinator.lastProcessedInsertionString = actionToProcess.attributedString.string
                
                if let textStorage = textView.textStorage {
                    context.coordinator.isProgrammaticallyChangingText = true
                    
                    let validLocation = min(actionToProcess.range.location, textStorage.length)
                    let validLength = min(actionToProcess.range.length, textStorage.length - validLocation)
                    let actualRangeToReplace = NSRange(location: validLocation, length: validLength)

                    logger.debug("NSTextView: Validated actualRangeToReplace for insertion: \(NSStringFromRange(actualRangeToReplace))")

                    textStorage.replaceCharacters(in: actualRangeToReplace, with: actionToProcess.attributedString)
                    let newCursorPosition = actualRangeToReplace.location + actionToProcess.attributedString.length
                    textView.setSelectedRange(NSRange(location: newCursorPosition, length: 0))
                    
                    textView.typingAttributes = defaultTypingAttributes // Reset typing attributes after insertion
                    
                    // After programmatic insertion, if the binding `self.text` doesn't match, update it.
                    // This ensures the ViewModel's `userInput` is also in sync if the insertion changed the overall text.
                    if self.text != textView.string {
                        self.text = textView.string // Sync binding OUT
                        textWasChangedByInsertionRequest = true // Mark that text was changed by this path
                        logger.debug("NSTextView: Synced binding OUT after insertion. New text: \"\(textView.string.prefix(50))\"")
                    }
                    context.coordinator.isProgrammaticallyChangingText = false
                } else {
                    logger.error("NSTextView: textStorage is nil for insertion ID: \(actionToProcess.id.uuidString).")
                }
            }
        } else {
             // Clear last processed insertion details if there's no current action
             if context.coordinator.lastProcessedInsertionID != nil {
                  context.coordinator.lastProcessedInsertionID = nil
                  context.coordinator.lastProcessedInsertionString = nil
             }
        }

        // 2. Synchronize the textView with the binding `self.text` if it changed externally (e.g., ViewModel cleared it)
        //    This is the CRITICAL section for the reported clearing issue.
        logger.debug("""
            updateNSView: About to check for binding sync.
            textWasChangedByInsertionRequest: \(textWasChangedByInsertionRequest),
            textView.string (current actual content, first 20): \"\(String(textView.string.prefix(20)))\",
            self.text (binding from ViewModel, first 20): \"\(String(self.text.prefix(20)))\",
            isProgrammaticallyChangingText (coordinator flag): \(context.coordinator.isProgrammaticallyChangingText)
            """)

        if !textWasChangedByInsertionRequest && textView.string != self.text && !context.coordinator.isProgrammaticallyChangingText {
            logger.debug("NSTextView: Syncing binding IN. TextView had: \"\(textView.string.prefix(50))\", Binding (now target): \"\(self.text.prefix(50))\"")
            
            let currentSelectedRange = textView.selectedRange() // Preserve selection if possible
            context.coordinator.isProgrammaticallyChangingText = true // Mark as programmatic change
            
            // Replace the entire content of the text view with the content of the binding
            textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: textView.string.count), with: self.text)
            
            // Attempt to restore cursor position, or move to end if text is shorter
            let newLocation = self.text.isEmpty ? 0 : min(currentSelectedRange.location, self.text.count)
            textView.setSelectedRange(NSRange(location: newLocation, length: 0))
            
            // Reset typing attributes if text is empty or if they somehow diverged
            // Corrected attribute comparison
            let currentFont = textView.typingAttributes[.font] as? NSFont
            let defaultFont = defaultTypingAttributes[.font] as? NSFont
            let currentFgColor = textView.typingAttributes[.foregroundColor] as? NSColor
            let defaultFgColor = defaultTypingAttributes[.foregroundColor] as? NSColor

            var needsAttributeReset = false
            if currentFont != defaultFont { needsAttributeReset = true }
            if currentFgColor != defaultFgColor { needsAttributeReset = true }
            if self.text.isEmpty && !needsAttributeReset { needsAttributeReset = true } // Always reset for empty text

            if needsAttributeReset {
                 textView.typingAttributes = defaultTypingAttributes
                 logger.debug("NSTextView: Reset typingAttributes after binding IN sync (text empty or attrs differed).")
            }
            // Ensure text color is standard (in case it was changed by attributes)
            if textView.textColor != NSColor.textColor {
                 textView.textColor = NSColor.textColor
                 logger.debug("NSTextView: Reset textColor to standard labelColor after binding IN sync.")
            }
            context.coordinator.isProgrammaticallyChangingText = false // Unmark
            logger.debug("NSTextView: Finished Syncing binding IN. TextView now: \"\(textView.string.prefix(50))\"")
        } else {
            // Log why the sync was skipped
            var reasons: [String] = []
            if textWasChangedByInsertionRequest { reasons.append("textWasChangedByInsertionRequest is true") }
            if textView.string == self.text { reasons.append("textView.string == self.text (no change needed or already synced)") }
            if context.coordinator.isProgrammaticallyChangingText { reasons.append("isProgrammaticallyChangingText is true") }
            
            if !reasons.isEmpty {
                logger.debug("NSTextView: SKIPPED Syncing binding IN because: \(reasons.joined(separator: "; ")). TextView content remains: \"\(textView.string.prefix(50))\"")
            } else if !textWasChangedByInsertionRequest && textView.string != self.text && context.coordinator.isProgrammaticallyChangingText {
                // This case implies an external binding change happened *while* another programmatic change was flagged.
                // This could be a tricky race condition.
                logger.warning("NSTextView: SKIPPED Syncing binding IN. Conditions: !textWasChangedByInsertionRequest (\(!textWasChangedByInsertionRequest)), textView.string != self.text (\(textView.string != self.text)), but isProgrammaticallyChangingText was TRUE. This might indicate a state issue if self.text was changed externally during a previous programmatic update.")
            }
        }
        // Ensure the intrinsic content size is invalidated if text might have changed height
        // This is implicitly handled by didChangeText, but an explicit call here might be beneficial
        // if changes happened without triggering didChangeText (e.g. direct textStorage manipulation if that were the case).
        // However, replaceCharacters(in:with:) should trigger didChangeText.
    }
    
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scrollView.documentView as? CustomNSTextView else {
            // Fallback to minHeight if textView is not available
            return CGSize(width: proposal.width ?? minHeight, height: minHeight)
        }
        let textViewIntrinsicHeight = textView.intrinsicContentSize.height
        // Clamp height between minHeight and maxHeight
        let clampedHeight = max(self.minHeight, min(textViewIntrinsicHeight, self.maxHeight))
        return CGSize(width: proposal.width ?? NSView.noIntrinsicMetric, height: clampedHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self, defaultTypingAttributes: defaultTypingAttributes)
    }

    // MARK: - Custom NSTextView Subclass
    class CustomNSTextView: NSTextView {
        weak var coordinator: Coordinator?
        
        // Designated initializer
        init(coordinator: Coordinator?) {
            self.coordinator = coordinator
            // Standard setup for a new NSTextView instance programmatically
            let textStorage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            textStorage.addLayoutManager(layoutManager)
            let textContainer = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)) // Initial size, will be overridden
            textContainer.widthTracksTextView = true // Important for resizing with the scroll view
            layoutManager.addTextContainer(textContainer)
            
            super.init(frame: .zero, textContainer: textContainer)
            commonInit()
        }
        
        required init?(coder: NSCoder) {
            // This might be called if initializing from a NIB/Storyboard, but less common in pure SwiftUI
            self.coordinator = nil // Coordinator would need to be set manually if this path is taken
            super.init(coder: coder)
            commonInit()
        }
        
        private func commonInit() {
            self.isVerticallyResizable = true
            self.isHorizontallyResizable = false // Typically false for chat inputs
            self.autoresizingMask = [.width] // Resize width with superview
            self.textContainer?.lineFragmentPadding = 5 // Standard padding
            self.textContainer?.widthTracksTextView = true
            self.textContainer?.heightTracksTextView = false // Height is managed by intrinsicContentSize

            // Set min and max size for the text view itself (helps layout manager)
            self.minSize = NSSize(width: 0, height: 0) // No practical minimum for the view itself
            self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        
        override var intrinsicContentSize: NSSize {
            guard let textContainer = self.textContainer, let layoutManager = self.layoutManager else {
                return super.intrinsicContentSize
            }
            layoutManager.ensureLayout(for: textContainer) // Ensure layout is up-to-date
            let usedRect = layoutManager.usedRect(for: textContainer)
            
            // Calculate ideal height based on usedRect, considering textContainerInsets
            // The textContainerInset is applied by the NSTextView, so usedRect height should be mostly correct.
            // Add top and bottom insets.
            let idealHeight = ceil(usedRect.height + self.textContainerInset.height * 2)
            
            // Ensure the intrinsic height respects the coordinator's parent's minHeight
            let finalHeight = max(coordinator?.parent.minHeight ?? 0, idealHeight)
            
            return NSSize(width: NSView.noIntrinsicMetric, height: finalHeight) // Width is flexible
        }

        override func didChangeText() {
            super.didChangeText()
            // When text changes, invalidate intrinsic content size to trigger recalculation of height
            self.invalidateIntrinsicContentSize()
            // Also invalidate the enclosing scroll view's size if it depends on this
            self.enclosingScrollView?.invalidateIntrinsicContentSize()
            
            // Attempt to scroll to the current selection/cursor, especially useful for multi-line input
            // Needs to be on the next run loop cycle to ensure layout has updated.
            DispatchQueue.main.async {
                if self.window != nil { // Ensure the view is part of a window
                    self.scrollRangeToVisible(self.selectedRange())
                }
            }
        }

        // This override helps ensure the text container resizes correctly when the view's frame changes.
        override func setFrameSize(_ newSize: NSSize) {
            if textContainer?.widthTracksTextView == true {
                // Calculate available width for text container
                let horizontalInsets = (textContainerInset.width * 2) + (textContainer?.lineFragmentPadding ?? 0) * 2
                let containerWidth = max(0, newSize.width - horizontalInsets)
                if textContainer?.containerSize.width != containerWidth {
                    textContainer?.containerSize = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
                }
            }
            super.setFrameSize(newSize)
        }

        // Handle key down events for custom behaviors like Option-Return or Shift-Return
        override func keyDown(with event: NSEvent) {
            let suggestionsActive = coordinator?.parent.showPromptSuggestions == true || coordinator?.parent.showFileSuggestions == true

            // Option-Return: Insert newline
            if event.modifierFlags.contains(.option), event.keyCode == 36 { // 36 is Return key
                insertNewline(nil)
                return
            }
            // Shift-Return: Commit/Send
            if event.modifierFlags.contains(.shift), event.keyCode == 36 {
                coordinator?.parent.onCommit(self.attributedString())
                return
            }
            // Return: Commit/Send if suggestions are NOT active, otherwise default behavior (which might be to select suggestion)
            if event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty, event.keyCode == 36 {
                if suggestionsActive {
                    super.keyDown(with: event) // Allow suggestion view to handle Return
                } else {
                    coordinator?.parent.onCommit(self.attributedString())
                }
                return
            }
            super.keyDown(with: event) // Default handling for other keys
        }
        
        // Override mouseDown to ensure focus and standard behavior
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            // You could add custom behavior here if needed, e.g., for text selection.
        }
    }

    // MARK: - Coordinator Class
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        weak var textView: CustomNSTextView?
        weak var lastKnownTextViewInstance: CustomNSTextView? // To track if textView instance changes
        var isTyping: Bool = false // General flag for typing state
        var isProgrammaticallyChangingText: Bool = false // Critical flag to prevent update loops
        var lastProcessedInsertionID: UUID? // To avoid reprocessing insertions
        var lastProcessedInsertionString: String? // Content of last processed insertion

        let defaultTypingAttributes: [NSAttributedString.Key: Any]

        init(_ parent: CustomTextEditor, defaultTypingAttributes: [NSAttributedString.Key: Any]) {
            self.parent = parent
            self.defaultTypingAttributes = defaultTypingAttributes
        }

        func textDidBeginEditing(_ notification: Notification) {
            isTyping = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isTyping = false
            // Sync out if text changed during editing and focus is lost
            if let tv = notification.object as? NSTextView, parent.text != tv.string {
                 parent.text = tv.string // Update binding
                 parent.logger.debug("Coordinator.textDidEndEditing: Synced binding OUT. New text: \"\(tv.string.prefix(50))\"")
            }
        }
        
        // This delegate method can be used to intercept changes, but often textDidChange is sufficient.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            // Can be used for input validation, e.g., character limits, but not used here.
            return true // Allow all changes by default
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = self.textView else { // Use the weak reference to textView
                parent.logger.error("Coordinator.textDidChange: textView is nil.")
                return
            }

            // If the change was programmatic (e.g., from updateNSView syncing the binding), ignore it to prevent loops.
            if isProgrammaticallyChangingText {
                parent.logger.trace("Coordinator.textDidChange: Ignoring change as it was programmatic. TextView content: \"\(textView.string.prefix(50))\"")
                return
            }
            
            // If change was by user, update the parent's @Binding text
            let currentPlainText = textView.string
            if parent.text != currentPlainText {
                parent.text = currentPlainText // Sync binding OUT
                parent.logger.debug("Coordinator.textDidChange: User input synced binding OUT. New text: \"\(currentPlainText.prefix(50))\"")
            }

            // Handle suggestion logic based on current text and cursor position
            let currentSelectedRange = textView.selectedRange()

            // Only one suggestion type should be active at a time. File suggestions take precedence if both triggers are met.
            // Check for file mention trigger first
            if !parent.showPromptSuggestions { // If prompt suggestions are not already active
                handleFileMentionSuggestionLogic(currentText: currentPlainText, cursorPosition: currentSelectedRange.location)
            } else {
                // If prompt suggestions are active, ensure file suggestions are cleared if user types '@'
                if parent.showFileSuggestions { clearFileMentionSuggestions() }
            }

            // Then check for prompt trigger if file suggestions are not active
            if !parent.showFileSuggestions {
                handlePromptSuggestionLogic(currentText: currentPlainText, cursorPosition: currentSelectedRange.location)
            } else {
                // If file suggestions are active, ensure prompt suggestions are cleared if user types '#'
                if parent.showPromptSuggestions { clearPromptSuggestions() }
            }
            
            // Reset typing attributes if no suggestions are active and selection is empty (caret)
            if !parent.showPromptSuggestions && !parent.showFileSuggestions {
                resetTypingAttributesIfNeeded(at: currentSelectedRange, in: textView)
            }
        }
        
        private func handlePromptSuggestionLogic(currentText: String, cursorPosition: Int) {
            if cursorPosition > 0 {
                let charBeforeCursorIndex = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 1)
                if currentText[charBeforeCursorIndex] == "#" {
                    // Check if '#' is at the start of text or preceded by whitespace/newline
                    let isAtStartOfText = (cursorPosition - 1 == 0)
                    var isPrecededBySpaceOrNewline = false
                    if cursorPosition - 2 >= 0 {
                        let preCharIdx = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 2)
                        if currentText[preCharIdx].isWhitespace || currentText[preCharIdx].isNewline {
                            isPrecededBySpaceOrNewline = true
                        }
                    }

                    if isAtStartOfText || isPrecededBySpaceOrNewline {
                        let triggerStartLocation = cursorPosition - 1 // Location of '#'
                        // Activate suggestions if not already active for this trigger
                        if !parent.showPromptSuggestions || parent.activePromptTriggerRange?.location != triggerStartLocation {
                            let initialTriggerRange = NSRange(location: triggerStartLocation, length: 1) // Range of '#'
                            parent.logger.debug("Activating prompt suggestions. Initial triggerRange: \(NSStringFromRange(initialTriggerRange))")
                            parent.showPromptSuggestions = true
                            parent.suggestionQuery = ""      // Reset query
                            parent.activePromptTriggerRange = initialTriggerRange
                            if parent.showFileSuggestions { clearFileMentionSuggestions() } // Clear other suggestions
                        }
                        // If already active for this trigger, this call is redundant but harmless.
                        return // Exit after activating or confirming activation
                    }
                }
            }

            // If prompt suggestions are currently active, update query or deactivate
            if parent.showPromptSuggestions, let currentActiveRange = parent.activePromptTriggerRange {
                // Ensure the trigger character '#' still exists at the start of the active range
                guard currentActiveRange.location < currentText.count,
                      currentText[currentText.index(currentText.startIndex, offsetBy: currentActiveRange.location)] == "#" else {
                    clearPromptSuggestions()
                    return
                }

                // Deactivate if cursor moves before the '#'
                if cursorPosition < currentActiveRange.location {
                    clearPromptSuggestions()
                    return
                }

                // Calculate query string (text after '#')
                let queryStartLocationInText = currentActiveRange.location + 1
                let queryLength = max(0, cursorPosition - queryStartLocationInText)
                
                // Update the active range to include the query
                let newActiveRangeLength = 1 + queryLength // '#' + query
                if parent.activePromptTriggerRange?.length != newActiveRangeLength {
                     parent.activePromptTriggerRange = NSRange(location: currentActiveRange.location, length: newActiveRangeLength)
                }
                
                let query: String
                if queryLength > 0 && queryStartLocationInText + queryLength <= currentText.count {
                    let queryStartIndex = currentText.index(currentText.startIndex, offsetBy: queryStartLocationInText)
                    let queryEndIndex = currentText.index(queryStartIndex, offsetBy: queryLength)
                    query = String(currentText[queryStartIndex..<queryEndIndex])
                } else {
                    query = ""
                }

                // Deactivate if query contains space or newline (usually means user finished typing the tag)
                if query.contains(" ") || query.contains("\n") {
                    clearPromptSuggestions()
                    return
                }
                
                // Update the suggestionQuery binding
                if parent.suggestionQuery != query {
                    parent.suggestionQuery = query
                }
            } else if parent.showPromptSuggestions {
                // This case should ideally not be hit if logic above is correct, but as a fallback:
                clearPromptSuggestions()
            }
        }

        private func handleFileMentionSuggestionLogic(currentText: String, cursorPosition: Int) {
            // Similar logic to handlePromptSuggestionLogic, but for '@'
             if cursorPosition > 0 {
                let charBeforeCursorIndex = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 1)
                if currentText[charBeforeCursorIndex] == "@" {
                    let isAtStart = (cursorPosition - 1 == 0)
                    var isPrecededBySpaceOrNewline = false
                    if cursorPosition - 2 >= 0 {
                        let preCharIdx = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 2)
                        if currentText[preCharIdx].isWhitespace || currentText[preCharIdx].isNewline { isPrecededBySpaceOrNewline = true }
                    }

                    if isAtStart || isPrecededBySpaceOrNewline {
                        let triggerStartLocation = cursorPosition - 1
                        if !parent.showFileSuggestions || parent.activeFileMentionTriggerRange?.location != triggerStartLocation {
                            let initialTriggerRange = NSRange(location: triggerStartLocation, length: 1)
                            parent.logger.debug("Activating file suggestions. Initial triggerRange: \(NSStringFromRange(initialTriggerRange))")
                            parent.showFileSuggestions = true
                            parent.fileSuggestionQuery = ""
                            parent.activeFileMentionTriggerRange = initialTriggerRange
                            if parent.showPromptSuggestions { clearPromptSuggestions() } // Clear other suggestions
                        }
                        return
                    }
                }
            }

            if parent.showFileSuggestions, let currentActiveRange = parent.activeFileMentionTriggerRange {
                guard currentActiveRange.location < currentText.count,
                      currentText[currentText.index(currentText.startIndex, offsetBy: currentActiveRange.location)] == "@" else {
                    clearFileMentionSuggestions(); return
                }
                if cursorPosition < currentActiveRange.location { clearFileMentionSuggestions(); return }

                let queryStartLocationInText = currentActiveRange.location + 1
                let queryLength = max(0, cursorPosition - queryStartLocationInText)
                let newActiveRangeLength = 1 + queryLength
                if parent.activeFileMentionTriggerRange?.length != newActiveRangeLength { // Check optional directly
                     parent.activeFileMentionTriggerRange = NSRange(location: currentActiveRange.location, length: newActiveRangeLength)
                }
                
                let query: String
                if queryLength > 0 && queryStartLocationInText + queryLength <= currentText.count {
                    let queryStartIndex = currentText.index(currentText.startIndex, offsetBy: queryStartLocationInText)
                    let queryEndIndex = currentText.index(queryStartIndex, offsetBy: queryLength)
                    query = String(currentText[queryStartIndex..<queryEndIndex])
                } else { query = "" }

                if query.contains(" ") || query.contains("\n") { clearFileMentionSuggestions(); return }
                if parent.fileSuggestionQuery != query { parent.fileSuggestionQuery = query }
            } else if parent.showFileSuggestions {
                clearFileMentionSuggestions()
            }
        }
        
        // Resets typing attributes to default if the current attributes are different
        private func resetTypingAttributesIfNeeded(at range: NSRange, in textView: NSTextView) {
            // Only reset if selection is an insertion point (caret)
            if range.length == 0 {
                let currentTypingAttrs = textView.typingAttributes
                var needsReset = false
                
                let currentFont = currentTypingAttrs[.font] as? NSFont
                let defaultFont = defaultTypingAttributes[.font] as? NSFont
                let currentTextColor = currentTypingAttrs[.foregroundColor] as? NSColor
                let defaultTextColor = defaultTypingAttributes[.foregroundColor] as? NSColor

                if currentFont != defaultFont || currentTextColor != defaultTextColor {
                    needsReset = true
                }
                
                if needsReset {
                    textView.typingAttributes = defaultTypingAttributes
                    parent.logger.trace("Coordinator.resetTypingAttributesIfNeeded: Typing attributes reset to default.")
                }
            }
        }

        // Utility to clear prompt suggestion state
        func clearPromptSuggestions() {
            if parent.showPromptSuggestions || parent.activePromptTriggerRange != nil || !parent.suggestionQuery.isEmpty {
                parent.showPromptSuggestions = false
                parent.suggestionQuery = ""
                parent.activePromptTriggerRange = nil
                parent.logger.debug("Cleared prompt suggestions state.")
            }
        }

        // Utility to clear file mention suggestion state
        func clearFileMentionSuggestions() {
            if parent.showFileSuggestions || parent.activeFileMentionTriggerRange != nil || !parent.fileSuggestionQuery.isEmpty {
                parent.showFileSuggestions = false
                parent.fileSuggestionQuery = ""
                parent.activeFileMentionTriggerRange = nil
                parent.logger.debug("Cleared file mention suggestions state.")
            }
        }
    }
}

// MARK: - Preview
struct CustomTextEditor_Previews_Refactor_P2_Debug: PreviewProvider {
    // State variables for the preview
    @State static var textContent: String = "Initial text for preview"
    @State static var showPrompts: Bool = false
    @State static var promptQuery: String = ""
    @State static var promptRange: NSRange? = nil
    @State static var showFiles: Bool = false
    @State static var fileQuery: String = ""
    @State static var fileRange: NSRange? = nil
    @State static var insertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil
    
    static var previews: some View {
        VStack {
            Text("CustomTextEditor Preview (Debug Build)")
                .font(.headline)
            
            CustomTextEditor(
                text: $textContent,
                onCommit: { attrString in
                    print("Preview Commit: \(attrString.string.prefix(30))")
                    // Simulate clearing after commit for testing
                    // textContent = "" // This would test the external clear
                },
                minHeight: 40, maxHeight: 120,
                showPromptSuggestions: $showPrompts,
                suggestionQuery: $promptQuery,
                activePromptTriggerRange: $promptRange,
                showFileSuggestions: $showFiles,
                fileSuggestionQuery: $fileQuery,
                activeFileMentionTriggerRange: $fileRange,
                attributedTextInsertion: $insertionRequest,
                textViewRef: { nsTextView in
                    // Can inspect nsTextView instance here if needed for preview debugging
                }
            )
            .padding()
            .frame(width: 380, height: 120) // Increased width slightly
            .border(Color.gray)

            Text("Bound text: \"\(textContent)\"")
                .padding(.top)
            
            HStack {
                Button("Clear Text Externally") {
                    textContent = "" // This simulates ViewModel clearing the text
                }
                Button("Set Text Externally") {
                    textContent = "External Set Text from Preview Button"
                }
            }
            .padding(.top)

            Button("Insert '#TestPrompt ' at end") {
                let currentTextCount = textContent.count // Get current length of the bound text
                let rangeToReplace = NSRange(location: currentTextCount, length: 0) // Insert at end
                let attrString = NSAttributedString(string: "#TestPrompt ") // Text to insert
                // Create and assign the insertion request
                insertionRequest = .init(range: rangeToReplace, attributedString: attrString)
            }
            .padding(.top)

            // Simulate selecting a prompt (more complex interaction)
            Button("Simulate Selecting Prompt 'Example'") {
                // 1. User types "#ex"
                textContent = "Some leading text #ex" // Update bound text
                // 2. Coordinator detects "#" and sets up suggestion state
                // For preview, we manually set these as ChatInputAreaView would
                let triggerLocation = textContent.range(of: "#ex")!.lowerBound.utf16Offset(in: textContent)
                promptRange = NSRange(location: triggerLocation, length: "#ex".count) // Range of "#ex"
                showPrompts = true
                promptQuery = "ex" // Query part

                // 3. User selects "Example Prompt" which has full text "This is an Example Prompt."
                let selectedPromptFullText = "This is an Example Prompt."
                let finalAttrString = NSMutableAttributedString(string: selectedPromptFullText + " ") // Add trailing space
                
                // 4. ChatInputAreaView creates an insertionRequest
                if let rangeToReplace = promptRange { // Use the stored range of "#ex"
                     insertionRequest = CustomTextEditor.AttributedTextInsertionAction(
                        range: rangeToReplace,
                        attributedString: finalAttrString
                    )
                }
                
                // 5. ChatInputAreaView clears its suggestion UI state
                showPrompts = false
                promptQuery = ""
                // activePromptTriggerRange would be cleared by CustomTextEditor or ChatInputAreaView
            }
            .padding(.top)

        }
        .padding()
        .previewDisplayName("CustomTextEditor (Debug Logging)")
    }
}
