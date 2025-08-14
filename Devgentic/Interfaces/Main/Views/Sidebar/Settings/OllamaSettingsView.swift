//
//  OllamaSettingsView.swift
//  Devgentic
//
//  Created by Raj Singh on 18/05/25.
//

import SwiftUI

/// A view for managing Ollama server settings and local models with a modern UI.
struct OllamaSettingsView: View {
    // Use the shared instance of OllamaService to interact with the Ollama server.
    @ObservedObject var ollamaService = OllamaService.shared
    
    // Access the main view model.
    @EnvironmentObject var mainApplicationViewModel: MainApplicationViewModel

    // State to track which model is pending deletion confirmation.
    @State private var modelIdPendingDeletion: LocalModel.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                Text("Ollama Configuration")
                    .font(.title2).bold()
                    .padding(.bottom, 8)

                // MARK: - Download Model Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        SectionHeader(title: "Download New Model", systemImage: "square.and.arrow.down.fill")
                        Spacer()
                        serverStatusView
                    }
                    
                    Text("Enter the name of a model from the Ollama library (e.g., 'llama3:latest', 'gemma:2b').")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    
                    downloadControlsView
                    
                    downloadProgressView
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(12)
                .shadow(radius: 1)

                // MARK: - Local Models Section
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(title: "Local Models", systemImage: "cpu.fill")
                    
                    // Display the model removal error message prominently under the header.
                    if let removeError = ollamaService.modelRemoveError {
                        ErrorView(message: removeError, showIcon: true)
                            .padding(.top, 4)
                    }
                    
                    modelListView
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(12)
                .shadow(radius: 1)
            }
            .padding()
        }
        .refreshable {
            await ollamaService.checkServerStatusAndUpdateModels()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // FIX: Clear previous action-specific errors when the view appears
            // to prevent stale error messages from being shown.
            ollamaService.clearAllModelActionStatuses()
            
            // Refresh models when the view first appears.
            Task {
                await ollamaService.checkServerStatusAndUpdateModels()
            }
        }
    }
    
    /// View for displaying the server status.
    private var serverStatusView: some View {
        StatusIndicator(status: ollamaService.serverStatus)
    }
    
    /// View for listing, searching, and managing local models.
    @ViewBuilder
    private var modelListView: some View {
        if ollamaService.isLoadingModels && ollamaService.localModels.isEmpty {
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Loading models...").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding()
        } else if let error = ollamaService.modelLoadingError {
            ErrorView(message: error)
        } else if ollamaService.serverStatus == .connected {
            if ollamaService.localModels.isEmpty {
                Text("No local models found. Pull a model to get started.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                // Define the grid layout
                let columns = [
                    GridItem(.adaptive(minimum: 240), spacing: 16)
                ]
                
                // Use LazyVGrid for the card layout
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(ollamaService.localModels) { model in
                        ModelCardView(
                            model: model,
                            isBeingRemoved: ollamaService.isRemovingModel && ollamaService.removingModelName == model.name,
                            isPendingDeletion: self.modelIdPendingDeletion == model.id,
                            onDelete: {
                                self.modelIdPendingDeletion = model.id
                            },
                            onConfirmDelete: {
                                Task {
                                    await ollamaService.removeModel(name: model.name, baseURL: ollamaService.ollamaBaseURL)
                                    self.modelIdPendingDeletion = nil // Reset state
                                }
                            },
                            onCancelDelete: {
                                self.modelIdPendingDeletion = nil
                            }
                        )
                        .disabled(ollamaService.isPullingModel || ollamaService.isRemovingModel)
                    }
                }
                .padding(.top, 8)
            }
        }
    }
    
    /// View for the model name text field and download button.
    private var downloadControlsView: some View {
        HStack {
            TextField("Model Name (e.g., gemma:2b)", text: $ollamaService.modelToPull)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            
            DownloadButton(isDownloading: ollamaService.isPullingModel) {
                Task {
                    await ollamaService.pullModel(name: ollamaService.modelToPull, baseURL: ollamaService.ollamaBaseURL)
                }
            }
            .disabled(ollamaService.modelToPull.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ollamaService.isPullingModel || ollamaService.isRemovingModel)
        }
    }
    
    /// View for displaying the download progress bar and status.
    @ViewBuilder
    private var downloadProgressView: some View {
        if ollamaService.isPullingModel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView(value: ollamaService.pullProgress, total: 1.0) {
                        Text(ollamaService.pullStatusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .progressViewStyle(.linear)

                    Button(action: {
                        ollamaService.cancelPullModel()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
        
        if let pullError = ollamaService.modelPullError {
            if ollamaService.pullErrorRequiresUpdate {
                UpdateRequiredErrorView(message: pullError)
                    .padding(.top, 4)
            } else {
                ErrorView(message: pullError, showIcon: true)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Subviews & Helpers

private struct ModelCardView: View {
    let model: LocalModel
    let isBeingRemoved: Bool
    let isPendingDeletion: Bool
    let onDelete: () -> Void
    let onConfirmDelete: () -> Void
    let onCancelDelete: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Card Header
            HStack {
                Text(model.name)
                    .font(.headline)
                    .fontWeight(.bold)
                    .lineLimit(1)
                Spacer()
                
                if isBeingRemoved {
                    ProgressView()
                        .scaleEffect(0.6)
                } else if isPendingDeletion {
                    // Show confirm and cancel buttons
                    HStack(spacing: 12) {
                        Button(action: onConfirmDelete) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: onCancelDelete) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    // Show initial delete button
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Spacer()

            // Tags using a Flow Layout
            FlowLayout(items: model.tags) { tag in
                TagView(tag: tag)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        .frame(minHeight: 100)
    }
}

/// A view that displays a single, styled model tag.
private struct TagView: View {
    let tag: ModelTag
    
    var body: some View {
        HStack(spacing: 4) {
            if let icon = tag.icon {
                Image(systemName: icon)
            }
            Text(tag.text)
        }
        .font(.caption)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tag.color.opacity(0.15))
        .foregroundColor(tag.color)
        .cornerRadius(8)
    }
}

/// A custom layout that arranges views in a wrapping horizontal flow.
struct FlowLayout<Data: RandomAccessCollection, RowContent: View>: View where Data.Element: Hashable {
    let items: Data
    @ViewBuilder let rowContent: (Data.Element) -> RowContent
    
    @State private var totalHeight: CGFloat = .zero

    var body: some View {
        VStack {
            GeometryReader { geometry in
                self.generateContent(in: geometry)
            }
        }
        .frame(height: totalHeight)
    }

    private func generateContent(in g: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero
        
        return ZStack(alignment: .topLeading) {
            ForEach(self.items, id: \.self) { item in
                self.rowContent(item)
                    .padding([.horizontal, .vertical], 4)
                    .alignmentGuide(.leading, computeValue: { d in
                        if (abs(width - d.width) > g.size.width) {
                            width = 0
                            height -= d.height
                        }
                        let result = width
                        if item == self.items.last {
                            width = 0 // Last item
                        } else {
                            width -= d.width
                        }
                        return result
                    })
                    .alignmentGuide(.top, computeValue: { d in
                        let result = height
                        if item == self.items.last {
                            height = 0 // Last item
                        }
                        return result
                    })
            }
        }
        .background(viewHeightReader($totalHeight))
    }

    private func viewHeightReader(_ binding: Binding<CGFloat>) -> some View {
        return GeometryReader { geometry -> Color in
            let rect = geometry.frame(in: .local)
            DispatchQueue.main.async {
                binding.wrappedValue = rect.size.height
            }
            return .clear
        }
    }
}


private struct DownloadButton: View {
    var isDownloading: Bool
    let action: () -> Void
    
    @State private var isAnimating = false

    var body: some View {
        Button(action: action) {
            if isDownloading {
                Image(systemName: "arrow.2.circlepath")
                    .rotationEffect(isAnimating ? .degrees(360) : .degrees(0))
                    .onAppear {
                        withAnimation(Animation.linear(duration: 1).repeatForever(autoreverses: false)) {
                            isAnimating = true
                        }
                    }
                    .onDisappear {
                        isAnimating = false
                    }
            } else {
                Image(systemName: "square.and.arrow.down")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)
    }
}


private struct SectionHeader: View {
    let title: String
    let systemImage: String
    
    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundColor(.accentColor)
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
        }
    }
}

private struct StatusIndicator: View {
    let status: OllamaServerStatus
    
    var body: some View {
        HStack {
            Image(systemName: status.systemImageName)
                .foregroundColor(status.color)
            Text("Status: ")
                .foregroundColor(.secondary)
            Text(status.description)
                .fontWeight(.bold)
                .foregroundColor(status.color)
        }
        .padding(8)
        .background(status.color.opacity(0.1))
        .cornerRadius(8)
    }
}

private struct ErrorView: View {
    let message: String
    var showIcon: Bool = false
    
    var body: some View {
        HStack(spacing: 4) {
            if showIcon {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            Text(message)
        }
        .font(.caption)
        .foregroundColor(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UpdateRequiredErrorView: View {
    let message: String
    private let downloadURL = URL(string: "https://ollama.com/download")!

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.circle.fill")
                Text(message)
            }
            .font(.caption)
            .foregroundColor(.orange)
            
            Link(destination: downloadURL) {
                Text("Download Latest Version from ollama.com")
                    .font(.caption)
                    .fontWeight(.bold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
        )
    }
}


// MARK: - Preview
struct OllamaSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        OllamaSettingsView()
            .environmentObject(MainApplicationViewModel())
    }
}
