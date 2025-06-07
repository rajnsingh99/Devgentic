//
//  OllamaSidebarView.swift
//  Devgentic
//
//  Created by Raj Singh on 07/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OllamaSidebarView")

// MARK: - Main Sidebar View for Ollama
struct OllamaSidebarView: View {
    // MARK: - Step 4 Change: viewModel is now an EnvironmentObject. The service is accessed via viewModel.
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Binding var sidebarWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The status view now gets the service instance from the environment view model
            OllamaStatusView(ollamaService: viewModel.ollamaService)
                .padding(.horizontal)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    OllamaProfilesSection()
                        .environmentObject(viewModel.ollamaProfileStore)

                    Divider()

                    LocalModelsSection(
                        ollamaService: viewModel.ollamaService,
                        ollamaBaseURL: viewModel.ollamaProfileStore.currentProfile?.baseURL ?? "http://localhost:11434",
                        sidebarWidth: $sidebarWidth
                    )
                }
                .padding(.horizontal)
                .padding(.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // MARK: - Step 4 Change: The .onAppear modifier has been removed.
        // Data loading is now handled centrally by MainApplicationViewModel.
        .onDisappear {
            logger.debug("OllamaSidebarView disappeared.")
            // Clearing action statuses on disappear is still good practice.
            viewModel.ollamaService.clearAllModelActionStatuses()
        }
    }
}

// MARK: - Profiles Section
private struct OllamaProfilesSection: View {
    @EnvironmentObject var ollamaProfileStore: OllamaProfileStore
    @State private var showingAddProfilePopover = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Profiles")
                    .font(.headline)
                Spacer()
                Button {
                    showingAddProfilePopover = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(PlainButtonStyle())
                .help("Add New Ollama Profile")
                .popover(isPresented: $showingAddProfilePopover, arrowEdge: .bottom) {
                    OllamaAddProfilePopover()
                        .environmentObject(ollamaProfileStore)
                }
            }
            .padding(.bottom, 5)

            LazyVStack(spacing: 8) {
                ForEach(ollamaProfileStore.profiles) { profile in
                    ProfileRowView(profile: profile)
                }
            }
        }
    }
}

// MARK: - Profile Row (Card Style)
private struct ProfileRowView: View {
    @EnvironmentObject var ollamaProfileStore: OllamaProfileStore
    let profile: OllamaProfileModel
    @State private var showingDeleteConfirmation = false

    var isActive: Bool {
        ollamaProfileStore.selectedProfileID == profile.id
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.profileName)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Text(profile.baseURL)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(NSColor.controlAlternatingRowBackgroundColors.first ?? .clear))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? .blue : Color.gray.opacity(0.2), lineWidth: isActive ? 0.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive {
                ollamaProfileStore.selectedProfileID = profile.id
            }
        }
        .contextMenu {
            Button("Set as Active") {
                ollamaProfileStore.selectedProfileID = profile.id
            }
            .disabled(isActive)

            Button("Delete Profile", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .disabled(ollamaProfileStore.profiles.count <= 1)
        }
        .confirmationDialog("Delete '\(profile.profileName)'?",
                            isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete Profile", role: .destructive) {
                ollamaProfileStore.deleteProfile(id: profile.id)
            }
        }
    }
}


// MARK: - Local Models Section
private struct LocalModelsSection: View {
    @ObservedObject var ollamaService: OllamaService
    let ollamaBaseURL: String
    @Binding var sidebarWidth: CGFloat

    struct ModelMetadata: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let description: String
        let sizeEstimate: String
    }

    private let knownModelsMetadata: [ModelMetadata] = [
        ModelMetadata(name: "llama3:8b", description: "Meta's latest generation 8B parameter model.", sizeEstimate: "4.7 GB"),
        ModelMetadata(name: "mistral:7b", description: "Popular 7B model known for efficiency and performance.", sizeEstimate: "4.1 GB"),
        ModelMetadata(name: "phi3:mini", description: "Microsoft's powerful 3.8B parameter small language model.", sizeEstimate: "2.3 GB"),
        ModelMetadata(name: "gemma:7b", description: "Google's family of lightweight, state-of-the-art open models.", sizeEstimate: "5.0 GB"),
        ModelMetadata(name: "codellama:7b", description: "Code synthesis model based on Llama 2.", sizeEstimate: "4.1 GB"),
        ModelMetadata(name: "llava:7b", description: "Large multimodal model connecting vision encoder and LLM.", sizeEstimate: "4.5 GB"),
        ModelMetadata(name: "qwen:7b", description: "Alibaba Cloud's large vision language model.", sizeEstimate: "4.1 GB")
    ]

    private var downloadedModels: [ModelMetadata] {
        let localModelNames = Set(ollamaService.localModels)
        let knownDownloaded = knownModelsMetadata.filter { localModelNames.contains($0.name) }
        
        let knownModelNames = Set(knownDownloaded.map { $0.name })
        let unknownModelNames = localModelNames.subtracting(knownModelNames)
        
        let unknownDownloaded = unknownModelNames.map {
            ModelMetadata(name: $0, description: "A locally installed Ollama model.", sizeEstimate: "Unknown")
        }
        
        return (knownDownloaded + unknownDownloaded).sorted { $0.name < $1.name }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 180))]
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Local LLMs")
                .font(.headline)
                .padding(.bottom, 5)
            
            if ollamaService.isLoadingModels {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading models...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let error = ollamaService.modelLoadingError {
                Text("Error loading models: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            } else if downloadedModels.isEmpty {
                Text("No local models found for the active profile. Download models via the settings panel.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(downloadedModels) { model in
                        LocalModelCard(
                            model: model,
                            ollamaService: ollamaService,
                            ollamaBaseURL: ollamaBaseURL
                        )
                    }
                }
            }
        }
    }
}


// MARK: - Local Model Card
private struct LocalModelCard: View {
    let model: LocalModelsSection.ModelMetadata
    @ObservedObject var ollamaService: OllamaService
    let ollamaBaseURL: String
    
    @EnvironmentObject var viewModel: MainApplicationViewModel
    
    @State private var showingRemovalConfirmation = false

    var isSelectedForChat: Bool {
        viewModel.ollamaProfileStore.currentProfile?.llmModelName == model.name
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
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 30)

            HStack {
                Text(model.sizeEstimate)
                    .font(.caption2)
                    .foregroundColor(.gray)
                Spacer()
            }
            .padding(.bottom, 5)
            
            HStack {
                if isSelectedForChat {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.blue)
                        .help("Selected for chat in current profile")
                }
                
                Spacer()

                Button {
                    showingRemovalConfirmation = true
                } label: {
                    if ollamaService.isRemovingModel && ollamaService.removingModelName == model.name {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.red)
                .help("Remove \(model.name)")
                .disabled(ollamaService.isRemovingModel || ollamaService.isPullingModel || isSelectedForChat)
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelectedForChat ? Color.blue.opacity(0.6) : Color.clear, lineWidth: 2)
        )
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2)
        .frame(minHeight: 140, alignment: .top)
        .confirmationDialog("Remove '\(model.name)'?",
                            isPresented: $showingRemovalConfirmation,
                            titleVisibility: .visible) {
            Button("Remove Model", role: .destructive) {
                Task {
                    await ollamaService.removeModel(name: model.name, baseURL: ollamaBaseURL)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }
}


// MARK: - Ollama Status View
private struct OllamaStatusView: View {
    @ObservedObject var ollamaService: OllamaService
    @Environment(\.openWindow) var openWindow

    var body: some View {
        HStack {
            Image(systemName: ollamaService.serverStatus.systemImageName)
                .foregroundColor(ollamaService.serverStatus.color)
            Text("Ollama Status: \(ollamaService.serverStatus.description)")
                .font(.callout)

            Spacer()

            if ollamaService.serverStatus == .disconnected || ollamaService.serverStatus == .error {
                Button {
                    Task {
                        // Use the shared service instance to perform the action
                        await OllamaService.shared.checkServerStatusAndUpdateModels()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Retry Connection")
                .disabled(ollamaService.serverStatus == .checking)
            } else if ollamaService.serverStatus == .checking {
                 ProgressView().controlSize(.small)
            }

            Button {
                openWindow(id: "ollama-profiles")
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Manage Ollama Profiles & Settings")
        }.padding(.top, 10)
    }
}
