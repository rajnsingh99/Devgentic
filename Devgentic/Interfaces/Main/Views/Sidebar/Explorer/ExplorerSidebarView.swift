//
//  ExplorerView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit

struct ExplorerSidebarView: View {

    @EnvironmentObject var viewModel: ExplorerViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.appTheme) private var theme
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Header
            SidebarHeaderView(
                title: "Explorer",
                buttonTitle: viewModel.selectedRootURL != nil ? "Change Folder" : "Open Folder",
                systemImage: "folder.badge.plus",
                onAction: {
                    viewModel.selectRootDirectory()
                }
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if viewModel.selectedRootURL != nil {
                // MARK: - Search Bar
                SidebarSearchBarView("Search files...", text: $viewModel.searchText)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                
                Divider()
                    .background(theme.surfaceOverlayStrong)
                
                // MARK: - File Tree
                if let errorMessage = viewModel.errorMessage, viewModel.rootItems.isEmpty && !viewModel.isLoading {
                    // Error State
                    SidebarEmptyStateView(
                        title: "Load Error",
                        subtitle: errorMessage,
                        buttonTitle: "Retry",
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
    }
}

// MARK: - Components

struct HeaderActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    
    @Environment(\.appTheme) private var theme
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(isHovering ? theme.primaryText : theme.secondaryText)
                .frame(width: 20, height: 20)
                .background(isHovering ? theme.surfaceOverlay : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}


// MARK: - NSViewRepresentable for NSOutlineView
struct FileOutlineView: NSViewRepresentable {
    @ObservedObject var viewModel: ExplorerViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.openWindow) var openWindow

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let outlineView = NSOutlineView()
        
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
        
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let outlineView = nsView.documentView as? NSOutlineView {
            context.coordinator.parent = self
            
            // Only reload if needed or perform a lightweight update
            // For now, let's keep it but ensure we don't redundantly expand
            outlineView.reloadData()
            
            // Apply expansion state from viewModel
            for item in viewModel.rootItems {
                applyExpansionState(for: item, in: outlineView)
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
        
        if let children = item.children {
            for child in children {
                applyExpansionState(for: child, in: outlineView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, viewModel: viewModel, themeManager: themeManager)
    }

    // MARK: - Coordinator
    @MainActor
    class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: FileOutlineView
        var viewModel: ExplorerViewModel
        var themeManager: ThemeManager
        weak var outlineView: NSOutlineView?

        init(parent: FileOutlineView, viewModel: ExplorerViewModel, themeManager: ThemeManager) {
            self.parent = parent
            self.viewModel = viewModel
            self.themeManager = themeManager
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let fileItem = item as? FileSystemItem {
                return fileItem.children?.count ?? 0
            }
            return viewModel.filteredRootItems.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let fileItem = item as? FileSystemItem {
                return fileItem.children![index]
            }
            return viewModel.filteredRootItems[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            if let fileItem = item as? FileSystemItem {
                return fileItem.isDirectory
            }
            return false
        }
        
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let fileItem = item as? FileSystemItem else { return nil }

            let view = ExplorerItemContentRow(item: fileItem, viewModel: viewModel)
                .environmentObject(themeManager) // Use injected theme manager
            let hostingView = NSHostingView(rootView: view)
            
            return hostingView
        }
        
        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] as? FileSystemItem else { return }
            viewModel.expandedItemIDs.insert(item.id)
            if item.children == nil {
                viewModel.toggleFolderExpansion(for: item)
            }
        }

        func outlineViewItemWillCollapse(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] as? FileSystemItem else { return }
            viewModel.expandedItemIDs.remove(item.id)
        }
        
        @objc func doubleClickedItem(_ sender: Any) {
            guard let outlineView = self.outlineView,
                  let clickedItem = outlineView.item(atRow: outlineView.clickedRow) as? FileSystemItem,
                  !clickedItem.isDirectory else { return }
            
            Task { @MainActor in
                viewModel.openFile(clickedItem)
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
    @ObservedObject var viewModel: ExplorerViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.appTheme) private var theme
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.iconName)
                .foregroundColor(item.isDirectory ? .secondary : item.iconColor(for: themeManager.currentTheme))
                .font(.system(size: 13))
            
            if viewModel.itemBeingRenamedID == item.id {
                TextField("", text: $viewModel.currentEditName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isTextFieldFocused)
                    .onSubmit { viewModel.commitRename() }
                    .onChange(of: isTextFieldFocused) { oldState, newState in
                        if !newState && viewModel.itemBeingRenamedID == item.id {
                             viewModel.cancelRename()
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            isTextFieldFocused = true
                        }
                    }
                    .padding(.horizontal, 4)
                    .background(theme.controlBackground)
                    .cornerRadius(4)
            } else {
                Text(item.name)
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineLimit(1)
            }
            Spacer()
        }
        .frame(height: 24)
        .padding(.leading, 4)
        .onDrag {
            guard !item.isDirectory else { return NSItemProvider() }
            return NSItemProvider(object: item.url as NSURL)
        }
        .contextMenu {
            // Context menu logic remains the same
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
                .environmentObject(noFolderViewModel)
                .environmentObject(ThemeManager())
                .previewDisplayName("No Folder")
                .frame(width: 300, height: 500)
                .background(Color(NSColor.windowBackgroundColor)) // Simulate sidebar

            ExplorerSidebarView()
                .environmentObject(folderOpenedViewModel)
                .environmentObject(ThemeManager())
                .previewDisplayName("Active Project")
                .frame(width: 300, height: 500)
                .background(AppThemes.DefaultTheme().primaryBackground)
        }
    }
}
