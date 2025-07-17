// Views/Messages/ErrorMessageView.swift (Example location)
import SwiftUI

struct ErrorMessageView: View {
    let title: String?
    let details: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.title3)
                .foregroundColor(.red)
                .padding(.top, 2) // Align icon nicely with text

            VStack(alignment: .leading, spacing: 3) {
                if let title = title, !title.isEmpty {
                    Text(title)
                        .font(.headline)
                        .bold()
                        // Use .primary to adapt to light/dark, maybe slightly red?
                        .foregroundColor(.primary.opacity(0.9))
                }
                Text(details)
                    .font(.system(size: 15)) // Increased font size for readability
                    // Use .secondary for less emphasis, but ensure readability
                    .foregroundColor(.secondary)
                    .textSelection(.enabled) // Allow copying error details
            }
            // Allow VStack to expand
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Add some internal padding within the bubble (handled by container)
        // No background needed here, container view will add it
    }
}

// MARK: - Preview Provider
struct ErrorMessageView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 15) {
            ErrorMessageView(
                title: "Connection Error",
                details: "Could not connect to the server (ollama). Check if it's running and the URL/Port is correct."
            )

            ErrorMessageView(
                title: nil, // Test without title
                details: "An unknown error occurred during processing."
            )

             ErrorMessageView(
                 title: "API Error",
                 details: "Bad server response (404)."
             )
        }
        .padding()
        // Simulate bubble appearance for preview
        .background(Color.gray.opacity(0.15))
        .cornerRadius(10)
        .frame(width: 400)
    }
}
