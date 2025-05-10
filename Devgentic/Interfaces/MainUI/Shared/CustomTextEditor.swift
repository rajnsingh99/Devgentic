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

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.CustomTextEditor", category: "CustomTextEditorRefactored")

    struct AttributedTextInsertionAction: Equatable {
        let id = UUID()
        let range: NSRange
        let attributedString: NSAttributedString
        static func == (lhs: AttributedTextInsertionAction, rhs: AttributedTextInsertionAction) -> Bool {
            return lhs.id == rhs.id
        }
    }

    // MARK: - NSViewRepresentable Methods
    func makeNSView(context: Context) -> NSScrollView {
        let textView = CustomNSTextView(coordinator: context.coordinator) // Pass coordinator

        // --- TextView Configuration ---
        textView.isRichText = true
        textView.allowsImageEditing = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.drawsBackground = false // Transparent
        textView.backgroundColor = NSColor.clear // Explicitly clear
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        
        textView.textContainerInset = NSSize(width: 0, height: 3) // Padding within the text container
        textView.textContainer?.lineFragmentPadding = 5 // Standard line fragment padding

        let defaultFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.typingAttributes = [
            .font: defaultFont,
            .foregroundColor: NSColor.labelColor
        ]
        textView.delegate = context.coordinator
        
        if !text.isEmpty {
             textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        } else {
            textView.string = ""
        }
        
        // --- ScrollView Configuration ---
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView // Set the textView as the document view
        scrollView.drawsBackground = false // Transparent

        // --- Make NSClipView transparent ---
        if let clipView = scrollView.contentView as? NSClipView {
            clipView.drawsBackground = false
            clipView.backgroundColor = .clear // Be explicit
        }
        // --- End NSClipView transparency ---

        // Use modern overlay scrollers by default
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        
        context.coordinator.textView = textView // Store weak reference in coordinator

        // Initial invalidation to ensure size is calculated
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

        // Update text view content if the binding changes from outside
        if textView.string != text && !context.coordinator.isTyping {
             logger.debug("Updating NSTextView from binding. New text: \"\(text.prefix(50))\"")
             let currentSelectedRange = textView.selectedRange()
             textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: textView.string.count), with: text)
             
             if currentSelectedRange.location <= text.count {
                 textView.setSelectedRange(NSRange(location: currentSelectedRange.location, length: currentSelectedRange.length))
             } else {
                 textView.setSelectedRange(NSRange(location: text.count, length: 0))
             }
             // After programmatic text change, ensure layout and size are re-evaluated
             textView.invalidateIntrinsicContentSize()
             scrollView.invalidateIntrinsicContentSize()
        }
        
        // Handle attributed text insertion
        if let action = attributedTextInsertion {
            logger.debug("NSTextView: Received attributed text insertion. Range: \(action.range), Text: \"\(action.attributedString.string.prefix(50))\"")
            if let textStorage = textView.textStorage {
                let validRange = NSRange(location: action.range.location, length: min(action.range.length, textStorage.length - action.range.location))
                textStorage.replaceCharacters(in: validRange, with: action.attributedString)
                
                let newPlainText = textStorage.string
                DispatchQueue.main.async {
                    if self.text != newPlainText { self.text = newPlainText }
                    self.attributedTextInsertion = nil
                }
                let newCursorPosition = validRange.location + action.attributedString.length
                textView.setSelectedRange(NSRange(location: newCursorPosition, length: 0))
                textView.didChangeText() // This will trigger its own invalidations
            } else {
                logger.error("NSTextView: textStorage is nil. Cannot insert attributed text.")
                DispatchQueue.main.async { self.attributedTextInsertion = nil }
            }
        }
    }
    
    // This method is crucial for telling SwiftUI how big this NSViewRepresentable wants to be.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scrollView.documentView as? CustomNSTextView else {
            logger.error("Failed to get CustomNSTextView from scrollView in sizeThatFits.")
            return CGSize(width: proposal.width ?? minHeight, height: minHeight)
        }

        let textViewIntrinsicHeight = textView.intrinsicContentSize.height
        let clampedHeight = max(self.minHeight, min(textViewIntrinsicHeight, self.maxHeight))
        let width = proposal.width ?? NSView.noIntrinsicMetric
        
        // logger.debug("sizeThatFits: textViewIntrinsicHeight=\(textViewIntrinsicHeight, privacy: .public), clampedHeight=\(clampedHeight, privacy: .public), proposedWidth=\(String(describing: proposal.width), privacy: .public)")
        
        return CGSize(width: width, height: clampedHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Custom NSTextView Subclass
    class CustomNSTextView: NSTextView {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator?) {
            self.coordinator = coordinator
            let textStorage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            textStorage.addLayoutManager(layoutManager)
            // Initialize with a non-zero width for the container; height is flexible.
            // This width will be overridden by widthTracksTextView and the text view's frame.
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
            self.isVerticallyResizable = true
            self.isHorizontallyResizable = false
            self.autoresizingMask = [.width]

            self.textContainer?.widthTracksTextView = true
            self.textContainer?.heightTracksTextView = false
            
            // Explicitly set min and max size for the text view itself
            // This tells the AppKit layout system about its flexibility.
            self.minSize = NSSize(width: 0, height: 0) // Min height can be 0, parent minHeight handles overall component
            self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        override var intrinsicContentSize: NSSize {
            guard let textContainer = self.textContainer,
                  let layoutManager = self.layoutManager,
                  let coordinator = self.coordinator else {
                let fallbackHeight = self.coordinator?.parent.minHeight ?? super.intrinsicContentSize.height
                // coordinator?.parent.logger.error("CustomNSTextView: Missing components for intrinsicContentSize. Falling back.")
                return NSSize(width: NSView.noIntrinsicMetric, height: fallbackHeight)
            }
            
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let verticalPadding = self.textContainerInset.height * 2
            let idealHeight = ceil(usedRect.height + verticalPadding)
            let minRequiredHeight = coordinator.parent.minHeight
            let calculatedHeight = max(minRequiredHeight, idealHeight)
            
            return NSSize(width: NSView.noIntrinsicMetric, height: calculatedHeight)
        }

        override func didChangeText() {
            super.didChangeText()
            self.invalidateIntrinsicContentSize()
            // coordinator?.parent.logger.debug("CustomNSTextView: didChangeText - invalidated self.intrinsicContentSize.")
            self.enclosingScrollView?.invalidateIntrinsicContentSize()

            DispatchQueue.main.async {
                guard self.window != nil else {
                    // self.coordinator?.parent.logger.warning("CustomNSTextView: Scroll attempt skipped (no window).")
                    return
                }
                if let layoutManager = self.layoutManager, let textContainer = self.textContainer {
                    layoutManager.ensureLayout(for: textContainer)
                }
                self.scrollRangeToVisible(self.selectedRange())
            }
        }
        
        override func setFrameSize(_ newSize: NSSize) {
            if textContainer?.widthTracksTextView == true {
                let horizontalTextInset = (self.textContainerInset.width * 2) + (self.textContainer?.lineFragmentPadding ?? 0) * 2
                let containerWidth = max(0, newSize.width - horizontalTextInset)
                
                if textContainer?.containerSize.width != containerWidth {
                    textContainer?.containerSize = NSSize(width: containerWidth,
                                                         height: CGFloat.greatestFiniteMagnitude)
                }
            }
            super.setFrameSize(newSize)
        }
        
        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.contains(.option) && event.keyCode == 36 {
                // coordinator?.parent.logger.debug("CustomNSTextView: Alt+Enter for newline.")
                self.insertNewline(nil)
                return
            }
            else if event.modifierFlags.contains(.shift) && event.keyCode == 36 {
                 // coordinator?.parent.logger.debug("CustomNSTextView: Shift+Enter, committing.")
                 coordinator?.parent.onCommit()
                 return
            }
            else if event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty &&
                      event.keyCode == 36 {
                if coordinator?.parent.showPromptSuggestions == true {
                    super.keyDown(with: event)
                } else {
                    // coordinator?.parent.logger.debug("CustomNSTextView: Enter, committing.")
                    coordinator?.parent.onCommit()
                }
                return
            }
            super.keyDown(with: event)
        }
    }

    // MARK: - Coordinator Class
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        weak var textView: CustomNSTextView?
        var isTyping: Bool = false

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            isTyping = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isTyping = false
            if let tv = notification.object as? NSTextView, parent.text != tv.string {
                parent.text = tv.string
            }
        }
        
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if parent.showPromptSuggestions && replacementString == " " {
                if let currentQuery = parent.suggestionQuery as String?, !currentQuery.isEmpty {
                    // parent.logger.debug("NSTextView Delegate: Space typed after query '\(currentQuery)'. Clearing suggestions.")
                    clearSuggestions()
                }
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CustomNSTextView else { return }
            let currentText = textView.string
            
            DispatchQueue.main.async {
                 if self.parent.text != currentText {
                    self.parent.text = currentText
                 }
            }
            
            let selectedRange = textView.selectedRange()
            let cursorPosition = selectedRange.location

            if cursorPosition > 0 {
                let charBeforeCursorIndex = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 1)
                if currentText[charBeforeCursorIndex] == "#" {
                    let isAtStartOfText = (cursorPosition - 1 == 0)
                    var isPrecededBySpaceOrNewline = false
                    if cursorPosition - 2 >= 0 {
                        let charBeforeHashIndex = currentText.index(currentText.startIndex, offsetBy: cursorPosition - 2)
                        if currentText[charBeforeHashIndex].isWhitespace || currentText[charBeforeHashIndex].isNewline {
                            isPrecededBySpaceOrNewline = true
                        }
                    }
                    
                    let newPotentialTriggerRange = NSRange(location: cursorPosition - 1, length: 1)
                    if isAtStartOfText || isPrecededBySpaceOrNewline {
                        if !parent.showPromptSuggestions || parent.activePromptTriggerRange != newPotentialTriggerRange {
                            // parent.logger.debug("NSTextView Delegate: '#' detected. Activating suggestions. Range: \(newPotentialTriggerRange)")
                            parent.showPromptSuggestions = true
                            parent.suggestionQuery = ""
                            parent.activePromptTriggerRange = newPotentialTriggerRange
                            return
                        }
                    }
                }
            }

            if parent.showPromptSuggestions, var currentActiveTriggerRange = parent.activePromptTriggerRange {
                if currentActiveTriggerRange.location >= currentText.count ||
                   currentText[currentText.index(currentText.startIndex, offsetBy: currentActiveTriggerRange.location)] != "#" {
                    // parent.logger.debug("NSTextView Delegate: Active trigger '#' character missing or out of bounds. Clearing suggestions.")
                    clearSuggestions()
                    return
                }
                if cursorPosition < currentActiveTriggerRange.location {
                    // parent.logger.debug("NSTextView Delegate: Cursor moved before active trigger. Clearing suggestions.")
                    clearSuggestions()
                    return
                }

                let newQueryLength = cursorPosition - (currentActiveTriggerRange.location + 1)
                if newQueryLength < 0 {
                    clearSuggestions()
                    return
                }
                
                currentActiveTriggerRange.length = newQueryLength + 1
                parent.activePromptTriggerRange = currentActiveTriggerRange

                let queryText: String = (newQueryLength > 0) ?
                    String(currentText[currentText.index(currentText.startIndex, offsetBy: currentActiveTriggerRange.location + 1)..<currentText.index(currentText.startIndex, offsetBy: currentActiveTriggerRange.location + 1 + newQueryLength)])
                    : ""

                if queryText.contains(" ") || queryText.contains("\n") {
                    // parent.logger.debug("NSTextView Delegate: Query '\(queryText)' contains space/newline. Clearing suggestions.")
                    clearSuggestions()
                    return
                }
                
                if parent.suggestionQuery != queryText {
                    // parent.logger.debug("NSTextView Delegate: Updating suggestion query to '\(queryText)'. Active range: \(currentActiveTriggerRange)")
                    parent.suggestionQuery = queryText
                }
                return
            }

            if parent.showPromptSuggestions {
                // parent.logger.debug("NSTextView Delegate: textDidChange reached end, showPromptSuggestions was true but conditions not met. Clearing suggestions.")
                clearSuggestions()
            }
        }
        
        func clearSuggestions() {
            if parent.showPromptSuggestions || parent.activePromptTriggerRange != nil || !parent.suggestionQuery.isEmpty {
                // parent.logger.debug("NSTextView Coordinator: Clearing suggestions state.")
                parent.showPromptSuggestions = false
                parent.suggestionQuery = ""
                parent.activePromptTriggerRange = nil
            }
        }
    }
}

// MARK: - Preview
struct CustomTextEditor_Previews_RefactoredSizing: PreviewProvider {
    @State static var textContent: String = "" // Start with empty text for placeholder testing
    @State static var showSuggestions: Bool = false
    @State static var query: String = ""
    @State static var range: NSRange? = nil
    @State static var insertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil
    @FocusState static var isFocusedPreview: Bool // For testing placeholder focus condition

    static var previews: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CustomTextEditor Preview (Placeholder Test)")
                .font(.headline)
            Text("Should show 'Ask Devgentic...' placeholder when empty & not focused. MinHeight: 40, MaxHeight: 120.")
                .font(.caption)
                .padding(.bottom, 5)
            
            // Mimic ChatInputAreaView's ZStack for placeholder
            ZStack(alignment: .topLeading) {
                CustomTextEditor(
                    text: $textContent,
                    onCommit: { print("Preview Commit: \(textContent.prefix(30))") },
                    minHeight: 40,
                    maxHeight: 120,
                    showPromptSuggestions: $showSuggestions,
                    suggestionQuery: $query,
                    activePromptTriggerRange: $range,
                    attributedTextInsertion: $insertionRequest
                )
                .focused($isFocusedPreview) // Bind focus state
                .frame(minHeight: 40, maxHeight: 120) // Match how it's used
                // .fixedSize(horizontal: false, vertical: true) // This might be needed too

                if textContent.isEmpty && !isFocusedPreview {
                    Text("Ask Devgentic...")
                        .font(Font.system(size: NSFont.systemFontSize))
                        .foregroundColor(Color(NSColor.placeholderTextColor))
                        .padding(.leading, 5 + 8) // NSTextView.lineFragmentPadding + ZStack padding
                        .padding(.top, 3 + 8)    // NSTextView.textContainerInset.height + ZStack padding
                        .allowsHitTesting(false)
                }
            }
            .padding(8) // This is the padding applied in ChatInputAreaView to the ZStack's container
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.5)))
            
            Button(isFocusedPreview ? "Unfocus" : "Focus Editor") {
                 isFocusedPreview.toggle()
            }

            Divider().padding(.vertical, 5)
            Text("Raw Text Binding: '\(textContent)'").font(.caption)
            Text("Is Empty: \(textContent.isEmpty.description)").font(.caption)
            Text("Is Focused: \(isFocusedPreview.description)").font(.caption)
            ScrollView { Text(textContent).font(.caption) }.frame(height: 50)
        }
        .padding()
        .frame(width: 400)
    }
}
