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
    
    // A list of categories for the UI.
    private let categories = ["All", "General", "Development", "Productivity", "Creativity", "Writing", "Education", "Research", "Marketing"]
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Search Bar & Add Button
            HStack(spacing: 8) {
                // Modern Glass Search Bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.7))
                    TextField("Search", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
                
                // Add Button (Subtle styling)
                Button {
                    viewModel.prepareForCreateNewPrompt()
                    showingAddPromptPopover = true
                    logger.info("Add New Prompt button tapped.")
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.1))
                .cornerRadius(6)
                .help("Create New Prompt")
                .popover(isPresented: $showingAddPromptPopover, arrowEdge: .bottom) {
                    CreateEditPromptView()
                        .environmentObject(viewModel)
                        .frame(minWidth: 480, idealWidth: 550, minHeight: 450, idealHeight: 500)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)
            
            // MARK: - Horizontal Category Bubbles
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.self) { category in
                        CategoryChip(
                            title: category,
                            isSelected: viewModel.selectedCategory == category,
                            action: { viewModel.selectedCategory = category }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(height: 44)
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            // MARK: - Prompt List
            if viewModel.filteredPrompts.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(viewModel.searchText.isEmpty ? "No Prompts" : "No results for \"\(viewModel.searchText)\"")
                        .font(.callout)
                        .foregroundColor(.secondary)
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
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
            }
        }
        // Transparent background for sidebar vibrancy
        .background(Color.clear)
        .frame(minWidth: 280, idealWidth: 320)
    }
}

// MARK: - Components

struct CategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.08))
                .foregroundColor(isSelected ? .black : .secondary)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color.clear : Color.white.opacity(0.1), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

struct PromptCardView: View {
    let prompt: DevPrompt
    @EnvironmentObject var viewModel: PromptLibraryViewModel
    
    @State private var isHovering: Bool = false
    @State private var showingEditPopover: Bool = false
    @State private var showingDeleteAlert: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(alignment: .top) {
                Text(prompt.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Spacer()
                
                if isHovering {
                    Menu {
                        Button {
                            viewModel.prepareToEditPrompt(prompt)
                            showingEditPopover = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        
                        Button(role: .destructive) {
                            showingDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }
            
            // Content Preview
            Text(prompt.text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            
            // Footer Tags
            HStack(spacing: 6) {
                // Category Tag (if All selected)
                if viewModel.selectedCategory == "All" {
                    Text(prompt.category)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue.opacity(0.9))
                        .cornerRadius(4)
                }
                
                // Custom Tags
                if let tags = prompt.tags, !tags.isEmpty {
                    ForEach(tags.prefix(2), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.08))
                            .foregroundColor(.secondary)
                            .cornerRadius(4)
                    }
                }
            }
        }
        .padding(10)
        // Card Background: "Plate" style on hover/default
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovering ? Color.white.opacity(0.1) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
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
            Text("Are you sure you want to delete \"\(prompt.title)\"?")
        }
    }
}

// MARK: - Preview
struct PromptLibrarySidebarView_Previews: PreviewProvider {
    static var previews: some View {
        PromptLibrarySidebarView()
            .frame(width: 320, height: 700)
            .background(Color(NSColor.windowBackgroundColor))
            .onAppear {
                if PromptService.shared.prompts.isEmpty {
                    DevPrompt.examplePrompts.forEach { PromptService.shared.addPrompt($0) }
                }
            }
            .previewDisplayName("Prompt Library Modern")
    }
}
