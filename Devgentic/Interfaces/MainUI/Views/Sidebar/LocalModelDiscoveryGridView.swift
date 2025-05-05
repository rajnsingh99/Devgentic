// Views/Sidebar/LocalModelDiscoveryGridView.swift
import SwiftUI
import os

// Logger
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "LocalModelDiscoveryGridView")

// MARK: - Local Model Discovery Grid View
struct LocalModelDiscoveryGridView: View {
    // Access the shared ViewModel
    @EnvironmentObject var viewModel: MainApplicationViewModel

    // --- State for this view ---
    // Define a structure for discoverable models (can be expanded later)
    struct DiscoverableModel: Identifiable, Hashable {
        let id = UUID()
        let name: String // e.g., "llama3:8b"
        let description: String
        let sizeEstimate: String // e.g., "5 GB"
        // Add other potential fields: publisher, tags, etc.
    }

    // Placeholder list of models available for download
    // TODO: Replace this with dynamic fetching from Ollama or a manifest
    let discoverableModels: [DiscoverableModel] = [
        DiscoverableModel(name: "llama3:8b", description: "Meta's latest generation 8B parameter model.", sizeEstimate: "4.7 GB"),
        DiscoverableModel(name: "mistral:7b", description: "Popular 7B model known for efficiency and performance.", sizeEstimate: "4.1 GB"),
        DiscoverableModel(name: "phi3:mini", description: "Microsoft's powerful 3.8B parameter small language model.", sizeEstimate: "2.3 GB"),
        DiscoverableModel(name: "gemma:7b", description: "Google's family of lightweight, state-of-the-art open models.", sizeEstimate: "5.0 GB"),
        DiscoverableModel(name: "codellama:7b", description: "Code synthesis model based on Llama 2.", sizeEstimate: "4.1 GB"),
        DiscoverableModel(name: "llava:7b", description: "Large multimodal model connecting vision encoder and LLM.", sizeEstimate: "4.5 GB"),
        DiscoverableModel(name: "qwen:7b", description: "Alibaba Cloud's large vision language model.", sizeEstimate: "4.1 GB")
    ]

    // Grid layout definition (e.g., 2 columns, flexible width)
    let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- Status/Error Area ---
            // Display Ollama server status and connection errors
            OllamaStatusView(viewModel: viewModel)
                .padding(.horizontal)
                .padding(.bottom, 10)

            // Display general pull/remove errors that might occur
            if let pullError = viewModel.modelPullError {
                Text("Error: \(pullError)")
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .padding(.bottom, 5)
            }
            if let removeError = viewModel.modelRemoveError {
                Text("Removal Error: \(removeError)")
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .padding(.bottom, 5)
            }
            // --- End Status/Error Area ---


            // --- Scrollable Grid ---
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(discoverableModels) { model in
                        ModelCardView(
                            model: model,
                            viewModel: viewModel // Pass ViewModel for status checks/actions
                        )
                    }
                }
                .padding() // Padding around the grid
            }
            // --- End Scrollable Grid ---
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Clear status messages when the view disappears
        .onDisappear {
            viewModel.clearModelActionStatus()
        }
        // Check server status when the view appears if needed (or rely on tab selection logic)
        .onAppear {
             // Clear any lingering status from other tabs
             viewModel.clearModelActionStatus()
             // Optionally trigger a status check if not connected
             if viewModel.selectedBackend == .ollama && viewModel.ollamaServerStatus != .connected {
                  Task {
                       await viewModel.checkOllamaServerStatus()
                  }
             }
        }
    }
}

// MARK: - Ollama Status View Helper
struct OllamaStatusView: View {
    @ObservedObject var viewModel: MainApplicationViewModel

    var body: some View {
        HStack {
            // Display status icon and text
            Image(systemName: viewModel.ollamaServerStatus.systemImageName)
                .foregroundColor(viewModel.ollamaServerStatus.color)
            Text("Ollama Status: \(viewModel.ollamaServerStatus.description)")
                .font(.callout)

            Spacer()

            // Button to manually refresh status if disconnected or errored
            if viewModel.ollamaServerStatus == .disconnected || viewModel.ollamaServerStatus == .error {
                Button {
                    Task {
                        await viewModel.checkOllamaServerStatus()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Retry Connection")
                .disabled(viewModel.ollamaServerStatus == .checking) // Disable while checking
            } else if viewModel.ollamaServerStatus == .checking {
                 ProgressView().controlSize(.small) // Show spinner while checking
            }
        }
    }
}


// MARK: - Model Card View
/// Displays information and actions for a sngle discoverable model.
struct ModelCardView: View {
    let model: LocalModelDiscoveryGridView.DiscoverableModel
    @ObservedObject var viewModel: MainApplicationViewModel // Use ObservedObject here

    // Computed property to check if this specific model is currently being pulled
    private var isPullingThisModel: Bool {
        viewModel.isPullingModel && viewModel.modelToPull == model.name
    }

    // Computed property to check if this model is already downloaded
    private var isDownloaded: Bool {
        viewModel.localOllamaModels.contains(model.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(model.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2) // Limit description lines
                .fixedSize(horizontal: false, vertical: true) // Allow vertical expansion

            HStack {
                Text(model.sizeEstimate)
                    .font(.caption2)
                    .foregroundColor(.gray)
                Spacer() // Push button/status to the right
            }
            .padding(.bottom, 5)


            // --- Action/Status Area ---
            if isPullingThisModel {
                // Show progress bar and status text if this model is downloading
                VStack(alignment: .leading) {
                    ProgressView(value: viewModel.pullProgress)
                        .progressViewStyle(.linear)
                    Text("\(viewModel.pullStage.capitalized)... \(String(format: "%.0f%%", viewModel.pullProgress * 100))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if isDownloaded {
                // Show downloaded status
                HStack {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Downloaded")
                        .font(.caption)
                }
            } else {
                // Show Download button if not downloaded and not currently pulling
                HStack {
                    Spacer() // Push button to the right
                    Button {
                        logger.info("Download button clicked for model: \(model.name)")
                        // Set the model name in ViewModel *before* calling pull
                        viewModel.modelToPull = model.name
                        Task {
                            await viewModel.pullModelAction(name: model.name)
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered) // Use bordered style for prominence
                    .font(.caption)
                    // Disable button if:
                    // - Ollama server is not connected
                    // - Any pull is in progress (even for another model)
                    // - Any removal is in progress
                    .disabled(viewModel.ollamaServerStatus != .connected ||
                              viewModel.isPullingModel ||
                              viewModel.isRemovingModel)
                }
            }
            // --- End Action/Status Area ---

        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor)) // Use standard window background
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2) // Subtle shadow
        // Ensure card takes height needed but doesn't stretch excessively
        .frame(minHeight: 140, alignment: .top) // Minimum height for consistency
    }
}

// MARK: - Preview Provider
struct LocalModelDiscoveryGridView_Previews: PreviewProvider {
    static var previews: some View {
        // Create mock ViewModels for different states
        let defaultViewModel = MainApplicationViewModel()
        defaultViewModel.localOllamaModels = ["mistral:7b"] // Simulate one model downloaded
        defaultViewModel.ollamaServerStatus = .connected

        let pullingViewModel = MainApplicationViewModel()
        pullingViewModel.localOllamaModels = ["mistral:7b"]
        pullingViewModel.isPullingModel = true
        pullingViewModel.modelToPull = "llama3:8b" // Simulate pulling llama3
        pullingViewModel.pullStage = "downloading manifest"
        pullingViewModel.pullProgress = 0.15
        pullingViewModel.ollamaServerStatus = .connected

        let disconnectedViewModel = MainApplicationViewModel()
        disconnectedViewModel.ollamaServerStatus = .disconnected

        return Group {
            LocalModelDiscoveryGridView()
                .environmentObject(defaultViewModel)
                .previewDisplayName("Default State")

            LocalModelDiscoveryGridView()
                .environmentObject(pullingViewModel)
                .previewDisplayName("Pulling State")

            LocalModelDiscoveryGridView()
                .environmentObject(disconnectedViewModel)
                .previewDisplayName("Disconnected State")
        }
        .frame(width: 350, height: 600) // Simulate sidebar pane size
    }
}
