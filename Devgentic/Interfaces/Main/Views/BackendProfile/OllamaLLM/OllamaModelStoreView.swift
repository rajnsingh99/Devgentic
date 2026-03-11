//
//  OllamaModelStoreView.swift
//  Devgentic
//
//  Created by Antigravity on 07/03/26.
//

import SwiftUI

struct OllamaModelStoreView: View {
    @StateObject private var viewModel = OllamaModelStoreViewModel()
    @Environment(\.dismiss) var dismiss
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                
                // MARK: - Header & Search Bar
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        // Search Field
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(theme.secondaryText)
                            
                            TextField("Search installed models or enter name to download...", text: $viewModel.searchText)
                                .textFieldStyle(.plain)
                                .font(.body)
                                .onSubmit {
                                    // If search doesn't match local, allow downloading
                                    if viewModel.displayedModels.isEmpty && !viewModel.searchText.isEmpty {
                                        viewModel.downloadModel(name: viewModel.searchText)
                                    }
                                }
                            
                            // Sort Menu
                            Menu {
                                Picker("Sort By", selection: $viewModel.sortOption) {
                                    ForEach(OllamaModelStoreViewModel.SortOption.allCases) { option in
                                        Label(option.rawValue, systemImage: option.icon).tag(option)
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.body)
                                    .foregroundColor(theme.secondaryText)
                                    .padding(.horizontal, 8)
                                    .contentShape(Rectangle())
                            }
                            .menuStyle(.borderlessButton)
                            .help("Sort Models")
                        }
                        .padding(10)
                        .background(theme.secondaryBackground)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.dividerColor, lineWidth: 1)
                        )
                        
                        // Download by Name Button (if no match)
                        if viewModel.displayedModels.isEmpty && !viewModel.searchText.isEmpty {
                            Button {
                                viewModel.downloadModel(name: viewModel.searchText)
                            } label: {
                                Label("Pull", systemImage: "arrow.down.circle.fill")
                                    .fontWeight(.medium)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                        }
                    }
                }
                .padding()
                .background(theme.primaryBackground)
                .overlay(Rectangle().frame(height: 1).foregroundColor(theme.dividerColor), alignment: .bottom)
                
                // MARK: - Main Content Area
                ZStack {
                    if viewModel.isLoading && viewModel.displayedModels.isEmpty {
                        VStack(spacing: 16) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Fetching local models...")
                                .foregroundColor(theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        
                    } else if viewModel.displayedModels.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "cpu")
                                .font(.system(size: 48))
                                .foregroundColor(theme.secondaryText.opacity(0.5))
                            
                            Text(viewModel.searchText.isEmpty ? "No local models found" : "No matching models")
                                .font(.title3)
                                .fontWeight(.medium)
                            
                            if !viewModel.searchText.isEmpty {
                                Text("Press Enter or click 'Pull' to download '\(viewModel.searchText)'")
                                    .foregroundColor(theme.secondaryText)
                                    .font(.caption)
                            } else {
                                Text("Ollama needs to be running to list models.")
                                    .foregroundColor(theme.secondaryText)
                            }
                            
                            Button("Refresh") {
                                viewModel.refresh()
                            }
                            .padding(.top, 8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(viewModel.displayedModels) { model in
                                    OllamaModelCardView(model: model, viewModel: viewModel)
                                }
                            }
                            .padding()
                        }
                    }
                    
                    // MARK: - Download Status Banner
                    if viewModel.isDownloading {
                        downloadBanner
                    }
                }
            }
            .navigationTitle("Ollama Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        viewModel.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh Models")
                }
            }
        }
        .frame(minWidth: 700, minHeight: 600)
    }
    
    private var downloadBanner: some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloading \(viewModel.currentDownloadName)...")
                        .font(.headline)
                        .lineLimit(1)
                    
                    ProgressView(value: viewModel.downloadProgress)
                        .controlSize(.small)
                        .tint(.blue)
                }
                
                Spacer()
                
                Text("\(Int(viewModel.downloadProgress * 100))%")
                    .monospacedDigit()
                    .fontWeight(.bold)
                
                Button {
                    viewModel.cancelDownload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Cancel Download")
            }
            .padding()
            .background(.regularMaterial)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
            .padding()
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct OllamaModelCardView: View {
    let model: LocalModel
    @ObservedObject var viewModel: OllamaModelStoreViewModel
    @State private var showingDeleteAlert = false
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.dividerColor)
                    .frame(width: 52, height: 52)
                
                Image(systemName: "cpu.fill")
                    .font(.title)
                    .foregroundColor(theme.secondaryText)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(model.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                // Badges
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.tags) { tag in
                            HStack(spacing: 4) {
                                if let icon = tag.icon {
                                    Image(systemName: icon)
                                }
                                Text(tag.text)
                            }
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(tag.color.opacity(0.1))
                            .foregroundColor(tag.color)
                            .cornerRadius(6)
                        }
                        
                        // Capability Badge
                        HStack(spacing: 4) {
                            Image(systemName: capabilityIcon(for: model.cognitiveCapability))
                            Text(model.cognitiveCapability.rawValue)
                        }
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(capabilityColor(for: model.cognitiveCapability).opacity(0.1))
                        .foregroundColor(capabilityColor(for: model.cognitiveCapability))
                        .cornerRadius(6)
                    }
                }
                
                if let details = model.details {
                    HStack(spacing: 12) {
                        if let size = details.parameterSize {
                            Text("• \(size)")
                        }
                        if let quant = details.quantizationLevel {
                            Text("• \(quant)")
                        }
                        if let family = details.family {
                            Text("• \(family)")
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(theme.secondaryText)
                }
            }
            
            Spacer()
            
            Button(role: .destructive) {
                showingDeleteAlert = true
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(theme.errorColor)
            }
            .buttonStyle(.plain)
            .help("Delete Model")
            .alert("Delete Model?", isPresented: $showingDeleteAlert) {
                Button("Delete", role: .destructive) {
                    viewModel.deleteModel(model)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Are you sure you want to delete '\(model.name)'? This will permanently remove the files from your local Ollama storage.")
            }
        }
        .padding(12)
        .background(theme.secondaryBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.dividerColor, lineWidth: 1)
        )
    }
    
    // Helper colors/icons duplicated from detail views or centralized (better to centralize)
    private func capabilityIcon(for capability: ModelCognitiveCapability) -> String {
        switch capability {
        case .parallelActions: return "bolt.fill"
        case .singleAction: return "wrench.fill"
        case .none: return "message.fill"
        }
    }
    
    private func capabilityColor(for capability: ModelCognitiveCapability) -> Color {
        switch capability {
        case .parallelActions: return .purple
        case .singleAction: return .blue
        case .none: return .green
        }
    }
}
