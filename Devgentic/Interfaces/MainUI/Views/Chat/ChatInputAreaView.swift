// Views/ChatInputAreaView.swift
import SwiftUI
import os

// Logger (Optional)
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ChatInputAreaView")

struct ChatInputAreaView: View {
    // Bindings and State passed down
    @Binding var userInput: String
    @Binding var showContextArea: Bool
    @Binding var activeContextFilePath: String?
    let isSending: Bool
    let showSettings: Bool
    var isInputFocused: FocusState<Bool>.Binding

    // Actions passed up
    let onSendMessage: () -> Void
    let onToggleContext: () -> Void

    // --- Constants for Styling ---
    private let iconSize: CGFloat = 18
    private let sendButtonSize: CGFloat = 26
    private let cornerRadiusValue: CGFloat = 12 // Used for the border
    private let minInputHeight: CGFloat = 24
    private let maxInputHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 3) { // This is the main container for the input area's content
            // --- Input Editor ---
            ZStack(alignment: .topLeading) {
                CustomTextEditor(
                    text: $userInput,
                    onCommit: onSendMessage,
                    minHeight: minInputHeight,
                    maxHeight: maxInputHeight
                )
                .padding(.top, 10)
                .padding(.bottom, 10)
                .frame(minHeight: minInputHeight, maxHeight: maxInputHeight)

                if userInput.isEmpty {
                    Text("Send a message...")
                        .font(Font.system(size: NSFont.systemFontSize))
                        .foregroundColor(SwiftUI.Color.gray)
                        .padding(.horizontal, 7)
                        .padding(.top, 14)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
            }
            .focused(isInputFocused)
            .disabled(isSending || showSettings)
            .padding(.horizontal, 10) // Padding inside the border for the text editor part
            .padding(.top, 4)         // Padding inside the border for the text editor part

            // --- Input Buttons ---
            HStack(spacing: 12) {
                Button { logger.info("Plus icon tapped") } label: {
                    Image(systemName: "plus")
                        .resizable().aspectRatio(contentMode: .fit).frame(width: iconSize, height: iconSize)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSending || showSettings)
                
                Button {
                    logger.info("Internet Search (globe) icon tapped - No functionality")
                } label: {
                    Image(systemName: "globe")
                        .resizable().aspectRatio(contentMode: .fit).frame(width: iconSize, height: iconSize)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSending || showSettings)
                
                Button(action: onToggleContext) {
                    Image(systemName: "paperclip")
                        .resizable().aspectRatio(contentMode: .fit).frame(width: iconSize, height: iconSize)
                        .foregroundColor(showContextArea ? .blue : .secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSending || showSettings)

                Spacer()

                Button { logger.info("Mic icon tapped") } label: {
                    Image(systemName: "mic.fill")
                        .resizable().aspectRatio(contentMode: .fit).frame(width: iconSize, height: iconSize)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSending || showSettings)

                Button(action: onSendMessage) {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: sendButtonSize, height: sendButtonSize)
                    } else {
                        ZStack {
                            Circle()
                                .fill(userInput.isEmpty || showSettings ? SwiftUI.Color.gray.opacity(0.3) : SwiftUI.Color.blue)
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
            .padding(.horizontal, 15) // Padding inside the border for the button row
            .padding(.bottom, 10)      // Padding inside the border for the button row

        } // End Input Area Content VStack
        // Ensure this view itself has a clear background. The wrapper will provide the visual background.
        .background(SwiftUI.Color.clear)
        // The cornerRadius here is for the overlay's shape.
        // The actual clipping of the visual background will happen on the wrapper in MainApplicationView.
        .cornerRadius(cornerRadiusValue)
        .overlay( // Draw the border
            RoundedRectangle(cornerRadius: cornerRadiusValue)
                .stroke(SwiftUI.Color.gray.opacity(0.4), lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
        // Outer padding is handled by the wrapper in MainApplicationView
    }
}

// --- Preview Provider ---
struct ChatInputAreaView_Previews: PreviewProvider {
    @FocusState static var isFocused: Bool
    @State static var text = "Single line"
    @State static var multiLineText = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8"
    @State static var showCtx = false
    @State static var ctxPath: String? = nil

    static var previews: some View {
        // This preview will show ChatInputAreaView with its clear background and border.
        // To see the floating effect, preview MainApplicationView.
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
        .padding() // Add some padding to see it against the preview background
        .background(SwiftUI.Color.purple.opacity(0.3)) // Temporary distinct preview background
        .previewDisplayName("Idle - Single Line (Standalone with Clear BG)")
        .frame(width: 400)
    }
}
