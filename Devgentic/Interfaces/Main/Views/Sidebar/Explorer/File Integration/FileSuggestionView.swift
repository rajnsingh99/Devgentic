//
//  FileSuggestionView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

// Logger for FileSuggestionView (Optional)
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "FileSuggestionView")

struct FileSuggestionView: View {
    // MARK: - Properties
    let files: [FileSystemItem] // The filtered list of files to display
    let suggestionQuery: String // The current query string after "@"
    let onSelectFile: (FileSystemItem) -> Void // Closure to call when a file is selected

    // MARK: - State
    @State private var hoveredItemID: FileSystemItem.ID? // Tracks the currently hovered item for visual feedback

    // MARK: - Constants
    private let rowHeight: CGFloat = 44 // Increased height to accommodate two lines of text
    private let maxListHeight: CGFloat = 180 // Max height for the suggestion list
    private let cornerRadiusValue: CGFloat = 8
    private let iconSize: CGFloat = 16

    // MARK: - Body
    var body: some View {
        if !files.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { fileItem in
                        Button(action: {
                            logger.info("File selected from suggestion: \(fileItem.name)")
                            onSelectFile(fileItem)
                        }) {
                            rowContent(for: fileItem)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .onHover { isHovering in
                            withAnimation(.easeInOut(duration: 0.1)) {
                                hoveredItemID = isHovering ? fileItem.id : nil
                            }
                        }

                        // Add a divider if it's not the last item
                        if fileItem.id != files.last?.id {
                            Divider()
                                .padding(.leading, 48) // Indent divider to align with text
                        }
                    }
                }
                .padding(4) // Padding inside the scroll view for the hover effect to have space
            }
            .frame(maxHeight: maxListHeight)
            .background(VisualEffectBlur(material: .sidebar).opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadiusValue))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadiusValue)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.15), radius: 5, x: 0, y: 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .onAppear {
                logger.debug("FileSuggestionView appeared with \(files.count) files for query '\(suggestionQuery)'.")
            }
        } else if !suggestionQuery.isEmpty {
            // Only show "No matching files" if the user has actually typed a query.
            Text("No matching files found.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VisualEffectBlur(material: .sidebar).opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadiusValue))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadiusValue)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.15), radius: 5, x: 0, y: 4)
                .transition(.opacity)
        }
        // If files are empty and the query is empty, show nothing (initial state).
    }

    // MARK: - View Builders
    
    /// Creates the view for a single row in the suggestion list.
    /// - Parameter fileItem: The file system item to display.
    /// - Returns: A view representing the file row.
    @ViewBuilder
    private func rowContent(for fileItem: FileSystemItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: fileItem.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .center) // Give icon a fixed-width container

            VStack(alignment: .leading, spacing: 2) {
                // Filename with the matched query part highlighted
                Text(highlightedText(for: fileItem.name, query: suggestionQuery))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // The path of the file for context
                Text(fileItem.url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(hoveredItemID == fileItem.id ? Color.gray.opacity(0.15) : Color.clear) // Apply hover effect
        .cornerRadius(6) // Rounded corners for the background highlight
    }

    // MARK: - Helper Methods

    /// Creates an attributed string with the query part highlighted in bold.
    /// - Parameters:
    ///   - fileName: The full text of the filename.
    ///   - query: The search query to highlight.
    /// - Returns: An `AttributedString` with the matched range styled.
    private func highlightedText(for fileName: String, query: String) -> AttributedString {
        var attributedString = AttributedString(fileName)
        
        // Apply default foreground color to the whole string
        attributedString.foregroundColor = Color(NSColor.labelColor)

        // If the query is not empty, find its range and make it bold
        if !query.isEmpty, let range = attributedString.range(of: query, options: .caseInsensitive) {
            attributedString[range].font = .system(size: 13, weight: .bold)
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

    static let sampleFilesShort: [FileSystemItem] = [
        FileSystemItem(id: URL(fileURLWithPath: "/path/to/short.txt"), name: "short.txt", url: URL(fileURLWithPath: "/path/to/short.txt"), isDirectory: false),
    ]
    
    static func handleSelection(_ item: FileSystemItem) {
        print("Preview: Selected file - \(item.name)")
    }

    static var previews: some View {
        VStack(spacing: 20) {
            Text("File Suggestions (Populated, query: 'doc')")
                .font(.headline)
            FileSuggestionView(
                files: sampleFiles,
                suggestionQuery: "doc",
                onSelectFile: handleSelection
            )
            .padding(.horizontal)

            Text("File Suggestions (Single Item)")
                .font(.headline)
            FileSuggestionView(
                files: sampleFilesShort,
                suggestionQuery: "short",
                onSelectFile: handleSelection
            )
            .padding(.horizontal)

            Text("File Suggestions (No Results)")
                .font(.headline)
            FileSuggestionView(
                files: [],
                suggestionQuery: "nonexistent",
                onSelectFile: handleSelection
            )
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 450) // Typical sidebar/panel width for context
        .background(Color(NSColor.windowBackgroundColor))
    }
}
