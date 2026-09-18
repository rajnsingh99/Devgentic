// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
// FileSystemItem.swift
import SwiftUI
import UniformTypeIdentifiers

struct FileSystemItem: Identifiable, Hashable {
    let id: URL
    var name: String
    var url: URL
    var isDirectory: Bool
    var children: [FileSystemItem]? = nil

    // MARK: - Enhanced Icon Name
    var iconName: String {
        if isDirectory {
            return "folder.fill"
        } else {
            // Use UTType for more accurate file type detection
            if let type = UTType(filenameExtension: url.pathExtension) {
                if type.conforms(to: .swiftSource) { return "swift" }
                if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
                if type.conforms(to: .image) { return "photo.on.rectangle.angled" }
                if type.conforms(to: .pdf) { return "doc.richtext.fill" }
                if type.conforms(to: .archive) { return "archivebox.fill" }
                if type.conforms(to: .json) { return "doc.text.below.ecg" }
                if type.conforms(to: .text) { return "doc.text" }
            }
            // Fallback for any other file type
            return "doc"
        }
    }
    
    // MARK: - Icon Color
    /// Provides a specific color for the icon based on the file type and the current theme.
    func iconColor(for theme: any Theme) -> Color {
        if isDirectory {
            return theme.accentColor // Use the theme's accent color for all folders
        }
        
        if let type = UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .swiftSource) { return Color(hex: "#F05138") } // Orange for Swift
            if type.conforms(to: .image) { return Color(hex: "#8E44AD") } // Purple for images
            if type.conforms(to: .archive) { return Color(hex: "#F39C12") } // Yellow for archives
        }
        
        // For all other files, use the theme's secondary text color for a subtle look.
        return theme.secondaryText
    }

    // FileTypeDescription and other properties remain the same...
    var fileTypeDescription: String {
        if isDirectory { return "Folder" }
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return url.pathExtension.isEmpty ? "File" : "\(url.pathExtension.uppercased()) File"
        }
        return type.localizedDescription ?? "File"
    }

    var childrenLoaded: Bool {
        return children != nil
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FileSystemItem, rhs: FileSystemItem) -> Bool {
        lhs.id == rhs.id
    }
}
