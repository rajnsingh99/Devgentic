// CustomTextEditor.swift
import SwiftUI
import AppKit
import os

private let customTextEditorLogger = DGLogger(category: "CustomTextEditor")

struct CustomTextEditor: NSViewRepresentable {
    // MARK: - Bindings and Properties
    @Binding var text: String
    var onCommit: (NSAttributedString) -> Void
    var minHeight: CGFloat
    var maxHeight: CGFloat

    // Suggestion Bindings
    @Binding var showPromptSuggestions: Bool
    @Binding var suggestionQuery: String
    @Binding var activePromptTriggerRange: NSRange?

    @Binding var showFileSuggestions: Bool
    @Binding var fileSuggestionQuery: String
    @Binding var activeFileMentionTriggerRange: NSRange?

    @Binding var attributedTextInsertion: AttributedTextInsertionAction?
    var textViewRef: ((CustomTextEditor.CustomNSTextView?) -> Void)?
    
    var onNavigateSuggestions: ((SuggestionNavigationDirection) -> Void)?
    var onConfirmSuggestion: (() -> Void)?
    var onNavigateQueryHistory: ((MainApplicationViewModel.QueryNavigationDirection) -> Void)?
    var onTextManuallyChanged: (() -> Void)?

    let logger = DGLogger(category: "CustomTextEditor_Input")

    struct AttributedTextInsertionAction: Equatable {
        let id = UUID()
        let range: NSRange
        let attributedString: NSAttributedString
        static func == (lhs: AttributedTextInsertionAction, rhs: AttributedTextInsertionAction) -> Bool {
            lhs.id == rhs.id
        }
    }
    
    private var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        return [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
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
        
        textView.textContainerInset = NSSize(width: 2, height: 10)
        textView.textContainer?.lineFragmentPadding = 5
        textView.typingAttributes = defaultTypingAttributes
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.allowsUndo = true
        
        // FIX: Enable layer backing to prevent ghosting/blur artifacts during SwiftUI transitions
        textView.wantsLayer = true
        
        context.coordinator.isProgrammaticallyChangingText = true
        textView.string = text
        context.coordinator.isProgrammaticallyChangingText = false
        
        let scrollView = NSScrollView()
        // FIX: Enable layer backing on ScrollView as well
        scrollView.wantsLayer = true
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        let clipView = scrollView.contentView
        clipView.drawsBackground = false
        clipView.backgroundColor = .clear
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
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CustomNSTextView else { return }
        
        if context.coordinator.lastKnownTextViewInstance !== textView {
            self.textViewRef?(textView)
            context.coordinator.lastKnownTextViewInstance = textView
        }

        var textWasChangedByInsertionRequest = false

        if let action = self.attributedTextInsertion {
            let actionToProcess = action
            // Clear the action immediately so we don't process it again
            DispatchQueue.main.async {
                if self.attributedTextInsertion == actionToProcess {
                    self.attributedTextInsertion = nil
                }
            }

            if context.coordinator.lastProcessedInsertionID != actionToProcess.id {
                context.coordinator.lastProcessedInsertionID = actionToProcess.id
                context.coordinator.lastProcessedInsertionString = actionToProcess.attributedString.string
                
                if let textStorage = textView.textStorage {
                    context.coordinator.isProgrammaticallyChangingText = true
                    
                    let validLocation = min(actionToProcess.range.location, textStorage.length)
                    let validLength = min(actionToProcess.range.length, textStorage.length - validLocation)
                    let actualRangeToReplace = NSRange(location: validLocation, length: validLength)

                    if actualRangeToReplace != actionToProcess.range {
                        customTextEditorLogger.warning("Insertion range clamped: requested \(actionToProcess.range.location)+\(actionToProcess.range.length) → actual \(validLocation)+\(validLength) (textStorage.length=\(textStorage.length))")
                    }

                    textStorage.replaceCharacters(in: actualRangeToReplace, with: actionToProcess.attributedString)
                    let newCursorPosition = actualRangeToReplace.location + actionToProcess.attributedString.length
                    textView.setSelectedRange(NSRange(location: newCursorPosition, length: 0))
                    
                    textView.typingAttributes = defaultTypingAttributes
                    
                    if self.text != textView.string {
                        // Important: Update binding directly here to avoid loop
                        DispatchQueue.main.async {
                            self.text = textView.string
                        }
                        textWasChangedByInsertionRequest = true
                    }
                    context.coordinator.isProgrammaticallyChangingText = false

                    // FIX: Programmatic textStorage replacement does not trigger
                    // didChangeText(), so the intrinsic content size cache is stale.
                    textView.invalidateIntrinsicContentSize()
                    scrollView.invalidateIntrinsicContentSize()
                }
            } else {
                customTextEditorLogger.debug("Skipped duplicate insertion request (id: \(actionToProcess.id))")
            }
        }

        // FIX: Allow update if the parent wants to CLEAR the text (text is empty),
        // even if the user is currently "typing" (which is true immediately after pressing Enter).
        let isClearing = self.text.isEmpty && !textView.string.isEmpty

        if !textWasChangedByInsertionRequest && textView.string != self.text
            && !context.coordinator.isProgrammaticallyChangingText
            && (!context.coordinator.isTyping || isClearing) {

            context.coordinator.isProgrammaticallyChangingText = true

            let currentSelectedRange = textView.selectedRange()
            let attributedString = NSAttributedString(string: self.text, attributes: defaultTypingAttributes)

            textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: textView.textStorage?.length ?? 0), with: attributedString)

            // Use UTF-16 length (NSString) for correct NSRange clamping
            let utf16Length = (self.text as NSString).length
            let newLocation = min(currentSelectedRange.location, utf16Length)
            textView.setSelectedRange(NSRange(location: newLocation, length: 0))

            textView.typingAttributes = defaultTypingAttributes
            textView.textColor = NSColor.textColor

            context.coordinator.isProgrammaticallyChangingText = false

            // FIX: Programmatic textStorage replacement does not trigger
            // didChangeText(), so the intrinsic content size cache is stale.
            textView.invalidateIntrinsicContentSize()
            scrollView.invalidateIntrinsicContentSize()
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
        /// Cached height to avoid recomputing layout on every SwiftUI query.
        /// Invalidated explicitly in `didChangeText` and `setFrameSize`.
        private var cachedIntrinsicHeight: CGFloat?

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
            if let cached = cachedIntrinsicHeight {
                return NSSize(width: NSView.noIntrinsicMetric, height: cached)
            }
            guard let textContainer = self.textContainer, let layoutManager = self.layoutManager else { return super.intrinsicContentSize }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let idealHeight = ceil(usedRect.height + self.textContainerInset.height * 2)
            let finalHeight = max(coordinator?.parent.minHeight ?? 0, idealHeight)
            cachedIntrinsicHeight = finalHeight
            return NSSize(width: NSView.noIntrinsicMetric, height: finalHeight)
        }

        override func invalidateIntrinsicContentSize() {
            cachedIntrinsicHeight = nil
            super.invalidateIntrinsicContentSize()
        }

        override func didChangeText() {
            super.didChangeText()
            self.invalidateIntrinsicContentSize()
            self.enclosingScrollView?.invalidateIntrinsicContentSize()
            // Scroll synchronously within the same layout pass to prevent
            // the timing gap where SwiftUI relays out before scroll completes.
            if self.window != nil {
                self.layoutManager?.ensureLayout(for: self.textContainer!)
                self.scrollRangeToVisible(self.selectedRange())
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            let widthChanged = self.frame.size.width != newSize.width
            super.setFrameSize(newSize)
            if widthChanged {
                invalidateIntrinsicContentSize()
                enclosingScrollView?.invalidateIntrinsicContentSize()
            }
        }

        override func paste(_ sender: Any?) {
            let pasteboard = NSPasteboard.general
            let attrs = coordinator?.parent.defaultTypingAttributes ?? [:]

            // Extract text from the best available pasteboard type
            let text: String? = {
                // 1. Plain text — most reliable, preserves Unicode emoji
                if let t = pasteboard.string(forType: .string), !t.isEmpty { return t }

                // 2. HTML — handles web sources with emoji
                if let data = pasteboard.data(forType: .html) {
                    do {
                        let attr = try NSAttributedString(
                            data: data,
                            options: [.documentType: NSAttributedString.DocumentType.html,
                                      .characterEncoding: String.Encoding.utf8.rawValue],
                            documentAttributes: nil
                        )
                        let s = attr.string.replacingOccurrences(of: "\u{FFFC}", with: "")
                        if !s.isEmpty { return s }
                    } catch {
                        customTextEditorLogger.warning("HTML paste parsing failed: \(error.localizedDescription)")
                    }
                }

                // 3. RTF — handles rich text sources
                if let data = pasteboard.data(forType: .rtf) {
                    do {
                        let attr = try NSAttributedString(
                            data: data,
                            options: [.documentType: NSAttributedString.DocumentType.rtf],
                            documentAttributes: nil
                        )
                        let s = attr.string.replacingOccurrences(of: "\u{FFFC}", with: "")
                        if !s.isEmpty { return s }
                    } catch {
                        customTextEditorLogger.warning("RTF paste parsing failed: \(error.localizedDescription)")
                    }
                }

                return nil
            }()

            guard let text, !text.isEmpty else { return }

            breakUndoCoalescing()
            let attrStr = NSAttributedString(string: text, attributes: attrs)
            insertText(attrStr, replacementRange: selectedRange())
        }

        override func keyDown(with event: NSEvent) {
            let suggestionsActive = coordinator?.parent.showPromptSuggestions == true || coordinator?.parent.showFileSuggestions == true
            
            if suggestionsActive {
                switch event.keyCode {
                case 125: coordinator?.parent.onNavigateSuggestions?(.down); return
                case 126: coordinator?.parent.onNavigateSuggestions?(.up); return
                case 36: coordinator?.parent.onConfirmSuggestion?(); return
                default: break
                }
            }
            
            let isAtStart = self.selectedRange().location == 0
            let isEmpty = self.string.isEmpty
            // Query history nav on bare Up/Down only — any modifier (shift for
            // selection extension, option for paragraph jump, etc.) must pass
            // through to AppKit's standard text-editing commands.
            let hasModifier = !event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty
            if !hasModifier && event.keyCode == 126 && (isEmpty || isAtStart) { coordinator?.parent.onNavigateQueryHistory?(.up); return }
            if !hasModifier && event.keyCode == 125 && (isEmpty || self.selectedRange().location == self.string.count) { coordinator?.parent.onNavigateQueryHistory?(.down); return }
            
            let keyCodeReturn: UInt16 = 36
            if event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty && event.keyCode == keyCodeReturn {
                // Check if we're in a list context — if so, Enter continues/terminates the list
                // instead of sending the message.
                if let textStorage = self.textStorage {
                    let action = ListFormattingEngine.handleEnterKey(
                        textStorage: textStorage,
                        selectedRange: self.selectedRange()
                    )
                    switch action {
                    case .passthrough:
                        coordinator?.parent.onCommit(self.attributedString())
                        return
                    case .continueList, .terminateList:
                        // Fall through to super.keyDown which triggers insertNewline → shouldChangeTextIn
                        super.keyDown(with: event)
                        return
                    }
                }
                coordinator?.parent.onCommit(self.attributedString())
                return
            }
            super.keyDown(with: event)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: CustomTextEditor
        weak var textView: CustomNSTextView?
        weak var lastKnownTextViewInstance: CustomNSTextView?
        var isTyping: Bool = false
        var isProgrammaticallyChangingText: Bool = false
        var lastProcessedInsertionID: UUID?
        var lastProcessedInsertionString: String?

        let defaultTypingAttributes: [NSAttributedString.Key: Any]
        let listConfig = ListFormattingEngine.Config.default

        init(_ parent: CustomTextEditor, defaultTypingAttributes: [NSAttributedString.Key: Any]) {
            self.parent = parent
            self.defaultTypingAttributes = defaultTypingAttributes
        }

        // MARK: - NSTextStorageDelegate
        // Normalize paragraph styles and apply list formatting after every edit
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            guard let font = defaultTypingAttributes[.font] as? NSFont else { return }

            let string = textStorage.string as NSString
            let fullEditedParagraphRange = string.paragraphRange(for: editedRange)

            // Process each paragraph independently for list detection
            string.enumerateSubstrings(in: fullEditedParagraphRange, options: [.byParagraphs, .substringNotRequired]) { _, paragraphRange, enclosingRange, _ in
                let targetStyle: NSParagraphStyle

                if let (_, markerRange) = ListFormattingEngine.detectListItem(in: string, paragraphRange: paragraphRange) {
                    let markerText = string.substring(with: markerRange)
                    targetStyle = ListFormattingEngine.listParagraphStyle(for: markerText, config: self.listConfig)
                } else {
                    targetStyle = ListFormattingEngine.defaultParagraphStyle(config: self.listConfig)
                }

                textStorage.addAttribute(.paragraphStyle, value: targetStyle, range: enclosingRange)

                // Enforce font uniformity — but preserve Apple Color Emoji
                // (set by fixAttributes for emoji characters before this delegate fires)
                textStorage.enumerateAttribute(.font, in: enclosingRange, options: []) { value, attrRange, _ in
                    guard let existing = value as? NSFont else {
                        textStorage.addAttribute(.font, value: font, range: attrRange)
                        return
                    }
                    if existing == font { return }
                    if existing.fontName.contains("AppleColorEmoji") { return }
                    textStorage.addAttribute(.font, value: font, range: attrRange)
                }
            }
        }

        func textDidBeginEditing(_ notification: Notification) { isTyping = true }
        func textDidEndEditing(_ notification: Notification) {
            isTyping = false
            if let tv = notification.object as? NSTextView, parent.text != tv.string { parent.text = tv.string }
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            // Intercept newlines to handle list continuation/termination
            guard let replacement = replacementString, replacement == "\n",
                  let textStorage = textView.textStorage else { return true }

            let action = ListFormattingEngine.handleEnterKey(
                textStorage: textStorage,
                selectedRange: affectedCharRange
            )

            switch action {
            case .passthrough:
                return true

            case .continueList(let insertionText):
                isProgrammaticallyChangingText = true
                let attrs = defaultTypingAttributes
                textStorage.replaceCharacters(
                    in: affectedCharRange,
                    with: NSAttributedString(string: insertionText, attributes: attrs)
                )
                let newCursorPos = affectedCharRange.location + (insertionText as NSString).length
                textView.setSelectedRange(NSRange(location: newCursorPos, length: 0))
                textView.typingAttributes = defaultTypingAttributes
                isProgrammaticallyChangingText = false
                parent.text = textView.string
                textView.didChangeText()
                return false

            case .terminateList(let paragraphRange):
                isProgrammaticallyChangingText = true
                textStorage.replaceCharacters(
                    in: paragraphRange,
                    with: NSAttributedString(string: "", attributes: defaultTypingAttributes)
                )
                textView.setSelectedRange(NSRange(location: paragraphRange.location, length: 0))
                textView.typingAttributes = defaultTypingAttributes
                isProgrammaticallyChangingText = false
                parent.text = textView.string
                textView.didChangeText()
                return false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = self.textView else { return }
            if isProgrammaticallyChangingText { return }
            
            parent.onTextManuallyChanged?()
            let currentPlainText = textView.string
            let currentSelectedRange = textView.selectedRange()

            if parent.text != currentPlainText {
                parent.text = currentPlainText
            }

            // 2. Trigger Analysis using TextTriggerAnalyzer
            if let result = TextTriggerAnalyzer.analyze(text: currentPlainText, cursorLocation: currentSelectedRange.location) {
                switch result.type {
                case .prompt:
                    updatePromptState(result: result)
                    clearFileState()
                case .file:
                    updateFileState(result: result)
                    clearPromptState()
                }
            } else {
                clearPromptState()
                clearFileState()
            }
            
            if !parent.showPromptSuggestions && !parent.showFileSuggestions {
                if currentSelectedRange.length == 0 {
                    textView.typingAttributes = defaultTypingAttributes
                }
            }
        }
        
        private func updatePromptState(result: TextTriggerAnalyzer.Result) {
            if !parent.showPromptSuggestions { parent.showPromptSuggestions = true }
            if parent.suggestionQuery != result.query { parent.suggestionQuery = result.query }
            if parent.activePromptTriggerRange != result.range { parent.activePromptTriggerRange = result.range }
        }
        
        private func updateFileState(result: TextTriggerAnalyzer.Result) {
            if !parent.showFileSuggestions { parent.showFileSuggestions = true }
            if parent.fileSuggestionQuery != result.query { parent.fileSuggestionQuery = result.query }
            if parent.activeFileMentionTriggerRange != result.range { parent.activeFileMentionTriggerRange = result.range }
        }

        private func clearPromptState() {
            if parent.showPromptSuggestions || parent.activePromptTriggerRange != nil || !parent.suggestionQuery.isEmpty {
                parent.showPromptSuggestions = false
                parent.suggestionQuery = ""
                parent.activePromptTriggerRange = nil
            }
        }

        private func clearFileState() {
            if parent.showFileSuggestions || parent.activeFileMentionTriggerRange != nil || !parent.fileSuggestionQuery.isEmpty {
                parent.showFileSuggestions = false
                parent.fileSuggestionQuery = ""
                parent.activeFileMentionTriggerRange = nil
            }
        }
    }
}
