////
////  ToolLibraryView.swift
////  Devgentic
////
////  Created by Raj Singh on 25/09/25.
////
//
//import SwiftUI
//
//// Main View for the Tool Library
//struct LocalToolLibraryView: View {
//
//    // A binding to the agent's currently configured tools.
//    // This allows the view to directly modify the agent's state.
//    @Binding var configuredTools: [Tool]
//    
//    // Environment property to dismiss the sheet.
//    @Environment(\.dismiss) private var dismiss
//
//    // State for the search text field.
//    @State private var searchText = ""
//    
//    // The complete list of tools available in the app.
//    private let allAvailableTools = LocalToolManager.shared.availableTools()
//
//    // A computed property to filter tools based on the search text.
//    private var filteredTools: [ExecutableTool] {
//        if searchText.isEmpty {
//            return allAvailableTools.sorted { $0.name < $1.name }
//        } else {
//            return allAvailableTools.filter {
//                $0.name.localizedCaseInsensitiveContains(searchText) ||
//                $0.description.localizedCaseInsensitiveContains(searchText)
//            }.sorted { $0.name < $1.name }
//        }
//    }
//
//    var body: some View {
//        VStack(spacing: 0) {
//            // Header with title and Done button
//            headerView
//            
//            // Search Bar
//            searchBarView
//                .padding(.bottom, 8)
//
//            // Main list of tools
//            List {
//                ForEach(filteredTools, id: \.name) { tool in
//                    ToolRowView(
//                        tool: tool,
//                        configuredTools: $configuredTools
//                    )
//                }
//            }
//            .listStyle(.inset(alternatesRowBackgrounds: true))
//        }
//        .frame(minWidth: 450, minHeight: 500, idealHeight: 600)
//    }
//    
//    // Reusable Header View
//    private var headerView: some View {
//        HStack {
//            Text("Tool Library")
//                .font(.title2)
//                .fontWeight(.bold)
//            
//            Spacer()
//
//            Button("Done") {
//                dismiss()
//            }
//            .buttonStyle(.borderedProminent)
//        }
//        .padding()
//        .background(Color(.windowBackgroundColor))
//    }
//    
//    // Reusable Search Bar
//    private var searchBarView: some View {
//        HStack {
//            Image(systemName: "magnifyingglass")
//                .foregroundColor(.secondary)
//            
//            TextField("Search Tools by name or description", text: $searchText)
//                .textFieldStyle(.plain)
//        }
//        .padding(.horizontal)
//        .padding(.vertical, 8)
//        .background(Color(.textBackgroundColor))
//        .cornerRadius(8)
//        .padding(.horizontal)
//    }
//}
//
//
//// A private view for displaying a single tool row in the list.
//private struct ToolRowView: View {
//    let tool: ExecutableTool
//    @Binding var configuredTools: [Tool]
//
//    // A custom binding to manage the toggle state for this specific tool.
//    private var isEnabled: Binding<Bool> {
//        Binding<Bool>(
//            get: {
//                // The tool is enabled if its name exists in the configuredTools array.
//                configuredTools.contains { $0.name == tool.name }
//            },
//            set: { isEnabled in
//                if isEnabled {
//                    // If toggled ON, add the tool if it doesn't already exist.
//                    if !configuredTools.contains(where: { $0.name == tool.name }) {
//                        let newTool = Tool(name: tool.name, description: tool.description, isEnabled: true)
//                        configuredTools.append(newTool)
//                    }
//                } else {
//                    // If toggled OFF, remove the tool from the array.
//                    configuredTools.removeAll { $0.name == tool.name }
//                }
//            }
//        )
//    }
//
//    var body: some View {
//        HStack {
//            VStack(alignment: .leading, spacing: 3) {
//                Text(tool.name)
//                    .fontWeight(.semibold)
//                Text(tool.description)
//                    .font(.caption)
//                    .foregroundColor(.secondary)
//            }
//            
//            Spacer()
//            
//            Toggle(isOn: isEnabled) {
//                // The label is empty as the text is on the leading side.
//            }
//            .labelsHidden()
//            .toggleStyle(.switch)
//        }
//        .padding(.vertical, 6)
//    }
//}
//
//// MARK: - Preview Provider
//struct LocalToolLibraryView_Previews: PreviewProvider {
//    // Create a sample binding for the preview
//    @State static var sampleTools: [Tool] = [
//        Tool(name: "execute_shell", description: "Executes a shell command.", isEnabled: true)
//    ]
//
//    static var previews: some View {
//        LocalToolLibraryView(configuredTools: $sampleTools)
//    }
//}
