// Views/ContextBarView.swift
import SwiftUI
import os

// Logger (Optional)
// private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ContextBarView")

struct ContextBarView: View {
    // Data passed down
    @Binding var activeContextFilePath: String? // Show info based on this path

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { // Allow scrolling if more contexts are added later
            HStack(spacing: 8) {
                // --- VS Code Context Container ---
                // This represents one potential context source
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right") // VS Code-like icon
                        .font(.system(size: 12)) // Smaller icon
                        .foregroundColor(.blue)
                    Text("VsCode")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.9))

                    // Display status icon based on whether a file path is active
                    if activeContextFilePath != nil {
                        Image(systemName: "doc.text.fill") // Indicate file loaded
                            .font(.system(size: 10))
                            .foregroundColor(.green.opacity(0.8))
                            // Optionally show tooltip with path on hover
                            .help(activeContextFilePath ?? "Active context file")
                    } else {
                         Image(systemName: "questionmark.circle") // Indicate nothing loaded/error
                             .font(.system(size: 10))
                             .foregroundColor(.gray)
                             .help("No active context file found")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.15)) // Slightly more prominent background
                .cornerRadius(6)
                // Add tap gesture if needed later (e.g., to show file path or switch context)
                // .onTapGesture { logger.info("VS Code context tapped. Path: \(activeContextFilePath ?? "None")") }

                // --- Add containers for other context sources here later ---
                // Example:
                // HStack { ... } .padding(...) .background(...) ...

            } // End Horizontal Stack for Contexts
            .padding(.horizontal, 8) // Padding for the scroll view content
        } // End ScrollView
        .frame(height: 28) // Fixed height for the context row
    }
}

// Preview Provider
struct ContextBarView_Previews: PreviewProvider {
    @State static var filePathActive: String? = "/Users/Shared/DemoProject/Sources/App/Controllers/UserController.swift"
    @State static var filePathInactive: String? = nil

    static var previews: some View {
        ContextBarView(activeContextFilePath: $filePathActive)
            .previewLayout(.sizeThatFits)
            .padding()
            .previewDisplayName("Context Active")

        ContextBarView(activeContextFilePath: $filePathInactive)
            .previewLayout(.sizeThatFits)
            .padding()
            .previewDisplayName("Context Inactive")
    }
}
