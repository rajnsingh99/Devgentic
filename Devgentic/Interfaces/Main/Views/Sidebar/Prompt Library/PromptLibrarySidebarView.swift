//
//  PromptLibrarySidebarView.swift
//  Devgentic
//
//  Created by Raj Singh.
//  Modernized on 17/02/26 with refined cards, tags, search, and micro-interactions.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PromptLibrarySidebarView")

/// A new SwiftUI view to display the Prompt Library directly in the sidebar.
/// This view replaces the old modal panel approach.
struct PromptLibrarySidebarView: View {
    @StateObject private var viewModel = PromptLibraryViewModel()
    @State private var showingAddPromptPopover: Bool = false
    @FocusState private var isSearchFieldFocused: Bool

    // A list of categories for the UI.
    private let categories = ["All", "General", "Development", "Productivity", "Creativity", "Writing", "Education", "Research", "Marketing"]

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Search Bar & Add Button
            HStack(spacing: 8) {
                // Enhanced Glass Search Bar with focus ring
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundColor(isSearchFieldFocused ? .accentColor : .secondary.opacity(0.7))
                        .animation(.easeInOut(duration: 0.2), value: isSearchFieldFocused)

                    TextField("Search prompts...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($isSearchFieldFocused)

                    // Clear button when text is present
                    if !viewModel.searchText.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                viewModel.searchText = ""
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isSearchFieldFocused ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.1),
                            lineWidth: isSearchFieldFocused ? 1.0 : 0.5
                        )
                )
                .shadow(
                    color: isSearchFieldFocused ? Color.accentColor.opacity(0.15) : Color.clear,
                    radius: 6, x: 0, y: 0
                )
                .animation(.easeInOut(duration: 0.2), value: isSearchFieldFocused)

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
                .buttonStyle(ScaleButtonStyle())
                .foregroundColor(.secondary)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

// MARK: - Refined Category Chip

struct CategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.08))
                .foregroundColor(isSelected ? .black : .secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color.white.opacity(0.08), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

// MARK: - Refined Prompt Card

struct PromptCardView: View {
    let prompt: DevPrompt
    @EnvironmentObject var viewModel: PromptLibraryViewModel
    @EnvironmentObject var appViewModel: MainApplicationViewModel

    @State private var isHovering: Bool = false
    @State private var showingEditPopover: Bool = false
    @State private var showingDeleteAlert: Bool = false

    var body: some View {
        cardContent
            .padding(10)
            .background(cardBackground)
            .overlay(cardBorder)
            .shadow(
                color: isHovering ? Color.black.opacity(0.15) : Color.clear,
                radius: isHovering ? 8 : 0, x: 0, y: 2
            )
            .animation(.easeInOut(duration: 0.2), value: isHovering)
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

    // MARK: - Extracted Sub-Views

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader
            cardPreview
            cardTags
        }
    }

    private var cardHeader: some View {
        HStack(alignment: .top) {
            Text(prompt.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            if isHovering {
                hoverActions
                    .transition(.opacity)
            }
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 4) {
            Button {
                appViewModel.insertPromptText.send(prompt.text)
            } label: {
                Text("Use")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)

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

    private var cardPreview: some View {
        Text(prompt.text)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .lineLimit(2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var cardTags: some View {
        HStack(spacing: 6) {
            if viewModel.selectedCategory == "All" {
                Text(prompt.category)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(Color.accentColor.opacity(0.9))
                    .clipShape(Capsule())
            }

            if let tags = prompt.tags, !tags.isEmpty {
                ForEach(tags.prefix(2), id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.white.opacity(0.06))
                        .foregroundColor(.secondary.opacity(0.8))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isHovering ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.04), lineWidth: 0.5)
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
