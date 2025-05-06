// Views/ChatInputAreaView.swift
import SwiftUI
import os

// Logger (Optional)
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ChatInputAreaView")

struct ChatInputAreaView: View {
    // Bindings and State passed down
    @Binding var userInput: String
    @Binding var showContextArea: Bool
    @Binding var activeContextFilePath: String? // To display info in ContextBarView
    let isSending: Bool
    let showSettings: Bool // To disable input when settings are open
    var isInputFocused: FocusState<Bool>.Binding // Pass down the FocusState binding

    // Actions passed up
    let onSendMessage: () -> Void
    let onToggleContext: () -> Void // Action for the paperclip button

    // --- Constants for Styling ---
    private let iconSize: CGFloat = 18
    private let sendButtonSize: CGFloat = 26
    private let cornerRadiusValue: CGFloat = 12
    // --- Define Min/Max Height Constraints ---
    private let minInputHeight: CGFloat = 24 // Minimum overall height for the text editor area
    private let maxInputHeight: CGFloat = 200 // Maximum overall height for the text editor area
    // ---------------------------------------

    var body: some View {
        VStack(spacing: 3) {
            // --- Input Editor ---
            // Use ZStack to overlay placeholder on CustomTextEditor
            ZStack(alignment: .topLeading) {
                // --- Pass min/max height to CustomTextEditor ---
                CustomTextEditor(
                    text: $userInput,
                    onCommit: onSendMessage,
                    minHeight: minInputHeight, // Pass constraint
                    maxHeight: maxInputHeight  // Pass constraint
                ).padding(.top, 10).padding(.bottom, 10)
                // --- Apply frame modifier to the ZStack ---
                // This allows the ZStack to grow/shrink based on CustomTextEditor's sizeThatFits
                .frame(minHeight: minInputHeight, maxHeight: maxInputHeight) // <<-- FRAME APPLIED HERE

                // Placeholder Text Overlay
                if userInput.isEmpty {
                    Text("Send a message...")
                        .font(Font.system(size: NSFont.systemFontSize))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 7) // Match CustomTextEditor internal horizontal padding + inset
                        .padding(.top, 14)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
            }
            .focused(isInputFocused)
            .disabled(isSending || showSettings)
            .padding(.horizontal, 10) // Padding inside the border
            .padding(.top, 4)         // Padding inside the border

            // --- Input Buttons ---
            // (Button HStack remains the same as before)
            HStack(spacing: 12) {
                // Plus Button
                Button { logger.info("Plus icon tapped") } label: {
                    Image(systemName: "plus")
                        .resizable().aspectRatio(contentMode: .fit).frame(width: iconSize, height: iconSize)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSending || showSettings)
                
                Button {
                    // No action for now, just log
                    logger.info("Internet Search (globe) icon tapped - No functionality")
                } label: {
                    Image(systemName: "globe") // Using globe icon
                        .resizable().aspectRatio(contentMode: .fit).frame(width: iconSize, height: iconSize)
                        .foregroundColor(.secondary) // Consistent styling
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSending || showSettings)
                
                // Context Button (Paperclip)
                Button(action: onToggleContext) {
                    Image(systemName: "paperclip")
                        .resizable().aspectRatio(contentMode: .fit).frame(width: iconSize, height: iconSize)
                        .foregroundColor(showContextArea ? .blue : .secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSending || showSettings)

                Spacer()

                // Mic Button
                Button { logger.info("Mic icon tapped") } label: {
                    Image(systemName: "mic.fill")
                        .resizable().aspectRatio(contentMode: .fit).frame(width: iconSize, height: iconSize)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSending || showSettings)

                // Send Button
                Button(action: onSendMessage) {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: sendButtonSize, height: sendButtonSize)
                    } else {
                        ZStack {
                            Circle()
                                .fill(userInput.isEmpty || showSettings ? Color.gray.opacity(0.3) : Color.blue)
                            Image(systemName: "arrow.up")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: sendButtonSize * 0.5, height: sendButtonSize * 0.5)
                                .foregroundColor(.white)
                        }
                        .frame(width: sendButtonSize, height: sendButtonSize)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(userInput.isEmpty || isSending || showSettings)
                .keyboardShortcut(.return, modifiers: .shift)
            }
            .padding(.horizontal, 15) // Padding inside the border
            .padding(.bottom, 10)      // Padding inside the border

        } // End Input Area VStack
        .background(.clear)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadiusValue)
                .stroke(Color.gray.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal) // Padding *around* the input area
        .padding(.bottom, 8)  // Padding *around* the input area
        // --- Use fixedSize to allow vertical expansion ---
        .fixedSize(horizontal: false, vertical: true) // <<-- REQUIRED MODIFIER
        // -------------------------------------------------
    }
}

// --- Preview Provider (Remains the same, should reflect dynamic height) ---
struct ChatInputAreaView_Previews: PreviewProvider {
    @FocusState static var isFocused: Bool
    @State static var text = "Single line" // Start with text for preview
    @State static var multiLineText = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8" // Multi-line text
    @State static var showCtx = false
    @State static var ctxPath: String? = nil

    static var previews: some View {
        VStack { // Use VStack to show multiple previews clearly
            Group {
                ChatInputAreaView(
                    userInput: $text, // Use single line text
                    showContextArea: $showCtx,
                    activeContextFilePath: $ctxPath,
                    isSending: false,
                    showSettings: false,
                    isInputFocused: $isFocused,
                    onSendMessage: { print("Preview: Send Tapped") },
                    onToggleContext: {
                        showCtx.toggle()
                        if showCtx { ctxPath = "/preview/file.swift"} else { ctxPath = nil }
                        print("Preview: Toggle Context Tapped")
                    }
                )
                .previewDisplayName("Idle - Single Line")

                ChatInputAreaView(
                    userInput: $multiLineText, // Use multi-line text
                    showContextArea: .constant(false),
                    activeContextFilePath: .constant(nil),
                    isSending: false,
                    showSettings: false,
                    isInputFocused: $isFocused,
                    onSendMessage: { },
                    onToggleContext: { }
                )
                .previewDisplayName("Idle - Multi Line")


                ChatInputAreaView(
                    userInput: .constant("Sending..."),
                    showContextArea: .constant(false),
                    activeContextFilePath: .constant(nil),
                    isSending: true, // Show sending state
                    showSettings: false,
                    isInputFocused: $isFocused,
                    onSendMessage: { },
                    onToggleContext: { }
                )
                .previewDisplayName("Sending")

                ChatInputAreaView(
                    userInput: .constant(""),
                    showContextArea: .constant(false),
                    activeContextFilePath: .constant(nil),
                    isSending: false,
                    showSettings: true, // Show settings open state (disabled)
                    isInputFocused: $isFocused,
                    onSendMessage: { },
                    onToggleContext: { }
                )
                .previewDisplayName("Settings Open (Disabled)")
            }
            .padding() // Add padding around previews
            .background(Color(nsColor: .windowBackgroundColor)) // Use window background for context
            // .previewLayout(.sizeThatFits) // Use default layout or fixed frame for VStack
        }
        .frame(width: 400) // Give VStack a frame for preview layout
    }
}
