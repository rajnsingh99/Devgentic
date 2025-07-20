//
//  MessageAssemblerService.swift
//  Devgentic
//
//  Created by Raj Singh on 15/05/25.
//

import Foundation
import os

// Logger for the MessageAssemblerService
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "MessageAssemblerService")

// Ensure OllamaModelInfo, BackendType, TextFileInclusionStrategy, OllamaImageHandlingStrategy,
// and OllamaBinaryFileHandlingStrategy are available (e.g., via import or defined in scope).
// For example, you might need:
// import YourProjectName // If these enums/structs are in your main module

// Also ensure FileSystemItem, MessagePart, FileProcessorService are defined or imported.

struct MessageAssemblerService {
    private let fileProcessorService: FileProcessorService
    
    private let maxInlineChars: Int = 10000 // A general character limit for inlining text files

    init(fileProcessorService: FileProcessorService) {
        self.fileProcessorService = fileProcessorService
    }

    func assembleMessageParts(
        userQuery: String,
        attachedFiles: [FileSystemItem],
        for backend: BackendType,
        ollamaModelDetails: OllamaModelInfo? = nil,
        maxInlineCharsOllama: Int = 5000,
        maxFilesForOllama: Int = 5,
        // NEW: Add strategy parameters with default values from FileHandlingSettings.swift
        textFileStrategy: TextFileInclusionStrategy = .preferInlining,
        imageHandlingStrategy: OllamaImageHandlingStrategy = .includePathWithWarning,
        binaryFileHandlingStrategy: OllamaBinaryFileHandlingStrategy = .includePathWithWarning
    ) async -> (parts: [MessagePart], warnings: [String]) {
        
        var messageParts: [MessagePart] = []
        var warnings: [String] = []
        var currentFileCountForOllama = 0

        if !userQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messageParts.append(.text(userQuery))
        }

        for fileItem in attachedFiles {
            let fileName = fileItem.name
            let fileURL = fileItem.url
            let mimeType = fileProcessorService.getFileMimeType(for: fileURL)

            switch backend {
            case .ollama:
                if currentFileCountForOllama >= maxFilesForOllama {
                    warnings.append("File Limit Reached: '\(fileName)' was not included. Only the first \(maxFilesForOllama) files are processed for the local LLM. Consider reducing files or using a backend that supports more attachments.")
                    logger.warning("Skipping file '\(fileName)' for Ollama due to file limit (\(maxFilesForOllama) files).")
                    continue
                }

                if fileProcessorService.isImageFile(mimeType: mimeType, url: fileURL) {
                    // Apply Image Handling Strategy
                    switch imageHandlingStrategy {
                    case .includePathWithWarning:
                        messageParts.append(.file(.localPath(fileName: fileName, path: fileURL.path, mimeType: mimeType)))
                        var imageWarning = "Image File: '\(fileName)' was included as a file path. "
                        if let modelDisplayName = ollamaModelDetails?.displayName {
                            imageWarning += "The current Ollama model ('\(modelDisplayName)') may not support images directly via path, or may require them in a different format (e.g., base64 if multimodal). The image might not be processed as expected."
                        } else {
                            imageWarning += "Only multimodal Ollama models that can access local file paths will be able to process this image. Standard text models will ignore it."
                        }
                        warnings.append(imageWarning)
                        logger.info("Image file '\(fileName)' added as localPath for Ollama (strategy: includePathWithWarning).")
                        currentFileCountForOllama += 1
                    case .doNotInclude:
                        warnings.append("Image File: '\(fileName)' was not included due to the 'Do Not Include Images' strategy.")
                        logger.info("Image file '\(fileName)' skipped for Ollama (strategy: doNotInclude).")
                        continue
                    }
                
                } else if fileProcessorService.isTextFile(mimeType: mimeType, url: fileURL) {
                    // Apply Text File Inclusion Strategy
                    switch textFileStrategy {
                    case .preferInlining:
                        if let content = fileProcessorService.readFileContent(for: fileURL, maxSize: maxInlineCharsOllama) {
                            messageParts.append(.file(.inlineContent(fileName: fileName, content: content, mimeType: mimeType)))
                            logger.info("Text/Source Code file '\(fileName)' added as inlineContent for Ollama (strategy: preferInlining).")
                        } else {
                            messageParts.append(.file(.localPath(fileName: fileName, path: fileURL.path, mimeType: mimeType)))
                            warnings.append("Text/Source Code File: '\(fileName)' was too large (max \(maxInlineCharsOllama) chars) or unreadable. Included as path.")
                            logger.info("Text/Source Code file '\(fileName)' added as localPath for Ollama (too large or read error under preferInlining).")
                        }
                    case .alwaysUsePaths:
                        messageParts.append(.file(.localPath(fileName: fileName, path: fileURL.path, mimeType: mimeType)))
                        let isInlineable = fileProcessorService.readFileContent(for: fileURL, maxSize: maxInlineCharsOllama) != nil
                        if isInlineable {
                             warnings.append("Text/Source Code File: '\(fileName)' included as path due to 'Always Use File Paths' strategy (was small enough to inline).")
                        } else {
                             warnings.append("Text/Source Code File: '\(fileName)' included as path (either too large or 'Always Use File Paths' strategy).")
                        }
                    }
                    currentFileCountForOllama += 1

                } else { // Other binary files
                    switch binaryFileHandlingStrategy {
                    case .includePathWithWarning:
                        messageParts.append(.file(.localPath(fileName: fileName, path: fileURL.path, mimeType: mimeType)))
                        var binaryFileWarning = "Binary File: '\(fileName)' (type: \(mimeType ?? "unknown")) was included as a file path. "
                        if let modelDisplayName = ollamaModelDetails?.displayName {
                             binaryFileWarning += "The current Ollama model ('\(modelDisplayName)') is likely text-based and cannot directly read the content of this file. "
                        } else {
                            binaryFileWarning += "Standard text-based Ollama models cannot directly read the content of this file type. "
                        }
                        warnings.append(binaryFileWarning)
                        currentFileCountForOllama += 1
                    case .doNotInclude:
                        warnings.append("Binary File: '\(fileName)' (type: \(mimeType ?? "unknown")) was not included due to the 'Do Not Include These File Types' strategy.")
                        continue
                    }
                }

            case .agent, .remote: // Group agent and remote as they have similar placeholder logic for now
                if fileProcessorService.isTextFile(mimeType: mimeType, url: fileURL) {
                    if let content = fileProcessorService.readFileContent(for: fileURL, maxSize: maxInlineChars) {
                        messageParts.append(.file(.inlineContent(fileName: fileName, content: content, mimeType: mimeType)))
                        logger.info("Text file '\(fileName)' added as inlineContent for \(backend.rawValue) backend.")
                    } else {
                        let reason = "File is too large for inlining (max \(maxInlineChars) characters) or could not be read. File upload functionality for the \(backend.rawValue) backend is not yet implemented."
                        messageParts.append(.file(.unprocessable(fileName: fileName, reason: reason, mimeType: mimeType)))
                        warnings.append("File Not Processed: '\(fileName)' could not be prepared for the \(backend.rawValue) backend. Reason: \(reason)")
                        logger.warning("File '\(fileName)' marked unprocessable for \(backend.rawValue) backend: \(reason)")
                    }
                } else {
                    let reason: String
                    let fileType = fileProcessorService.isImageFile(mimeType: mimeType, url: fileURL) ? "Image" : "Binary"
                    reason = "\(fileType) file processing for the \(backend.rawValue) backend is not yet implemented. The file cannot be sent."
                    messageParts.append(.file(.unprocessable(fileName: fileName, reason: reason, mimeType: mimeType)))
                    warnings.append("File Not Processed: '\(fileName)' (\(mimeType)) could not be prepared for the \(backend.rawValue) backend. Reason: \(reason)")
                    logger.warning("File '\(fileName)' (\(mimeType ?? "unknown")) marked unprocessable for \(backend.rawValue) backend: \(reason)")
                }
                
            case .none:
                let reason = "No backend is selected."
                warnings.append("File Not Processed: '\(fileName)' because no backend is currently selected.")
                logger.warning("File '\(fileName)' skipped because no backend is selected.")
                continue
            }
        }
        
        // Final check for empty content
        let hasTextPart = messageParts.contains { $0.type == .text && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let hasEffectivelyProcessableFilePart = messageParts.contains { part in
            if part.type == .file, let rep = part.fileRepresentation {
                if case .unprocessable = rep { return false }
                return true
            }
            return false
        }

        if !hasTextPart && !hasEffectivelyProcessableFilePart {
            if !attachedFiles.isEmpty && userQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                 warnings.append("No Content to Send: All attached files were unsuitable or hit processing limits for the selected backend, and no text query was provided.")
                 logger.warning("Message assembly resulted in no effectively processable parts, though files were attached and query was empty.")
            }
        }

        logger.info("Message assembly complete. \(messageParts.count) parts created. \(warnings.count) warnings generated.")
        return (messageParts, warnings)
    }
}
