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
    @Environment(\.openWindow) var openWindow
    
    @State private var isHoveringHeader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let rootURL = viewModel.selectedRootURL {
                // MARK: - Project Header
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "cube.box")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        
                        Text(rootURL.lastPathComponent.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.5)
                            .foregroundColor(.secondary.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Spacer()
                        
                        // Action buttons appear on hover
                        if isHoveringHeader {
                            HStack(spacing: 4) {
                                HeaderActionButton(icon: "doc.badge.plus", help: "New File") {
                                    // TODO: Implement New File Action
                                }

                                HeaderActionButton(icon: "folder.badge.plus", help: "New Folder") {
                                    // TODO: Implement New Folder Action
                                }
                                
                                HeaderActionButton(icon: "arrow.clockwise", help: "Refresh") {
                                    viewModel.loadDirectoryContents(for: rootURL)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(isHoveringHeader ? Color.white.opacity(0.04) : Color.clear)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHoveringHeader = hovering
                        }
                    }
                    
                    Divider()
                        .background(Color.white.opacity(0.1))
                }
                
                // MARK: - File Tree
                if let errorMessage = viewModel.errorMessage, viewModel.rootItems.isEmpty && !viewModel.isLoading {
                    // Error State
                    VStack {
                        Text("Unable to load folder")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FileOutlineView(viewModel: viewModel)
                }

            } else {
                // MARK: - Empty State
                VStack(alignment: .center, spacing: 16) {
                    Spacer()
                    
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.03))
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(spacing: 6) {
                        Text("No Project Open")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text("Open a folder to start working with your codebase context.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }

                    Button {
                        viewModel.selectRootDirectory()
                    } label: {
                        Text("Open Folder")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 8)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(isHovering ? .primary : .secondary)
                .frame(width: 20, height: 20)
                .background(isHovering ? Color.white.opacity(0.1) : Color.clear)
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
            // Note: In a real app, careful diffing is better than reloadData
            outlineView.reloadData()
            for item in viewModel.rootItems {
                recursivelyExpand(item: item, in: outlineView)
            }
        }
    }
    
    private func recursivelyExpand(item: FileSystemItem, in outlineView: NSOutlineView) {
        if viewModel.expandedItemIDs.contains(item.id) {
            outlineView.expandItem(item)
            if let children = item.children {
                for child in children {
                    recursivelyExpand(item: child, in: outlineView)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, viewModel: viewModel)
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: FileOutlineView
        var viewModel: ExplorerViewModel
        weak var outlineView: NSOutlineView?

        init(parent: FileOutlineView, viewModel: ExplorerViewModel) {
            self.parent = parent
            self.viewModel = viewModel
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let fileItem = item as? FileSystemItem {
                return fileItem.children?.count ?? 0
            }
            return viewModel.rootItems.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let fileItem = item as? FileSystemItem {
                return fileItem.children![index]
            }
            return viewModel.rootItems[index]
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
                .environmentObject(ThemeManager()) // Pass theme manager if needed
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
            
            parent.openWindow(id: "file-viewer-window", value: clickedItem.url)
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
                    .background(Color.black.opacity(0.3))
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
                .background(Color(NSColor.windowBackgroundColor))
        }
    }
}
