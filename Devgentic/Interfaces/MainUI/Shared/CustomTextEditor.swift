// CustomTextEditor.swift
import SwiftUI
import AppKit
import os

struct CustomTextEditor: NSViewRepresentable {
    // MARK: - Bindings and Properties
    @Binding var text: String // Plain text representation
    // NEW: Callback to pass the NSAttributedString when committing
    var onCommit: (NSAttributedString) -> Void
    var minHeight: CGFloat
    var maxHeight: CGFloat

    // --- Prompt Suggestion Properties ---
    @Binding var showPromptSuggestions: Bool
    @Binding var suggestionQuery: String
    @Binding var activePromptTriggerRange: NSRange?
    var onPromptTagTapped: ((UUID) -> Void)?

    // --- File Mention Suggestion Properties ---
    @Binding var showFileSuggestions: Bool
    @Binding var fileSuggestionQuery: String
    @Binding var activeFileMentionTriggerRange: NSRange?
    var onFileTagTapped: ((URL) -> Void)?

    // --- Common Attributed Text Insertion ---
    @Binding var attributedTextInsertion: AttributedTextInsertionAction?

    // NEW: Callback to expose the NSTextView instance
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
        textView.textColor = NSColor.labelColor
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
            self.attributedTextInsertion = nil

            if context.coordinator.lastProcessedInsertionID == actionToProcess.id {
                logger.warning("NSTextView: Attributed text insertion ID \(actionToProcess.id) was already processed. Skipping.")
                return
            }

            logger.debug("NSTextView: Processing attributed text insertion. ID: \(actionToProcess.id)")
            context.coordinator.lastProcessedInsertionID = actionToProcess.id
            
            if let textStorage = textView.textStorage {
                context.coordinator.isProgrammaticallyChangingText = true

                let validRangeStart = min(actionToProcess.range.location, textStorage.length)
                let validLength = min(actionToProcess.range.length, textStorage.length - validRangeStart)
                let actualRangeToReplace = NSRange(location: validRangeStart, length: validLength)

                textStorage.replaceCharacters(in: actualRangeToReplace, with: actionToProcess.attributedString)
                
                let newCursorPosition = actualRangeToReplace.location + actionToProcess.attributedString.length
                textView.setSelectedRange(NSRange(location: newCursorPosition, length: 0))
                
                textView.typingAttributes = defaultTypingAttributes
                
                context.coordinator.isProgrammaticallyChangingText = false
                
                // The textDidChange delegate method will update the plain text binding.
            } else {
                logger.error("NSTextView: textStorage is nil for attributed insertion ID: \(actionToProcess.id).")
            }
            return
        } else {
            if context.coordinator.lastProcessedInsertionID != nil {
                 context.coordinator.lastProcessedInsertionID = nil
            }
        }

        // Synchronize plain text if changed externally (e.g., programmatic clear after send)
        // This condition ensures that we only update the NSTextView from the `text` binding
        // if the change didn't originate from the NSTextView itself (isTyping) or from another
        // programmatic change within this component (isProgrammaticallyChangingText).
        if textView.string != self.text && !context.coordinator.isTyping && !context.coordinator.isProgrammaticallyChangingText {
             logger.debug("Updating NSTextView from plain text binding. Current NSTextView: \"\(textView.string.prefix(50))\", New binding value: \"\(self.text.prefix(50))\"")
             let currentSelectedRange = textView.selectedRange()
             context.coordinator.isProgrammaticallyChangingText = true
             
             // Replace the entire content of the textStorage.
             // Use textView.string.count for the length of the current string in NSTextView.
             textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: textView.string.count), with: self.text)
                                                                                                // ^^^^^ Corrected here
             context.coordinator.isProgrammaticallyChangingText = false
             
             // Try to restore selection or set to end of the new text.
             let newLocation = min(currentSelectedRange.location, self.text.count)
             textView.setSelectedRange(NSRange(location: newLocation, length: 0)) // Length 0 for cursor
             
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
                return NSSize(width: NSView.noIntrinsicMetric, height: coordinator?.parent.minHeight ?? super.intrinsicContentSize.height)
            }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let idealHeight = ceil(usedRect.height + self.textContainerInset.height * 2)
            let finalHeight = max(coordinator?.parent.minHeight ?? 0, idealHeight)
            return NSSize(width: NSView.noIntrinsicMetric, height: finalHeight)
        }

        override func didChangeText() {
            super.didChangeText()
            invalidateIntrinsicContentSize()
            enclosingScrollView?.invalidateIntrinsicContentSize()
            DispatchQueue.main.async {
                if self.window != nil {
                    self.scrollRangeToVisible(self.selectedRange())
                }
            }
        }
        
        override func setFrameSize(_ newSize: NSSize) {
            if textContainer?.widthTracksTextView == true {
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
            
            if event.modifierFlags.contains(.option), event.keyCode == 36 {
                insertNewline(nil); return
            }
            if event.modifierFlags.contains(.shift), event.keyCode == 36 {
                coordinator?.parent.onCommit(self.attributedString()); return
            }
            if event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty, event.keyCode == 36 {
                if suggestionsActive {
                    super.keyDown(with: event)
                } else {
                    coordinator?.parent.onCommit(self.attributedString())
                }
                return
            }
            super.keyDown(with: event)
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            let pointInView = self.convert(event.locationInWindow, from: nil)
            guard let layoutManager = self.layoutManager,
                  let textContainer = self.textContainer,
                  let textStorage = self.textStorage else { return }

            let charIndex = layoutManager.characterIndex(for: pointInView, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            
            if charIndex < textStorage.length {
                if let promptID = textStorage.attribute(.promptID, at: charIndex, effectiveRange: nil) as? UUID {
                    coordinator?.parent.logger.debug("Clicked on text with promptID: \(promptID.uuidString)")
                    coordinator?.promptTagTapped(with: promptID)
                    return
                }
                if let fileURL = textStorage.attribute(.devgenticFileURL, at: charIndex, effectiveRange: nil) as? URL {
                    coordinator?.parent.logger.debug("Clicked on text with devgenticFileURL: \(fileURL.path)")
                    coordinator?.fileTagTapped(with: fileURL)
                    return
                }
            }
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        weak var textView: CustomNSTextView?
        weak var lastKnownTextViewInstance: CustomNSTextView?

        var isTyping: Bool = false
        var isProgrammaticallyChangingText: Bool = false
        var lastProcessedInsertionID: UUID?
        let defaultTypingAttributes: [NSAttributedString.Key: Any]

        init(_ parent: CustomTextEditor, defaultTypingAttributes: [NSAttributedString.Key: Any]) {
            self.parent = parent
            self.defaultTypingAttributes = defaultTypingAttributes
        }

        func textDidBeginEditing(_ notification: Notification) { isTyping = true }
        func textDidEndEditing(_ notification: Notification) {
            isTyping = false
            if let tv = notification.object as? NSTextView, parent.text != tv.string {
                 parent.text = tv.string
            }
        }
        
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let textStorage = textView.textStorage else { return true }
            if replacementString?.isEmpty ?? false && affectedCharRange.length == 1 {
                let deletionLocation = affectedCharRange.location
                if deletionLocation >= 0 && deletionLocation < textStorage.length {
                    var effectiveRange = NSRange()
                    if textStorage.attribute(.promptID, at: deletionLocation, effectiveRange: &effectiveRange) != nil {
                        parent.logger.debug("Atomic deletion triggered for prompt tag at range: \(effectiveRange)")
                        performAtomicDeletion(for: effectiveRange, in: textStorage, textView: textView)
                        return false
                    }
                    effectiveRange = NSRange()
                    if textStorage.attribute(.devgenticFileURL, at: deletionLocation, effectiveRange: &effectiveRange) != nil {
                        parent.logger.debug("Atomic deletion triggered for file tag at range: \(effectiveRange)")
                        performAtomicDeletion(for: effectiveRange, in: textStorage, textView: textView)
                        return false
                    }
                }
            }
            return true
        }

        private func performAtomicDeletion(for range: NSRange, in textStorage: NSTextStorage, textView: NSTextView) {
            isProgrammaticallyChangingText = true
            textStorage.replaceCharacters(in: range, with: "")
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.typingAttributes = defaultTypingAttributes
            isProgrammaticallyChangingText = false
            parent.text = textStorage.string
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = self.textView, !isProgrammaticallyChangingText else { return }
            
            let currentPlainText = textView.string
            let currentSelectedRange = textView.selectedRange()
            
            DispatchQueue.main.async {
                if self.parent.text != currentPlainText {
                    self.parent.text = currentPlainText
                }
            }

            if !parent.showFileSuggestions {
                handlePromptSuggestionLogic(currentText: currentPlainText, cursorPosition: currentSelectedRange.location)
            } else {
                if parent.showPromptSuggestions { clearPromptSuggestions() }
            }

            if !parent.showPromptSuggestions {
                handleFileMentionSuggestionLogic(currentText: currentPlainText, cursorPosition: currentSelectedRange.location)
            } else {
                if parent.showFileSuggestions { clearFileMentionSuggestions() }
            }
            
            if !parent.showPromptSuggestions && !parent.showFileSuggestions {
                resetTypingAttributesIfNeeded(at: currentSelectedRange, in: textView)
            }
        }
        
        private func handlePromptSuggestionLogic(currentText: String, cursorPosition: Int) {
            if cursorPosition > 0 {
                let charBeforeCursorIndex = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 1)
                if currentText[charBeforeCursorIndex] == "#" {
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
                        if !parent.showPromptSuggestions || parent.activePromptTriggerRange != triggerRange {
                            parent.logger.debug("Activating prompt suggestions for '#'. Range: \(triggerRange)")
                            parent.showPromptSuggestions = true
                            parent.suggestionQuery = ""
                            parent.activePromptTriggerRange = triggerRange
                            if parent.showFileSuggestions { clearFileMentionSuggestions() }
                            return
                        }
                    }
                }
            }
            if parent.showPromptSuggestions, var activeRange = parent.activePromptTriggerRange {
                guard activeRange.location < currentText.count,
                      currentText[currentText.index(currentText.startIndex, offsetBy: activeRange.location)] == "#" else {
                    parent.logger.debug("Dismissing prompt suggestions: '#' removed or changed.")
                    clearPromptSuggestions()
                    return
                }
                if cursorPosition < activeRange.location {
                    parent.logger.debug("Dismissing prompt suggestions: Cursor moved before '#'.")
                    clearPromptSuggestions()
                    return
                }
                let queryLength = cursorPosition - (activeRange.location + 1)
                if queryLength < 0 {
                    if parent.suggestionQuery != "" { parent.suggestionQuery = "" }
                    activeRange.length = 1
                    parent.activePromptTriggerRange = activeRange
                    return
                }
                activeRange.length = queryLength + 1
                parent.activePromptTriggerRange = activeRange
                let queryStartIndex = currentText.index(currentText.startIndex, offsetBy: activeRange.location + 1)
                let queryEndIndex = currentText.index(queryStartIndex, offsetBy: queryLength)
                let query = (queryLength > 0) ? String(currentText[queryStartIndex..<queryEndIndex]) : ""
                if query.contains(" ") || query.contains("\n") {
                    parent.logger.debug("Dismissing prompt suggestions: Query contains space/newline.")
                    clearPromptSuggestions()
                    return
                }
                if parent.suggestionQuery != query {
                    parent.suggestionQuery = query
                    parent.logger.trace("Prompt suggestion query updated: '\(query)'")
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
                            if parent.showPromptSuggestions { clearPromptSuggestions() }
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
            if range.length == 0 {
                var cursorIsInsideTaggedSegment = false
                if range.location > 0 {
                    if textView.textStorage?.attribute(.promptID, at: range.location - 1, effectiveRange: nil) != nil ||
                       textView.textStorage?.attribute(.devgenticFileURL, at: range.location - 1, effectiveRange: nil) != nil {
                        cursorIsInsideTaggedSegment = true
                    }
                }
                if !cursorIsInsideTaggedSegment && range.location < textView.string.count {
                     if textView.textStorage?.attribute(.promptID, at: range.location, effectiveRange: nil) != nil ||
                        textView.textStorage?.attribute(.devgenticFileURL, at: range.location, effectiveRange: nil) != nil {
                        cursorIsInsideTaggedSegment = true
                    }
                }
                if !cursorIsInsideTaggedSegment {
                    let currentTypingAttrs = textView.typingAttributes
                    var needsReset = false
                    if currentTypingAttrs[.promptID] != nil || currentTypingAttrs[.devgenticFileURL] != nil {
                        needsReset = true
                    } else if (currentTypingAttrs[.font] as? NSFont) != (defaultTypingAttributes[.font] as? NSFont) {
                        needsReset = true
                    } else if (currentTypingAttrs[.foregroundColor] as? NSColor) != (defaultTypingAttributes[.foregroundColor] as? NSColor) {
                        needsReset = true
                    }
                    if needsReset {
                        textView.typingAttributes = defaultTypingAttributes
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

        func fileTagTapped(with url: URL) {
            parent.logger.debug("Coordinator: File tag tapped with URL: \(url.path)")
            parent.onFileTagTapped?(url)
        }
    }
}

// MARK: - Preview
struct CustomTextEditor_Previews_Phase5_Corrected: PreviewProvider { // Renamed preview struct
    @State static var textContent: String = "Test #SampleTag and @FileMention.txt here."
    @State static var showPrompts: Bool = false
    @State static var promptQuery: String = ""
    @State static var promptRange: NSRange? = nil
    @State static var showFiles: Bool = false
    @State static var fileQuery: String = ""
    @State static var fileRange: NSRange? = nil
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
            showFileSuggestions: $showFiles,
            fileSuggestionQuery: $fileQuery,
            activeFileMentionTriggerRange: $fileRange,
            onFileTagTapped: { url in print("Tapped file: \(url)") },
            attributedTextInsertion: $insertionRequest,
            textViewRef: { nsTextView in
                print("NSTextView instance received in preview: \(nsTextView != nil)")
            }
        )
        .padding()
        .frame(width: 350, height: 100)
        .previewDisplayName("CustomTextEditor with Attributed Commit (Corrected)")
    }
}
