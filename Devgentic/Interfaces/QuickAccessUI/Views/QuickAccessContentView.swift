//
//  QuickAccessContentView.swift
//  Devgentic
//
//  Created by Raj Singh on 07/05/25.


import SwiftUI

struct QuickAccessContentView: View {
    // Closure to be called to dismiss/close the panel.
    var dismiss: () -> ()
    // Closure to inform the hosting panel about height changes (expand/collapse).
    var onResize: ((CGFloat) -> Void)?
    // NEW: Closure to request panel zoom toggle.
    var onToggleZoom: (() -> Void)?

    // State variable to hold the text entered in the TextField.
    @State private var inputText: String = ""
    // State to manage if the panel is expanded to show the response.
    @State private var isExpanded: Bool = false
    // State to store the last submitted query.
    @State private var submittedQuery: String = ""
    // State to store the mock response.
    @State private var mockResponse: String = ""
    // NEW: State to track if the panel is currently "zoomed" by our button.
    @State private var isPanelZoomedToFullScreen: Bool = false


    // --- Define colors for the UI elements ---
    let panelBackgroundColor = Color.black.opacity(0.5)
    let responseBackgroundColor = Color.black.opacity(0.35)
    let iconColor = Color(white: 0.85)
    let placeholderTextColor = Color(white: 0.65)
    let textColor = Color.white
    let responseTextColor = Color(white: 0.95)
    let borderColor = Color.white.opacity(0.2)
    let expandedInputAreaContainerBackgroundColor = Color.black.opacity(0.15)
    let expandedTextFieldContainerBackgroundColor = Color.black.opacity(0.1)


    // --- Define heights and padding/margins ---
    let inputBarHeight: CGFloat = 95
    let textFieldHeight: CGFloat = 40
    let buttonRowHeight: CGFloat = 30

    let expandedViewMinHeight: CGFloat = 400
    let topBarHeight: CGFloat = 40
    let panelCornerRadius: CGFloat = 12
    let responseBoxCornerRadius: CGFloat = 8
    let expandedInputAreaContainerCornerRadius: CGFloat = 10
    let expandedTextFieldContainerCornerRadius: CGFloat = 8
    let expandedInputAreaHorizontalMargin: CGFloat = 10
    
    let contentViewMinWidth: CGFloat = 400
    let expandedInputAreaMaxAllowedWidth: CGFloat = 700


    // Main initializer - updated to include onToggleZoom
    init(dismiss: @escaping () -> (), onResize: ((CGFloat) -> Void)? = nil, onToggleZoom: (() -> Void)? = nil) {
        self.dismiss = dismiss
        self.onResize = onResize
        self.onToggleZoom = onToggleZoom
    }

    // Initializer for previews or specific states - updated
    init(dismiss: @escaping () -> (), onResize: ((CGFloat) -> Void)? = nil, onToggleZoom: (() -> Void)? = nil, isExpanded: Bool, submittedQuery: String, mockResponse: String) {
        self.dismiss = dismiss
        self.onResize = onResize
        self.onToggleZoom = onToggleZoom
        _isExpanded = State(initialValue: isExpanded)
        _inputText = State(initialValue: "")
        _submittedQuery = State(initialValue: submittedQuery)
        _mockResponse = State(initialValue: mockResponse)
    }

    // --- Main Body ---
    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                topBarView
                responseAreaView
            }
            Spacer(minLength: 0)
            
            inputAreaViewContainer
                .frame(maxWidth: isExpanded ? expandedInputAreaMaxAllowedWidth : .infinity)
                .padding(.horizontal, isExpanded ? expandedInputAreaHorizontalMargin : 0)
        }
        .frame(minWidth: contentViewMinWidth)
        .background(.ultraThinMaterial)
        .background(panelBackgroundColor)
        .cornerRadius(isExpanded ? panelCornerRadius : 20)
        .overlay(
            RoundedRectangle(cornerRadius: isExpanded ? panelCornerRadius : 20)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isExpanded ? 0.45 : 0.35),
                radius: isExpanded ? 8 : 5,
                x: 0,
                y: isExpanded ? 5 : 3)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isExpanded)
        // Also animate zoom state changes for smoother icon transition if any
        .animation(.easeInOut(duration: 0.2), value: isPanelZoomedToFullScreen)
        .onChange(of: isExpanded) { _ in // Use _ if newValue is not directly used
            let newIdealHeight = isExpanded ? expandedViewMinHeight : inputBarHeight
            onResize?(newIdealHeight)
            if !isExpanded { // If collapsing, ensure it's not considered zoomed
                isPanelZoomedToFullScreen = false
            }
        }
        .onAppear {
             let currentIdealHeight = isExpanded ? expandedViewMinHeight : inputBarHeight
             onResize?(currentIdealHeight)
        }
    }

    func submitQuery() {
        if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            submittedQuery = inputText
            mockResponse = "Mock response for: \"\(submittedQuery)\". This should ideally be added to a conversation history."
            if !isExpanded {
                isExpanded = true
            }
        }
    }
}

// --- Extracted Sub-views ---
extension QuickAccessContentView {
    @ViewBuilder
    private var topBarView: some View {
        HStack {
            Button(action: {
                if isPanelZoomedToFullScreen { // If zoomed, unzoom first then dismiss
                    onToggleZoom?()
                    isPanelZoomedToFullScreen = false
                }
                isExpanded = false;
                dismiss()
            }) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundColor(iconColor)
            }.buttonStyle(PlainButtonStyle()).padding(.leading, 12)
            
            Spacer()
            
            Button(action: {
                print("Copy tapped. Response: \(mockResponse)")
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(mockResponse, forType: .string)
                #endif
            }) {
                Image(systemName: "doc.on.doc").font(.system(size: 16, weight: .medium)).foregroundColor(iconColor)
            }.buttonStyle(PlainButtonStyle())
            
            Button(action: { print("Pin/Edit tapped") }) {
                Image(systemName: "pin").font(.system(size: 16, weight: .medium)).foregroundColor(iconColor)
            }.buttonStyle(PlainButtonStyle())

            // NEW: Zoom Toggle Button
            Button(action: {
                onToggleZoom?() // Call the closure passed from ContentPanel
                isPanelZoomedToFullScreen.toggle() // Toggle local state for icon change
            }) {
                Image(systemName: isPanelZoomedToFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(iconColor)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 12)
        }
        .frame(height: topBarHeight)
        .padding(.top, 5)
    }

    @ViewBuilder
    private var responseAreaView: some View {
        ScrollView {
            Text(mockResponse)
                .font(.system(size: 14)).foregroundColor(responseTextColor).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background( ZStack {
                        RoundedRectangle(cornerRadius: responseBoxCornerRadius).fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: responseBoxCornerRadius).fill(responseBackgroundColor)
                        RoundedRectangle(cornerRadius: responseBoxCornerRadius).stroke(borderColor.opacity(0.5), lineWidth: 0.5)
                    }
                )
                .padding(.horizontal, 15).padding(.top, 5)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    // Container view for the input area that applies conditional styling
    @ViewBuilder
    private var inputAreaViewContainer: some View {
        Group {
            if isExpanded {
                expandedInputAreaLayout
            } else {
                collapsedInputAreaLayout
            }
        }
        .padding(isExpanded ? EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10) : EdgeInsets(top: (inputBarHeight - textFieldHeight - buttonRowHeight - 5) / 2, leading: 10, bottom: (inputBarHeight - textFieldHeight - buttonRowHeight - 5) / 2, trailing: 10) )
        .background(isExpanded ? expandedInputAreaContainerBackgroundColor : Color.clear)
        .cornerRadius(isExpanded ? expandedInputAreaContainerCornerRadius : 0)
        .frame(height: isExpanded ? nil : inputBarHeight)
        .padding(.bottom, isExpanded ? 10 : 0)
    }

    // Specific layout for the expanded input area
    @ViewBuilder
    private var expandedInputAreaLayout: some View {
        VStack(spacing: 8) {
            // Row 1: Action buttons (plus, globe, telescope, hand/pointer)
            HStack {
                Button(action: { print("Plus icon tapped") }) {
                    Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle())
                Button(action: { print("Globe icon tapped") }) {
                    Image(systemName: "globe").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle())
                Button(action: { print("Telescope icon tapped") }) {
                    Image(systemName: "binoculars.fill").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle())
                Button(action: { print("Hand icon tapped") }) {
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle())
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: buttonRowHeight)

            // Row 2: TextField, Mic, Send (within its own styled container)
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if inputText.isEmpty {
                        Text("Ask anything").foregroundColor(placeholderTextColor).font(.system(size: 15)).padding(.leading, 12)
                    }
                    TextField("", text: $inputText)
                        .textFieldStyle(PlainTextFieldStyle()).foregroundColor(textColor).font(.system(size: 15))
                        .padding(.horizontal, 12)
                        .onSubmit { submitQuery() }
                }
                .frame(height: textFieldHeight)

                Button(action: { print("Mic icon tapped") }) {
                    Image(systemName: "mic.fill").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle())

                Button(action: { submitQuery() }) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20, weight: .medium))
                        .foregroundColor(inputText.isEmpty ? iconColor.opacity(0.5) : iconColor)
                }.buttonStyle(PlainButtonStyle()).disabled(inputText.isEmpty)
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .background(expandedTextFieldContainerBackgroundColor)
            .cornerRadius(expandedTextFieldContainerCornerRadius)
        }
    }

    // Specific layout for the collapsed input area
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
                Button(action: { print("Plus icon tapped") }) {
                    Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle())
                Button(action: { print("Globe icon tapped") }) {
                    Image(systemName: "globe").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle())
                Button(action: { print("Hand icon tapped") }) {
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle())
                Spacer()
                Button(action: { print("Mic icon tapped") }) {
                    Image(systemName: "mic.fill").font(.system(size: 18, weight: .medium)).foregroundColor(iconColor)
                }.buttonStyle(PlainButtonStyle())
                Button(action: { submitQuery() }) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20, weight: .medium))
                        .foregroundColor(inputText.isEmpty ? iconColor.opacity(0.5) : iconColor)
                }.buttonStyle(PlainButtonStyle()).disabled(inputText.isEmpty)
            }
            .padding(.horizontal, 12).frame(height: buttonRowHeight)
        }
    }
}

// --- Preview Provider ---
struct QuickAccessContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            QuickAccessContentView(dismiss: { print("Dismiss called") },
                        onResize: { height in print("Resizing to \(height)") },
                        onToggleZoom: { print("Toggle zoom called") }) // Added onToggleZoom for preview
                .previewDisplayName("Collapsed (Zoom Button)")
                .frame(width: 500, height: 95)
                .padding(50)
                .background(Image(systemName: "photo.fill").resizable().scaledToFill().ignoresSafeArea())

            QuickAccessContentView(dismiss: { print("Dismiss called") },
                        onResize: { height in print("Resizing to \(height)") },
                        onToggleZoom: { print("Toggle zoom called") }, // Added onToggleZoom for preview
                        isExpanded: true,
                        submittedQuery: "Hi",
                        mockResponse: "Hi there! How can I help you today?")
                .previewDisplayName("Expanded (Zoom Button)")
                .frame(width: 500, height: 400)
                .padding(50)
                .background(Image(systemName: "photo.fill").resizable().scaledToFill().ignoresSafeArea())
        }
    }
}
