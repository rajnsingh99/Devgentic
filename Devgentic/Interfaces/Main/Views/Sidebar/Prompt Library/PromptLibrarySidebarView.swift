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
    @Environment(\.appTheme) private var theme
    @EnvironmentObject var appViewModel: MainApplicationViewModel
    @EnvironmentObject private var router: MainViewRouter

    // A list of categories for the UI.
    private let categories = ["All", "General", "Development", "Productivity", "Creativity", "Writing", "Education", "Research", "Marketing"]

    private var activePromptID: UUID? {
        if case .promptDetail(let id) = router.activeDestination { return id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            SidebarHeaderView(
                title: "Prompts",
                buttonTitle: "New Prompt",
                systemImage: "plus",
                onAction: {
                    viewModel.prepareForCreateNewPrompt()
                    showingAddPromptPopover = true
                }
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .popover(isPresented: $showingAddPromptPopover, arrowEdge: .bottom) {
                CreateEditPromptView()
                    .environmentObject(viewModel)
                    .frame(minWidth: 480, idealWidth: 550, minHeight: 450, idealHeight: 500)
            }

            // MARK: - Search Bar
            SidebarSearchBarView("Search prompts...", text: $viewModel.searchText)
                .padding(.horizontal, 12)
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
            }
            .padding(.bottom, 10)

            // MARK: - Prompt List
            if viewModel.filteredPrompts.isEmpty {
                SidebarEmptyStateView(
                    title: viewModel.searchText.isEmpty ? "No Prompts" : "No results",
                    subtitle: viewModel.searchText.isEmpty ? "Start creating prompts to build your library" : "No results for \"\(viewModel.searchText)\"",
                    buttonTitle: "Create Prompt",
                    systemImage: "tray",
                    onAction: {
                        viewModel.prepareForCreateNewPrompt()
                        showingAddPromptPopover = true
                    }
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.filteredPrompts) { prompt in
                            PromptRowView(
                                prompt: prompt,
                                isSelected: activePromptID == prompt.id,
                                onSelect: {
                                    router.navigateToPrompt(prompt.id)
                                },
                                onEdit: {
                                    router.navigateToPrompt(prompt.id)
                                },
                                onDelete: {
                                    viewModel.deletePrompt(prompt)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Color.clear)
        .frame(minWidth: 280, idealWidth: 320)
    }
}

// MARK: - Refined Category Chip

struct CategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? theme.primaryText : theme.surfaceOverlay)
                .foregroundColor(isSelected ? theme.primaryBackground : theme.secondaryText)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : theme.surfaceOverlay, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
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
