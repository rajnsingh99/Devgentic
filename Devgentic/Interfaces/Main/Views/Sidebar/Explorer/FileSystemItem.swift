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

    // MARK: - Noise / Dependency Detection
    var isIgnoredOrDependency: Bool {
        if isDirectory {
            let lower = name.lowercased()
            return lower == "node_modules" || lower == ".git" || lower == ".build" ||
                   lower == "dist" || lower == "build" || lower == ".deriveddata" ||
                   lower == "pods" || lower == ".next" || lower == ".cache"
        } else {
            return name == ".DS_Store" || name == "package-lock.json" ||
                   name == "yarn.lock" || name == "pnpm-lock.yaml"
        }
    }

    // MARK: - Enhanced Icon Name
    var iconName: String {
        if isDirectory {
            let lower = name.lowercased()
            if lower == "node_modules" { return "shippingbox.fill" }
            if lower == ".git" { return "arrow.triangle.branch" }
            if lower == ".github" { return "folder.fill" }
            if lower == "test" || lower == "tests" || lower == "__tests__" {
                return "folder.badge.gearshape"
            }
            return "folder.fill"
        }

        let ext = url.pathExtension.lowercased()
        let lowerName = name.lowercased()

        // Special filenames
        if lowerName == "package.json" { return "doc.text.below.ecg" }
        if lowerName.hasPrefix(".env") { return "lock.shield" }
        if lowerName == "dockerfile" || lowerName.hasPrefix("docker-compose") { return "server.rack" }
        if lowerName.hasPrefix("readme") { return "book.closed" }
        if lowerName.hasPrefix("license") { return "doc.plaintext" }
        if lowerName.hasPrefix(".git") { return "arrow.triangle.branch" }

        // File extensions
        switch ext {
        case "swift":
            return "swift"
        case "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "pyw", "go", "rs", "c", "h", "cpp", "hpp", "cc", "java", "kt", "kts", "rb", "php":
            return "chevron.left.forwardslash.chevron.right"
        case "html", "htm", "xml":
            return "chevron.left.slash.chevron.right"
        case "css", "scss", "sass", "less":
            return "paintbrush.fill"
        case "json":
            return "doc.text.below.ecg"
        case "yaml", "yml", "toml":
            return "slider.horizontal.3"
        case "sql", "sqlite", "db":
            return "cylinder.split.1x2"
        case "sh", "bash", "zsh", "fish":
            return "terminal.fill"
        case "md", "markdown", "mdx", "txt", "rtf", "log":
            return "doc.text"
        case "pdf":
            return "doc.richtext.fill"
        case "png", "jpg", "jpeg", "gif", "webp", "ico", "svg", "bmp", "tiff":
            return "photo.on.rectangle.angled"
        case "mp3", "wav", "m4a", "aac", "flac":
            return "speaker.wave.2.fill"
        case "mp4", "mov", "avi", "mkv", "webm":
            return "film.fill"
        case "zip", "tar", "gz", "tgz", "rar", "7z", "dmg":
            return "archivebox.fill"
        case "ttf", "otf", "woff", "woff2":
            return "textformat"
        default:
            if let type = UTType(filenameExtension: ext) {
                if type.conforms(to: .swiftSource) { return "swift" }
                if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
                if type.conforms(to: .image) { return "photo.on.rectangle.angled" }
                if type.conforms(to: .pdf) { return "doc.richtext.fill" }
                if type.conforms(to: .archive) { return "archivebox.fill" }
                if type.conforms(to: .json) { return "doc.text.below.ecg" }
                if type.conforms(to: .text) { return "doc.text" }
            }
            return "doc"
        }
    }
    
    // MARK: - Icon Color
    func iconColor(for theme: any Theme) -> Color {
        if isDirectory {
            if isIgnoredOrDependency {
                return theme.secondaryText.opacity(0.6)
            }
            return theme.accentColor
        }

        if isIgnoredOrDependency {
            return theme.secondaryText.opacity(0.55)
        }

        let ext = url.pathExtension.lowercased()
        let lowerName = name.lowercased()

        if lowerName.hasPrefix(".env") { return Color(hex: "#F59E0B") }
        if lowerName == "package.json" { return Color(hex: "#38BDF8") }
        if lowerName.hasPrefix("docker") { return Color(hex: "#06B6D4") }

        switch ext {
        case "swift":
            return Color(hex: "#F05138") // Swift Orange
        case "ts", "tsx":
            return Color(hex: "#38BDF8") // TypeScript Azure
        case "js", "jsx", "mjs", "cjs":
            return Color(hex: "#FBBF24") // JavaScript Gold
        case "html", "htm":
            return Color(hex: "#FB923C") // HTML Orange
        case "css", "scss", "sass", "less":
            return Color(hex: "#06B6D4") // CSS Cyan
        case "json":
            return Color(hex: "#F59E0B") // JSON Amber
        case "yaml", "yml", "toml":
            return Color(hex: "#A78BFA") // YAML Violet
        case "py", "pyw", "ipynb":
            return Color(hex: "#60A5FA") // Python Sky
        case "rs":
            return Color(hex: "#FB923C") // Rust Coral
        case "go":
            return Color(hex: "#22D3EE") // Go Cyan
        case "c", "h", "cpp", "hpp", "cc":
            return Color(hex: "#818CF8") // C/C++ Indigo
        case "java", "kt", "kts":
            return Color(hex: "#F97316") // Java/Kotlin
        case "sh", "bash", "zsh", "fish":
            return Color(hex: "#34D399") // Terminal Mint
        case "sql", "sqlite", "db":
            return Color(hex: "#38BDF8") // SQL Blue
        case "md", "markdown", "mdx":
            return Color(hex: "#94A3B8") // Slate
        case "pdf":
            return Color(hex: "#EF4444") // PDF Red
        case "png", "jpg", "jpeg", "gif", "webp", "ico", "svg":
            return Color(hex: "#C084FC") // Media Violet
        case "mp3", "wav", "m4a", "aac", "flac", "mp4", "mov", "avi":
            return Color(hex: "#F472B6") // Audio/Video Pink
        case "zip", "tar", "gz", "tgz", "rar", "7z", "dmg":
            return Color(hex: "#F59E0B") // Archive Amber
        default:
            if let type = UTType(filenameExtension: ext) {
                if type.conforms(to: .swiftSource) { return Color(hex: "#F05138") }
                if type.conforms(to: .image) { return Color(hex: "#C084FC") }
                if type.conforms(to: .archive) { return Color(hex: "#F59E0B") }
            }
            return theme.secondaryText
        }
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
