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

struct MessageAssemblerService {
    private let fileProcessorService: FileProcessorService

    // Configuration constants
    private let maxInlineCharsOllama: Int = 5000
    private let maxFilesForOllamaTextPrompt: Int = 5
    private let maxInlineCharsAgent: Int = 10000


    init(fileProcessorService: FileProcessorService) {
        self.fileProcessorService = fileProcessorService
    }

    /// Assembles an array of `MessagePart` objects from user query and attached files,
    /// tailored for the specified backend.
    /// - Parameters:
    ///   - userQuery: The plain text user query.
    ///   - attachedFiles: An array of `FileSystemItem` objects representing attached files.
    ///   - backend: The target `BackendType` (e.g., .ollama, .agent).
    ///   - ollamaModelDetails: Optional information about the specific Ollama model being used.
    /// - Returns: A tuple containing an array of `MessagePart` objects and an array of warning strings.
    func assembleMessageParts(
        userQuery: String,
        attachedFiles: [FileSystemItem],
        for backend: BackendType,
        ollamaModelDetails: OllamaModelInfo? = nil
    ) async -> (parts: [MessagePart], warnings: [String]) {
        
        var messageParts: [MessagePart] = []
        var warnings: [String] = []
        var currentFileCountForOllama = 0

        if !userQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messageParts.append(.text(userQuery))
        }

        for fileItem in attachedFiles {
            let fileName = fileItem.name
            let fileURL = fileItem.url // fileURL is crucial now for type checking
            let mimeType = fileProcessorService.getFileMimeType(for: fileURL) // Mime type is still determined

            switch backend {
            case .ollama:
                if currentFileCountForOllama >= maxFilesForOllamaTextPrompt {
                    warnings.append("File Limit Reached: '\(fileName)' was not included. Only the first \(maxFilesForOllamaTextPrompt) files are processed for the local LLM to keep the prompt manageable. Consider reducing the number of files or using a backend that supports more attachments.")
                    logger.warning("Skipping file '\(fileName)' for Ollama due to file limit (\(maxFilesForOllamaTextPrompt) files).")
                    continue
                }

                // Use the fileURL for more accurate type checking with isImageFile and isTextFile
                if fileProcessorService.isImageFile(mimeType: mimeType, url: fileURL) {
                    messageParts.append(.file(.localPath(fileName: fileName, path: fileURL.path, mimeType: mimeType)))
                    var imageWarning = "Image File: '\(fileName)' was included as a file path. "
                    if let modelName = ollamaModelDetails?.displayName {
                        imageWarning += "The current Ollama model ('\(modelName)') may not support images directly via path, or may require them in a different format (e.g., base64 if multimodal). The image might not be processed as expected."
                    } else {
                        imageWarning += "Only multimodal Ollama models that can access local file paths will be able to process this image. Standard text models will ignore it."
                    }
                    warnings.append(imageWarning)
                    logger.info("Image file '\(fileName)' added as localPath for Ollama.")
                    currentFileCountForOllama += 1
                
                } else if fileProcessorService.isTextFile(mimeType: mimeType, url: fileURL) { // Pass fileURL
                    if let content = fileProcessorService.readFileContent(for: fileURL, maxSize: maxInlineCharsOllama) {
                        messageParts.append(.file(.inlineContent(fileName: fileName, content: content, mimeType: mimeType)))
                        logger.info("Text/Source Code file '\(fileName)' added as inlineContent for Ollama.")
                    } else {
                        messageParts.append(.file(.localPath(fileName: fileName, path: fileURL.path, mimeType: mimeType)))
                        warnings.append("Text/Source Code File: '\(fileName)' was too large to include its content directly (max \(maxInlineCharsOllama) characters) or could not be read. It has been included as a file path for the LLM to potentially access, if the model supports it.")
                        logger.info("Text/Source Code file '\(fileName)' added as localPath for Ollama (too large or read error).")
                    }
                    currentFileCountForOllama += 1

                } else { // Other binary files (PDF, DOCX, etc.) not identified as text/image
                    messageParts.append(.file(.localPath(fileName: fileName, path: fileURL.path, mimeType: mimeType)))
                    var binaryFileWarning = "Binary File: '\(fileName)' (type: \(mimeType)) was included as a file path. "
                    if let modelName = ollamaModelDetails?.displayName {
                         binaryFileWarning += "The current Ollama model ('\(modelName)') is likely text-based and cannot directly read the content of this file. "
                    } else {
                        binaryFileWarning += "Standard text-based Ollama models cannot directly read the content of this file type. "
                    }
                    binaryFileWarning += "Consider extracting text manually and pasting it, or using a specialized model if available that can handle this file type via path."
                    warnings.append(binaryFileWarning)
                    logger.info("Binary file '\(fileName)' (\(mimeType)) added as localPath for Ollama.")
                    currentFileCountForOllama += 1
                }

            case .agent:
                // Pass fileURL to isTextFile and isImageFile for agent backend as well
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
                        reason = "Binary file type (\(mimeType)) requires an upload mechanism for the Agent backend, which is not yet implemented. The file cannot be sent."
                    }
                    messageParts.append(.file(.unprocessable(fileName: fileName, reason: reason, mimeType: mimeType)))
                    warnings.append("File Not Processed: '\(fileName)' (\(mimeType)) could not be prepared for the Agent. Reason: \(reason)")
                    logger.warning("File '\(fileName)' (\(mimeType)) marked unprocessable for Agent: \(reason)")
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
                 warnings.append("No Content to Send: The text query was provided, but all attached files were unsuitable or hit processing limits for the selected backend, resulting in no file parts being added.")
                 logger.warning("Message assembly resulted in no effectively processable file parts, though files were attached and query was present.")
            }
        }

        logger.info("Message assembly complete. \(messageParts.count) parts created. \(warnings.count) warnings generated.")
        return (messageParts, warnings)
    }
}
