// FileSystemItem.swift
// (Located in your "Models" or "Explorer" group)
import SwiftUI
import UniformTypeIdentifiers // Make sure this is imported

struct FileSystemItem: Identifiable, Hashable {
    let id: URL // Use URL as the unique ID for file system items
    var name: String
    var url: URL
    var isDirectory: Bool
    var children: [FileSystemItem]? = nil // Loaded lazily for directories

    // MARK: - Enhanced Icon Name
    var iconName: String {
        if isDirectory {
            return "folder.fill" // Standard folder icon
        } else {
            // Try to get a type-specific icon using UTType
            if let type = UTType(filenameExtension: url.pathExtension) {
                if type.conforms(to: .sourceCode) || type.conforms(to: .text) {
                    // For source code and text files, use the "< >" icon from the screenshot
                    // We'll use "chevron.left.forwardslash.chevron.right" as a proxy for "< / >"
                    // or "curlybraces" for a more code-like feel.
                    // Let's use "doc.text" for now and customize in AttachedFilePillView if a custom SVG/image is needed.
                    // For a symbol that looks somewhat like "< >": "chevron.left.slash.chevron.right" is available.
                    // Or, if you want to exactly match the screenshot, you might need a custom asset or SF Symbol that looks like "</>".
                    // For now, let's use a generic code/text icon.
                    return "doc.text" // Placeholder, will be refined in PillView if needed for the exact < >
                }
                if type.conforms(to: .image) {
                    return "photo.fill"
                }
                if type.conforms(to: .pdf) {
                    return "doc.richtext.fill" // PDFs often look like rich text docs
                }
                // Add more specific UTType checks here if needed
            }
            return "doc" // Generic document icon as a fallback
        }
    }
    
    // MARK: - Enhanced File Type Description
    var fileTypeDescription: String {
        if isDirectory {
            return "Folder"
        }
        
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            // Fallback for unknown extensions or if extension is missing
            if url.pathExtension.isEmpty {
                return "File"
            }
            return "\(url.pathExtension.uppercased()) File"
        }

        // Provide more specific descriptions based on UTType
        if type.conforms(to: .sourceCode) {
            // Specific known source code types
            if type.identifier == "com.apple.swift-source" { return "Swift Source Code" }
            if type.identifier == "public.python-script" { return "Python Source Code" }
            if type.identifier == "com.netscape.javascript-source" { return "JavaScript Source Code" }
            if type.identifier == "public.c-source" { return "C Source Code" }
            if type.identifier == "public.c-plus-plus-source" { return "C++ Source Code" }
            if type.identifier == "com.sun.java-source" { return "Java Source Code" }
            // Generic fallback for other source code
            return type.localizedDescription ?? "Source Code"
        }
        
        if type.conforms(to: .text) { return type.localizedDescription ?? "Text Document" }
        if type.conforms(to: .image) { return type.localizedDescription ?? "Image" }
        if type.conforms(to: .pdf) { return "PDF Document" }
        if type.conforms(to: .archive) { return type.localizedDescription ?? "Archive" }
        if type.conforms(to: .spreadsheet) { return type.localizedDescription ?? "Spreadsheet" }
        if type.conforms(to: .presentation) { return type.localizedDescription ?? "Presentation" }
        if type.conforms(to: .database) { return type.localizedDescription ?? "Database" }
        
        // General fallback using localized description from UTType
        if let localizedDesc = type.localizedDescription, !localizedDesc.isEmpty {
            return localizedDesc
        }
        
        // If localizedDescription is too generic (like "Document"), use the extension
        if !url.pathExtension.isEmpty {
            return "\(url.pathExtension.uppercased()) File"
        }
        
        return "File" // Absolute fallback
    }

    // Helper to check if children have been loaded (for lazy loading)
    var childrenLoaded: Bool {
        return children != nil
    }

    // Conformance to Hashable (id is unique)
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FileSystemItem, rhs: FileSystemItem) -> Bool {
        lhs.id == rhs.id
    }
}
