// FileTagPopoverView.swift
import SwiftUI
import AppKit // For NSPasteboard

struct FileTagPopoverView: View {
    let fileItem: FileSystemItem
    var dismissAction: () -> Void // Action to dismiss the popover

    @State private var fullPathCopied: Bool = false
    @State private var contentPreview: String? = nil
    @State private var isLoadingPreview: Bool = false
    @State private var previewError: String? = nil

    private func loadContentPreview() {
        isLoadingPreview = true
        previewError = nil
        
        Task {
            let didStartAccess = fileItem.url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess { fileItem.url.stopAccessingSecurityScopedResource() }
            }

            if didStartAccess {
                do {
                    let data = try Data(contentsOf: fileItem.url)
                    if let stringContent = String(data: data, encoding: .utf8) {
                        await MainActor.run {
                            self.contentPreview = String(stringContent.prefix(1000))
                            if stringContent.count > 1000 {
                                self.contentPreview! += "\n\n--- (Preview truncated) ---"
                            }
                        }
                    } else {
                        await MainActor.run {
                            self.contentPreview = "--- (Binary content or unsupported encoding) ---"
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.previewError = "Error reading file: \(error.localizedDescription)"
                    }
                }
            } else {
                await MainActor.run {
                    self.previewError = "Could not access file for preview."
                }
            }
            await MainActor.run {
                isLoadingPreview = false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: fileItem.iconName)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text(fileItem.name)
                    .font(.headline)
                Spacer()
                Button(action: dismissAction) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray.opacity(0.7))
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Close")
            }

            Text("Path: \(fileItem.url.path)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            
            HStack {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(fileItem.url.path, forType: .string)
                    fullPathCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        fullPathCopied = false
                    }
                } label: {
                    HStack {
                        Image(systemName: fullPathCopied ? "checkmark.circle.fill" : "doc.on.doc")
                        Text(fullPathCopied ? "Path Copied!" : "Copy Path")
                    }
                    .foregroundColor(fullPathCopied ? .green : .accentColor)
                }
                .buttonStyle(.bordered)
                
                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileItem.url])
                    dismissAction()
                }
            }
            
            Divider()

            if let preview = contentPreview {
                Text("Content Preview:")
                    .font(.caption.weight(.semibold))
                ScrollView {
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(5)
                        .background(Color.gray.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .frame(maxHeight: 150)
            } else if isLoadingPreview {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading preview...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let error = previewError {
                 Text("Preview Error:")
                    .font(.caption.weight(.semibold))
                 Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            } else {
                Button("Show Content Preview") {
                    loadContentPreview()
                }
            }
        }
        .padding()
        .frame(minWidth: 300, idealWidth: 350, maxWidth: 450)
        .onAppear(perform: loadContentPreview)
    }
}

struct FileTagPopoverView_Previews: PreviewProvider {
    // Corrected: Call createDummyFile() as part of sampleFile initialization
    static let sampleFile: FileSystemItem = {
        createDummyFile() // Ensure dummy file is created before sampleFile is fully initialized
        return FileSystemItem(
            id: URL(fileURLWithPath: "/tmp/sample.txt"),
            name: "sample_document_for_preview.txt",
            url: URL(fileURLWithPath: "/tmp/sample.txt"),
            isDirectory: false
        )
    }()
    
    static func createDummyFile() {
        let dummyURL = URL(fileURLWithPath: "/tmp/sample.txt")
        if !FileManager.default.fileExists(atPath: dummyURL.path) {
            try? "This is a sample text file for SwiftUI preview purposes.\nIt contains multiple lines.\nHello, World!".write(to: dummyURL, atomically: true, encoding: .utf8)
        }
    }

    static var previews: some View {
        // Now the previews body only contains the View, and sampleFile is already set up.
        FileTagPopoverView(fileItem: sampleFile, dismissAction: { print("Preview dismiss") })
            .previewLayout(.sizeThatFits)
            .padding()
    }
}
