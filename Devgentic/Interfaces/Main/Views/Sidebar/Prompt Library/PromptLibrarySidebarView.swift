//
//  PromptLibrarySidebarView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PromptLibrarySidebarView")

/// A new SwiftUI view to display the Prompt Library directly in the sidebar.
/// This view replaces the old modal panel approach.
struct PromptLibrarySidebarView: View {
    @StateObject private var viewModel = PromptLibraryViewModel()
    @State private var showingAddPromptPopover: Bool = false
    
    // A list of categories for the UI. This could be dynamic in the future.
    private let categories = ["All", "General", "Development", "Productivity", "Creativity", "Writing", "Education", "Research", "Marketing"]
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Search Bar & Add Button
            HStack(spacing: 8) {
                // Custom Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search Prompts...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.windowBackgroundColor))
                .cornerRadius(8)
                
                // Add Button
                Button {
                    viewModel.prepareForCreateNewPrompt()
                    showingAddPromptPopover = true
                    logger.info("Add New Prompt button tapped.")
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .help("Create New Prompt")
                .popover(isPresented: $showingAddPromptPopover, arrowEdge: .bottom) {
                    CreateEditPromptView()
                        .environmentObject(viewModel)
                        .frame(minWidth: 480, idealWidth: 550, minHeight: 450, idealHeight: 500)
                }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)
            
            // MARK: - Horizontal Category Bubbles
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(categories, id: \.self) { category in
                        Button(action: {
                            viewModel.selectedCategory = category
                        }) {
                            Text(category)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(viewModel.selectedCategory == category ? Color.accentColor : Color.secondary.opacity(0.2))
                                .foregroundColor(viewModel.selectedCategory == category ? .white : .primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            
            Divider()
            
            // MARK: - Prompt List (Card View)
            if viewModel.filteredPrompts.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    Text(viewModel.searchText.isEmpty ? "No Prompts Found" : "No prompts match \"\(viewModel.searchText)\".")
                        .foregroundColor(.secondary)
                        .font(.headline)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.filteredPrompts) { prompt in
                            PromptCardView(prompt: prompt)
                                .environmentObject(viewModel)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
        }
        .background(Color(.underPageBackgroundColor))
        .frame(minWidth: 320, idealWidth: 360)
    }
}

/// A card view for displaying a single prompt in the list.
struct PromptCardView: View {
    let prompt: DevPrompt
    @EnvironmentObject var viewModel: PromptLibraryViewModel
    
    @State private var isHovering: Bool = false
    @State private var showingEditPopover: Bool = false
    @State private var showingDeleteAlert: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(prompt.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                
                if isHovering {
                    Menu {
                        Button {
                            viewModel.prepareToEditPrompt(prompt)
                            showingEditPopover = true
                        } label: {
                            Label("Edit Prompt", systemImage: "pencil")
                        }
                        
                        Button(role: .destructive) {
                            showingDeleteAlert = true
                        } label: {
                            Label("Delete Prompt", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            
            Text(prompt.text)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            
            HStack(spacing: 6) {
                // FIX: Conditionally show the category only when "All" is selected.
                if viewModel.selectedCategory == "All" {
                    Text(prompt.category)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .cornerRadius(5)
                }
                
                if let tags = prompt.tags, !tags.isEmpty {
                    ForEach(tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(5)
                    }
                }
            }
            .lineLimit(1)
        }
        .padding(12)
        .background(isHovering ? Color(.windowBackgroundColor) : Color(.clear))
        .cornerRadius(8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $showingEditPopover, arrowEdge: .trailing) {
            CreateEditPromptView()
                .environmentObject(viewModel)
                .frame(minWidth: 480, idealWidth: 550, minHeight: 450, idealHeight: 500)
        }
        .alert("Delete Prompt?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) { viewModel.deletePrompt(prompt) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete the prompt \"\(prompt.title)\"? This action cannot be undone.")
        }
    }
}

// MARK: - Preview
struct PromptLibrarySidebarView_Previews: PreviewProvider {
    static var previews: some View {
        PromptLibrarySidebarView()
            .frame(width: 350, height: 700)
            .onAppear {
                if PromptService.shared.prompts.isEmpty {
                    DevPrompt.examplePrompts.forEach { PromptService.shared.addPrompt($0) }
                }
            }
            .previewDisplayName("Prompt Library Sidebar")
    }
}
