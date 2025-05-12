//
//  FileSuggestionView.swift
//  Devgentic
//
//  Created by Raj Singh on 12/05/25.
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

    // MARK: - Constants
    private let rowHeight: CGFloat = 28
    private let maxListHeight: CGFloat = 150 // Max height for the suggestion list
    private let cornerRadiusValue: CGFloat = 8
    private let iconSize: CGFloat = 16

    // MARK: - Body
    var body: some View {
        if files.isEmpty {
            // Optionally, show a "No results" message or just an empty view
            // For now, an empty view, so it doesn't take space if no files.
            EmptyView()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { fileItem in
                        Button(action: {
                            logger.info("File selected from suggestion: \(fileItem.name)")
                            onSelectFile(fileItem)
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: fileItem.iconName) // Using iconName from FileSystemItem
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: iconSize, height: iconSize)
                                    .foregroundColor(.secondary)

                                Text(fileItem.name)
                                    .font(.system(size: 13))
                                    .foregroundColor(Color(NSColor.labelColor))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                Spacer() // Pushes content to the left
                            }
                            .padding(.horizontal, 10)
                            .frame(height: rowHeight)
                        }
                        .buttonStyle(PlainButtonStyle()) // Use PlainButtonStyle for custom row appearance
                        .background(Color.clear) // Ensure button background is clear

                        // Add a divider if it's not the last item
                        if fileItem.id != files.last?.id {
                            Divider()
                                .padding(.leading, 10) // Indent divider slightly
                        }
                    }
                }
            }
            .frame(maxHeight: maxListHeight) // Limit the height of the scrollable area
            .background(VisualEffectBlur(material: .sidebar).opacity(0.8)) // Semi-transparent background
            .clipShape(RoundedRectangle(cornerRadius: cornerRadiusValue))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadiusValue)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2)
            .transition(.opacity.combined(with: .move(edge: .bottom))) // Nice transition
            .onAppear {
                logger.debug("FileSuggestionView appeared with \(files.count) files for query '\(suggestionQuery)'.")
            }
        }
    }
}

// MARK: - Preview Provider
struct FileSuggestionView_Previews: PreviewProvider {
    static let sampleFiles: [FileSystemItem] = [
        FileSystemItem(id: URL(fileURLWithPath: "/path/to/document.pdf"), name: "very_long_document_name_that_should_be_truncated.pdf", url: URL(fileURLWithPath: "/path/to/document.pdf"), isDirectory: false),
        FileSystemItem(id: URL(fileURLWithPath: "/path/to/image.png"), name: "image.png", url: URL(fileURLWithPath: "/path/to/image.png"), isDirectory: false),
        FileSystemItem(id: URL(fileURLWithPath: "/path/to/script.swift"), name: "script.swift", url: URL(fileURLWithPath: "/path/to/script.swift"), isDirectory: false),
        FileSystemItem(id: URL(fileURLWithPath: "/path/to/another.txt"), name: "another_file_with_a_long_name.txt", url: URL(fileURLWithPath: "/path/to/another.txt"), isDirectory: false),
        FileSystemItem(id: URL(fileURLWithPath: "/path/to/data.csv"), name: "data.csv", url: URL(fileURLWithPath: "/path/to/data.csv"), isDirectory: false),
    ]

    static let sampleFilesShort: [FileSystemItem] = [
        FileSystemItem(id: URL(fileURLWithPath: "/path/to/short.txt"), name: "short.txt", url: URL(fileURLWithPath: "/path/to/short.txt"), isDirectory: false),
    ]
    
    static func handleSelection(_ item: FileSystemItem) {
        print("Preview: Selected file - \(item.name)")
    }

    static var previews: some View {
        VStack(spacing: 20) {
            Text("File Suggestions (Populated)")
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

            Text("File Suggestions (Empty)")
                .font(.headline)
            FileSuggestionView(
                files: [],
                suggestionQuery: "nonexistent",
                onSelectFile: handleSelection
            )
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 350) // Typical sidebar/panel width for context
        .background(Color(NSColor.windowBackgroundColor))
    }
}
