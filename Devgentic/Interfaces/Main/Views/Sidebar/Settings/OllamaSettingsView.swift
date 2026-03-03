//
//  OllamaSettingsView.swift
//  Devgentic
//
//  Created by Raj Singh on 18/05/25.
//

import SwiftUI

/// A view for managing Ollama server settings and local models, optimized for a sidebar.
struct OllamaSettingsView_old: View {
    // Use the shared instance of OllamaService to interact with the Ollama server.
    @ObservedObject var ollamaService = OllamaService.shared
    
    // Access the main view model.
    @EnvironmentObject var mainApplicationViewModel: MainApplicationViewModel
    @Environment(\.appTheme) private var theme

    // State to track which model is pending deletion via the confirmation alert.
    @State private var modelPendingDeletion: LocalModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                
                // MARK: - Server Status Section
                serverStatusView
                
                Rectangle()
                    .fill(theme.dividerColor)
                    .frame(height: 1)

                // MARK: - Download Model Section
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Download New Model", systemImage: "square.and.arrow.down.fill")
                    
                    Text("Enter a model name from the Ollama library (e.g., 'llama3:latest').")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                    
                    downloadControlsView
                    
                    downloadProgressView
                }

                Rectangle()
                    .fill(theme.dividerColor)
                    .frame(height: 1)

                // MARK: - Local Models Section
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Local Models", systemImage: "cpu.fill")
                    
                    if let removeError = ollamaService.modelRemoveError {
                        ErrorView(message: removeError, showIcon: true)
                            .padding(.top, 4)
                    }
                    
                    modelListView
                }
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .background(theme.primaryBackground)
        .refreshable {
            await ollamaService.checkServerStatusAndUpdateModels()
        }
        .onAppear {
            ollamaService.clearAllModelActionStatuses()
            Task {
                await ollamaService.checkServerStatusAndUpdateModels()
            }
        }
        .alert(
            "Delete \(modelPendingDeletion?.name ?? "Model")?",
            isPresented: .constant(modelPendingDeletion != nil),
            presenting: modelPendingDeletion
        ) { model in
            Button("Delete", role: .destructive) {
                Task {
                    await ollamaService.removeModel(name: model.name, baseURL: ollamaService.ollamaBaseURL)
                    modelPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                modelPendingDeletion = nil
            }
        } message: { _ in
            Text("This action cannot be undone. The model files will be permanently removed from your computer.")
        }
    }
    
    /// View for displaying the server status.
    private var serverStatusView: some View {
        StatusIndicator(status: ollamaService.serverStatus)
    }
    
    /// View for listing local models in a compact, vertical stack.
    @ViewBuilder
    private var modelListView: some View {
        if ollamaService.isLoadingModels && ollamaService.localModels.isEmpty {
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Loading models...").foregroundColor(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 10)
        } else if let error = ollamaService.modelLoadingError {
            ErrorView(message: error)
        } else if ollamaService.serverStatus == .connected {
            if ollamaService.localModels.isEmpty {
                Text("No local models found.")
                    .foregroundColor(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(ollamaService.localModels) { model in
                        CompactModelRowView(
                            model: model,
                            isBeingRemoved: ollamaService.isRemovingModel && ollamaService.removingModelName == model.name,
                            onRequestDelete: {
                                self.modelPendingDeletion = model
                            }
                        )
                        .disabled(ollamaService.isPullingModel || ollamaService.isRemovingModel)
                    }
                }
            }
        }
    }
    
    /// View for the model name text field and download button.
    private var downloadControlsView: some View {
        HStack {
            TextField("Model Name (e.g., gemma:2b)", text: $ollamaService.modelToPull)
                .textFieldStyle(.plain)
                .padding(8)
                .background(theme.controlBackground)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
                )
                .foregroundColor(theme.primaryText)
            
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
                    ProgressView(value: ollamaService.pullProgress, total: 1.0)
                    .progressViewStyle(.linear)

                    Button(action: { ollamaService.cancelPullModel() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
                Text(ollamaService.pullStatusMessage)
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.top, 4)
        }
        
        if let pullError = ollamaService.modelPullError {
            if ollamaService.pullErrorRequiresUpdate {
                UpdateRequiredErrorView(message: pullError)
            } else {
                ErrorView(message: pullError, showIcon: true)
            }
        }
    }
}

// MARK: - Redesigned & New Subviews for Compact Layout

/// A compact row view for displaying a single local model, designed for a list.
private struct CompactModelRowView: View {
    let model: LocalModel
    let isBeingRemoved: Bool
    let onRequestDelete: () -> Void
    
    @Environment(\.appTheme) private var theme
    
    private var filteredTags: [ModelTag] {
        let allowedTagTexts = ["Tools", "Vision", "Thinking"]
        return model.tags.filter { allowedTagTexts.contains($0.text) }
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(model.name)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            
            if isBeingRemoved {
                ProgressView().scaleEffect(0.6)
            }
            
            Spacer()
            
            if !filteredTags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(filteredTags) { tag in
                        IconTagView(tag: tag)
                    }
                }
            }
        }
        .padding(12)
        .background(theme.controlBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
        )
        .contextMenu {
            Button(role: .destructive, action: onRequestDelete) {
                Label("Delete Model", systemImage: "trash")
            }
        }
    }
}

private struct IconTagView: View {
    let tag: ModelTag
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        HStack {
            if let icon = tag.icon {
                Image(systemName: icon)
            }
        }
        .font(.caption2)
        .padding(5)
        .background(tag.color.opacity(theme.id == "one_light" ? 0.1 : 0.2))
        .foregroundColor(tag.color)
        .clipShape(Circle())
        .help(tag.text)
    }
}

private struct DownloadButton: View {
    var isDownloading: Bool
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    
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
        .tint(theme.accentColor)
    }
}

private struct SectionHeader: View {
    let title: String
    let systemImage: String
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundColor(theme.accentColor)
            Text(title)
                .font(.headline)
                .foregroundColor(theme.primaryText)
        }
    }
}

private struct StatusIndicator: View {
    let status: OllamaServerStatus
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        HStack {
            Image(systemName: status.systemImageName)
            Text("Ollama Status: ")
                .foregroundColor(theme.primaryText)
            Text(status.description)
                .fontWeight(.bold)
                .foregroundColor(status.color)
            Spacer()
        }
        .font(.subheadline)
        .padding(10)
        .background(status.color.opacity(theme.id == "one_light" ? 0.1 : 0.2))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(status.color.opacity(0.4), lineWidth: 1)
        )
    }
}

private struct ErrorView: View {
    let message: String
    var showIcon: Bool = false
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        HStack(spacing: 4) {
            if showIcon {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            Text(message)
        }
        .font(.caption)
        .foregroundColor(theme.errorColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UpdateRequiredErrorView: View {
    let message: String
    @Environment(\.appTheme) private var theme
    private let downloadURL = URL(string: "https://ollama.com/download")!

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.circle.fill")
                Text(message)
            }
            .font(.caption)
            .foregroundColor(theme.warningColor)
            
            Link(destination: downloadURL) {
                Text("Download Latest Version")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(theme.accentColor)
                    .underline()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(theme.warningColor.opacity(0.15))
        .cornerRadius(8)
    }
}
