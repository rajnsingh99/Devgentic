// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolPathKeys.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Every argument name a native tool reads as a filesystem path, per tool: the one list both the tool's decoder
/// and `WorkspaceBoundary` read. Per tool, never one global set: `target` is a process id in `kill_process`,
/// and the boundary rewrites allowed paths to absolute form. A name is a path only where that tool's decoder says so.
enum ToolPathKeys {

    // MARK: - The decoders' own alias lists (read by the tools — order is their precedence)

    /// `edit_code`, `edit_code_single`, `edit_code_batch`, `create_file`, `create_new_file`,
    /// `overwrite_file`, `file_overview`.
    static let codingFile = ["file_path", "filePath", "path", "file"]
    static let listDirectory = ["path", "directory", "folder", "dir", "directoryPath", "folderPath", "targetPath"]
    static let readFile = ["path", "file", "filename", "filePath", "source", "target", "file_path"]
    static let writeFile = ["path", "file", "filename", "destination", "filepath", "target", "filePath"]
    static let deleteFile = ["path", "file", "filename", "item", "filePath", "target"]
    static let moveFileSource = ["source", "src", "from", "current_path", "source_path", "original", "sourcePath", "filePath"]
    static let moveFileDestination = ["destination", "dest", "to", "target", "new_path", "target_path",
                                      "destinationPath", "newPath", "targetPath"]
    static let copyFileSource = ["source", "src", "from", "current_path", "original", "sourcePath"]
    static let copyFileDestination = ["destination", "dest", "to", "target", "copy_path", "destinationPath"]
    static let createFolder = ["path", "folder", "directory", "dir", "name", "target", "folderPath", "directoryPath"]
    static let grepFiles = ["path", "directory", "dir", "folder"]
    static let previewFile = ["path", "file", "filePath"]
    static let spotlightScope = ["search_scope", "scope", "path", "folder", "directory", "searchScope"]
    static let fileMetadata = ["path", "filePath", "file", "filename"]
    /// Each may hold a string or an array of strings; the boundary checks both shapes.
    static let batchMoveSources = ["sourcePaths", "source_paths", "paths", "files", "sourcePath", "source_path",
                                   "path", "file", "src", "source", "from"]
    static let batchMoveDestination = ["destinationFolder", "destination_folder", "destination", "folder", "target",
                                       "dst", "to", "targetPath", "target_path", "output"]
    static let watchFolder = ["path", "folder", "directory", "dir"]

    // MARK: - What the boundary reads

    /// Tool name → every argument it reads as a path.
    static let byTool: [String: Set<String>] = {
        var table: [String: Set<String>] = [:]
        for tool in ["edit_code", "edit_code_single", "edit_code_batch", "create_file", "create_new_file",
                     "overwrite_file", "file_overview"] {
            table[tool] = Set(codingFile)
        }
        table["list_directory"] = Set(listDirectory)
        table["read_file"] = Set(readFile)
        table["write_file"] = Set(writeFile)
        table["delete_file"] = Set(deleteFile)
        table["move_file"] = Set(moveFileSource + moveFileDestination)
        table["copy_file"] = Set(copyFileSource + copyFileDestination)
        table["create_folder"] = Set(createFolder)
        table["grep_files"] = Set(grepFiles)
        table["preview_file"] = Set(previewFile)
        table["spotlight_search"] = Set(spotlightScope)
        table["read_file_metadata"] = Set(fileMetadata)
        table["batch_move_files"] = Set(batchMoveSources + batchMoveDestination)
        table["watch_folder"] = Set(watchFolder)
        return table
    }()

    /// The names `WorkspaceBoundary` treats as paths for `toolName`: the generic set it always
    /// checked, plus this tool's own aliases.
    static func pathArguments(forTool toolName: String) -> Set<String> {
        WorkspaceBoundary.pathArgumentNames.union(byTool[toolName] ?? [])
    }
}
