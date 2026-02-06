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

    // Suggestion Bindings
    @Binding var showPromptSuggestions: Bool
    @Binding var suggestionQuery: String
    @Binding var activePromptTriggerRange: NSRange?

    @Binding var showFileSuggestions: Bool
    @Binding var fileSuggestionQuery: String
    @Binding var activeFileMentionTriggerRange: NSRange?

    @Binding var attributedTextInsertion: AttributedTextInsertionAction?
    var textViewRef: ((CustomTextEditor.CustomNSTextView?) -> Void)?
    
    var onNavigateSuggestions: ((ChatInputAreaView.SuggestionNavigationDirection) -> Void)?
    var onConfirmSuggestion: (() -> Void)?
    var onNavigateQueryHistory: ((MainApplicationViewModel.QueryNavigationDirection) -> Void)?
    var onTextManuallyChanged: (() -> Void)?

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
        textView.allowsUndo = true
        
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

                    textStorage.replaceCharacters(in: actualRangeToReplace, with: actionToProcess.attributedString)
                    let newCursorPosition = actualRangeToReplace.location + actionToProcess.attributedString.length
                    textView.setSelectedRange(NSRange(location: newCursorPosition, length: 0))
                    
                    textView.typingAttributes = defaultTypingAttributes
                    
                    if self.text != textView.string {
                        // Important: Update binding directly here to avoid loop
                        // But we are in updateNSView, so we rely on coordinator to sync back if needed,
                        // or trust that the binding update caused this.
                        // Actually, insertion updates usually come from VM, so we must sync back to binding.
                        DispatchQueue.main.async {
                            self.text = textView.string
                        }
                        textWasChangedByInsertionRequest = true
                    }
                    context.coordinator.isProgrammaticallyChangingText = false
                }
            }
        }

        // CRITICAL FIX:
        // Only update the TextView from binding if the content is actually different.
        // We added a check to ensure we don't overwrite user input if the binding is lagging.
        // Since we removed the debounce in textDidChange, 'self.text' should be up to date.
        // However, we double check to ensure we don't reset cursor position unnecessarily.
        if !textWasChangedByInsertionRequest && textView.string != self.text && !context.coordinator.isProgrammaticallyChangingText {
            
            // Safety Check: If the user is typing (active window), avoid replacing unless totally necessary
            // This prevents "fighting" the user input.
            context.coordinator.isProgrammaticallyChangingText = true
            
            let currentSelectedRange = textView.selectedRange()
            let attributedString = NSAttributedString(string: self.text, attributes: defaultTypingAttributes)
            
            // Replace contents
            textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: textView.textStorage?.length ?? 0), with: attributedString)
            
            // Attempt to restore cursor, but clamp to new length
            let newLocation = min(currentSelectedRange.location, self.text.count)
            textView.setSelectedRange(NSRange(location: newLocation, length: 0))
            
            textView.typingAttributes = defaultTypingAttributes
            textView.textColor = NSColor.textColor
            
            context.coordinator.isProgrammaticallyChangingText = false
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
            guard let textContainer = self.textContainer, let layoutManager = self.layoutManager else { return super.intrinsicContentSize }
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
            DispatchQueue.main.async { if self.window != nil { self.scrollRangeToVisible(self.selectedRange()) } }
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

        override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

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
            if event.keyCode == 126 && (isEmpty || isAtStart) { coordinator?.parent.onNavigateQueryHistory?(.up); return }
            if event.keyCode == 125 && (isEmpty || self.selectedRange().location == self.string.count) { coordinator?.parent.onNavigateQueryHistory?(.down); return }
            
            let keyCodeReturn: UInt16 = 36
            if event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty && event.keyCode == keyCodeReturn {
                coordinator?.parent.onCommit(self.attributedString())
                return
            }
            super.keyDown(with: event)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        weak var textView: CustomNSTextView?
        weak var lastKnownTextViewInstance: CustomNSTextView?
        var isTyping: Bool = false
        var isProgrammaticallyChangingText: Bool = false
        var lastProcessedInsertionID: UUID?
        var lastProcessedInsertionString: String?
        
        // Removed textUpdateWorkItem (Debouncer) to fix cursor lag/jumping issues
        // var textUpdateWorkItem: DispatchWorkItem?

        let defaultTypingAttributes: [NSAttributedString.Key: Any]

        init(_ parent: CustomTextEditor, defaultTypingAttributes: [NSAttributedString.Key: Any]) {
            self.parent = parent
            self.defaultTypingAttributes = defaultTypingAttributes
        }

        func textDidBeginEditing(_ notification: Notification) { isTyping = true }
        func textDidEndEditing(_ notification: Notification) {
            isTyping = false
            if let tv = notification.object as? NSTextView, parent.text != tv.string { parent.text = tv.string }
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool { return true }

        func textDidChange(_ notification: Notification) {
            guard let textView = self.textView else { return }
            if isProgrammaticallyChangingText { return }
            
            parent.onTextManuallyChanged?()
            let currentPlainText = textView.string
            let currentSelectedRange = textView.selectedRange()

            // FIX 1 & 3: REMOVED DEBOUNCE
            // Updating the binding immediately prevents race conditions where the parent View
            // (triggered by suggestion state changes) would re-render CustomTextEditor with "old" text,
            // causing the cursor to jump back.
            if parent.text != currentPlainText {
                parent.text = currentPlainText
            }

            // 2. Trigger Analysis using TextTriggerAnalyzer
            // This replaces the manual "if char == @" logic that was failing
            if let result = TextTriggerAnalyzer.analyze(text: currentPlainText, cursorLocation: currentSelectedRange.location) {
                switch result.type {
                case .prompt:
                    updatePromptState(result: result)
                    clearFileState() // Mutual exclusion
                case .file:
                    updateFileState(result: result)
                    clearPromptState() // Mutual exclusion
                }
            } else {
                // No active trigger found -> Clear all
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
