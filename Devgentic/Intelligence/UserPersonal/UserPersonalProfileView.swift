//
//  UserPersonalProfileView.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Container View (with DynamicIslandBar)

/// Wraps the profile content for display in the main content area.
/// Action buttons (Analyze, Edit, Export, Reset) live in the DynamicIslandBar.
struct UserPersonalContainerView: View {

    @ObservedObject private var service = UserPersonalService.shared
    @Environment(\.appTheme) private var theme

    @State private var isEditing: Bool = false
    @State private var editableText: String = ""
    @State private var showExportDialog: Bool = false
    @State private var showResetConfirmation: Bool = false
    @State private var exportDocument: MarkdownProfileDocument?

    var body: some View {
        VStack(spacing: 0) {
            // Island bar with actions
            DynamicIslandBar {
                // Center: Title + status
                HStack(spacing: 8) {
                    Image(systemName: "person.text.rectangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.accentColor)

                    Text("Your Profile")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    if let lastUpdated = service.lastUpdated {
                        Text("· \(lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
            } trailing: {
                islandActionButtons
            }

            // Content area
            if isEditing {
                editView
            } else {
                readOnlyView
            }
        }
        .fileExporter(
            isPresented: $showExportDialog,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "UserProfile.md"
        ) { _ in }
        .alert("Reset Profile?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                service.resetProfile()
            }
        } message: {
            Text("This will clear all learned observations and reset the profile to its default state. This cannot be undone.")
        }
    }

    // MARK: - Island Action Buttons

    private var islandActionButtons: some View {
        HStack(spacing: 8) {
            if isEditing {
                // --- Edit mode: Revert + Save ---
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isEditing = false }
                } label: {
                    Text("Revert")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.surfaceOverlay))
                }
                .buttonStyle(.plain)

                Button {
                    service.updateProfile(with: editableText)
                    withAnimation(.easeInOut(duration: 0.2)) { isEditing = false }
                } label: {
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.green))
                }
                .buttonStyle(.plain)
            } else {
                // --- View mode: Analyze + Export + Edit + More ---
                Button {
                    Task { await service.analyzeRecentConversations() }
                } label: {
                    HStack(spacing: 4) {
                        if service.isAnalyzing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                        }
                        Text(service.isAnalyzing ? "Analyzing..." : "Analyze")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(service.isAnalyzing)

                Button {
                    exportDocument = MarkdownProfileDocument(content: service.profileMarkdown)
                    showExportDialog = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.surfaceOverlay))
                }
                .buttonStyle(.plain)
                .help("Export as Markdown")

                Button {
                    editableText = service.profileMarkdown
                    withAnimation(.easeInOut(duration: 0.2)) { isEditing = true }
                } label: {
                    Text("Edit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.surfaceOverlay))
                }
                .buttonStyle(.plain)

                Menu {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("Reset Profile", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.surfaceOverlay))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    // MARK: - Read-Only View

    private var readOnlyView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                let blocks = parseMarkdown(service.profileMarkdown)
                ForEach(blocks) { block in
                    ProfileBlockRenderer(block: block, theme: theme)
                }
            }
            .padding(24)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Edit View

    private var editView: some View {
        TextEditor(text: $editableText)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(16)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.secondaryBackground.opacity(0.3))
    }
}

// MARK: - Welcome View Profile Card

/// A compact card shown on the WelcomeView that summarizes the profile status
/// and lets the user tap to view the full profile.
struct UserPersonalWelcomeCard: View {

    @ObservedObject private var service = UserPersonalService.shared
    @Environment(\.appTheme) private var theme
    @Environment(MainViewRouter.self) private var router

    @State private var isHovering = false

    /// Whether the profile has any real content (not just placeholders).
    private var hasContent: Bool {
        service.getProfileForInjection() != nil
    }

    /// Count sections with actual observations.
    private var populatedSectionCount: Int {
        UserProfileSection.allCases.filter { section in
            let header = "## \(section.rawValue)"
            guard let range = service.profileMarkdown.range(of: header) else { return false }
            let afterHeader = service.profileMarkdown[range.upperBound...]
            let nextHeader = afterHeader.range(of: "\n## ")
            let sectionContent: Substring
            if let nextHeader = nextHeader {
                sectionContent = afterHeader[..<nextHeader.lowerBound]
            } else {
                sectionContent = afterHeader
            }
            return !sectionContent.contains("_No observations yet._") && sectionContent.trimmingCharacters(in: .whitespacesAndNewlines).count > 5
        }.count
    }

    var body: some View {
        Button {
            router.navigateToUserPersonalProfile()
        } label: {
            HStack(spacing: 14) {
                // Icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor.opacity(isHovering ? 0.25 : 0.15), theme.accentColor.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 38, height: 38)

                    Image(systemName: "person.text.rectangle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.accentColor)
                }

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Your Profile")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        if hasContent {
                            Text("\(populatedSectionCount)/\(UserProfileSection.allCases.count)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(theme.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(theme.accentColor.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }

                    if hasContent {
                        if let lastUpdated = service.lastUpdated {
                            Text("Updated \(lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                    } else {
                        Text("Tap to view — learns from your conversations")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.controlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isHovering ? theme.accentColor.opacity(0.4) : theme.surfaceOverlayStrong,
                        lineWidth: 1
                    )
            )
            .shadow(color: theme.primaryText.opacity(isHovering ? 0.08 : 0.03), radius: isHovering ? 12 : 6, x: 0, y: 4)
            .scaleEffect(isHovering ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) { isHovering = hovering }
        }
    }
}

// MARK: - Profile Block Renderer

/// Lightweight renderer for profile markdown blocks.
/// Handles the subset of `ContentBlock.BlockType` relevant to profiles:
/// headings, paragraphs, list items, horizontal rules, and blockquotes.
struct ProfileBlockRenderer: View {
    let block: ContentBlock
    let theme: any Theme

    var body: some View {
        switch block.type {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            paragraphView(text: text)
        case .listItem(_, let text, let indentation):
            listItemView(text: text, indentation: indentation)
        case .horizontalRule:
            Divider()
                .background(theme.dividerColor)
                .padding(.vertical, 8)
        case .code(_, let content, _):
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.secondaryBackground)
                .cornerRadius(6)
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        case .image:
            EmptyView()
        }
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        let size: CGFloat = level == 1 ? 22 : (level == 2 ? 16 : 14)
        let weight: Font.Weight = level <= 2 ? .bold : .semibold

        HStack(spacing: 8) {
            if level == 2 {
                // Section headers get their icon
                if let section = UserProfileSection.allCases.first(where: { text.contains($0.rawValue) }) {
                    Image(systemName: section.icon)
                        .font(.system(size: 13))
                        .foregroundColor(theme.accentColor)
                }
            }

            Text(text)
                .font(.system(size: size, weight: weight, design: .rounded))
                .foregroundColor(theme.primaryText)
        }
        .padding(.top, level == 1 ? 4 : 16)
        .padding(.bottom, level == 1 ? 2 : 6)
    }

    private func paragraphView(text: String) -> some View {
        Group {
            if text.hasPrefix("_") && text.hasSuffix("_") {
                // Italic placeholder text
                Text(text.trimmingCharacters(in: CharacterSet(charactersIn: "_")))
                    .font(.system(size: 13))
                    .italic()
                    .foregroundColor(theme.tertiaryText)
            } else if text.hasPrefix(">") {
                // Blockquote
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.accentColor.opacity(0.4))
                        .frame(width: 3)

                    Text(text.trimmingCharacters(in: CharacterSet(charactersIn: "> ")))
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(3)
                }
                .padding(.vertical, 4)
            } else {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func listItemView(text: String, indentation: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(theme.accentColor.opacity(0.7))
                .frame(width: 5, height: 5)
                .padding(.top, 6)

            Text(text)
                .font(.system(size: 13))
                .foregroundColor(theme.primaryText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(indentation) * 16)
        .padding(.vertical, 2)
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                ForEach(headers, id: \.self) { header in
                    Text(header)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
            .background(theme.secondaryBackground)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    ForEach(row, id: \.self) { cell in
                        Text(cell)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
        }
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.dividerColor, lineWidth: 0.5)
        )
    }
}
