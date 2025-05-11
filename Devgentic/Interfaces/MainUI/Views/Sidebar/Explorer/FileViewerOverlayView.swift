// FileViewerOverlayView.swift
// (Create this file, e.g., in "Interfaces/MainUI/Views/Shared" or "Interfaces/MainUI/Views/Explorer")
import SwiftUI
import UniformTypeIdentifiers // For more robust file type checking

struct FileViewerOverlayView: View {
    @Environment(\.dismiss) var dismiss

    let fileName: String?
    let fileContent: String?
    let errorMessage: String?

    // State for copy button feedback
    @State private var justCopied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Header
            HStack {
                Image(systemName: sfSymbolForFileName(fileName))
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .frame(width: 24, alignment: .center)

                if let name = fileName {
                    Text(name)
                        .font(.system(.title3, design: .default).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("File Viewer")
                        .font(.system(.title3, design: .default).weight(.medium))
                }
                
                Spacer()
                
                // Copy Button - only shown if there's content and no error
                if fileContent != nil && errorMessage == nil {
                    Button {
                        copyContentToClipboard()
                    } label: {
                        Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(justCopied ? .green : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(justCopied ? "Copied!" : "Copy content")
                    .padding(.trailing, 8)
                }
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
                .padding(EdgeInsets(top: -4, leading: -4, bottom: -4, trailing: -4))
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

            Divider()

            // MARK: - Content Area
            Group {
                if let error = errorMessage {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.red)
                        
                        Text("Error Opening File")
                            .font(.title2.weight(.semibold))
                        
                        Text(error)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let content = fileContent {
                    ScrollView {
                        // Use monospaced font for all content for consistency in a "code viewer"
                        // SwiftUI's Text will render basic Markdown if present in the content.
                        Text(content)
                            .font(.system(.body, design: .monospaced)) // Consistently monospaced
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16))
                            .textSelection(.enabled)
                    }
                } else {
                    VStack {
                        Spacer()
                        Text("No Content")
                            .font(.title2.weight(.medium))
                            .foregroundColor(.secondary)
                        Text("The file may be empty or could not be loaded.")
                            .font(.body)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.top, (errorMessage != nil || fileContent != nil) ? 0 : 12)
            
        }
        .frame(minWidth: 450, idealWidth: 700, maxWidth: 1200,
               minHeight: 350, idealHeight: 600, maxHeight: 900)
        .background(.ultraThickMaterial)
    }

    private func sfSymbolForFileName(_ name: String?) -> String {
        guard let name = name else { return "doc.fill" } // Default icon if name is nil
        
        // Attempt to get the file extension
        let fileExtension = name.split(separator: ".").last?.lowercased() ?? ""

        // Create a UTType from the file extension for more accurate icon determination
        if let type = UTType(filenameExtension: fileExtension) {
            // Specific check for Markdown using its identifier
            if let markdownUTI = UTType("net.daringfireball.markdown"), type.conforms(to: markdownUTI) {
                 return "doc.richtext.fill" // Specific icon for Markdown
            }
            // Check for other common types
            if type.conforms(to: .sourceCode) {
                return "doc.text.fill"
            }
            // Broader text check, but after specific source code and Markdown
            if type.conforms(to: .text) { // This includes plain text, potentially some code-like files not caught by .sourceCode
                // If it's a known text-based extension not specifically Markdown or source code, use doc.text.fill
                // Examples: json, xml, sh, yaml, yml, log, csv etc.
                let commonTextExtensions = ["json", "xml", "sh", "yaml", "yml", "log", "csv", "txt", "ini", "cfg"]
                if commonTextExtensions.contains(fileExtension) {
                    return "doc.text.fill"
                }
                // If it's just generic .text and not one of the above, doc.richtext might be more appropriate
                // if it's not explicitly code or a common plain text data format.
                return "doc.plaintext.fill" // Or "doc.richtext.fill" if preferred for general text
            }
            if type.conforms(to: .image) {
                return "photo.fill"
            }
            if type.conforms(to: .pdf) {
                return "doc.richtext.fill.ar" // Using the AR variant for PDF
            }
            if type.conforms(to: .archive) {
                return "doc.zipper"
            }
        }
        
        // Fallback for unknown extensions or if UTType couldn't be determined,
        // but we have an extension.
        switch fileExtension {
            case "md": // Fallback if UTType("net.daringfireball.markdown") fails for some reason
                return "doc.richtext.fill"
            case "swift", "js", "py", "java", "html", "css", "json", "xml", "sh", "yaml", "yml":
                return "doc.text.fill"
            case "txt":
                return "doc.plaintext.fill"
            case "png", "jpg", "jpeg", "gif", "heic", "webp":
                return "photo.fill"
            case "pdf":
                return "doc.richtext.fill.ar"
            case "zip", "tar", "gz", "rar", "7z":
                return "doc.zipper"
            default:
                return "doc.fill" // Generic document icon
        }
    }

    private func copyContentToClipboard() {
        guard let content = fileContent else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        
        // Provide feedback
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            justCopied = false
        }
    }
}

// MARK: - Preview Provider
struct FileViewerOverlayView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            FileViewerOverlayView(
                fileName: "MyDocument.md",
                fileContent: """
                # Main Title
                This is some **bold text** and some *italic text*.
                Here's `inline code`.

                Visit [OpenAI](https://www.openai.com).

                - Item 1
                - Item 2
                """,
                errorMessage: nil
            )
            .previewDisplayName("Markdown File Content")

            FileViewerOverlayView(
                fileName: "script.js",
                fileContent: """
                function greet(name) {
                    console.log(`Hello, ${name}!`);
                }
                greet('World');
                """,
                errorMessage: nil
            )
            .previewDisplayName("Code File Content")
            
            FileViewerOverlayView(
                fileName: "important_archive.zip",
                fileContent: nil,
                errorMessage: "Could not display binary file. Please open with an external application."
            )
            .previewDisplayName("Error Display (Binary)")
            
            FileViewerOverlayView(
                fileName: "secret.txt",
                fileContent: nil,
                errorMessage: "Permission denied to read this file. Please check your system permissions."
            )
            .previewDisplayName("Error Display (Permission)")
            
            FileViewerOverlayView(
                fileName: "unknown.xyz",
                fileContent: "Some content of an unknown file type.",
                errorMessage: nil
            )
            .previewDisplayName("Unknown File Type")
        }
        .frame(width: 700, height: 600)
    }
}
