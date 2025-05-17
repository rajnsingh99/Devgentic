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
    
    private let maxInlineCharsAgent: Int = 10000

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
                        // Do not increment currentFileCountForOllama as the file is skipped
                        continue // Skip to the next file
                    }
                
                } else if fileProcessorService.isTextFile(mimeType: mimeType, url: fileURL) {
                    // Apply Text File Inclusion Strategy
                    var addedAsPathDueToStrategyOrSize = false
                    switch textFileStrategy {
                    case .preferInlining:
                        if let content = fileProcessorService.readFileContent(for: fileURL, maxSize: maxInlineCharsOllama) {
                            messageParts.append(.file(.inlineContent(fileName: fileName, content: content, mimeType: mimeType)))
                            logger.info("Text/Source Code file '\(fileName)' added as inlineContent for Ollama (strategy: preferInlining).")
                        } else {
                            messageParts.append(.file(.localPath(fileName: fileName, path: fileURL.path, mimeType: mimeType)))
                            warnings.append("Text/Source Code File: '\(fileName)' was too large (max \(maxInlineCharsOllama) chars) or unreadable. Included as path.")
                            logger.info("Text/Source Code file '\(fileName)' added as localPath for Ollama (too large or read error under preferInlining).")
                            addedAsPathDueToStrategyOrSize = true
                        }
                    case .alwaysUsePaths:
                        messageParts.append(.file(.localPath(fileName: fileName, path: fileURL.path, mimeType: mimeType)))
                        // Optional: Add a specific warning or log message if it was small enough to inline but strategy overrode
                        let isInlineable = fileProcessorService.readFileContent(for: fileURL, maxSize: maxInlineCharsOllama) != nil
                        if isInlineable {
                             warnings.append("Text/Source Code File: '\(fileName)' included as path due to 'Always Use File Paths' strategy (was small enough to inline).")
                             logger.info("Text/Source Code file '\(fileName)' added as localPath for Ollama (strategy: alwaysUsePaths, was inlineable).")
                        } else {
                             warnings.append("Text/Source Code File: '\(fileName)' included as path (either too large or 'Always Use File Paths' strategy).")
                             logger.info("Text/Source Code file '\(fileName)' added as localPath for Ollama (strategy: alwaysUsePaths or too large).")
                        }
                        addedAsPathDueToStrategyOrSize = true
                    }
                    currentFileCountForOllama += 1

                } else { // Other binary files (PDF, DOCX, etc.)
                    // Apply Binary File Handling Strategy
                    switch binaryFileHandlingStrategy {
                    case .includePathWithWarning:
                        messageParts.append(.file(.localPath(fileName: fileName, path: fileURL.path, mimeType: mimeType)))
                        var binaryFileWarning = "Binary File: '\(fileName)' (type: \(mimeType ?? "unknown")) was included as a file path. "
                        if let modelDisplayName = ollamaModelDetails?.displayName {
                             binaryFileWarning += "The current Ollama model ('\(modelDisplayName)') is likely text-based and cannot directly read the content of this file. "
                        } else {
                            binaryFileWarning += "Standard text-based Ollama models cannot directly read the content of this file type. "
                        }
                        binaryFileWarning += "Consider extracting text manually and pasting it, or using a specialized model if available that can handle this file type via path."
                        warnings.append(binaryFileWarning)
                        logger.info("Binary file '\(fileName)' (\(mimeType ?? "unknown")) added as localPath for Ollama (strategy: includePathWithWarning).")
                        currentFileCountForOllama += 1
                    case .doNotInclude:
                        warnings.append("Binary File: '\(fileName)' (type: \(mimeType ?? "unknown")) was not included due to the 'Do Not Include These File Types' strategy.")
                        logger.info("Binary file '\(fileName)' (\(mimeType ?? "unknown")) skipped for Ollama (strategy: doNotInclude).")
                        // Do not increment currentFileCountForOllama
                        continue // Skip to next file
                    }
                }

            case .agent:
                // Agent logic remains unchanged by these Ollama-specific strategies
                if fileProcessorService.isTextFile(mimeType: mimeType, url: fileURL) {
                    if let content = fileProcessorService.readFileContent(for: fileURL, maxSize: maxInlineCharsAgent) {
                        messageParts.append(.file(.inlineContent(fileName: fileName, content: content, mimeType: mimeType)))
                        logger.info("Text file '\(fileName)' added as inlineContent for Agent.")
                    } else {
                        let reason = "File is too large for inlining (max \(maxInlineCharsAgent) characters) or could not be read. Agent file upload functionality is not yet implemented."
                        messageParts.append(.file(.unprocessable(fileName: fileName, reason: reason, mimeType: mimeType)))
                        warnings.append("File Not Processed: '\(fileName)' could not be prepared for the Agent. Reason: \(reason)")
                        logger.warning("File '\(fileName)' marked unprocessable for Agent: \(reason)")
                    }
                } else {
                    let reason: String
                    if fileProcessorService.isImageFile(mimeType: mimeType, url: fileURL) {
                        reason = "Image file processing (e.g., upload or base64 encoding) for the Agent backend is not yet implemented. The file cannot be sent."
                    } else {
                        reason = "Binary file type (\(mimeType ?? "unknown")) requires an upload mechanism for the Agent backend, which is not yet implemented. The file cannot be sent."
                    }
                    messageParts.append(.file(.unprocessable(fileName: fileName, reason: reason, mimeType: mimeType)))
                    warnings.append("File Not Processed: '\(fileName)' (\(mimeType ?? "unknown")) could not be prepared for the Agent. Reason: \(reason)")
                    logger.warning("File '\(fileName)' (\(mimeType ?? "unknown")) marked unprocessable for Agent: \(reason)")
                }
            }
        }
        
        let hasTextPart = messageParts.contains { $0.type == .text && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let hasEffectivelyProcessableFilePart = messageParts.contains { part in
            if part.type == .file {
                if let rep = part.fileRepresentation {
                    if case .unprocessable = rep { return false }
                    return true
                }
            }
            return false
        }

        if !hasTextPart && !hasEffectivelyProcessableFilePart {
            if !attachedFiles.isEmpty && userQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                 warnings.append("No Content to Send: All attached files were unsuitable or hit processing limits for the selected backend, and no text query was provided.")
                 logger.warning("Message assembly resulted in no effectively processable parts, though files were attached and query was empty.")
            } else if !attachedFiles.isEmpty && !userQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                 let originalFileCount = attachedFiles.count
                 let processableFileCount = messageParts.filter {
                     $0.type == .file &&
                     $0.fileRepresentation != nil &&
                     ($0.fileRepresentation.flatMap { rep -> Bool? in if case .unprocessable = rep { return true } else { return false } } == false)
                 }.count
                
                 if originalFileCount > 0 && processableFileCount == 0 {
                    warnings.append("No Files to Send: The text query was provided, but all attached files were unsuitable or hit processing limits for the selected backend, resulting in no file parts being added.")
                    logger.warning("Message assembly resulted in no effectively processable file parts, though files were attached and query was present.")
                 }
            }
        }

        logger.info("Message assembly complete. \(messageParts.count) parts created. \(warnings.count) warnings generated.")
        return (messageParts, warnings)
    }
}
