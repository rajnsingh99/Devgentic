// Views/ChatHeaderView.swift
import SwiftUI

struct ChatHeaderView: View {
    // The title of the current chat, passed from the parent view
    let chatTitle: String
    
    // Flag indicating if the "user messages only" filter is active
    let isFilterActive: Bool
    
    // Action to perform when the eye button is tapped
    let onEyeButtonTapped: () -> Void
    
    // A subtle color for the bottom border, adaptable to light/dark mode
    private var borderColor: Color {
        #if os(macOS)
        return Color(NSColor.separatorColor).opacity(0.6)
        #else
        return Color(UIColor.separator).opacity(0.6)
        #endif
    }

    var body: some View {
        HStack {
            // Chat Title on the left
            Text(chatTitle)
                .font(.headline) // Suitable font size for a header title
                .foregroundColor(.primary) // Adapts to light/dark mode
                .lineLimit(1) // Prevent title from wrapping
                .truncationMode(.tail) // Truncate if too long

            Spacer() // Pushes the title left and the button right

            // Eye icon button on the right
            Button(action: onEyeButtonTapped) {
                // Dynamically change the icon based on the filter state
                Image(systemName: isFilterActive ? "eye.slash.fill" : "eye.fill") // Using filled icons for better visibility
                    .font(.title3) // Adjust icon size if needed
            }
            .buttonStyle(.plain) // Removes default button styling
            // Change color to indicate active state (e.g., blue when active)
            .foregroundColor(isFilterActive ? .blue : .secondary)
            // Change tooltip based on state
            .help(isFilterActive ? "Show all messages" : "Show only my messages")
        }
        .padding(.horizontal) // Horizontal padding for content
        .padding(.vertical, 12) // Vertical padding (as updated per your request)
        // Optional background - uncomment if you want a blurred header background
        // .background(VisualEffectBlur(material: .headerView)) // Example material
        .overlay( // Draw the bottom border
            Rectangle()
                .frame(height: 0.5) // Thin border
                .foregroundColor(borderColor), // Use the defined border color
            alignment: .bottom
        )
    }
}

// MARK: - Preview Provider
struct ChatHeaderView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) { // Add spacing for preview clarity
            // Preview when filter is inactive
            ChatHeaderView(
                chatTitle: "Standard Conversation Title",
                isFilterActive: false,
                onEyeButtonTapped: {
                    print("Eye button tapped (filter inactive)")
                }
            )
            
            // Preview when filter is active
            ChatHeaderView(
                chatTitle: "Filtered User Messages View",
                isFilterActive: true,
                onEyeButtonTapped: {
                    print("Eye button tapped (filter active)")
                }
            )

            // Preview with a very long title
             ChatHeaderView(
                 chatTitle: "This is an Example of a Very Long Conversation Title That Needs Truncation",
                 isFilterActive: false,
                 onEyeButtonTapped: {}
             )
        }
        .padding() // Padding around the VStack for preview
        .background(Color(NSColor.windowBackgroundColor)) // Simulate window background
        .previewLayout(.sizeThatFits) // Adjust preview layout
    }
}
