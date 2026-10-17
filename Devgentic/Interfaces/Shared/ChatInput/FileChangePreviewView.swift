// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    /// `append` = write_file's append mode, where `content` is the appended FRAGMENT,
    /// not the full file — the preview must reconstruct existing + fragment or it shows
    /// the whole file as deleted.
    case write(path: String, content: String, append: Bool)
    case delete(path: String)
    case move(source: String, destination: String)
    case copy(source: String, destination: String)
    case createFolder(path: String)
    /// A search-and-replace edit — `edit_code_single` / `edit_code_batch`.
    ///
    /// ⚠️⚠️ ADDED 2026-09-20 because the Code interface had NO file preview at all. Every tool
    /// this enum understood (`write_file`, `delete_file`, `move_file`, `copy_file`,
    /// `create_folder`) is a `.library` tool, and `write_file` is `.libraryExceptCode` — hidden
    /// from Code profiles. So a Code-mode approval banner fell back to raw JSON for every edit it
    /// ever showed. Field-observed: a user approved an `edit_code_batch` whose `old_string` was a
    /// whole method body, because serialized JSON does not look destructive. It deleted
    /// `greetRaj()`, duplicated another method, and left the file uncompilable.
    case replace(path: String, hunks: [ReplacementHunk])

    /// One search-and-replace pair. Kept as a type (not a tuple) so `FileChange` stays `Equatable`.
    struct ReplacementHunk: Equatable {
        let oldString: String
        let newString: String
    }

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

        // Append flag, mirroring WriteFileTool's own decoder: alias keys, Bool or
        // Bool-coercible string, plus 0/1 numbers (models emit all three).
        func flag(_ keys: [String]) -> Bool {
            for key in keys {
                switch dict[key] {
                case .bool(let b)?: return b
                case .string(let s)?: if let b = Bool(s.lowercased()) { return b }
                case .number(let n)?: return n != 0
                default: continue
                }
            }
            return false
        }

        switch toolName {
        case "write_file":
            guard let p = value(writeKeys), !p.isEmpty else { return nil }
            return .write(path: p,
                          content: value(contentKeys) ?? "",
                          append: flag(["append", "isAppend", "shouldAppend", "appending"]))
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

        // ── Code preset ────────────────────────────────────────────────────────────────────
        // ⚠️ These four are `.codeOnly`, so they reach ONLY the Code interface — the one place
        // that had no preview. `create_new_file` / `overwrite_file` are full-content writes and
        // reuse `.write` unchanged; only search-and-replace needed a new shape.

        // ⚠️ `file_path` EXACTLY — not the `writeKeys` alias list. Those aliases exist because
        // the library tools have lenient hand-written decoders; these four declare
        // `let file_path: String` with a synthesized `Decodable`, so any other spelling fails to
        // decode and the tool never runs. Previewing a looser key would draw a confident diff for
        // a call that is about to error. (Caught by `CodeEditPreviewTests` — `writeKeys` contains
        // `filepath` and `filePath` but not `file_path`, so reusing it previewed nothing at all.)
        case "create_new_file", "overwrite_file":
            guard case .string(let p)? = dict["file_path"], !p.isEmpty else { return nil }
            return .write(path: p, content: value(contentKeys) ?? "", append: false)

        case "edit_code_single":
            guard case .string(let p)? = dict["file_path"], !p.isEmpty,
                  case .string(let oldStr)? = dict["old_string"],
                  case .string(let newStr)? = dict["new_string"] else { return nil }
            return .replace(path: p, hunks: [ReplacementHunk(oldString: oldStr, newString: newStr)])

        case "edit_code_batch":
            guard case .string(let p)? = dict["file_path"], !p.isEmpty,
                  case .array(let raw)? = dict["edits"] else { return nil }
            let hunks: [ReplacementHunk] = raw.compactMap { entry in
                guard case .object(let e) = entry,
                      case .string(let oldStr)? = e["old_string"],
                      case .string(let newStr)? = e["new_string"] else { return nil }
                return ReplacementHunk(oldString: oldStr, newString: newStr)
            }
            // A batch whose edits could not be decoded is NOT previewable — fall through to the
            // JSON view rather than showing a confident "no changes" diff.
            guard hunks.count == raw.count, !hunks.isEmpty else { return nil }
            return .replace(path: p, hunks: hunks)

        default:
            return nil
        }
    }
}

// `diffLineText`, `DiffLineRow` and `DiffLinesList` live in `CodeViewer/DiffLineView.swift`,
// shared with the Git Changes panel.

/// The path the tool will ACTUALLY act on, abbreviated with `~` for display.
///
/// Resolving first is load-bearing, not cosmetic. A model that emits a bare relative path
/// (`January2026.java`) has that path anchored to HOME by `FilePathResolver`, but the raw
/// string renders as a lone filename — so an approval banner built from it looked exactly
/// like an edit to the file the user had attached, while the write landed in the home
/// folder (field-observed 2026-07-25). Resolved, the same call reads `~/January2026.java`
/// and the wrong target is obvious before the user approves it.
private func displayPath(_ path: String) -> String {
    (FilePathResolver.resolve(path) as NSString).abbreviatingWithTildeInPath
}

// MARK: - Preview

struct FileChangePreviewView: View {
    let change: FileChange
    @Environment(\.appTheme) private var theme

    var body: some View {
        switch change {
        case .write(let path, let content, let append):
            WriteFilePreview(path: path, newContent: content, append: append)
        case .delete(let path):
            FileOpSummary(icon: "trash", tint: theme.errorColor, verb: "Delete", path: path)
        case .move(let s, let d):
            FilePathTransition(icon: "arrow.right", verb: "Move", from: s, to: d)
        case .copy(let s, let d):
            FilePathTransition(icon: "doc.on.doc", verb: "Copy", from: s, to: d)
        case .createFolder(let path):
            FileOpSummary(icon: "folder.badge.plus", tint: theme.warningColor, verb: "Create folder", path: path)
        case .replace(let path, let hunks):
            ReplaceFilePreview(path: path, hunks: hunks)
        }
    }
}

// MARK: - Write diff

private struct WriteFilePreview: View {
    let path: String
    let newContent: String
    /// write_file append mode: `newContent` is the FRAGMENT; the previewed post-state is
    /// existing + fragment.
    let append: Bool
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
                // Append to an existing file is additive (success tint), overwrite is
                // destructive (warning tint), create is new (success tint).
                let isAppendToExisting = append && fileExisted
                Image(systemName: isAppendToExisting ? "text.append" : (fileExisted ? "pencil.line" : "doc.badge.plus"))
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(fileExisted && !isAppendToExisting ? theme.warningColor : theme.successColor)
                Text(isAppendToExisting ? "Append to" : (fileExisted ? "Overwrite" : "Create"))
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(fileExisted && !isAppendToExisting ? theme.warningColor : theme.successColor)
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
                    DiffLinesList(diff: diff)
                }
                .frame(maxHeight: 170)
            }
        }
        .task(id: path) { await computeDiff() }
    }

    private func computeDiff() async {
        loading = true
        let resolved = FilePathResolver.resolve(path)
        let content = newContent
        let isAppend = append
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
            // Append mode: `content` is the fragment; the post-state being approved is
            // existing + fragment. Diffing the fragment alone rendered the entire file
            // as deleted — the inverse of what the user was approving.
            let effectiveNew = (isAppend && exists) ? ((existing ?? "") + content) : content
            return (exists, readable, false, DiffUtility.generateDiff(original: existing ?? "", modified: effectiveNew))
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
            let resolved = FilePathResolver.resolve(path)
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

// MARK: - Search-and-replace diff

/// Previews `edit_code_single` / `edit_code_batch` by applying their hunks to the file ON DISK
/// and diffing the real before/after.
///
/// ⚠️⚠️ Deliberately NOT a diff of the hunks in isolation. Rendering `old_string` as red and
/// `new_string` as green would be cheaper, but it cannot answer the question that matters —
/// *what does the file look like afterwards?* The edit that prompted this view replaced a whole
/// method body with a DIFFERENT method: shown as two isolated blobs it reads as "some code
/// changes"; shown against the file it reads as "`greetRaj()` disappears and a second copy of
/// `farewell()` appears", which is refusable at a glance.
///
/// ⚠️ It also reports hunks whose `old_string` is ABSENT or AMBIGUOUS. Those make the tool fail
/// or edit the wrong occurrence, and the old JSON banner gave no hint before approval.
private struct ReplaceFilePreview: View {
    let path: String
    let hunks: [FileChange.ReplacementHunk]
    @Environment(\.appTheme) private var theme

    /// Matches `WriteFilePreview` — above this we skip the line diff rather than hold two copies.
    private static let diffByteLimit = 1_000_000

    @State private var diff: [DiffResult] = []
    @State private var fileExisted = false
    @State private var existingReadable = true
    @State private var tooLarge = false
    @State private var loading = true
    /// Hunks whose `old_string` does not appear exactly once, with the count found.
    @State private var unmatched: [(index: Int, occurrences: Int)] = []

    private var addedCount: Int { diff.filter { $0.type == .added }.count }
    private var removedCount: Int { diff.filter { $0.type == .deleted }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.line")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text(hunks.count == 1 ? "Edit" : "Edit (\(hunks.count) changes)")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text(displayPath(path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if !loading && !tooLarge && existingReadable && fileExisted {
                    Text("+\(addedCount) −\(removedCount)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            // ⚠️ Surfaced ABOVE the diff: a hunk that will not apply is the most important thing
            // on screen, because approving it wastes a turn or edits the wrong place.
            if !unmatched.isEmpty {
                ForEach(unmatched, id: \.index) { problem in
                    Text(problem.occurrences == 0
                         ? "Change \(problem.index + 1) won't apply — its search text isn't in this file"
                         : "Change \(problem.index + 1) is ambiguous — its search text appears \(problem.occurrences) times")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.warningColor)
                }
            }

            if loading {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else if !fileExisted {
                Text("File doesn't exist — this edit will fail")
                    .font(.system(size: 10))
                    .foregroundColor(theme.warningColor)
            } else if !existingReadable {
                Text("Existing content can't be previewed (binary or unreadable)")
                    .font(.system(size: 10))
                    .foregroundColor(theme.warningColor)
            } else if tooLarge {
                Text("File too large — diff skipped")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
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
                .frame(maxHeight: 160)
            }
        }
        .task(id: path) { await load() }
    }

    @ViewBuilder
    private func diffLine(_ result: DiffResult) -> some View {
        let tint: Color = result.type == .added ? theme.successColor
                        : result.type == .deleted ? theme.errorColor
                        : theme.secondaryText
        diffLineText(result, emphasisBackground: tint)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .background(result.type == .unchanged ? Color.clear : tint.opacity(0.08))
    }

    private func load() async {
        // Resolve first — the same reason `displayPath` does. A bare relative path anchors
        // elsewhere, and previewing the wrong file is worse than previewing none.
        let resolved = FilePathResolver.resolve(path)
        let (existing, existed, readable) = await Task.detached(priority: .userInitiated) { () -> (String, Bool, Bool) in
            guard FileManager.default.fileExists(atPath: resolved) else { return ("", false, true) }
            guard let data = FileManager.default.contents(atPath: resolved) else { return ("", true, false) }
            guard let text = String(data: data, encoding: .utf8) else { return ("", true, false) }
            return (text, true, true)
        }.value

        fileExisted = existed
        existingReadable = readable
        guard existed, readable else { loading = false; return }

        guard existing.utf8.count <= Self.diffByteLimit else {
            tooLarge = true
            loading = false
            return
        }

        // Apply the hunks in order, exactly as the tool will, and record any that won't land.
        var result = existing
        var problems: [(index: Int, occurrences: Int)] = []
        for (i, hunk) in hunks.enumerated() {
            let occurrences = result.components(separatedBy: hunk.oldString).count - 1
            if occurrences != 1 {
                problems.append((index: i, occurrences: occurrences))
                // Do not apply an ambiguous or missing hunk — the previewed post-state must match
                // what the tool would actually produce, and the tool refuses these too.
                continue
            }
            if let range = result.range(of: hunk.oldString) {
                result.replaceSubrange(range, with: hunk.newString)
            }
        }

        unmatched = problems
        diff = DiffUtility.generateDiff(original: existing, modified: result)
        loading = false
    }
}
