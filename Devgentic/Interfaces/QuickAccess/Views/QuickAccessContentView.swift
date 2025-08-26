//
//  QuickAccessContentView.swift
//  Devgentic
//
//  Created by Raj Singh on 07/05/25.
//
import SwiftUI
import AppKit // For NSPasteboard

struct QuickAccessContentView: View {
    // --- Callbacks ---
    var dismiss: () -> ()
    var onResize: ((CGFloat) -> Void)?
    var onToggleZoom: (() -> Void)?

    // --- View Model ---
    // Ensure QuickAccessViewModel is initialized here.
    // If it's passed from QuickAccessPanelView, adjust accordingly.
    @StateObject private var viewModel = QuickAccessViewModel()

    // --- UI State ---
    @State private var inputText: String = ""
    @State private var isExpanded: Bool = false
    @State private var isPanelZoomedToFullScreen: Bool = false

    // --- Styling Constants ---
    let panelBackgroundColor = Color.black.opacity(0.5)
    let iconColor = Color(white: 0.85)
    let placeholderTextColor = Color(white: 0.65)
    let textColor = Color.white
    let borderColor = Color.white.opacity(0.2)
    let expandedInputAreaContainerBackgroundColor = Color.black.opacity(0.15)
    let expandedTextFieldContainerBackgroundColor = Color.black.opacity(0.1)
    let inputBarHeight: CGFloat = 95
    let textFieldHeight: CGFloat = 40
    let buttonRowHeight: CGFloat = 30
    let expandedViewMinHeight: CGFloat = 400
    let topBarHeight: CGFloat = 40
    let panelCornerRadius: CGFloat = 12
    let expandedInputAreaContainerCornerRadius: CGFloat = 10
    let expandedTextFieldContainerCornerRadius: CGFloat = 8
    let expandedInputAreaHorizontalMargin: CGFloat = 10
    let contentViewMinWidth: CGFloat = 400
    let expandedInputAreaMaxAllowedWidth: CGFloat = 700

    init(dismiss: @escaping () -> (), onResize: ((CGFloat) -> Void)? = nil, onToggleZoom: (() -> Void)? = nil) {
        self.dismiss = dismiss
        self.onResize = onResize
        self.onToggleZoom = onToggleZoom
    }

    init(dismiss: @escaping () -> (), onResize: ((CGFloat) -> Void)? = nil, onToggleZoom: (() -> Void)? = nil, isExpanded: Bool) {
        self.dismiss = dismiss
        self.onResize = onResize
        self.onToggleZoom = onToggleZoom
        _isExpanded = State(initialValue: isExpanded)
        _inputText = State(initialValue: "")
    }

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                topBarView
//                chatHistoryAreaView
            }
            Spacer(minLength: 0)
            inputAreaViewContainer
                .frame(maxWidth: isExpanded ? expandedInputAreaMaxAllowedWidth : .infinity)
                .padding(.horizontal, isExpanded ? expandedInputAreaHorizontalMargin : 0)
        }
        .frame(minWidth: contentViewMinWidth)
        .background(.ultraThinMaterial)
        .cornerRadius(isExpanded ? panelCornerRadius : 20)
        .overlay(
            RoundedRectangle(cornerRadius: isExpanded ? panelCornerRadius : 20)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isExpanded ? 0.45 : 0.35),
                radius: isExpanded ? 8 : 5, x: 0, y: isExpanded ? 5 : 3)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isExpanded)
        .animation(.easeInOut(duration: 0.2), value: isPanelZoomedToFullScreen)
        .onChange(of: isExpanded) { newValue in
            let newIdealHeight = newValue ? expandedViewMinHeight : inputBarHeight
            onResize?(newIdealHeight)
            if !newValue {
                isPanelZoomedToFullScreen = false
            }
        }
        .onAppear {
             let currentIdealHeight = isExpanded ? expandedViewMinHeight : inputBarHeight
             onResize?(currentIdealHeight)
        }
    }

    func submitQuery() {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            viewModel.submitQuery(query: query)
            inputText = ""
            if !isExpanded {
                isExpanded = true
            }
        }
    }
}

extension QuickAccessContentView {
    
    @ViewBuilder
    private var topBarView: some View {
        HStack {
            Button(action: {
                if isPanelZoomedToFullScreen {
                    onToggleZoom?()
                    isPanelZoomedToFullScreen = false
                }
                isExpanded = false;
                dismiss()
            }) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundColor(iconColor)
            }.buttonStyle(PlainButtonStyle()).padding(.leading, 12)
            
            Spacer()
            
            Button(action: { copyLastMessageToClipboard() }) {
                Image(systemName: "doc.on.doc").font(.system(size: 16, weight: .medium)).foregroundColor(iconColor)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(viewModel.messages.isEmpty)
            .help("Copy last message")
            
            // --- NEW CHAT BUTTON ---
            Button(action: {
                viewModel.startNewChatSession() // Calls the updated ViewModel method
                inputText = "" // Optionally clear input text as well
            }) {
                Image(systemName: "plus.message.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(iconColor)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Start New Chat Session")
            // --- END NEW CHAT BUTTON ---

            Button(action: {
                onToggleZoom?()
                isPanelZoomedToFullScreen.toggle()
            }) {
                Image(systemName: isPanelZoomedToFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(iconColor)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 12)
            .help(isPanelZoomedToFullScreen ? "Exit Full Screen" : "Enter Full Screen")
        }
        .frame(height: topBarHeight)
        .padding(.top, 5)
    }

//    @ViewBuilder
//    private var chatHistoryAreaView: some View {
//        ScrollViewReader { scrollProxy in
//             ChatHistoryView( // Assuming ChatHistoryView is defined elsewhere
//                 messages: viewModel.messages,
//                 isSending: viewModel.isSending,
//                 hasSelectedConversation: true
//             )
//             .frame(maxWidth: .infinity, maxHeight: .infinity)
//             .padding(.horizontal)
//             .padding(.top, 5)
//             .onChange(of: viewModel.messages) { _ in scrollToBottom(scrollProxy: scrollProxy) }
//             .onChange(of: viewModel.isSending) { _ in scrollToBottom(scrollProxy: scrollProxy) }
//        }
//        .frame(minHeight: 0, maxHeight: .infinity)
//    }

    @ViewBuilder
    private var inputAreaViewContainer: some View {
        Group {
            if isExpanded { expandedInputAreaLayout }
            else { collapsedInputAreaLayout }
        }
        .padding(isExpanded ? EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10) : EdgeInsets(top: (inputBarHeight - textFieldHeight - buttonRowHeight - 5) / 2, leading: 10, bottom: (inputBarHeight - textFieldHeight - buttonRowHeight - 5) / 2, trailing: 10) )
        .background(isExpanded ? expandedInputAreaContainerBackgroundColor : Color.clear)
        .cornerRadius(isExpanded ? expandedInputAreaContainerCornerRadius : 0)
        .frame(height: isExpanded ? nil : inputBarHeight)
        .padding(.bottom, isExpanded ? 10 : 0)
    }

    @ViewBuilder
    private var expandedInputAreaLayout: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: { print("Attach File (Not Implemented)") }) {
                    Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle()).help("Attach File (Not Implemented)")
                Button(action: { print("Web Search (Not Implemented)") }) {
                    Image(systemName: "globe").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle()).help("Web Search (Not Implemented)")
                Button(action: { print("Explore (Not Implemented)") }) {
                    Image(systemName: "binoculars.fill").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle()).help("Explore (Not Implemented)")
                Button(action: { print("Select Mode (Not Implemented)") }) {
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle()).help("Select Mode (Not Implemented)")
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: buttonRowHeight)

            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if inputText.isEmpty {
                        Text("Ask anything").foregroundColor(placeholderTextColor).font(.system(size: 15)).padding(.leading, 12)
                    }
                    TextField("", text: $inputText, axis: .vertical)
                        .textFieldStyle(PlainTextFieldStyle()).foregroundColor(textColor).font(.system(size: 15))
                        .lineLimit(1...5)
                        .padding(.horizontal, 12)
                        .onSubmit { submitQuery() }
                }
                .frame(minHeight: textFieldHeight)

                Button(action: { print("Voice Input (Not Implemented)") }) {
                    Image(systemName: "mic.fill").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle()).help("Voice Input (Not Implemented)")

                Button(action: { submitQuery() }) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20, weight: .medium))
                        .foregroundColor(inputText.isEmpty ? iconColor.opacity(0.5) : iconColor)
                }.buttonStyle(PlainButtonStyle()).disabled(inputText.isEmpty).help("Send")
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .background(expandedTextFieldContainerBackgroundColor)
            .cornerRadius(expandedTextFieldContainerCornerRadius)
        }
    }

    @ViewBuilder
    private var collapsedInputAreaLayout: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .leading) {
                if inputText.isEmpty {
                    Text("Ask anything").foregroundColor(placeholderTextColor).font(.system(size: 15)).padding(.horizontal, 12)
                }
                TextField("", text: $inputText)
                    .textFieldStyle(PlainTextFieldStyle()).foregroundColor(textColor).font(.system(size: 15))
                    .padding(.horizontal, 12).frame(height: textFieldHeight)
                    .onSubmit { submitQuery() }
            }
            HStack {
                Button(action: { print("Attach File (Not Implemented)") }) {
                    Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle()).help("Attach File (Not Implemented)")
                Button(action: { print("Web Search (Not Implemented)") }) {
                    Image(systemName: "globe").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle()).help("Web Search (Not Implemented)")
                Button(action: { print("Select Mode (Not Implemented)") }) {
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle()).help("Select Mode (Not Implemented)")
                Spacer()
                Button(action: { print("Voice Input (Not Implemented)") }) {
                    Image(systemName: "mic.fill").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle()).help("Voice Input (Not Implemented)")
                Button(action: { submitQuery() }) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20, weight: .medium))
                        .foregroundColor(inputText.isEmpty ? iconColor.opacity(0.5) : iconColor)
                }.buttonStyle(PlainButtonStyle()).disabled(inputText.isEmpty).help("Send")
            }
            .padding(.horizontal, 12).frame(height: buttonRowHeight)
        }
    }
    
    private func copyLastMessageToClipboard() {
        guard let lastMessage = viewModel.messages.last else { return }
        var textToCopy = ""
        switch lastMessage.content {
        case .plainText(let text), .markdownText(let text): textToCopy = text
        case .codeBlock(_, let code): textToCopy = code
        case .error(_, let details): textToCopy = details
        case .image(let url, let alt, _): textToCopy = url?.absoluteString ?? alt ?? "Image"
        }
        if !textToCopy.isEmpty {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(textToCopy, forType: .string)
            #endif
        }
    }
    
    private func scrollToBottom(scrollProxy: ScrollViewProxy) {
        guard !viewModel.messages.isEmpty else { return }
        let lastMessageID = viewModel.messages.last?.id
        let targetID: AnyHashable? = viewModel.isSending ? "thinkingIndicator" : lastMessageID
        
        if let id = targetID {
            withAnimation(.easeOut(duration: 0.2)) {
                scrollProxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}

struct QuickAccessContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            QuickAccessContentView(
                dismiss: { print("Dismiss called") },
                onResize: { height in print("Resizing to \(height)") },
                onToggleZoom: { print("Toggle zoom called") }
            )
            .previewDisplayName("Collapsed")
            .frame(width: 500, height: 95)
            .padding(50)
            .background(Color.gray)

            QuickAccessContentView(
                dismiss: { print("Dismiss called") },
                onResize: { height in print("Resizing to \(height)") },
                onToggleZoom: { print("Toggle zoom called") },
                isExpanded: true
            )
            .previewDisplayName("Expanded (Empty History)")
            .frame(width: 500, height: 400)
            .padding(50)
            .background(Color.gray)
        }
    }
}
