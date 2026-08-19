//
//  FileProcessorService.swift
//  Devgentic
//
//  Created by Raj Singh on 15/05/25.
//

import Foundation
import UniformTypeIdentifiers // For UTType
import PDFKit // ADDED: Import PDFKit to handle PDF files
import os // For Logger

// Logger for the FileProcessorService
private let logger = DGLogger(category: "FileProcessorService")

struct FileProcessorService {

    /// Reads the content of a file at the given URL.
    /// This function now supports text extraction from PDF files.
    /// - Parameters:
    ///   - url: The URL of the file to read.
    ///   - maxSize: The maximum number of characters to read. If the file is larger, `nil` is returned.
    ///              Defaults to 500,000 characters.
    /// - Returns: The content of the file as a String, or `nil` if reading fails, the file exceeds `maxSize`,
    ///            or security-scoped access cannot be obtained.
    func readFileContent(for url: URL, maxSize: Int = 500_000) async -> String? {
        logger.debug("Attempting to read content for file: \(url.path)")

        let didStartAccess = url.startAccessingSecurityScopedResource()
        if !didStartAccess && url.isFileURL {
            logger.info("Could not start security-scoped access for \(url.path). This might be okay if access is not required (e.g. app sandbox file).")
        } else if didStartAccess {
            logger.debug("Successfully started security-scoped access for \(url.path)")
        }

        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
                logger.debug("Stopped security-scoped access for \(url.path)")
            }
        }

        // Try document extraction for rich formats first (PDF, DOCX, XLSX, CSV, PPTX, RTF)
        let registry = DocumentExtractionRegistry.shared
        if registry.canExtract(from: url) {
            do {
                let result = try await registry.extract(from: url, maxSize: maxSize)
                if result.metadata.wasTruncated {
                    logger.warning("Document \(url.lastPathComponent) was truncated at \(maxSize) chars")
                }
                logger.info("Extracted \(result.metadata.format) content from \(url.lastPathComponent) (\(result.metadata.wordCount) words via \(result.metadata.extractionMethod))")
                return result.text
            } catch {
                logger.warning("Document extraction failed for \(url.lastPathComponent): \(error.localizedDescription), falling back to text read")
                // Fall through to existing text reading logic
            }
        }

        // Existing logic for plain text files
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? NSNumber {
                // ⚠️ Overflow-safe: `maxSize * 4` TRAPS for a caller passing `Int.max` to mean
                // "unbounded" (the workflow document path does exactly that since 2026-08-15).
                // An overflowing cap means no real file can exceed it, so the check is skipped.
                let byteCap = maxSize.multipliedReportingOverflow(by: 4)
                if !byteCap.overflow, fileSize.intValue > byteCap.partialValue {
                    logger.warning("File \(url.lastPathComponent) is potentially too large (size: \(fileSize.intValue) bytes) to inline, exceeding estimated limit for \(maxSize) chars.")
                }
            }

            let fileContent = try String(contentsOf: url, encoding: .utf8)
            if fileContent.count > maxSize {
                logger.warning("File content for \(url.lastPathComponent) exceeds \(maxSize) characters (actual: \(fileContent.count)). Not inlining.")
                return nil
            }
            logger.info("Successfully read content for file: \(url.lastPathComponent) (length: \(fileContent.count) chars)")
            return fileContent
        } catch {
            logger.error("Failed to read content for file \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Strict variant of `readFileContent` that **throws a typed `FileRetrievalError`**
    /// instead of swallowing every failure to `nil`. Use this on paths that must
    /// report retrieval failures to the user (Round 2). Distinguishes missing /
    /// access-denied / too-large / read-failed / document-extraction causes, and
    /// surfaces the underlying `DocumentExtractionError` (which the nil variant
    /// silently catches and discards).
    func readFileContentOrThrow(for url: URL, maxSize: Int = 500_000) async throws -> String {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

        if url.isFileURL && !FileManager.default.fileExists(atPath: url.path) {
            throw FileRetrievalError.notFound(path: url.path)
        }

        // Rich document formats (PDF/DOCX/XLSX/CSV/PPTX/RTF) — surface the real cause.
        let registry = DocumentExtractionRegistry.shared
        if registry.canExtract(from: url) {
            do {
                return try await registry.extract(from: url, maxSize: maxSize).text
            } catch let docError as DocumentExtractionError {
                throw FileRetrievalError.from(docError, path: url.path)
            } catch {
                throw FileRetrievalError.extractionFailed(path: url.path, underlying: error.localizedDescription)
            }
        }

        // Plain text.
        do {
            // ⚠️ Overflow-safe — same rule as `readFileContent` above, and the two must not drift:
            // `maxSize * 4` traps on `Int.max`, which the workflow document path passes to mean
            // "unbounded" (user decision 2026-08-15). An overflowing cap admits every file size.
            let byteCap = maxSize.multipliedReportingOverflow(by: 4)
            if let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
               !byteCap.overflow, size.intValue > byteCap.partialValue {
                throw FileRetrievalError.tooLarge(path: url.path)
            }
            let content = try String(contentsOf: url, encoding: .utf8)
            if content.count > maxSize {
                throw FileRetrievalError.tooLarge(path: url.path)
            }
            return content
        } catch let retrievalError as FileRetrievalError {
            throw retrievalError
        } catch let nsError as NSError where nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError: throw FileRetrievalError.accessDenied(path: url.path)
            case NSFileReadNoSuchFileError:   throw FileRetrievalError.notFound(path: url.path)
            default:                          throw FileRetrievalError.readFailed(path: url.path, underlying: nsError.localizedDescription)
            }
        } catch {
            throw FileRetrievalError.readFailed(path: url.path, underlying: error.localizedDescription)
        }
    }

    /// Determines the MIME type of a file. It prioritizes specific UTType preferred MIME types
    /// and falls back to "text/plain" for known source code extensions if a more specific
    /// text-based MIME type isn't available.
    /// - Parameter url: The URL of the file.
    /// - Returns: A string representing the MIME type.
    func getFileMimeType(for url: URL) -> String {
        let fileExtension = url.pathExtension.lowercased()

        if let type = UTType(filenameExtension: fileExtension) {
            if let preferredMimeType = type.preferredMIMEType {
                // If UTType gives a specific MIME type, use it, unless it's octet-stream for a known text type
                if preferredMimeType == "application/octet-stream" && isKnownSourceCodeExtension(fileExtension) {
                    logger.debug("UTType resolved to octet-stream for known source code extension '\(fileExtension)'. Overriding to text/plain for \(url.lastPathComponent).")
                    return "text/plain" // Treat known source code as text/plain if UTType is too generic
                }
                logger.debug("Determined MIME type for \(url.lastPathComponent): \(preferredMimeType) using UTType.")
                return preferredMimeType
            }
            // If no preferred MIME type, but it conforms to text or source code, use text/plain
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) {
                logger.debug("UTType for \(url.lastPathComponent) (ext: '\(fileExtension)') conforms to text/source but has no preferred MIME. Using text/plain.")
                return "text/plain"
            }
        }
        
        // Fallback for known source code extensions if UTType failed or was too generic without conformance
        if isKnownSourceCodeExtension(fileExtension) {
            logger.debug("File extension '\(fileExtension)' for \(url.lastPathComponent) is a known source code type. Using text/plain as MIME type.")
            return "text/plain"
        }

        logger.warning("Could not determine specific MIME type for \(url.lastPathComponent) (ext: '\(fileExtension)'). Falling back to application/octet-stream.")
        return "application/octet-stream" // Default fallback MIME type
    }
    
    /// Helper to identify common source code file extensions.
    private func isKnownSourceCodeExtension(_ fileExtension: String) -> Bool {
        let knownSourceExtensions: Set<String> = [
            "swift", "java", "js", "ts", "py", "rb", "php", "cs", "c", "cpp", "h", "hpp",
            "go", "rs", "kt", "kts", "m", "mm", "sh", "pl", "pm", "lua", "r", "scala",
            "html", "htm", "css", "scss", "less", "xml", "json", "yaml", "yml", "md", "markdown",
            "sql", "java", "properties", "gradle", "gitignore", "dockerfile", "tf", "hcl"
            // Add more as needed
        ]
        return knownSourceExtensions.contains(fileExtension.lowercased())
    }

    /// Checks if a given MIME type or file URL represents a text-based format,
    /// giving strong consideration to source code and now PDFs.
    /// - Parameters:
    ///   - mimeType: The MIME type string.
    ///   - url: The URL of the file, used for extension checking as a fallback.
    /// - Returns: `true` if the MIME type or file extension suggests a text-based format, `false` otherwise.
    func isTextFile(mimeType: String, url: URL) -> Bool {
        let lowercasedMimeType = mimeType.lowercased()
        
        // Check based on UTType conformance from the URL first
        if let type = UTType(filenameExtension: url.pathExtension) {
            // Text, source code, and PDF types are all readable
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .pdf) {
                logger.trace("File '\(url.lastPathComponent)' (UTType) is text/source code/pdf.")
                return true
            }
        }

        // Rich document formats (extractable to text via DocumentExtractionRegistry)
        let documentExtensions: Set<String> = ["docx", "xlsx", "xls", "csv", "tsv", "pptx", "rtf", "rtfd"]
        if documentExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }

        // Check based on MIME type string
        let textMimeTypePrefixes = ["text/"]
        let commonTextMimeTypes = [
            "application/json", "application/xml", "application/javascript", "application/ecmascript",
            "application/xhtml+xml", "application/sql", "application/rtf",
            "image/svg+xml", // SVG is XML-based text
            "application/pdf" // Explicitly add PDF MIME type here as well for robustness
        ]

        for prefix in textMimeTypePrefixes {
            if lowercasedMimeType.starts(with: prefix) {
                logger.trace("MIME type '\(mimeType)' starts with 'text/', evaluated as text.")
                return true
            }
        }
        if commonTextMimeTypes.contains(lowercasedMimeType) {
            logger.trace("MIME type '\(mimeType)' is in commonTextMimeTypes, evaluated as text.")
            return true
        }
        
        // Fallback: Check if the extension is a known source code type, even if MIME was generic
        if isKnownSourceCodeExtension(url.pathExtension) {
            logger.trace("File extension for '\(url.lastPathComponent)' is a known source code type, evaluated as text.")
            return true
        }
        
        logger.trace("MIME type '\(mimeType)' for URL '\(url.lastPathComponent)' evaluated as non-text.")
        return false
    }

    /// Checks if a given MIME type or file URL represents an image format.
    /// - Parameters:
    ///   - mimeType: The MIME type string.
    ///   - url: The URL of the file, used for extension checking.
    /// - Returns: `true` if the MIME type or file extension suggests an image, `false` otherwise.
    func isImageFile(mimeType: String, url: URL) -> Bool {
        let lowercasedMimeType = mimeType.lowercased()

        // Check based on UTType conformance from the URL first
        if let type = UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .image) {
                logger.trace("File '\(url.lastPathComponent)' (UTType) is an image.")
                return true
            }
        }
        
        // Fallback to MIME string check
        if lowercasedMimeType.starts(with: "image/") {
            logger.trace("MIME type '\(mimeType)' starts with 'image/', evaluated as image.")
            return true
        }
        logger.trace("MIME type '\(mimeType)' for URL '\(url.lastPathComponent)' evaluated as non-image.")
        return false
    }

    /// Returns extraction capability info for a file
    func extractionInfo(for url: URL) -> (canExtract: Bool, format: String?) {
        let ext = url.pathExtension.lowercased()
        let registry = DocumentExtractionRegistry.shared
        if registry.canExtract(from: url) {
            return (true, ext.uppercased())
        }
        if isTextFile(mimeType: getFileMimeType(for: url), url: url) {
            return (true, "Text")
        }
        return (false, nil)
    }
}
