// Onboarding/Views/OllamaModelSelectorView.swift
import SwiftUI

struct OllamaModelSelectorView: View {
    let models: [OllamaModelInfo]
    // Use a binding to a Set of selected model *names*
    @Binding var selectedModelNames: Set<String>

    var body: some View {
        VStack(alignment: .leading) {
            Text("Select Models to Download:")
                .font(.caption)
                .foregroundColor(.secondary)
            List {
                ForEach(models) { model in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.displayName)
                                .font(.headline)
                            Text(model.sizeDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        // Use a Toggle based on whether the model name is in the Set
                        Toggle("", isOn: Binding(
                            get: { selectedModelNames.contains(model.name) },
                            set: { isSelected, _ in // Use transaction if needed
                                if isSelected {
                                    selectedModelNames.insert(model.name)
                                } else {
                                    selectedModelNames.remove(model.name)
                                }
                            }
                        ))
                        .labelsHidden() // Hide the toggle label
                        .toggleStyle(.switch) // Or .checkbox for macOS 13+
                    }
                    // Add padding inside list rows if needed
                    // .padding(.vertical, 4)
                }
            }
            .listStyle(.bordered) // Add a border around the list
            // Set a frame height for the list
            .frame(height: 120) // Adjust height as needed
        }
    }
}

#Preview {
    // Example preview data
    let recommendedModels = [
        OllamaModelInfo(name: "llama3", displayName: "Llama 3", sizeDescription: "8B Instruct"),
        OllamaModelInfo(name: "codellama", displayName: "Code Llama", sizeDescription: "7B Code"),
        OllamaModelInfo(name: "phi3", displayName: "Phi-3 Mini", sizeDescription: "3.8B Instruct")
    ]
    // Use @State for the binding in the preview
    @State var selected: Set<String> = ["llama3"]

    return OllamaModelSelectorView(models: recommendedModels, selectedModelNames: $selected)
        .padding()
        .frame(width: 350)
}