// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeViewerBreadcrumbsBar.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit

// MARK: - Breadcrumb Item Model

struct CodeViewerBreadcrumbItem: Identifiable, Equatable {
    let id: String
    let name: String
    let isFolder: Bool
    let fullURL: URL?
    let isLast: Bool

    /// Generates hierarchical breadcrumb items for a Code Viewer tab.
    ///
    /// If the tab has a real `filePath`, normalizes against the user's home directory (`~/...`)
    /// and generates a cumulative URL for each directory step leading up to the file.
    /// If the tab is an attachment or snippet, splits slash-separated names or falls back to the tab title.
    static func breadcrumbs(for tab: CodeViewerTab) -> [CodeViewerBreadcrumbItem] {
        if let path = tab.filePath, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            var components = url.pathComponents
            if components.first == "/" {
                components.removeFirst()
            }
            guard !components.isEmpty else {
                return [CodeViewerBreadcrumbItem(id: path, name: tab.title, isFolder: false, fullURL: url, isLast: true)]
            }

            let homeURL = FileManager.default.homeDirectoryForCurrentUser
            let homeComponents = homeURL.pathComponents.filter { $0 != "/" }

            var displayComponents: [(name: String, cumulativePath: String)] = []
            var currentAccumPath = ""

            if components.starts(with: homeComponents) {
                let afterHome = components.dropFirst(homeComponents.count)
                currentAccumPath = homeURL.path
                displayComponents.append(("~", currentAccumPath))
                for seg in afterHome {
                    currentAccumPath += "/" + seg
                    displayComponents.append((seg, currentAccumPath))
                }
            } else {
                for seg in components {
                    currentAccumPath += "/" + seg
                    displayComponents.append((seg, currentAccumPath))
                }
            }

            return displayComponents.enumerated().map { index, item in
                let isLast = index == displayComponents.count - 1
                return CodeViewerBreadcrumbItem(
                    id: item.cumulativePath,
                    name: item.name,
                    isFolder: !isLast,
                    fullURL: URL(fileURLWithPath: item.cumulativePath),
                    isLast: isLast
                )
            }
        } else if let fileName = tab.fileName, !fileName.isEmpty {
            let parts = fileName.split(separator: "/").map(String.init)
            if parts.count > 1 {
                var accum = ""
                return parts.enumerated().map { index, part in
                    accum += (accum.isEmpty ? "" : "/") + part
                    let isLast = index == parts.count - 1
                    return CodeViewerBreadcrumbItem(
                        id: accum,
                        name: part,
                        isFolder: !isLast,
                        fullURL: nil,
                        isLast: isLast
                    )
                }
            } else {
                return [
                    CodeViewerBreadcrumbItem(
                        id: fileName,
                        name: fileName,
                        isFolder: false,
                        fullURL: nil,
                        isLast: true
                    )
                ]
            }
        } else {
            return [
                CodeViewerBreadcrumbItem(
                    id: tab.id.uuidString,
                    name: tab.title,
                    isFolder: false,
                    fullURL: nil,
                    isLast: true
                )
            ]
        }
    }
}

// MARK: - Breadcrumbs Bar View

struct CodeViewerBreadcrumbsBar: View {
    let tab: CodeViewerTab
    let textColor: Color
    let secondaryColor: Color
    let accentColor: Color
    let backgroundColor: Color

    @State private var didCopyPath = false

    private var items: [CodeViewerBreadcrumbItem] {
        CodeViewerBreadcrumbItem.breadcrumbs(for: tab)
    }

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(items) { item in
                        CodeViewerBreadcrumbSegmentView(
                            item: item,
                            language: tab.effectiveLanguage ?? tab.snippet.language,
                            textColor: textColor,
                            secondaryColor: secondaryColor,
                            accentColor: accentColor
                        )

                        if !item.isLast {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(secondaryColor.opacity(0.35))
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 4)

            // Trailing Quick Action Buttons
            HStack(spacing: 4) {
                // Copy Path
                Button {
                    let textToCopy = tab.filePath ?? tab.fileName ?? tab.title
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(textToCopy, forType: .string)
                    didCopyPath = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        didCopyPath = false
                    }
                } label: {
                    Image(systemName: didCopyPath ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(didCopyPath ? .green : secondaryColor.opacity(0.75))
                        .frame(width: 20, height: 20)
                        .background(secondaryColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Copy path"))
                .accessibilityLabel(String(localized: "Copy path to clipboard"))

                // Reveal in Finder (when file-backed)
                if let path = tab.filePath {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Image(systemName: "macwindow")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(secondaryColor.opacity(0.75))
                            .frame(width: 20, height: 20)
                            .background(secondaryColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Reveal in Finder"))
                    .accessibilityLabel(String(localized: "Reveal active file in Finder"))
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            backgroundColor
                .overlay(
                    Rectangle()
                        .fill(secondaryColor.opacity(0.12))
                        .frame(height: 0.5),
                    alignment: .bottom
                )
        )
    }
}

// MARK: - Breadcrumb Segment View

fileprivate struct CodeViewerBreadcrumbSegmentView: View {
    let item: CodeViewerBreadcrumbItem
    let language: String?
    let textColor: Color
    let secondaryColor: Color
    let accentColor: Color

    @State private var isHovering = false

    var body: some View {
        Button {
            if let url = item.fullURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } label: {
            HStack(spacing: 3) {
                if item.isFolder {
                    Image(systemName: item.name == "~" ? "house" : "folder")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(isHovering ? accentColor : secondaryColor.opacity(0.65))
                } else {
                    Image(systemName: codeViewerLanguageIcon(for: language))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(item.isLast ? accentColor : secondaryColor.opacity(0.65))
                }

                Text(item.name)
                    .font(.system(size: 11, weight: item.isLast ? .medium : .regular))
                    .foregroundColor(item.isLast ? textColor : (isHovering ? textColor : secondaryColor.opacity(0.85)))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(isHovering ? secondaryColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(item.fullURL?.path ?? item.name)
        .contextMenu {
            if item.isFolder {
                if let url = item.fullURL {
                    Button(String(localized: "Reveal Folder in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }

                    Button(String(localized: "Open in Terminal")) {
                        let terminalAppURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                        if FileManager.default.fileExists(atPath: terminalAppURL.path) {
                            NSWorkspace.shared.open([url], withApplicationAt: terminalAppURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                        } else {
                            NSWorkspace.shared.open(url)
                        }
                    }

                    Divider()

                    Button(String(localized: "Copy Folder Path")) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(url.path, forType: .string)
                    }

                    Button(String(localized: "Copy Relative Path")) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(formatRelativePath(for: url.path), forType: .string)
                    }
                }
            } else {
                if let url = item.fullURL {
                    Button(String(localized: "Reveal in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }

                    Button(String(localized: "Open with System App")) {
                        NSWorkspace.shared.open(url)
                    }

                    Divider()

                    Button(String(localized: "Copy File Path")) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(url.path, forType: .string)
                    }

                    Button(String(localized: "Copy Relative Path")) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(formatRelativePath(for: url.path), forType: .string)
                    }

                    Button(String(localized: "Copy Filename")) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(item.name, forType: .string)
                    }
                } else {
                    Button(String(localized: "Copy Name")) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(item.name, forType: .string)
                    }
                }
            }
        }
    }
}
