//
//  ExplorerView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit

struct ExplorerView: View {

    @EnvironmentObject var viewModel: ExplorerViewModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- Toolbar ---
            HStack {
                Button {
                    viewModel.selectRootDirectory()
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }
                .padding([.leading, .top, .bottom], 8)
                .help("Select a root folder to explore")

                Spacer()

                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding([.trailing, .top, .bottom], 8)
                }
            }
            .frame(height: 40)

            // --- Main Content Area ---
            // The rest of your body code remains exactly the same.
            if let rootURL = viewModel.selectedRootURL {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EXPLORER")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(rootURL.lastPathComponent.uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 6)

                Divider()

                if viewModel.isIndexing {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Indexing files...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }

                if let renameError = viewModel.renameErrorMessage {
                    Text(renameError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                }
                
                if let errorMessage = viewModel.errorMessage, viewModel.rootItems.isEmpty && !viewModel.isLoading {
                     VStack(alignment: .center, spacing: 10) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Error Accessing Folder")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Try Again") {
                            viewModel.loadDirectoryContents(for: rootURL)
                        }
                        .padding(.top, 5)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FileOutlineView(viewModel: viewModel)
                        .contextMenu {
                            // Context menu can be simplified or attached to rows in the Coordinator
                        }
                }

            } else {
                VStack(alignment: .center, spacing: 12) {
                    Spacer()
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text("No Folder Opened")
                        .font(.title3)
                        .fontWeight(.medium)
                    Text("Select a folder to view its contents in the explorer.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button {
                        viewModel.selectRootDirectory()
                    } label: {
                        Text("Open Folder")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                    Spacer()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
        
        // Handle double-click
        outlineView.doubleAction = #selector(Coordinator.doubleClickedItem(_:))
        outlineView.target = context.coordinator

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        
        context.coordinator.outlineView = outlineView
        
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // When the view model's data changes, reload the outline view
        if let outlineView = nsView.documentView as? NSOutlineView {
            context.coordinator.parent = self
            outlineView.reloadData()
            // Expand items that are in the viewModel's expanded set
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

        // MARK: DataSource Methods
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
        
        // MARK: Delegate Methods
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let fileItem = item as? FileSystemItem else { return nil }

            let view = ExplorerItemContentRow(item: fileItem, viewModel: viewModel)
            let hostingView = NSHostingView(rootView: view)
            
            return hostingView
        }
        
        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] as? FileSystemItem else { return }
            viewModel.expandedItemIDs.insert(item.id)
            if item.children == nil { // Lazy load if children haven't been fetched
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
            return true // Shows the disclosure triangle
        }
    }
}

// This view is now used inside the NSHostingView for each row
struct ExplorerItemContentRow: View {
    let item: FileSystemItem
    @ObservedObject var viewModel: ExplorerViewModel
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        HStack {
            Image(systemName: item.iconName)
                .foregroundColor(item.isDirectory ? Color.accentColor : .secondary)
            
            if viewModel.itemBeingRenamedID == item.id {
                TextField("", text: $viewModel.currentEditName)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        viewModel.commitRename()
                    }
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
                    .lineLimit(1)
            }
            Spacer()
        }
        .frame(height: 22)
        .background(Color.clear)
        .cornerRadius(4)
        .contextMenu {
            // Context menu logic remains the same
            Button(item.isDirectory ? "Expand/Collapse" : "Open") {
                 if item.isDirectory {
                    // This is now handled by the outline view itself
                 } else {
                    // This is handled by double-click
                 }
            }
            Button("Reveal in Finder") { viewModel.revealInFinder(item) }
            Button("Copy Path") { viewModel.copyPath(item) }
            Divider()
            Button("Rename...") { viewModel.startRename(item) }
            Button("Delete", role: .destructive) { viewModel.deleteItem(item) }
            if item.isDirectory {
                Divider()
                Button("New File") { viewModel.createNewFile(in: item) }
                Button("New Folder") { viewModel.createNewFolder(in: item) }
            }
        }
    }
}

// MARK: - Preview Provider
struct ExplorerView_Previews: PreviewProvider {
    static var previews: some View {
        // --- Preview for "No Folder Opened" state ---
        let noFolderViewModel = ExplorerViewModel()

        // --- Preview for "Folder Opened" state ---
        let folderOpenedViewModel = ExplorerViewModel()
        let mockURL = URL(fileURLWithPath: "/Users/Shared/TestProject")
        folderOpenedViewModel.selectedRootURL = mockURL
        folderOpenedViewModel.rootItems = [
            FileSystemItem(id: mockURL, name: "TestProject", url: mockURL, isDirectory: true, children: [
                FileSystemItem(id: mockURL.appendingPathComponent("File1.swift"), name: "File1.swift", url: mockURL.appendingPathComponent("File1.swift"), isDirectory: false),
                FileSystemItem(id: mockURL.appendingPathComponent("Subfolder"), name: "Subfolder", url: mockURL.appendingPathComponent("Subfolder"), isDirectory: true, children: [
                     FileSystemItem(id: mockURL.appendingPathComponent("Subfolder/Image.png"), name: "Image.png", url: mockURL.appendingPathComponent("Subfolder/Image.png"), isDirectory: false)
                ]),
                FileSystemItem(id: mockURL.appendingPathComponent("README.md"), name: "README.md", url: mockURL.appendingPathComponent("README.md"), isDirectory: false)
            ])
        ]
        folderOpenedViewModel.expandedItemIDs.insert(mockURL)


        return Group {
            ExplorerView()
                .environmentObject(noFolderViewModel)
                .previewDisplayName("No Folder Opened")
                .frame(width: 300, height: 500)

            ExplorerView()
                .environmentObject(folderOpenedViewModel)
                .previewDisplayName("Folder Opened")
                .frame(width: 300, height: 500)
        }
    }
}

