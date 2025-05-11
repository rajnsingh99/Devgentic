// FileSystemItem.swift
// (Create this file, e.g., in a new "Explorer" group under "Models" or "Interfaces/MainUI/Views/Sidebar/Explorer")
import SwiftUI

struct FileSystemItem: Identifiable, Hashable {
    let id: URL // Use URL as the unique ID for file system items
    var name: String
    var url: URL
    var isDirectory: Bool
    var children: [FileSystemItem]? = nil // Loaded lazily for directories

    var iconName: String {
        if isDirectory {
            // We can differentiate between open/closed folder icons later if needed
            return "folder.fill"
        } else {
            // Basic document icon, can be enhanced for specific file types
            return "doc"
        }
    }

    // Helper to check if children have been loaded (for lazy loading)
    var childrenLoaded: Bool {
        return children != nil
    }
}
