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

    var body: some View {
        VStack(spacing: 6) {
            // --- Input Editor ---
            ZStack(alignment: .topLeading) {
                // Use the CustomTextEditor component
                CustomTextEditor(
                    text: $userInput,
                    onCommit: onSendMessage // Trigger send on Shift+Enter
                )

                // Placeholder Text Overlay
                if userInput.isEmpty {
                    Text(showContextArea ? "Context active. Type a message..." : "Type a message (Shift+Enter to send)...")
                        .font(Font.system(size: NSFont.systemFontSize))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 7) // Match CustomTextEditor's internal padding
                        .padding(.top, 8)       // Match CustomTextEditor's internal padding
                        .allowsHitTesting(false) // Let clicks pass through to the editor
                }
            }
            .frame(minHeight: 30, maxHeight: 120) // Allow vertical expansion
            .focused(isInputFocused) // Apply focus state
            .disabled(isSending || showSettings) // Disable when sending or settings are open

            // --- Input Buttons ---
            HStack(spacing: 10) {
                // Web Button
                Button { logger.info("Web icon tapped") } label: {
                    Image(systemName: "globe")
                        .resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSending || showSettings)

                // Plus Button
                Button { logger.info("Plus icon tapped") } label: {
                    Image(systemName: "plus")
                        .resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSending || showSettings)

                // Context Button (Paperclip)
                Button(action: onToggleContext) { // Use the passed closure
                    Image(systemName: "paperclip")
                        .resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                        .foregroundColor(showContextArea ? .blue : .white.opacity(0.7)) // Indicate active state
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSending || showSettings)

                Spacer() // Pushes Mic and Send buttons to the right

                // Mic Button
                Button { logger.info("Mic icon tapped") } label: {
                    Image(systemName: "mic.fill")
                        .resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSending || showSettings)

                // Send Button
                Button(action: onSendMessage) { // Use the passed closure
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28, height: 28) // Match button size
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .resizable().frame(width: 28, height: 28)
                            .foregroundColor(userInput.isEmpty || showSettings ? .gray : .blue) // Dim if disabled
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(userInput.isEmpty || isSending || showSettings) // Disable conditions
                .keyboardShortcut(.return, modifiers: .shift) // Also trigger on Shift+Enter (redundant with CustomTextEditor but good practice)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

        } // End Input Area VStack
        .background(Color.white.opacity(0.1)) // Background for the input area
        .cornerRadius(10)
        .padding(.horizontal) // Padding around the input area
        .padding(.bottom, 10)
    }
}

// Preview Provider
struct ChatInputAreaView_Previews: PreviewProvider {
    // Use FocusState preview helper if needed, otherwise pass .constant(false)
    @FocusState static var isFocused: Bool
    @State static var text = ""
    @State static var showCtx = false
    @State static var ctxPath: String? = nil

    static var previews: some View {
        ChatInputAreaView(
            userInput: $text,
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
        .previewLayout(.sizeThatFits)
        .previewDisplayName("Idle")

        ChatInputAreaView(
            userInput: .constant("Some message"),
            showContextArea: .constant(true),
            activeContextFilePath: .constant("/preview/file.swift"),
            isSending: false,
            showSettings: false,
            isInputFocused: $isFocused,
            onSendMessage: { },
            onToggleContext: { }
        )
        .previewLayout(.sizeThatFits)
        .previewDisplayName("With Text & Context")


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
        .previewLayout(.sizeThatFits)
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
        .previewLayout(.sizeThatFits)
        .previewDisplayName("Settings Open (Disabled)")
    }
}
