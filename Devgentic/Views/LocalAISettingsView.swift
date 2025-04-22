// Views/LocalAISettingsView.swift
import SwiftUI

// MARK: - Local AI Settings Detail View
struct LocalAISettingsView: View {
    // Binding to the setting managed by the parent view
    @Binding var llmModelName: String
    // You might add other Local AI related settings here (e.g., Ollama URL if needed)
    // @State private var ollamaBaseURL: String = "http://127.0.0.1:11434" // Example

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Local AI (Ollama)")
                .font(.title2)
                .padding(.bottom, 5)

            Divider()

            HStack {
                Text("Ollama Model:")
                    .frame(width: 150, alignment: .leading) // Consistent label width
                TextField("e.g., gemma:2b", text: $llmModelName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .controlSize(.regular)

            // Example for adding Ollama URL setting later:
            /*
            HStack {
                Text("Ollama Base URL:")
                    .frame(width: 150, alignment: .leading)
                TextField("http://...", text: $ollamaBaseURL) // Use @AppStorage or pass binding
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .controlSize(.regular)
            */

            // Note: The BackendType picker might be removed or repurposed
            // if Ollama is always configured here and Agents elsewhere.
            // For now, it's still controlled by the @AppStorage variable in the main view.

            Spacer() // Push content to top
        }
    }
}

// Preview Provider
struct LocalAISettingsView_Previews: PreviewProvider {
    @State static var modelName = "gemma:latest"

    static var previews: some View {
        LocalAISettingsView(llmModelName: $modelName)
            .padding()
            .frame(width: 400)
            .previewLayout(.sizeThatFits)
    }
}
