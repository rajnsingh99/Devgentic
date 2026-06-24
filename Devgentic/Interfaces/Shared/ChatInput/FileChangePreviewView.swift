//
//  FileChangePreviewView.swift
//  Devgentic
//
//  [HITL A2] Diff / preview for file-mutating tool confirmations. The highest-stakes approvals
//  (write / delete / move / copy / create_folder) previously showed only a one-line args string;
//  this renders what will actually change — a unified diff for write_file (vs the on-disk file),
//  and a concise source→destination / target summary for the others.
//

import SwiftUI

// MARK: - Parsed file operation

enum FileChange: Equatable {
    case write(path: String, content: String)
    case delete(path: String)
    case move(source: String, destination: String)
    case copy(source: String, destination: String)
    case createFolder(path: String)

    /// Parse a file operation from a confirmation's tool name + structured arguments (A1).
    /// Returns nil for non-file tools or unparseable args (banner falls back to the JSON view).
    static func parse(toolName: String, arguments: JSONValue?) -> FileChange? {
        guard case .object(let dict)? = arguments else { return nil }
        func value(_ keys: [String]) -> String? {
            for key in keys { if case .string(let v)? = dict[key] { return v } }
            return nil
        }
        // Alias lists mirror the tools' own decoders (NativeFileSystemTools.swift) so the preview
        // appears for whatever key the model used.
        let writeKeys = ["path", "file", "filename", "destination", "filepath", "target", "filePath"]
        let deleteKeys = ["path", "file", "filename", "item", "filePath", "target", "filepath"]
        let folderKeys = ["path", "folder", "directory", "dir", "name", "target", "folderPath", "directoryPath"]
        let contentKeys = ["content", "text", "body", "data", "string"]
        let srcKeys = ["source", "src", "from", "current_path", "source_path", "original", "sourcePath", "filePath"]
        let dstKeys = ["destination", "dest", "to", "target", "new_path", "target_path", "destinationPath", "newPath", "targetPath", "copy_path"]

        switch toolName {
        case "write_file":
            guard let p = value(writeKeys), !p.isEmpty else { return nil }
            return .write(path: p, content: value(contentKeys) ?? "")
        case "delete_file":
            guard let p = value(deleteKeys), !p.isEmpty else { return nil }
            return .delete(path: p)
        case "move_file":
            guard let s = value(srcKeys), let d = value(dstKeys) else { return nil }
            return .move(source: s, destination: d)
        case "copy_file":
            guard let s = value(srcKeys), let d = value(dstKeys) else { return nil }
            return .copy(source: s, destination: d)
        case "create_folder":
            guard let p = value(folderKeys), !p.isEmpty else { return nil }
            return .createFolder(path: p)
        default:
            return nil
        }
    }
}

/// Abbreviates an absolute path with `~` for display.
private func displayPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

// MARK: - Preview

struct FileChangePreviewView: View {
    let change: FileChange
    @Environment(\.appTheme) private var theme

    var body: some View {
        switch change {
        case .write(let path, let content):
            WriteFilePreview(path: path, newContent: content)
        case .delete(let path):
            FileOpSummary(icon: "trash", tint: theme.errorColor, verb: "Delete", path: path)
        case .move(let s, let d):
            FilePathTransition(icon: "arrow.right", verb: "Move", from: s, to: d)
        case .copy(let s, let d):
            FilePathTransition(icon: "doc.on.doc", verb: "Copy", from: s, to: d)
        case .createFolder(let path):
            FileOpSummary(icon: "folder.badge.plus", tint: theme.warningColor, verb: "Create folder", path: path)
        }
    }
}

// MARK: - Write diff

private struct WriteFilePreview: View {
    let path: String
    let newContent: String
    @Environment(\.appTheme) private var theme

    /// Above this size we skip the line-by-line diff (memory) and show a byte summary instead.
    private static let diffByteLimit = 1_000_000

    @State private var diff: [DiffResult] = []
    @State private var fileExisted = false      // decode-independent existence (drives Create/Overwrite)
    @State private var existingReadable = true  // false when the existing file can't be UTF-8 decoded
    @State private var tooLarge = false
    @State private var loading = true

    private var addedCount: Int { diff.filter { $0.type == .added }.count }
    private var removedCount: Int { diff.filter { $0.type == .deleted }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: fileExisted ? "pencil.line" : "doc.badge.plus")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(fileExisted ? theme.warningColor : theme.successColor)
                Text(fileExisted ? "Overwrite" : "Create")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(fileExisted ? theme.warningColor : theme.successColor)
                Text(displayPath(path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if !loading && !tooLarge && existingReadable {
                    Text("+\(addedCount) −\(removedCount)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            if loading {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else if tooLarge {
                Text("\(newContent.utf8.count.formatted(.byteCount(style: .file))) — diff skipped")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            } else if fileExisted && !existingReadable {
                Text("Existing content can't be previewed (binary or unreadable)")
                    .font(.system(size: 10))
                    .foregroundColor(theme.warningColor)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.prefix(400)) { result in
                            diffLine(result)
                        }
                        if diff.count > 400 {
                            Text("… \(diff.count - 400) more lines")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 170)
            }
        }
        .task(id: path) { await computeDiff() }
    }

    @ViewBuilder
    private func diffLine(_ result: DiffResult) -> some View {
        let (bg, fg, sign): (Color, Color, String) = {
            switch result.type {
            case .added:     return (theme.successColor.opacity(0.14), theme.successColor, "+")
            case .deleted:   return (theme.errorColor.opacity(0.14), theme.errorColor, "−")
            case .unchanged: return (Color.clear, theme.tertiaryText, " ")
            }
        }()
        HStack(spacing: 4) {
            Text(sign).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(fg).frame(width: 8)
            Text(result.line.isEmpty ? " " : result.line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(result.type == .unchanged ? theme.secondaryText : fg)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 0.5)
        .background(bg)
    }

    private func computeDiff() async {
        loading = true
        let resolved = (path as NSString).expandingTildeInPath
        let content = newContent
        let limit = Self.diffByteLimit
        // Read + diff off the main actor (files can be large; DiffUtility caps at 5k lines).
        let result = await Task.detached(priority: .userInitiated) {
            () -> (exists: Bool, readable: Bool, big: Bool, diff: [DiffResult]) in
            // Existence is decode-independent — a binary / UTF-16 / unreadable file still EXISTS and
            // will be overwritten, so the verdict must not depend on a successful UTF-8 read.
            let exists = FileManager.default.fileExists(atPath: resolved)
            // Skip the diff (memory) for very large writes; check existing size cheaply too.
            let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
            let existingSize = (attrs?[.size] as? Int) ?? 0
            if content.utf8.count > limit || existingSize > limit {
                return (exists, true, true, [])
            }
            let existing = try? String(contentsOfFile: resolved, encoding: .utf8)
            let readable = !exists || existing != nil
            return (exists, readable, false, DiffUtility.generateDiff(original: existing ?? "", modified: content))
        }.value
        fileExisted = result.exists
        existingReadable = result.readable
        tooLarge = result.big
        diff = result.diff
        loading = false
    }
}

// MARK: - Non-diff summaries

private struct FileOpSummary: View {
    let icon: String
    let tint: Color
    let verb: String
    let path: String
    @Environment(\.appTheme) private var theme
    @State private var exists: Bool?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(.caption2, weight: .semibold)).foregroundColor(tint)
            Text(verb).font(.system(.caption2, weight: .semibold)).foregroundColor(tint)
            Text(displayPath(path))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let exists {
                Text(exists ? "exists" : "not found")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(exists ? theme.tertiaryText : theme.warningColor)
            }
        }
        .task(id: path) {
            let resolved = (path as NSString).expandingTildeInPath
            exists = await Task.detached { FileManager.default.fileExists(atPath: resolved) }.value
        }
    }
}

private struct FilePathTransition: View {
    let icon: String
    let verb: String
    let from: String
    let to: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(.caption2, weight: .semibold)).foregroundColor(theme.warningColor)
                Text(verb).font(.system(.caption2, weight: .semibold)).foregroundColor(theme.warningColor)
            }
            Text(displayPath(from))
                .font(.system(size: 11, design: .monospaced)).foregroundColor(theme.secondaryText)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.right").font(.system(size: 9)).foregroundColor(theme.tertiaryText)
                Text(displayPath(to))
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(theme.primaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
