// ExplorerView.swift
import SwiftUI

struct ExplorerView: View {
    @StateObject private var viewModel: ExplorerViewModel

    // Default initializer
    init() {
        _viewModel = StateObject(wrappedValue: ExplorerViewModel())
    }

    // Initializer for previews or DI
    init(viewModel: ExplorerViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

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
            if let rootURL = viewModel.selectedRootURL {
                // --- Explorer Header (Root Folder Name) ---
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

                // --- Rename Error Message ---
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
                    List {
                        if let errorMessage = viewModel.errorMessage, !viewModel.rootItems.isEmpty {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding(.horizontal, 2)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 5, trailing: 0))
                        }
                        
                        ForEach(viewModel.rootItems) { item in
                            ExplorerDisclosureRowView(item: item, viewModel: viewModel)
                        }
                    }
                    .listStyle(.sidebar)
                }

            } else {
                // --- No Folder Opened View ---
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
        // The .sheet modifier is REMOVED from here.
    }
}

struct ExplorerDisclosureRowView: View {
    let item: FileSystemItem
    @ObservedObject var viewModel: ExplorerViewModel

    var body: some View {
        if item.isDirectory {
            DisclosureGroup(
                isExpanded: viewModel.expansionBinding(for: item),
                content: {
                    if let children = item.children {
                        ForEach(children) { childItem in
                            ExplorerDisclosureRowView(item: childItem, viewModel: viewModel)
                                .padding(.leading, 10)
                        }
                    } else {
                        EmptyView()
                    }
                },
                label: {
                    ExplorerItemContentRow(item: item, viewModel: viewModel)
                }
            )
        } else {
            ExplorerItemContentRow(item: item, viewModel: viewModel)
        }
    }
}

struct ExplorerItemContentRow: View {
    let item: FileSystemItem
    @ObservedObject var viewModel: ExplorerViewModel
    @FocusState private var isTextFieldFocused: Bool
    
    // ---- NEW: Environment action to open a window ----
    @Environment(\.openWindow) var openWindow

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
                            if viewModel.currentEditName.trimmingCharacters(in: .whitespacesAndNewlines) != item.name &&
                               !viewModel.currentEditName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                viewModel.cancelRename()
                            } else {
                                viewModel.cancelRename()
                            }
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
        }
        .frame(height: 22)
        .background(viewModel.itemBeingRenamedID == item.id ? Color(NSColor.selectedControlColor).opacity(0.2) : Color.clear)
        .cornerRadius(4)
        .onTapGesture(count: 2) {
            if viewModel.itemBeingRenamedID == item.id { return }
            if !item.isDirectory {
                // ---- MODIFIED: Call openWindow for files ----
                openWindow(id: "file-viewer-window", value: item.url)
                // viewModel.openFile(item) // This call is no longer strictly necessary if openWindow is used directly
            }
        }
        .contextMenu {
            if viewModel.itemBeingRenamedID == item.id {
                Button("Save Rename") { viewModel.commitRename() }
                Button("Cancel Rename", role: .cancel) { viewModel.cancelRename() }
            } else {
                Button(item.isDirectory ? "Expand/Collapse" : "Open") { // "Open in New Window" could be more explicit
                     if item.isDirectory {
                        var isCurrentlyExpanded = viewModel.expandedItemIDs.contains(item.id)
                        viewModel.expansionBinding(for: item).wrappedValue.toggle()
                     } else {
                        // ---- MODIFIED: Call openWindow for files ----
                        openWindow(id: "file-viewer-window", value: item.url)
                        // viewModel.openFile(item) // This call is no longer strictly necessary
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
}

// PreviewProvider ... (remains the same, but the sheet presentation part will no longer work directly from here)
// For previewing the new window, you'd typically run the app and trigger it.
// Or, create a separate preview for FileViewerWindowView once it's made.
struct ExplorerView_Previews: PreviewProvider {
    static var previews: some View {
        // ... (existing previews are fine, but the file viewing part will now open a new window)
        let noFolderViewModel = ExplorerViewModel()

        let folderOpenedViewModel = ExplorerViewModel()
        let rootPreviewURL = URL(fileURLWithPath: "/MyProject", isDirectory: true)
        let file1URL = rootPreviewURL.appendingPathComponent("example.swift")
        let subfolderURL = rootPreviewURL.appendingPathComponent("Subfolder", isDirectory: true)
        let file2URL = subfolderURL.appendingPathComponent("another.txt")

        let file1 = FileSystemItem(id: file1URL, name: "example.swift", url: file1URL, isDirectory: false)
        let file2 = FileSystemItem(id: file2URL, name: "another.txt", url: file2URL, isDirectory: false)
        let subfolder = FileSystemItem(id: subfolderURL, name: "Subfolder", url: subfolderURL, isDirectory: true, children: [file2])
        let rootItem = FileSystemItem(id: rootPreviewURL, name: "MyProject", url: rootPreviewURL, isDirectory: true, children: [file1, subfolder])
        
        folderOpenedViewModel.selectedRootURL = rootPreviewURL
        folderOpenedViewModel.rootItems = [rootItem]
        folderOpenedViewModel.isLoading = false
        folderOpenedViewModel.errorMessage = nil
        folderOpenedViewModel.expandedItemIDs.insert(rootPreviewURL)
        if subfolder.isDirectory {
             folderOpenedViewModel.expandedItemIDs.insert(subfolder.id)
        }

        let errorViewModel = ExplorerViewModel()
        // ... (error view model setup)

        return Group {
            ExplorerView(viewModel: noFolderViewModel)
                .previewDisplayName("No Folder Opened")
                .frame(width: 300, height: 500)

            ExplorerView(viewModel: folderOpenedViewModel)
                .previewDisplayName("Folder Opened (Expanded)")
                .frame(width: 300, height: 500)
            
            // ExplorerView(viewModel: errorViewModel) // ...
        }
    }
}
