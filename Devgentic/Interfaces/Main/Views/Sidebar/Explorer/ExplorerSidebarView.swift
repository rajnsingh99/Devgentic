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
                VStack(spacing: 0) {
                    HStack {
                        Text(rootURL.lastPathComponent.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(themeManager.currentTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Spacer()
                        
                        // Action buttons appear on hover
                        if isHoveringHeader {
                            Button(action: {
                                // TODO: Implement New File Action
                            }) {
                                Image(systemName: "doc.badge.plus")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(themeManager.currentTheme.secondaryText)
                            .help("New File")

                            Button(action: {
                                // TODO: Implement New Folder Action
                            }) {
                                Image(systemName: "folder.badge.plus")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(themeManager.currentTheme.secondaryText)
                            .help("New Folder")
                            
                            Button(action: {
                                viewModel.loadDirectoryContents(for: rootURL)
                            }) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(themeManager.currentTheme.secondaryText)
                            .help("Refresh")
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(themeManager.currentTheme.secondaryBackground)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            isHoveringHeader = hovering
                        }
                    }
                    
                    Divider().background(themeManager.currentTheme.dividerColor)
                }
                
                if let errorMessage = viewModel.errorMessage, viewModel.rootItems.isEmpty && !viewModel.isLoading {
                } else {
                    FileOutlineView(viewModel: viewModel)
                }

            } else {
                VStack(alignment: .center, spacing: 18) {
                    Spacer()
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundColor(themeManager.currentTheme.secondaryText)
                    
                    Text("Connect Your Project")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(themeManager.currentTheme.primaryText)

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Explore your entire project with ease.", systemImage: "sparkles")
                        Label("Mention files with ‘@’ to give the AI instant context.", systemImage: "at.circle.fill")
                        Label("Access quick actions like ‘Copy Path’ & ‘Open in Terminal’.", systemImage: "bolt.fill")
                    }
                    .font(.callout)
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .padding(.horizontal, 30)

                    
                    Button {
                        viewModel.selectRootDirectory()
                    } label: {
                        Text("Open Folder")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                    .tint(themeManager.currentTheme.accentColor)
                    .padding(.top, 8)
                    Spacer()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(themeManager.currentTheme.primaryBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DataColumn"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        
        outlineView.doubleAction = #selector(Coordinator.doubleClickedItem(_:))
        outlineView.target = context.coordinator

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        
        context.coordinator.outlineView = outlineView
        
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let outlineView = nsView.documentView as? NSOutlineView {
            context.coordinator.parent = self
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
                .environmentObject(ThemeManager())
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
        HStack {
            Image(systemName: item.iconName)
                .foregroundColor(item.iconColor(for: themeManager.currentTheme))
            
            if viewModel.itemBeingRenamedID == item.id {
                TextField("", text: $viewModel.currentEditName)
                    .textFieldStyle(.plain)
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
            } else {
                Text(item.name)
                    .foregroundColor(themeManager.currentTheme.primaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .frame(height: 22)
        .background(Color.clear)
        .cornerRadius(4)
        .onDrag {
            // We only want to drag files, not directories.
            guard !item.isDirectory else { return NSItemProvider() }
            // Provide the item's URL as the draggable content.
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
        // Mock data setup...

        return Group {
            ExplorerSidebarView()
                .environmentObject(noFolderViewModel)
                .environmentObject(ThemeManager())
                .previewDisplayName("No Folder Opened")
                .frame(width: 300, height: 500)

            ExplorerSidebarView()
                .environmentObject(folderOpenedViewModel)
                .environmentObject(ThemeManager())
                .previewDisplayName("Folder Opened")
                .frame(width: 300, height: 500)
        }
    }
}
