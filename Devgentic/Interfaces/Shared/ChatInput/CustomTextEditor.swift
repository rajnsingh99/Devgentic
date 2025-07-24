// CustomTextEditor.swift
import SwiftUI
import AppKit
import os

struct CustomTextEditor: NSViewRepresentable {
    // MARK: - Bindings and Properties
    @Binding var text: String
    var onCommit: (NSAttributedString) -> Void // Called when Enter is pressed (and not for suggestions)
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

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.CustomTextEditor", category: "CustomTextEditor_Input")

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
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 2),
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
        textView.textColor = NSColor.textColor
        textView.insertionPointColor = NSColor.labelColor
        textView.textContainerInset = NSSize(width: 0, height: 10)
        textView.textContainer?.lineFragmentPadding = 10
        textView.typingAttributes = defaultTypingAttributes
        textView.delegate = context.coordinator
        
        context.coordinator.isProgrammaticallyChangingText = true
        textView.string = text
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

        var textWasChangedByInsertionRequest = false

        if let action = self.attributedTextInsertion {
            let actionToProcess = action
            self.attributedTextInsertion = nil

            if context.coordinator.lastProcessedInsertionID == actionToProcess.id &&
               actionToProcess.attributedString.string == context.coordinator.lastProcessedInsertionString {
                logger.warning("NSTextView: Insertion ID \(actionToProcess.id.uuidString) with same string already processed. Skipping.")
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
                    
                    textView.typingAttributes = defaultTypingAttributes
                    
                    if self.text != textView.string {
                        self.text = textView.string
                        textWasChangedByInsertionRequest = true
                        logger.debug("NSTextView: Synced binding OUT after insertion. New text: \"\(textView.string.prefix(50))\"")
                    }
                    context.coordinator.isProgrammaticallyChangingText = false
                } else {
                    logger.error("NSTextView: textStorage is nil for insertion ID: \(actionToProcess.id.uuidString).")
                }
            }
        } else {
             if context.coordinator.lastProcessedInsertionID != nil {
                  context.coordinator.lastProcessedInsertionID = nil
                  context.coordinator.lastProcessedInsertionString = nil
             }
        }

        if !textWasChangedByInsertionRequest && textView.string != self.text && !context.coordinator.isProgrammaticallyChangingText {
            logger.debug("NSTextView: Syncing binding IN. TextView had: \"\(textView.string.prefix(50))\", Binding (now target): \"\(self.text.prefix(50))\"")
            
            let currentSelectedRange = textView.selectedRange()
            context.coordinator.isProgrammaticallyChangingText = true
            
            // --- FIX: Apply default attributes when updating text programmatically ---
            // Create an attributed string from the plain text binding, applying the desired font and color.
            let attributedString = NSAttributedString(string: self.text, attributes: defaultTypingAttributes)
            // Replace the entire contents of the text storage with our new styled string.
            textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: textView.textStorage?.length ?? 0), with: attributedString)
            
            let newLocation = self.text.isEmpty ? 0 : min(currentSelectedRange.location, self.text.count)
            textView.setSelectedRange(NSRange(location: newLocation, length: 0))
            
            let currentFont = textView.typingAttributes[.font] as? NSFont
            let defaultFont = defaultTypingAttributes[.font] as? NSFont
            let currentFgColor = textView.typingAttributes[.foregroundColor] as? NSColor
            let defaultFgColor = defaultTypingAttributes[.foregroundColor] as? NSColor

            var needsAttributeReset = false
            if currentFont != defaultFont { needsAttributeReset = true }
            if currentFgColor != defaultFgColor { needsAttributeReset = true }
            if self.text.isEmpty && !needsAttributeReset { needsAttributeReset = true }

            if needsAttributeReset {
                 textView.typingAttributes = defaultTypingAttributes
                 logger.debug("NSTextView: Reset typingAttributes after binding IN sync.")
            }
            if textView.textColor != NSColor.textColor {
                 textView.textColor = NSColor.textColor
                 logger.debug("NSTextView: Reset textColor to standard after binding IN sync.")
            }
            context.coordinator.isProgrammaticallyChangingText = false
            logger.debug("NSTextView: Finished Syncing binding IN. TextView now: \"\(textView.string.prefix(50))\"")
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

    // MARK: - Custom NSTextView Subclass
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
            self.coordinator = nil
            super.init(coder: coder)
            commonInit()
        }
        
        private func commonInit() {
            self.isVerticallyResizable = true
            self.isHorizontallyResizable = false
            self.autoresizingMask = [.width]
            self.textContainer?.lineFragmentPadding = 5
            self.textContainer?.widthTracksTextView = true
            self.textContainer?.heightTracksTextView = false
            self.minSize = NSSize(width: 0, height: 0)
            self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        
        override var intrinsicContentSize: NSSize {
            guard let textContainer = self.textContainer, let layoutManager = self.layoutManager else {
                return super.intrinsicContentSize
            }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let idealHeight = ceil(usedRect.height + self.textContainerInset.height * 2)
            let finalHeight = max(coordinator?.parent.minHeight ?? 0, idealHeight)
            return NSSize(width: NSView.noIntrinsicMetric, height: finalHeight)
        }

        override func didChangeText() {
            super.didChangeText()
            self.invalidateIntrinsicContentSize()
            self.enclosingScrollView?.invalidateIntrinsicContentSize()
            DispatchQueue.main.async {
                if self.window != nil {
                    self.scrollRangeToVisible(self.selectedRange())
                }
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            if textContainer?.widthTracksTextView == true {
                let horizontalInsets = (textContainerInset.width * 2) + (textContainer?.lineFragmentPadding ?? 0) * 2
                let containerWidth = max(0, newSize.width - horizontalInsets)
                if textContainer?.containerSize.width != containerWidth {
                    textContainer?.containerSize = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
                }
            }
            super.setFrameSize(newSize)
        }

        // Handle key down events for custom behaviors
        override func keyDown(with event: NSEvent) {
            let suggestionsActive = coordinator?.parent.showPromptSuggestions == true || coordinator?.parent.showFileSuggestions == true
            let keyCodeReturn: UInt16 = 36 // Key code for Return/Enter

            // Shift + Return: Insert newline
            if event.modifierFlags.contains(.shift) && event.keyCode == keyCodeReturn {
                coordinator?.parent.logger.debug("Shift + Enter pressed. Inserting newline.")
                insertNewline(nil)
                return // Explicitly return to prevent further processing
            }
            
            // Option + Return: Insert newline (standard macOS behavior, good to keep)
            if event.modifierFlags.contains(.option) && event.keyCode == keyCodeReturn {
                coordinator?.parent.logger.debug("Option + Enter pressed. Inserting newline.")
                insertNewline(nil)
                return // Explicitly return
            }

            // Enter (alone): Commit/Send if suggestions are NOT active
            // If suggestions ARE active, super.keyDown will handle it (e.g., selecting a suggestion)
            if event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty && event.keyCode == keyCodeReturn {
                if suggestionsActive {
                    coordinator?.parent.logger.debug("Enter pressed with suggestions active. Passing to super.")
                    super.keyDown(with: event) // Allow suggestion view to handle Return
                } else {
                    coordinator?.parent.logger.debug("Enter pressed, no suggestions. Committing.")
                    coordinator?.parent.onCommit(self.attributedString())
                }
                return // Explicitly return
            }
            
            // Default handling for all other keys/combinations
            super.keyDown(with: event)
        }
        
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
        }
    }

    // MARK: - Coordinator Class
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        weak var textView: CustomNSTextView?
        weak var lastKnownTextViewInstance: CustomNSTextView?
        var isTyping: Bool = false
        var isProgrammaticallyChangingText: Bool = false
        var lastProcessedInsertionID: UUID?
        var lastProcessedInsertionString: String?

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
            if let tv = notification.object as? NSTextView, parent.text != tv.string {
                 parent.text = tv.string
                 parent.logger.debug("Coordinator.textDidEndEditing: Synced binding OUT. New text: \"\(tv.string.prefix(50))\"")
            }
        }
        
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = self.textView else {
                parent.logger.error("Coordinator.textDidChange: textView is nil.")
                return
            }

            if isProgrammaticallyChangingText {
                parent.logger.trace("Coordinator.textDidChange: Ignoring change as it was programmatic. TextView content: \"\(textView.string.prefix(50))\"")
                return
            }
            
            let currentPlainText = textView.string
            if parent.text != currentPlainText {
                parent.text = currentPlainText
            }

            let currentSelectedRange = textView.selectedRange()

            if !parent.showPromptSuggestions {
                handleFileMentionSuggestionLogic(currentText: currentPlainText, cursorPosition: currentSelectedRange.location)
            } else {
                if parent.showFileSuggestions { clearFileMentionSuggestions() }
            }

            if !parent.showFileSuggestions {
                handlePromptSuggestionLogic(currentText: currentPlainText, cursorPosition: currentSelectedRange.location)
            } else {
                if parent.showPromptSuggestions { clearPromptSuggestions() }
            }
            
            if !parent.showPromptSuggestions && !parent.showFileSuggestions {
                resetTypingAttributesIfNeeded(at: currentSelectedRange, in: textView)
            }
        }
        
        private func handlePromptSuggestionLogic(currentText: String, cursorPosition: Int) {
            if cursorPosition > 0 {
                let charBeforeCursorIndex = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 1)
                if currentText[charBeforeCursorIndex] == "#" {
                    let isAtStartOfText = (cursorPosition - 1 == 0)
                    var isPrecededBySpaceOrNewline = false
                    if cursorPosition - 2 >= 0 {
                        let preCharIdx = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 2)
                        if currentText[preCharIdx].isWhitespace || currentText[preCharIdx].isNewline {
                            isPrecededBySpaceOrNewline = true
                        }
                    }

                    if isAtStartOfText || isPrecededBySpaceOrNewline {
                        let triggerStartLocation = cursorPosition - 1
                        if !parent.showPromptSuggestions || parent.activePromptTriggerRange?.location != triggerStartLocation {
                            let initialTriggerRange = NSRange(location: triggerStartLocation, length: 1)
                            parent.logger.debug("Activating prompt suggestions. Initial triggerRange: \(NSStringFromRange(initialTriggerRange))")
                            parent.showPromptSuggestions = true
                            parent.suggestionQuery = ""
                            parent.activePromptTriggerRange = initialTriggerRange
                            if parent.showFileSuggestions { clearFileMentionSuggestions() }
                        }
                        return
                    }
                }
            }

            if parent.showPromptSuggestions, let currentActiveRange = parent.activePromptTriggerRange {
                guard currentActiveRange.location < currentText.count,
                      currentText[currentText.index(currentText.startIndex, offsetBy: currentActiveRange.location)] == "#" else {
                    clearPromptSuggestions()
                    return
                }

                if cursorPosition < currentActiveRange.location {
                    clearPromptSuggestions()
                    return
                }

                let queryStartLocationInText = currentActiveRange.location + 1
                let queryLength = max(0, cursorPosition - queryStartLocationInText)
                
                let newActiveRangeLength = 1 + queryLength
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

                if query.contains(" ") || query.contains("\n") {
                    clearPromptSuggestions()
                    return
                }
                
                if parent.suggestionQuery != query {
                    parent.suggestionQuery = query
                }
            } else if parent.showPromptSuggestions {
                clearPromptSuggestions()
            }
        }

        private func handleFileMentionSuggestionLogic(currentText: String, cursorPosition: Int) {
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
                            if parent.showPromptSuggestions { clearPromptSuggestions() }
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
                if parent.activeFileMentionTriggerRange?.length != newActiveRangeLength {
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
        
        private func resetTypingAttributesIfNeeded(at range: NSRange, in textView: NSTextView) {
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

        func clearPromptSuggestions() {
            if parent.showPromptSuggestions || parent.activePromptTriggerRange != nil || !parent.suggestionQuery.isEmpty {
                parent.showPromptSuggestions = false
                parent.suggestionQuery = ""
                parent.activePromptTriggerRange = nil
                parent.logger.debug("Cleared prompt suggestions state.")
            }
        }

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

struct CustomTextEditor_Previews_KeyboardHandling: PreviewProvider {
    @State static var textContent: String = "Type here...\nShift+Enter for new line.\nEnter to commit."
    @State static var showPrompts: Bool = false
    @State static var promptQuery: String = ""
    @State static var promptRange: NSRange? = nil
    @State static var showFiles: Bool = false
    @State static var fileQuery: String = ""
    @State static var fileRange: NSRange? = nil
    @State static var insertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil
    
    static var previews: some View {
        VStack {
            Text("CustomTextEditor Preview (Keyboard Handling)")
                .font(.headline)
            
            CustomTextEditor(
                text: $textContent,
                onCommit: { attrString in
                    print("Preview Commit (Enter): \(attrString.string.prefix(30))")
                    // Simulate clearing after commit for testing
                    // textContent = ""
                },
                minHeight: 60, maxHeight: 150, // Increased minHeight for better preview
                showPromptSuggestions: $showPrompts,
                suggestionQuery: $promptQuery,
                activePromptTriggerRange: $promptRange,
                showFileSuggestions: $showFiles,
                fileSuggestionQuery: $fileQuery,
                activeFileMentionTriggerRange: $fileRange,
                attributedTextInsertion: $insertionRequest,
                textViewRef: { _ in }
            )
            .padding()
            .frame(width: 380, height: 150)
            .border(Color.gray)

            Text("Bound text: \"\(textContent)\"")
                .padding(.top)
        }
        .padding()
        .previewDisplayName("CustomTextEditor (Keyboard)")
    }
}
