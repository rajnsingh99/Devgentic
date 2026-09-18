// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PromptLibrarySidebarView.swift
//  Devgentic
//
//  Created by Raj Singh.
//  Modernized on 17/02/26 with refined cards, tags, search, and micro-interactions.
//  Overhauled on 2026-04-21 — split browse/edit VMs, lazy rows, hover actions,
//  context menus, keyboard nav, delete confirm, sort + pin + tag filter,
//  sheet (not popover) for create, error banner.
//

import SwiftUI
import os

private let logger = DGLogger(category: "PromptLibrarySidebarView")

// MARK: - Localized titles for the sort / source menus
//
// Both enums are declared in `Foundation`-only files (`PromptBrowseViewModel.swift`,
// `PromptCategory.swift`), so the SwiftUI-dependent title lives here, in the file
// that renders it, rather than forcing `import SwiftUI` into the model layer.

extension PromptSortOrder {
    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)`
    /// binds to the non-localizing `StringProtocol` overload, so every rawValue-sourced
    /// label was invisible to the String Catalog extractor and would have shipped
    /// untranslated inside otherwise-translated chrome. `rawValue` stays for
    /// persistence (`UserDefaults` key `promptBrowse.sortOrder`) and logging only.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .alphabetical:    return "Alphabetical"
        case .recentlyUsed:    return "Recently Used"
        case .recentlyCreated: return "Recently Created"
        }
    }
}

extension PromptSourceFilter {
    /// User-facing name. ⚠️ Separate from `rawValue` on purpose — see
    /// `PromptSortOrder.localizedTitle`. `rawValue` is persisted to `UserDefaults`
    /// under `promptBrowse.selectedSource`, so it must never change.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .all:     return "All"
        case .user:    return "My Prompts"
        case .builtIn: return "Built-in"
        }
    }
}

/// Displays the Prompt Library directly in the sidebar.
struct PromptLibrarySidebarView: View {
    /// Sidebar browse VM owned by `DestinationCoordinator` so search /
    /// category / sort / pin filter state survives tab switches.
    @Environment(DestinationCoordinator.self) private var coordinator

    /// A per-view edit VM used solely for the "New Prompt" sheet.
    @State private var createEditVM = PromptEditViewModel()
    @State private var showingCreateSheet: Bool = false

    /// Global tag management sheet (rename / delete tags across all prompts).
    @State private var showingTagManagerSheet: Bool = false

    /// Delete-confirmation target.
    @State private var promptPendingDeletion: DevPrompt? = nil

    // Batch selection mode. Enters via long-press on a row or the
    // header "Select" menu item. Exits via Cancel button or ESC.
    @State private var isSelectionMode: Bool = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showingBatchDeleteAlert: Bool = false

    /// Keyboard-focused prompt ID (drives arrow-key nav). Kept separate from
    /// `activePromptID` (which reflects the router's detail-view target) so
    /// focus doesn't snap away while the detail view is open.
    @State private var focusedPromptID: UUID? = nil
    @FocusState private var isListFocused: Bool
    @FocusState private var isSearchFocused: Bool

    @Environment(\.appTheme) private var theme
    @Environment(MainApplicationViewModel.self) var appViewModel
    @Environment(MainViewRouter.self) private var router
    @Environment(ChatInputViewModel.self) private var chatInputVM
    @Environment(ToastManager.self) private var toastManager

    // MARK: - Derived

    private var activePromptID: UUID? {
        if case .promptDetail(let id) = router.activeDestination { return id }
        return nil
    }

    // MARK: - Body

    var body: some View {
        @Bindable var viewModel = coordinator.promptBrowse

        VStack(spacing: 0) {
            if isSelectionMode {
                batchHeaderRow(viewModel: viewModel)
            } else {
                headerRow(viewModel: viewModel)

                SidebarSearchBarView("Search prompts...", text: $viewModel.searchText)
                    .focused($isSearchFocused)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)

                categoryChipsRow(viewModel: viewModel)

                if !viewModel.availableTags.isEmpty {
                    tagChipsRow(viewModel: viewModel)
                }

                if viewModel.loadState.isError {
                    errorBanner
                }
            }

            Divider()
                .background(theme.dividerColor)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            promptList(viewModel: viewModel)
        }
        .background(Color.clear)
        .frame(minWidth: 280, idealWidth: 320)
        .sheet(isPresented: $showingCreateSheet) {
            CreateEditPromptView()
                .environment(createEditVM)
                .frame(minWidth: 520, minHeight: 520)
        }
        .sheet(isPresented: $showingTagManagerSheet) {
            TagManagementSheet()
        }
        .alert("Delete Prompt?", isPresented: Binding(
            get: { promptPendingDeletion != nil },
            set: { if !$0 { promptPendingDeletion = nil } }
        ), presenting: promptPendingDeletion) { prompt in
            Button("Delete", role: .destructive) {
                if viewModel.deletePrompt(prompt) {
                    if focusedPromptID == prompt.id { focusedPromptID = nil }
                } else {
                    // Typically only happens if the prompt flipped to
                    // built-in between alert-present and confirm, or if
                    // persistence failed. Either way, surface the refusal.
                    toastManager.show("Couldn't delete — prompt may be built-in", style: .error)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text("“\(prompt.title)” will be permanently removed.")
        }
        .alert(
            "Delete \(selectedIDs.count) Prompt\(selectedIDs.count == 1 ? "" : "s")?",
            isPresented: $showingBatchDeleteAlert
        ) {
            Button("Delete", role: .destructive) {
                commitBatchDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These prompts will be permanently removed.")
        }
        .onChange(of: viewModel.filteredPrompts.map(\.id)) { _, newIDs in
            // Keep keyboard focus valid as the list changes underneath us.
            if let id = focusedPromptID, !newIDs.contains(id) {
                focusedPromptID = newIDs.first
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newPrompt)) { _ in
            createEditVM.loadCreateDraft()
            showingCreateSheet = true
        }
    }

    // MARK: - Header

    private func headerRow(viewModel: PromptBrowseViewModel) -> some View {
        HStack {
            Text("Prompts")
                .font(theme.fontBody.weight(.semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            sortMenu(viewModel: viewModel)

            SidebarHeaderActionButton(
                title: "New",
                systemImage: "plus",
                shortcut: "⌘N"
            ) {
                createEditVM.loadCreateDraft()
                showingCreateSheet = true
            }
            .keyboardShortcut("n", modifiers: [.command])
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// Combined sort + source filter menu. Kept together to avoid adding a
    /// second header button — the two are both "list shaping" concerns so
    /// grouping them reads naturally. Checkmarks on active items give
    /// visual feedback without needing a segmented picker.
    private func sortMenu(viewModel: PromptBrowseViewModel) -> some View {
        Menu {
            Section("Sort By") {
                ForEach(PromptSortOrder.allCases) { order in
                    Button {
                        viewModel.sortOrder = order
                    } label: {
                        Label(order.localizedTitle, systemImage: order.systemImage)
                        if viewModel.sortOrder == order {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Section("Show") {
                ForEach(PromptSourceFilter.allCases) { source in
                    Button {
                        viewModel.selectedSource = source
                    } label: {
                        Label(source.localizedTitle, systemImage: source.systemImage)
                        if viewModel.selectedSource == source {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: viewModel.sortOrder.systemImage)
                .font(theme.fontCaption.weight(.semibold))
                .frame(width: 22, height: 22)
                .foregroundColor(
                    viewModel.selectedSource == .all ? theme.secondaryText : theme.accentColor
                )
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.surfaceOverlay)
                )
                .overlay(
                    // Subtle dot indicator when a non-default source filter
                    // is active — so users see at a glance that the list
                    // isn't showing everything.
                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: 4, height: 4)
                        .offset(x: 8, y: -8)
                        .opacity(viewModel.selectedSource == .all ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // ⚠️ Composed, not interpolated: `"\(x.localizedTitle)"` would not compile
        // and `"\(x.rawValue)"` would silently bake an untranslated English word
        // into an otherwise-translatable sentence. Nesting `Text` keeps the frame
        // ("Sort: %@ · Show: %@") extractable *and* localizes both values.
        .help("Sort: \(Text(viewModel.sortOrder.localizedTitle)) · Show: \(Text(viewModel.selectedSource.localizedTitle))")
        // `accessibilityLabel(_: String)` does not localize — the `Text` overload does.
        .accessibilityLabel(
            Text("Sort and filter. Sort: \(Text(viewModel.sortOrder.localizedTitle)). Showing: \(Text(viewModel.selectedSource.localizedTitle))")
        )
    }

    // MARK: - Category Chips

    private func categoryChipsRow(viewModel: PromptBrowseViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PromptCategoryFilter.allCases) { filter in
                    CategoryChip(
                        title: filter.localizedTitle,
                        isSelected: viewModel.selectedCategory == filter,
                        action: { viewModel.selectedCategory = filter }
                    )
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Tag Chips

    private func tagChipsRow(viewModel: PromptBrowseViewModel) -> some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    TagChip(
                        title: "Any tag",
                        systemImage: "number",
                        isSelected: viewModel.selectedTag == nil,
                        action: { viewModel.selectedTag = nil }
                    )
                    ForEach(viewModel.availableTags, id: \.self) { tag in
                        TagChip(
                            title: tag,
                            systemImage: nil,
                            isSelected: viewModel.selectedTag == tag,
                            action: {
                                viewModel.selectedTag = viewModel.selectedTag == tag ? nil : tag
                            }
                        )
                    }
                }
                .padding(.horizontal, 12)
            }

            // Tag manager entry point — rename / delete tags across all prompts.
            Button {
                showingTagManagerSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(theme.fontCodeCaption.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .foregroundColor(theme.secondaryText)
                    .background(
                        Circle().fill(theme.surfaceOverlay)
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .help("Manage tags…")
            .accessibilityLabel("Manage tags")
        }
        .padding(.bottom, 10)
    }

    // MARK: - Error Banner

    private var errorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(theme.warningColor)
            if case .error(let message) = coordinator.promptBrowse.loadState {
                Text(message)
                    .font(theme.fontCaption)
                    .foregroundColor(theme.primaryText)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                PromptService.shared.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(theme.fontCaption)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accentColor)
            .help("Retry")
            .accessibilityLabel("Retry loading prompts")
        }
        .padding(10)
        .background(theme.warningColor.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.warningColor.opacity(0.3), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Prompt library error")
    }

    // MARK: - List

    @ViewBuilder
    private func promptList(viewModel: PromptBrowseViewModel) -> some View {
        if viewModel.filteredPrompts.isEmpty {
            SidebarEmptyStateView(
                title: viewModel.searchText.isEmpty && viewModel.selectedCategory == .all && viewModel.selectedTag == nil
                    ? "No Prompts"
                    : "No results",
                subtitle: emptyStateSubtitle(viewModel: viewModel),
                buttonTitle: viewModel.searchText.isEmpty ? "Create Prompt" : "Clear filters",
                systemImage: "tray",
                onAction: {
                    if viewModel.searchText.isEmpty && viewModel.selectedCategory == .all && viewModel.selectedTag == nil {
                        createEditVM.loadCreateDraft()
                        showingCreateSheet = true
                    } else {
                        viewModel.clearFilters()
                    }
                }
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                        if !viewModel.pinnedPrompts.isEmpty {
                            sectionHeader(title: "Pinned", systemImage: "pin.fill")
                            ForEach(viewModel.pinnedPrompts) { prompt in
                                rowFor(prompt, viewModel: viewModel)
                            }
                            if !viewModel.unpinnedPrompts.isEmpty {
                                sectionHeader(title: "All Prompts", systemImage: nil)
                                    .padding(.top, 8)
                            }
                        }
                        ForEach(viewModel.unpinnedPrompts) { prompt in
                            rowFor(prompt, viewModel: viewModel)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
                .focusable()
                .focused($isListFocused)
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    moveFocus(direction, in: viewModel.filteredPrompts)
                    if let id = focusedPromptID {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                .onKeyPress(.return) {
                    if let id = focusedPromptID {
                        router.navigateToPrompt(id)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.delete) {
                    if let id = focusedPromptID,
                       let prompt = viewModel.filteredPrompts.first(where: { $0.id == id }) {
                        if prompt.isUserDefined {
                            promptPendingDeletion = prompt
                        } else {
                            toastManager.show("Built-in prompts can't be deleted", style: .warning)
                        }
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress("p") {
                    if let id = focusedPromptID,
                       let prompt = viewModel.filteredPrompts.first(where: { $0.id == id }) {
                        viewModel.togglePin(prompt)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress("u") {
                    if let id = focusedPromptID,
                       let prompt = viewModel.filteredPrompts.first(where: { $0.id == id }),
                       !prompt.text.isEmpty {
                        useInChat(prompt)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress { press in
                    if press.key == "f" && press.modifiers.contains(.command) {
                        isSearchFocused = true
                        return .handled
                    }
                    return .ignored
                }
                .onAppear {
                    if focusedPromptID == nil {
                        focusedPromptID = activePromptID ?? viewModel.filteredPrompts.first?.id
                    }
                }
            }
        }
    }

    private func emptyStateSubtitle(viewModel: PromptBrowseViewModel) -> LocalizedStringKey {
        if !viewModel.searchText.isEmpty {
            return "No results for “\(viewModel.searchText)”"
        }
        if viewModel.selectedTag != nil {
            return "No prompts match the current filter"
        }
        if viewModel.selectedCategory != .all {
            return "No prompts in this category yet"
        }
        switch viewModel.selectedSource {
        case .user:    return "You haven't created any prompts yet"
        case .builtIn: return "No built-in prompts match"
        case .all:     return "Start creating prompts to build your library"
        }
    }

    @ViewBuilder
    private func rowFor(_ prompt: DevPrompt, viewModel: PromptBrowseViewModel) -> some View {
        PromptRowView(
            prompt: prompt,
            isSelected: activePromptID == prompt.id,
            isKeyboardFocused: focusedPromptID == prompt.id,
            onSelect: {
                focusedPromptID = prompt.id
                router.navigateToPrompt(prompt.id)
            },
            onEdit: {
                focusedPromptID = prompt.id
                router.navigateToPrompt(prompt.id)
            },
            onDelete: {
                promptPendingDeletion = prompt
            },
            onTogglePin: {
                viewModel.togglePin(prompt)
            },
            onUseInChat: {
                useInChat(prompt)
            },
            isSelectionMode: isSelectionMode,
            isBatchSelected: selectedIDs.contains(prompt.id),
            onToggleBatchSelect: {
                // Built-ins are undeletable, so block selection outright —
                // that way the Delete pill's count always matches what will
                // actually be removed and there's no "skipped" surprise.
                guard prompt.isUserDefined else {
                    toastManager.show("Built-in prompts can't be selected", style: .warning)
                    return
                }
                if selectedIDs.contains(prompt.id) {
                    selectedIDs.remove(prompt.id)
                    // Exit selection mode automatically once the last item
                    // is deselected — matches Finder / Mail expectations.
                    if selectedIDs.isEmpty { isSelectionMode = false }
                } else {
                    selectedIDs.insert(prompt.id)
                }
            },
            onEnterSelectionMode: {
                // Only allow entering selection mode from a user-defined row —
                // the first tap will also try to toggle that row on, so
                // starting from a built-in would be immediately frustrating.
                if prompt.isUserDefined {
                    isSelectionMode = true
                } else {
                    toastManager.show("Built-in prompts can't be selected", style: .warning)
                }
            }
        )
        .id(prompt.id)
    }

    /// Stages the prompt into the chat input and returns to chat. Shared
    /// behavior with the detail view's overflow-menu action, but invokable
    /// directly from the sidebar row (hover button + context menu) so users
    /// don't have to open the prompt just to insert it. No-op with an error
    /// toast if the prompt's text is empty (rare but possible for skeleton
    /// user-created entries).
    private func useInChat(_ prompt: DevPrompt) {
        if chatInputVM.stagePromptFromLibrary(prompt) {
            toastManager.show("Ready in chat input", style: .success)
            router.returnToChat()
        } else {
            toastManager.show("Prompt text is empty — nothing to insert", style: .error)
        }
    }

    // MARK: - Batch Selection

    /// Header shown when the user is in selection mode. Replaces the normal
    /// search/chips chrome (no sense filtering when you're about to act on
    /// a known set). Cancel exits, Delete opens the confirmation alert.
    private func batchHeaderRow(viewModel: PromptBrowseViewModel) -> some View {
        HStack(spacing: 10) {
            BatchHeaderTextButton(
                title: "Cancel",
                tint: theme.secondaryText,
                action: { exitSelectionMode() }
            )
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel batch selection")

            Spacer()

            Text("\(selectedIDs.count) selected")
                .font(theme.fontBody.weight(.semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            BatchHeaderTextButton(
                title: selectedIDs.count == viewModel.filteredPrompts.count ? "Deselect All" : "Select All",
                tint: theme.accentColor,
                action: { selectAllVisible(viewModel: viewModel) }
            )
            .help(selectedIDs.count == viewModel.filteredPrompts.count ? "Clear selection" : "Select all visible prompts")

            Button {
                showingBatchDeleteAlert = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(theme.fontCaption.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.errorColor.opacity(0.15))
                .foregroundColor(theme.errorColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(selectedIDs.isEmpty)
            .opacity(selectedIDs.isEmpty ? 0.5 : 1)
            .keyboardShortcut(.delete, modifiers: [.command])
            .help("Delete selected (⌘⌫)")
            .accessibilityLabel("Delete \(selectedIDs.count) selected prompts")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func selectAllVisible(viewModel: PromptBrowseViewModel) {
        // Select All only picks user-defined rows — built-ins are undeletable,
        // so including them in the selection would be misleading (the Delete
        // pill would show a count higher than what actually gets removed).
        let selectableIDs = Set(
            viewModel.filteredPrompts
                .filter { $0.isUserDefined }
                .map(\.id)
        )
        if selectedIDs == selectableIDs {
            // Already all selected → clear.
            selectedIDs.removeAll()
            if selectedIDs.isEmpty { exitSelectionMode() }
        } else {
            selectedIDs = selectableIDs
        }
    }

    private func exitSelectionMode() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isSelectionMode = false
            selectedIDs.removeAll()
        }
    }

    private func commitBatchDelete() {
        let requestedCount = selectedIDs.count
        let deleted = PromptService.shared.deletePrompts(withIds: selectedIDs)
        let skipped = requestedCount - deleted
        if deleted > 0 && skipped == 0 {
            toastManager.show("Deleted \(deleted) prompt\(deleted == 1 ? "" : "s")", style: .success)
        } else if deleted > 0 && skipped > 0 {
            toastManager.show("Deleted \(deleted) — skipped \(skipped) built-in", style: .warning)
        } else if deleted == 0 && skipped > 0 {
            toastManager.show("Nothing deleted — all \(skipped) were built-in", style: .warning)
        } else {
            toastManager.show("Couldn't delete prompts", style: .error)
        }
        exitSelectionMode()
    }

    // MARK: - Section Header

    private func sectionHeader(title: String, systemImage: String?) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(theme.fontCodeCaption.weight(.semibold))
            }
            Text(title.uppercased())
                .font(theme.fontCodeCaption.weight(.semibold))
                .tracking(0.5)
            Spacer()
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Keyboard navigation

    private func moveFocus(_ direction: MoveCommandDirection, in prompts: [DevPrompt]) {
        guard !prompts.isEmpty else { return }
        let ids = prompts.map(\.id)
        let currentIndex = focusedPromptID.flatMap { ids.firstIndex(of: $0) }
        let target: Int
        switch direction {
        case .up:
            target = max(0, (currentIndex ?? 0) - 1)
        case .down:
            target = min(ids.count - 1, (currentIndex ?? -1) + 1)
        default:
            return
        }
        focusedPromptID = ids[target]
    }
}

// MARK: - Refined Category Chip



// MARK: - Tag Chip

struct TagChip: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(theme.fontCodeCaption.weight(.semibold))
                }
                Text(title)
                    .font(theme.fontCodeCaption.weight(isSelected ? .semibold : .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
            .background(
                Capsule()
                    .fill(isSelected ? theme.accentColor.opacity(0.15) : theme.surfaceOverlay.opacity(isHovered ? 1 : 0.6))
            )
            .overlay(
                Capsule()
                    .stroke(
                        isSelected ? theme.accentColor.opacity(0.4) : Color.clear,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .accessibilityLabel("Tag \(title)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
