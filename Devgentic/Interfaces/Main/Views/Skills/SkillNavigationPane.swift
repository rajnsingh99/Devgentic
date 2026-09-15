// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

struct SkillNavigationPane: View {

    @Environment(\.appTheme) private var theme
    @Environment(MainViewRouter.self) private var router

    @State private var showingImport = false
    @State private var showingCreate = false
    /// Bumped after a sheet writes, so this pane re-reads even when the store's own revision has
    /// already been observed once in this render pass.
    @State private var revision = 0

    /// ⚠️ Observes the STORE's revision as well as the local one. A mutation made in the content
    /// area has to invalidate this pane's read too — each view keeping only its own counter is why
    /// adding a skill in one place left the other showing a stale list.
    private var skillsResult: Result<[SkillSD], SkillStoreError> {
        _ = revision
        _ = SkillStore.shared.revision
        return SkillStore.shared.fetchSkills()
    }

    private var skills: [SkillSD] { (try? skillsResult.get()) ?? [] }

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
            if let storeFailure {
                unavailableState(storeFailure)
            } else if skills.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(skills, id: \.id) { skill in
                            skillRow(skill)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showingImport) {
            SkillImportSheet { revision += 1 }
        }
        .sheet(isPresented: $showingCreate) {
            SkillCreateSheet { _ in revision += 1 }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 6) {
            Text("Skills")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Spacer()
            Button { showingCreate = true } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Write a new skill")
            .accessibilityIdentifier("skills.create")

            Button { showingImport = true } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Add skills from a folder, archive or .md file")
            .accessibilityIdentifier("skills.add")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// Distinct from `emptyState` on purpose — see `storeFailure`.
    private func unavailableState(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Skill storage is unavailable", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your skills are still there — they cannot be read right now. Do not re-import them.")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No skills yet.")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
            Text("Add one from a folder, a .zip or a .md file — or write your own.")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText.opacity(0.8))
            HStack(spacing: 8) {
                Button("Add…") { showingImport = true }
                Button("Create…") { showingCreate = true }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func skillRow(_ skill: SkillSD) -> some View {
        Button {
            // ⚠️⚠️ THIS DISCARDED `skill` AND NAVIGATED TO THE BARE LIST. Clicking a named row
            // dropped the user on an unfiltered library with that skill neither selected nor open,
            // so the only way to inspect a skill was to find it a second time — and each click
            // pushed another entry on the navigation stack. The row names a skill; it opens it.
            router.navigate(to: .skillLibrary(profileID: nil, openSkillID: skill.id))
        } label: {
            HStack(spacing: 8) {
                // ⚠️ Draft and ready are DIFFERENT states with different consequences — a draft is
                // never offered to an agent even where it is linked — so they must not render alike.
                Circle()
                    .fill(skill.isDraft ? Color.orange : theme.accentColor.opacity(0.7))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(skill.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Text(subtitle(for: skill))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
