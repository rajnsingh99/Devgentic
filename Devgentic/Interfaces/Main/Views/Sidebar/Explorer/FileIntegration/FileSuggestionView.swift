// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileSuggestionView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

// Logger for FileSuggestionView (Optional)
private let logger = DGLogger(category: "FileSuggestionView")

struct FileSuggestionView: View {
    // MARK: - Properties
    let files: [FileSystemItem]
    let suggestionQuery: String

    // MARK: - State
    @Binding var selectedItemID: FileSystemItem.ID?
    @Binding var multiSelectedFileIDs: Set<FileSystemItem.ID>
    @State private var hoveredItemID: FileSystemItem.ID?
    @Environment(\.appTheme) private var theme

    // MARK: - Constants
    private let rowHeight: CGFloat = 44
    private let maxListHeight: CGFloat = 180
    private let cornerRadiusValue: CGFloat = 8
    private let iconSize: CGFloat = 16

    // MARK: - Body
    var body: some View {
        Group {
            if !files.isEmpty {
                // CASE 1: Files found
                fileListView
            } else if !suggestionQuery.isEmpty {
                // CASE 2: Query exists, but no files found
                emptyStateView(text: "No matching files found.")
            } else {
                // CASE 3: Initial Trigger (@ typed, query is empty, results pending)
                // This fixes the issue where the view didn't appear immediately on typing "@"
                emptyStateView(text: "Type to search files")
            }
        }
    }

    // MARK: - Subviews
    
    private var fileListView: some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { fileItem in
                        Button(action: {
                            toggleSelection(for: fileItem.id)
                        }) {
                            rowContent(for: fileItem)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .id(fileItem.id)
                        .onHover { isHovering in
                            withAnimation(.easeInOut(duration: 0.1)) {
                                hoveredItemID = isHovering ? fileItem.id : nil
                            }
                        }

                        if fileItem.id != files.last?.id {
                            Divider()
                                .padding(.leading, 60)
                        }
                    }
                }
                .padding(4)
            }
            .onChange(of: selectedItemID) { _, newId in
                if let newId {
                    withAnimation {
                        scrollViewProxy.scrollTo(newId, anchor: .center)
                    }
                }
            }
        }
        .frame(maxHeight: maxListHeight)
        .appSurface(in: .rect(cornerRadius: cornerRadiusValue), elevation: .popover)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .onAppear {
            logger.debug("FileSuggestionView appeared with \(files.count) files for query '\(suggestionQuery)'.")
            if selectedItemID == nil, let firstId = files.first?.id {
                selectedItemID = firstId
            }
        }
    }
    
    private func emptyStateView(text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(theme.secondaryText)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSurface(in: .rect(cornerRadius: cornerRadiusValue), elevation: .popover)
            .transition(.opacity)
    }

    // MARK: - View Builders
    
    @ViewBuilder
    private func rowContent(for fileItem: FileSystemItem) -> some View {
        let isFocused = selectedItemID == fileItem.id
        let isSelected = multiSelectedFileIDs.contains(fileItem.id)
        let isHovered = hoveredItemID == fileItem.id
        
        HStack(spacing: 12) {
            // New Checkbox view
            CheckboxView(isChecked: .constant(isSelected))
                .padding(.leading, 4)

            Image(systemName: fileItem.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundColor(theme.secondaryText)
                .frame(width: 20, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedText(for: fileItem.name, query: suggestionQuery))
                    .font(theme.fontSubheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(fileItem.url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(
            ZStack {
                if isSelected {
                    theme.accentColor.opacity(0.2)
                } else if isHovered || isFocused {
                    theme.secondaryText.opacity(0.15)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.1), value: isSelected)
        .animation(.easeInOut(duration: 0.1), value: isFocused)
    }

    // MARK: - Helper Methods

    private func toggleSelection(for itemID: FileSystemItem.ID) {
        if multiSelectedFileIDs.contains(itemID) {
            multiSelectedFileIDs.remove(itemID)
        } else {
            multiSelectedFileIDs.insert(itemID)
        }
    }

    private func highlightedText(for fileName: String, query: String) -> AttributedString {
        var attributedString = AttributedString(fileName)
        attributedString.foregroundColor = theme.primaryText
        if !query.isEmpty, let range = attributedString.range(of: query, options: .caseInsensitive) {
            attributedString[range].font = .system(.subheadline, weight: .bold)
        }
        return attributedString
    }
}

// MARK: - Preview Provider
struct FileSuggestionView_Previews: PreviewProvider {
    static let sampleFiles: [FileSystemItem] = [
        FileSystemItem(id: URL(fileURLWithPath: "/Users/alice/Documents/ProjectAlpha/Source/very_long_document_name_that_should_be_truncated.pdf"), name: "very_long_document_name_that_should_be_truncated.pdf", url: URL(fileURLWithPath: "/Users/alice/Documents/ProjectAlpha/Source/very_long_document_name_that_should_be_truncated.pdf"), isDirectory: false),
        FileSystemItem(id: URL(fileURLWithPath: "/Users/alice/Documents/ProjectAlpha/Assets/image.png"), name: "image.png", url: URL(fileURLWithPath: "/Users/alice/Documents/ProjectAlpha/Assets/image.png"), isDirectory: false),
        FileSystemItem(id: URL(fileURLWithPath: "/Users/alice/Documents/ProjectAlpha/Source/script.swift"), name: "script.swift", url: URL(fileURLWithPath: "/Users/alice/Documents/ProjectAlpha/Source/script.swift"), isDirectory: false),
        FileSystemItem(id: URL(fileURLWithPath: "/Users/alice/Documents/ProjectAlpha/another_file_with_a_long_name.txt"), name: "another_file_with_a_long_name.txt", url: URL(fileURLWithPath: "/path/to/another.txt"), isDirectory: false),
        FileSystemItem(id: URL(fileURLWithPath: "/Users/alice/Documents/data.csv"), name: "data.csv", url: URL(fileURLWithPath: "/Users/alice/Documents/data.csv"), isDirectory: false),
    ]
    
    struct PreviewWrapper: View {
        @State private var selectedID: FileSystemItem.ID? = sampleFiles[1].id
        @State private var multiSelectedIDs: Set<FileSystemItem.ID> = [sampleFiles[0].id, sampleFiles[2].id]

        var body: some View {
            FileSuggestionView(
                files: sampleFiles,
                suggestionQuery: "doc",
                selectedItemID: $selectedID,
                multiSelectedFileIDs: $multiSelectedIDs
            )
        }
    }

    static var previews: some View {
        VStack(spacing: 20) {
            Text("File Suggestions (Multi-select)")
                .font(.headline)
            
            PreviewWrapper()
                .padding(.horizontal)
        }
        .padding()
        .frame(width: 450)
        .background(AppThemes.MaterialTheme().primaryBackground)
    }
}
