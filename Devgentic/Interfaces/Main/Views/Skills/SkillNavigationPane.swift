// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillNavigationPane.swift
//  Devgentic
//
//  The Skills tab's sidebar: the library itself, plus the two ways to add to it.
//
//  ⚠️ REWRITTEN FOR V6. This used to list skill SOURCES — folders on disk, with per-source Rescan,
//  Reveal in Finder and Remove. None of those exist any more: Devgentic owns skill content, so
//  there is no folder to rescan, reveal or lose. What the pane lists now is skills.
//
//  ⚠️ Reads the library, never a profile. Skills are global; which profile links which is the
//  content area's job, and putting it here is what made five profiles keep five copies.
//

import SwiftUI

// MARK: - Category Filter Enum

enum SkillCategoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case created = "Created"
    case imported = "Imported"
    case drafts = "Drafts"

    var id: String { rawValue }
    var localizedTitle: LocalizedStringKey { LocalizedStringKey(rawValue) }
}

struct SkillNavigationPane: View {

    @Environment(\.appTheme) private var theme
    @Environment(MainViewRouter.self) private var router

    @State private var showingImport = false
    @State private var showingCreate = false
    /// Bumped after a sheet writes, so this pane re-reads even when the store's own revision has
    /// already been observed once in this render pass.
    @State private var revision = 0

    @State private var searchText: String = ""
    @State private var selectedCategory: SkillCategoryFilter = .all
    @State private var focusedSkillID: String? = nil
    @State private var hoveredSkillID: String? = nil
    @State private var skillPendingDeletion: SkillSD? = nil

    @FocusState private var isListFocused: Bool
    @FocusState private var isSearchFocused: Bool

    /// Currently active skill in the router's content view.
    private var activeSkillID: String? {
        if case .skillDetail(let id) = router.activeDestination { return id }
        return nil
    }

    /// ⚠️ Observes the STORE's revision as well as the local one. A mutation made in the content
    /// area has to invalidate this pane's read too — each view keeping only its own counter is why
    /// adding a skill in one place left the other showing a stale list.
    private var skillsResult: Result<[SkillSD], SkillStoreError> {
        _ = revision
        _ = SkillStore.shared.revision
        return SkillStore.shared.fetchSkills()
    }

    private var skills: [SkillSD] { (try? skillsResult.get()) ?? [] }

    private var filteredSkills: [SkillSD] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return skills.filter { skill in
            let matchesCategory: Bool
            switch selectedCategory {
            case .all:
                matchesCategory = true
            case .created:
                matchesCategory = skill.origin == .created
            case .imported:
                matchesCategory = skill.origin == .imported
            case .drafts:
                matchesCategory = skill.isDraft
            }

            guard matchesCategory else { return false }

            if query.isEmpty { return true }
            return skill.displayName.lowercased().contains(query) ||
                skill.id.lowercased().contains(query) ||
                skill.name.lowercased().contains(query)
        }
    }

    /// ⚠️ "Storage is down" and "you have no skills yet" are DIFFERENT states with opposite
    /// remedies, and collapsing them is what makes a user re-create everything they already had.
    /// The store returns a `Result` precisely so this distinction survives to the UI.
    private var storeFailure: String? {
        if case .failure(let error) = skillsResult { return error.localizedDescription }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !skills.isEmpty {
                SidebarSearchBarView("Search skills...", text: $searchText)
                    .focused($isSearchFocused)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SkillCategoryFilter.allCases) { filter in
                            CategoryChip(
                                title: filter.localizedTitle,
                                isSelected: selectedCategory == filter,
                                action: { selectedCategory = filter }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.bottom, 10)

                Divider()
                    .background(theme.dividerColor.opacity(0.4))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            if let storeFailure {
                unavailableState(storeFailure)
            } else if skills.isEmpty {
                emptyState
            } else if filteredSkills.isEmpty {
                noMatchesView
            } else {
                skillsList
            }
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showingImport) {
            SkillImportSheet { revision += 1 }
        }
        .sheet(isPresented: $showingCreate) {
            SkillCreateSheet { _ in revision += 1 }
        }
        .alert("Delete Skill?", isPresented: Binding(
            get: { skillPendingDeletion != nil },
            set: { if !$0 { skillPendingDeletion = nil } }
        ), presenting: skillPendingDeletion) { skill in
            Button("Delete Permanently", role: .destructive) {
                _ = SkillStore.shared.deleteSkill(id: skill.id)
                revision += 1
                if focusedSkillID == skill.id {
                    focusedSkillID = nil
                }
                if activeSkillID == skill.id {
                    router.navigate(to: .skillLibrary(profileID: nil))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { skill in
            Text("“\(skill.displayName)” will be permanently removed.")
        }
        .onAppear {
            if focusedSkillID == nil {
                focusedSkillID = activeSkillID ?? filteredSkills.first?.id
            }
        }
        .onChange(of: activeSkillID) { _, newID in
            if let newID {
                focusedSkillID = newID
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .createSkill)) { _ in
            showingCreate = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .importSkills)) { _ in
            showingImport = true
        }
        .onChange(of: filteredSkills.map(\.id)) { _, newIDs in
            if let id = focusedSkillID, !newIDs.contains(id) {
                focusedSkillID = newIDs.first
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Text("Skills")
                .font(theme.fontBody.weight(.semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            // Import Button
            Button {
                showingImport = true
            } label: {
                Image(systemName: "arrow.down.doc")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.surfaceOverlay)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.secondaryText.opacity(0.18), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Import skills from a folder, archive or .md file (⌘I)")
            .keyboardShortcut("i", modifiers: [.command])
            .accessibilityIdentifier("skills.add")

            // New Skill Button
            SidebarHeaderActionButton(
                title: "New",
                systemImage: "plus",
                shortcut: "⌘N"
            ) {
                showingCreate = true
            }
            .keyboardShortcut("n", modifiers: [.command])
            .accessibilityIdentifier("skills.create")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var skillsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(filteredSkills, id: \.id) { skill in
                        skillRow(skill)
                            .id(skill.id)
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
                moveFocus(direction, in: filteredSkills)
                if let id = focusedSkillID {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onKeyPress(.return) {
                if let id = focusedSkillID,
                   let skill = filteredSkills.first(where: { $0.id == id }) {
                    router.navigate(to: .skillDetail(skillID: skill.id))
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.delete) {
                if let id = focusedSkillID,
                   let skill = filteredSkills.first(where: { $0.id == id }) {
                    skillPendingDeletion = skill
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
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection, in items: [SkillSD]) {
        guard !items.isEmpty else { return }
        guard let currentID = focusedSkillID,
              let currentIndex = items.firstIndex(where: { $0.id == currentID }) else {
            focusedSkillID = items.first?.id
            return
        }

        switch direction {
        case .down:
            let nextIndex = min(currentIndex + 1, items.count - 1)
            focusedSkillID = items[nextIndex].id
        case .up:
            let prevIndex = max(currentIndex - 1, 0)
            focusedSkillID = items[prevIndex].id
        default:
            break
        }
    }

    /// Distinct from `emptyState` on purpose — see `storeFailure`.
    private func unavailableState(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Skill storage is unavailable", systemImage: "exclamationmark.triangle")
                .font(theme.fontSubheadline.weight(.medium))
                .foregroundStyle(.orange)
            Text(reason)
                .font(theme.fontCaption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your skills are still there — they cannot be read right now. Do not re-import them.")
                .font(theme.fontCaption2)
                .foregroundStyle(theme.secondaryText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        SidebarEmptyStateView(
            title: "No Skills",
            subtitle: "Create a custom skill or import from a package to empower your agents.",
            buttonTitle: "New Skill",
            systemImage: "puzzlepiece",
            onAction: { showingCreate = true }
        )
    }

    private var noMatchesView: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 20)
            Text("No matching skills")
                .font(theme.fontSubheadline)
                .foregroundColor(theme.secondaryText)

            Button("Clear filters") {
                searchText = ""
                selectedCategory = .all
            }
            .buttonStyle(.plain)
            .font(theme.fontCaption.weight(.medium))
            .foregroundColor(theme.accentColor)

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
    }

    private func skillRow(_ skill: SkillSD) -> some View {
        let isSelected = activeSkillID == skill.id
        let isFocused = isListFocused && focusedSkillID == skill.id
        let isHovered = hoveredSkillID == skill.id

        return Button {
            focusedSkillID = skill.id
            router.navigate(to: .skillDetail(skillID: skill.id))
        } label: {
            HStack(spacing: 0) {
                // Left indicator rail = STATE: accent when selected, focused, or hovered
                if isSelected || isHovered || isFocused {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(
                            LinearGradient(
                                colors: isSelected ? [theme.accentColor, theme.accentColor.opacity(0.45)] : [theme.accentColor.opacity(0.4), theme.accentColor.opacity(0.15)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 3)
                        .padding(.vertical, isSelected ? 2 : 5)
                        .padding(.trailing, 5)
                        .shadow(color: isSelected ? theme.accentColor.opacity(0.4) : .clear, radius: 4)
                        .transition(.opacity.combined(with: .scale))
                } else {
                    Spacer().frame(width: 8)
                }

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.displayName)
                        .font(theme.fontFootnote.weight(isSelected ? .semibold : .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Text(subtitle(for: skill))
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // Draft Pill Badge
                if skill.isDraft {
                    Text("Draft")
                        .font(theme.fontCodeCaption.weight(.medium))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.accentColor.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(theme.accentColor.opacity(0.15), lineWidth: 0.5)
                            )
                            .shadow(color: theme.accentColor.opacity(0.05), radius: 4, x: 0, y: 0)
                    } else if isFocused {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.surfaceOverlayStrong)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(theme.accentColor.opacity(0.35), lineWidth: 1)
                            )
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.surfaceOverlay)
                    }
                }
            )
            .overlay(alignment: .trailing) {
                if isHovered {
                    Button {
                        skillPendingDeletion = skill
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.errorColor.opacity(0.85))
                            .frame(width: 22, height: 22)
                            .background(
                                Circle()
                                    .fill(theme.errorColor.opacity(0.12))
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .padding(.trailing, 8)
                    .help("Delete skill")
                    .accessibilityLabel("Delete \(skill.displayName)")
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredSkillID = hovering ? skill.id : (hoveredSkillID == skill.id ? nil : hoveredSkillID)
            }
        }
        .contextMenu {
            Button {
                focusedSkillID = skill.id
                router.navigate(to: .skillDetail(skillID: skill.id))
            } label: {
                Label("Open Skill", systemImage: "puzzlepiece")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(skill.name, forType: .string)
            } label: {
                Label("Copy Identifier", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                skillPendingDeletion = skill
            } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        }
    }

    private func subtitle(for skill: SkillSD) -> String {
        var parts: [String] = []
        if skill.isDraft { parts.append("Draft") }
        let versions = skill.versions.count
        parts.append("\(versions) version\(versions == 1 ? "" : "s")")
        if let files = skill.latestVersion?.files.count, files > 0 {
            parts.append("\(files) file\(files == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}
