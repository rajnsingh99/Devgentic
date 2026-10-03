// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ExplorerView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit

struct ExplorerSidebarView: View {

    @Environment(ExplorerViewModel.self) var viewModel
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appTheme) private var theme
    @Environment(\.openWindow) var openWindow
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel: ChatHistoryViewModel?
    
    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Header
            HStack(spacing: 6) {
                Text("Explorer")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if viewModel.selectedRootURL != nil {
                    HStack(spacing: 2) {
                        TactileIconButton(
                            icon: "doc.badge.plus",
                            tooltip: "New File",
                            variant: .subtle,
                            size: 24
                        ) {
                            viewModel.createNewFile(in: nil)
                        }

                        TactileIconButton(
                            icon: "folder.badge.plus",
                            tooltip: "New Folder",
                            variant: .subtle,
                            size: 24
                        ) {
                            viewModel.createNewFolder(in: nil)
                        }

                        TactileIconButton(
                            icon: "arrow.clockwise",
                            tooltip: "Refresh",
                            variant: .subtle,
                            size: 24
                        ) {
                            viewModel.refresh()
                        }

                        TactileIconButton(
                            icon: "chevron.up.chevron.down",
                            tooltip: "Collapse All",
                            variant: .subtle,
                            size: 24
                        ) {
                            viewModel.collapseAll()
                        }

                        TactileIconButton(
                            icon: "folder",
                            tooltip: "Change Folder",
                            variant: .subtle,
                            size: 24
                        ) {
                            viewModel.selectRootDirectory()
                        }
                    }
                } else {
                    SidebarHeaderActionButton(
                        title: "Open Folder",
                        systemImage: "folder.badge.plus",
                        action: {
                            viewModel.selectRootDirectory()
                        }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if viewModel.selectedRootURL != nil {
                // MARK: - Search Bar
                SidebarSearchBarView("Search files", text: $viewModel.searchText)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)

                // MARK: - File Tree
                if let errorMessage = viewModel.errorMessage, viewModel.rootItems.isEmpty && !viewModel.isLoading {
                    // Error State
                    SidebarEmptyStateView(
                        title: "Load Error",
                        subtitle: LocalizedStringKey(errorMessage),
                        buttonTitle: "Retry",
                        buttonIcon: "arrow.clockwise",
                        systemImage: "exclamationmark.triangle",
                        onAction: {
                            if let rootURL = viewModel.selectedRootURL {
                                viewModel.loadDirectoryContents(for: rootURL)
                            }
                        }
                    )
                } else if viewModel.rootItems.isEmpty && viewModel.isLoading {
                    VStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading...")
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredRootItems.isEmpty && !viewModel.searchText.isEmpty {
                    SidebarEmptyStateView(
                        title: "No matches",
                        subtitle: "No files found for \"\(viewModel.searchText)\"",
                        buttonTitle: "Clear Search",
                        systemImage: "magnifyingglass",
                        onAction: {
                            viewModel.searchText = ""
                        }
                    )
                } else {
                    FileOutlineView(viewModel: viewModel)
                }

            } else {
                // MARK: - Empty State
                SidebarEmptyStateView(
                    title: "No Project Open",
                    subtitle: "Open a folder to start working with your codebase context.",
                    buttonTitle: "Open Folder",
                    buttonIcon: "folder.badge.plus",
                    systemImage: "folder.badge.plus",
                    onAction: {
                        viewModel.selectRootDirectory()
                    }
                )
            }
        }
        // Modern sidebar background (Translucent)
        .background(Color.clear)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            setupOpenFileHandler()
        }
        .onAppear {
            setupOpenFileHandler()
        }
    }

    private func setupOpenFileHandler() {
        viewModel.onOpenFileRequested = { [weak chatHistoryViewModel, weak viewModel] item in
            if let chatHistoryViewModel {
                FileOpenCoordinator.open(item: item, in: chatHistoryViewModel, fallbackViewModel: viewModel)
            } else {
                viewModel?.openWithSystemApp(item)
            }
        }
    }
}

// MARK: - Components

// MARK: - Custom OutlineView with Indentation Guides
final class ExplorerOutlineView: NSOutlineView {
    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        guard indentationPerLevel > 0 else { return }

        let visibleRows = rows(in: clipRect)
        guard visibleRows.length > 0 else { return }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor)
        context.setLineWidth(0.5)

        for row in visibleRows.location..<(visibleRows.location + visibleRows.length) {
            let lvl = level(forRow: row)
            guard lvl > 1 else { continue }
            let rowFrame = rect(ofRow: row)
            for ancestorLevel in 1..<lvl {
                let x = CGFloat(ancestorLevel) * indentationPerLevel + 8.5
                context.move(to: CGPoint(x: x, y: rowFrame.minY))
                context.addLine(to: CGPoint(x: x, y: rowFrame.maxY))
            }
        }
        context.strokePath()
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            let clickedRow = self.row(at: point)
            let targetRow = clickedRow >= 0 ? clickedRow : selectedRow
            if targetRow >= 0, let item = item(atRow: targetRow) as? FileSystemItem {
                if !item.isDirectory {
                    if let coordinator = delegate as? FileOutlineView.Coordinator {
                        if let chatVM = coordinator.chatHistoryViewModel {
                            FileOpenCoordinator.open(item: item, in: chatVM, fallbackViewModel: coordinator.viewModel)
                        } else {
                            coordinator.viewModel.openFile(item)
                        }
                    }
                } else {
                    if isItemExpanded(item) {
                        collapseItem(item)
                    } else {
                        expandItem(item)
                    }
                }
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        // Return (36) or Space (49) opens the selected file or toggles folder expansion
        if event.keyCode == 36 || event.keyCode == 49 {
            if selectedRow >= 0, let item = item(atRow: selectedRow) as? FileSystemItem {
                if !item.isDirectory {
                    if let coordinator = delegate as? FileOutlineView.Coordinator {
                        if let chatVM = coordinator.chatHistoryViewModel {
                            FileOpenCoordinator.open(item: item, in: chatVM, fallbackViewModel: coordinator.viewModel)
                        } else {
                            coordinator.viewModel.openFile(item)
                        }
                    }
                    return
                } else {
                    if isItemExpanded(item) {
                        collapseItem(item)
                    } else {
                        expandItem(item)
                    }
                    return
                }
            }
        }
        super.keyDown(with: event)
    }
}

// MARK: - NSViewRepresentable for NSOutlineView
struct FileOutlineView: NSViewRepresentable {
    var viewModel: ExplorerViewModel
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.openWindow) var openWindow
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel: ChatHistoryViewModel?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let outlineView = ExplorerOutlineView()
        
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.headerView = nil
        outlineView.style = .sourceList // Sidebar style
        outlineView.floatsGroupRows = false
        outlineView.rowHeight = 24 // Comfortable hit target
        
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DataColumn"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        
        outlineView.doubleAction = #selector(Coordinator.doubleClickedItem(_:))
        outlineView.target = context.coordinator

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false // Important for transparency
        outlineView.backgroundColor = .clear
        
        context.coordinator.outlineView = outlineView
        context.coordinator.setupCallbacks()
        
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let outlineView = nsView.documentView as? NSOutlineView {
            context.coordinator.parent = self
            context.coordinator.viewModel = viewModel
            context.coordinator.chatHistoryViewModel = chatHistoryViewModel

            if context.coordinator.lastTreeVersion != viewModel.treeVersion {
                context.coordinator.lastTreeVersion = viewModel.treeVersion
                outlineView.reloadData()

                for item in viewModel.rootItems {
                    applyExpansionState(for: item, in: outlineView)
                }
            }
        }
    }
    
    private func applyExpansionState(for item: FileSystemItem, in outlineView: NSOutlineView) {
        let isExpanded = viewModel.expandedItemIDs.contains(item.id)
        if isExpanded && !outlineView.isItemExpanded(item) {
            outlineView.expandItem(item)
        } else if !isExpanded && outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        }
        
        let liveItem = viewModel.findItem(by: item.id) ?? item
        if let children = liveItem.children {
            for child in children {
                applyExpansionState(for: child, in: outlineView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, viewModel: viewModel, themeManager: themeManager, chatHistoryViewModel: chatHistoryViewModel)
    }

    // MARK: - Coordinator
    @MainActor
    class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: FileOutlineView
        var viewModel: ExplorerViewModel
        var themeManager: ThemeManager
        var chatHistoryViewModel: ChatHistoryViewModel?
        weak var outlineView: NSOutlineView?
        var lastTreeVersion: Int = -1

        init(parent: FileOutlineView, viewModel: ExplorerViewModel, themeManager: ThemeManager, chatHistoryViewModel: ChatHistoryViewModel?) {
            self.parent = parent
            self.viewModel = viewModel
            self.themeManager = themeManager
            self.chatHistoryViewModel = chatHistoryViewModel
            super.init()
            setupCallbacks()
        }

        func setupCallbacks() {
            viewModel.onNodeReloadRequired = { [weak self] parentURL in
                guard let self = self, let outlineView = self.outlineView else { return }
                if self.viewModel.expandedItemIDs.isEmpty {
                    outlineView.collapseItem(nil, collapseChildren: true)
                }
                if let parentItem = self.viewModel.findItem(by: parentURL) {
                    outlineView.reloadItem(parentItem, reloadChildren: true)
                    if self.viewModel.expandedItemIDs.contains(parentURL) && !outlineView.isItemExpanded(parentItem) {
                        outlineView.expandItem(parentItem)
                    }
                } else {
                    outlineView.reloadData()
                }
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let fileItem = item as? FileSystemItem {
                if let liveItem = viewModel.findItem(by: fileItem.id) {
                    return liveItem.children?.count ?? 0
                }
                return fileItem.children?.count ?? 0
            }
            return viewModel.filteredRootItems.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let fileItem = item as? FileSystemItem {
                let liveItem = viewModel.findItem(by: fileItem.id) ?? fileItem
                if let children = liveItem.children, index < children.count {
                    return children[index]
                }
            }
            let items = viewModel.filteredRootItems
            guard index < items.count else {
                let placeholder = URL(fileURLWithPath: "/dev/null")
                return FileSystemItem(id: placeholder, name: "", url: placeholder, isDirectory: false)
            }
            return items[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            if let fileItem = item as? FileSystemItem {
                return fileItem.isDirectory
            }
            return false
        }
        
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let fileItem = item as? FileSystemItem else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("ExplorerItemCell")
            let baseView = ExplorerItemContentRow(item: fileItem, viewModel: viewModel)
                .environment(themeManager)
                .environment(\.appTheme, themeManager.currentTheme)

            let finalView: AnyView
            if let chatVM = chatHistoryViewModel {
                finalView = AnyView(baseView.environment(chatVM).id(fileItem.id))
            } else {
                finalView = AnyView(baseView.id(fileItem.id))
            }

            if let recycled = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSHostingView<AnyView> {
                recycled.rootView = finalView
                return recycled
            }

            let hostingView = NSHostingView(rootView: finalView)
            hostingView.identifier = identifier
            return hostingView
        }
        
        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] as? FileSystemItem else { return }
            viewModel.expandedItemIDs.insert(item.id)
            let liveItem = viewModel.findItem(by: item.id) ?? item
            if liveItem.children == nil {
                viewModel.toggleFolderExpansion(for: liveItem)
            }
        }

        func outlineViewItemWillCollapse(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] as? FileSystemItem else { return }
            viewModel.expandedItemIDs.remove(item.id)
        }
        
        @objc func doubleClickedItem(_ sender: Any) {
            guard let outlineView = self.outlineView else { return }
            let row: Int
            if outlineView.clickedRow >= 0 {
                row = outlineView.clickedRow
            } else if outlineView.selectedRow >= 0 {
                row = outlineView.selectedRow
            } else {
                let mousePoint = outlineView.convert(NSApp.currentEvent?.locationInWindow ?? .zero, from: nil)
                row = outlineView.row(at: mousePoint)
            }
            guard row >= 0, let clickedItem = outlineView.item(atRow: row) as? FileSystemItem else { return }
            
            if clickedItem.isDirectory {
                if outlineView.isItemExpanded(clickedItem) {
                    outlineView.collapseItem(clickedItem)
                } else {
                    outlineView.expandItem(clickedItem)
                }
            } else {
                Task { @MainActor in
                    if let chatHistoryViewModel {
                        FileOpenCoordinator.open(item: clickedItem, in: chatHistoryViewModel, fallbackViewModel: viewModel)
                    } else {
                        viewModel.openFile(clickedItem)
                    }
                }
            }
        }
        
        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            return true
        }
    }
}

// MARK: - Row View

struct ExplorerItemContentRow: View {
    let item: FileSystemItem
    var viewModel: ExplorerViewModel
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appTheme) private var theme
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel: ChatHistoryViewModel?
    @FocusState private var isTextFieldFocused: Bool

    @State private var isHovered = false

    var body: some View {
        @Bindable var viewModel = viewModel
        HStack(spacing: 6) {
            if viewModel.loadingIDs.contains(item.id) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: item.iconName)
                    .foregroundColor(item.iconColor(for: themeManager.currentTheme))
                    .font(theme.fontSubheadline)
                    .accessibilityHidden(true)
            }
            
            if viewModel.itemBeingRenamedID == item.id {
                TextField("", text: $viewModel.currentEditName)
                    .textFieldStyle(.plain)
                    .font(theme.fontSubheadline)
                    .focused($isTextFieldFocused)
                    .onSubmit { viewModel.commitRename() }
                    .onChange(of: isTextFieldFocused) { oldState, newState in
                        if !newState && viewModel.itemBeingRenamedID == item.id {
                             viewModel.cancelRename()
                        }
                    }
                    .task {
                        try? await Task.sleep(for: .milliseconds(50))
                        isTextFieldFocused = true
                    }
                    .padding(.horizontal, 4)
                    .background(theme.controlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text(item.name)
                    .font(theme.fontFootnote.weight(item.isDirectory ? .medium : .regular))
                    .foregroundColor(item.isIgnoredOrDependency ? theme.secondaryText.opacity(0.55) : theme.primaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .frame(height: 24)
        .padding(.leading, 4)
        .padding(.trailing, isHovered ? (item.isDirectory ? 78 : 54) : 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? theme.surfaceOverlay : Color.clear)
        )
        .overlay(alignment: .trailing) {
            if isHovered && viewModel.itemBeingRenamedID != item.id {
                HStack(spacing: 2) {
                    if item.isDirectory {
                        HoverActionButton(icon: "plus", action: {
                            viewModel.createNewFile(in: item)
                        })
                        .help("New File")
                    }

                    HoverActionButton(icon: "pencil", action: {
                        viewModel.startRename(item)
                    })
                    .help("Rename")
                    
                    HoverActionButton(icon: "doc.on.doc", action: {
                        viewModel.copyPath(item)
                    })
                    .help("Copy Path")
                }
                .padding(.trailing, 4)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contentShape(Rectangle())
        .highPriorityGesture(
            TapGesture(count: 2).onEnded {
                guard viewModel.itemBeingRenamedID != item.id else { return }
                if !item.isDirectory {
                    if let chatHistoryViewModel {
                        FileOpenCoordinator.open(item: item, in: chatHistoryViewModel, fallbackViewModel: viewModel)
                    } else {
                        viewModel.openFile(item)
                    }
                } else {
                    viewModel.toggleFolderExpansion(for: item)
                }
            }
        )
        .onDrag {
            guard !item.isDirectory else { return NSItemProvider() }
            return NSItemProvider(object: item.url as NSURL)
        }
        .contextMenu {
            if item.isDirectory {
                Button {
                    viewModel.createNewFile(in: item)
                } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                }
                
                Button {
                    viewModel.createNewFolder(in: item)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                
                Divider()
            }

            Button {
                viewModel.openFile(item)
            } label: {
                Label("Open", systemImage: "doc.text")
            }

            if !item.isDirectory {
                Button {
                    viewModel.openWithSystemApp(item)
                } label: {
                    Label("Open with System App", systemImage: "arrow.up.forward.app")
                }
            }
            
            Button {
                viewModel.revealInFinder(item)
            } label: {
                Label("Reveal in Finder", systemImage: "arrow.right.doc.on.clipboard")
            }

            Button {
                viewModel.openInTerminal(item)
            } label: {
                Label("Open in Terminal", systemImage: "terminal")
            }

            Divider()

            Button {
                viewModel.copyPath(item)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            Button {
                viewModel.copyRelativePath(item)
            } label: {
                Label("Copy Relative Path", systemImage: "doc.on.clipboard")
            }

            Divider()

            Button {
                viewModel.startRename(item)
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button(role: .destructive) {
                viewModel.deleteItem(item)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }
}

// MARK: - Preview Provider
struct ExplorerSidebarView_Previews: PreviewProvider {
    static var previews: some View {
        let noFolderViewModel = ExplorerViewModel()
        let folderOpenedViewModel = ExplorerViewModel()
        let mockURL = URL(fileURLWithPath: "/Users/Shared/TestProject")
        folderOpenedViewModel.selectedRootURL = mockURL

        return Group {
            ExplorerSidebarView()
                .environment(noFolderViewModel)
                .environment(ThemeManager())
                .previewDisplayName("No Folder")
                .frame(width: 300, height: 500)
                .background(Color(NSColor.windowBackgroundColor)) // Simulate sidebar

            ExplorerSidebarView()
                .environment(folderOpenedViewModel)
                .environment(ThemeManager())
                .previewDisplayName("Active Project")
                .frame(width: 300, height: 500)
                .background(AppThemes.MaterialTheme().primaryBackground)
        }
    }
}
