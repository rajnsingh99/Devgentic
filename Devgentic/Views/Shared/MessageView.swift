//// Views/MessageView.swift
//import SwiftUI
//
//// MARK: - Message View Helper
//struct MessageView: View {
//    let message: String
//    let isUser: Bool
//
//    // Determine if the message is from the user based on the prefix
//    init(message: String) {
//        self.message = message
//        self.isUser = message.starts(with: "You:")
//    }
//
//    var body: some View {
//        // Determine prefix length to remove ("You: " or "Agent: ")
//        let prefixLength = isUser ? 4 : (message.starts(with: "Agent:") ? 6 : 0)
//        // Get the actual message content, removing prefix and trimming whitespace
//        let displayText = message.dropFirst(prefixLength)
//            .trimmingCharacters(in: .whitespacesAndNewlines)
//
//        Text(displayText)
//            .padding(10) // Padding inside the bubble
//            // Different background colors for user vs agent
//            .background(isUser ? Color.blue.opacity(0.4) : Color.white.opacity(0.1))
//            .foregroundColor(.white) // Text color
//            .cornerRadius(10) // Rounded corners for the bubble
//            .textSelection(.enabled) // Allow users to select/copy text
//            // Set max width to prevent bubbles from becoming too wide
//            .frame(maxWidth: 500, alignment: isUser ? .trailing : .leading)
//    }
//}
//
//// Preview Provider
//struct MessageView_Previews: PreviewProvider {
//    static var previews: some View {
//        VStack(spacing: 10) {
//            MessageView(message: "You: This is a message from the user.")
//            MessageView(message: "Agent: This is a reply from the agent, which might be a bit longer to see how it wraps.")
//            MessageView(message: "You: Short.")
//            MessageView(message: "Agent: OK.")
//        }
//        .padding()
//        .background(Color.gray) // Add background to see bubbles clearly
//    }
//}
