//
//  FileProcessorService.swift
//  Devgentic
//
//  Created by Raj Singh on 15/05/25.
//

import Foundation
import UniformTypeIdentifiers // For UTType
import os // For Logger

// Logger for the FileProcessorService
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "FileProcessorService")

struct FileProcessorService {

    /// Reads the content of a text file at the given URL.
    /// - Parameters:
    ///   - url: The URL of the file to read.
    ///   - maxSize: The maximum number of characters to read. If the file is larger, `nil` is returned.
    ///              Defaults to 500,000 characters.
    /// - Returns: The content of the file as a String, or `nil` if reading fails, the file exceeds `maxSize`,
    ///            or security-scoped access cannot be obtained.
    func readFileContent(for url: URL, maxSize: Int = 500_000) -> String? {
        logger.debug("Attempting to read content for file: \(url.path, privacy: .public)")

        let didStartAccess = url.startAccessingSecurityScopedResource()
        if !didStartAccess && url.isFileURL {
            logger.info("Could not start security-scoped access for \(url.path, privacy: .public). This might be okay if access is not required (e.g. app sandbox file).")
        } else if didStartAccess {
            logger.debug("Successfully started security-scoped access for \(url.path, privacy: .public)")
        }
        
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
                logger.debug("Stopped security-scoped access for \(url.path, privacy: .public)")
            }
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? NSNumber {
                if fileSize.intValue > maxSize * 4 {
                    logger.warning("File \(url.lastPathComponent, privacy: .public) is potentially too large (size: \(fileSize.intValue) bytes) to inline, exceeding estimated limit for \(maxSize) chars.")
                }
            }

            let fileContent = try String(contentsOf: url, encoding: .utf8)
            if fileContent.count > maxSize {
                logger.warning("File content for \(url.lastPathComponent, privacy: .public) exceeds \(maxSize) characters (actual: \(fileContent.count)). Not inlining.")
                return nil
            }
            logger.info("Successfully read content for file: \(url.lastPathComponent, privacy: .public) (length: \(fileContent.count) chars)")
            return fileContent
        } catch {
            logger.error("Failed to read content for file \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
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
                    logger.debug("UTType resolved to octet-stream for known source code extension '\(fileExtension)'. Overriding to text/plain for \(url.lastPathComponent, privacy: .public).")
                    return "text/plain" // Treat known source code as text/plain if UTType is too generic
                }
                logger.debug("Determined MIME type for \(url.lastPathComponent, privacy: .public): \(preferredMimeType, privacy: .public) using UTType.")
                return preferredMimeType
            }
            // If no preferred MIME type, but it conforms to text or source code, use text/plain
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) {
                logger.debug("UTType for \(url.lastPathComponent, privacy: .public) (ext: '\(fileExtension)') conforms to text/source but has no preferred MIME. Using text/plain.")
                return "text/plain"
            }
        }
        
        // Fallback for known source code extensions if UTType failed or was too generic without conformance
        if isKnownSourceCodeExtension(fileExtension) {
            logger.debug("File extension '\(fileExtension)' for \(url.lastPathComponent, privacy: .public) is a known source code type. Using text/plain as MIME type.")
            return "text/plain"
        }

        logger.warning("Could not determine specific MIME type for \(url.lastPathComponent, privacy: .public) (ext: '\(fileExtension)'). Falling back to application/octet-stream.")
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
    /// giving strong consideration to source code.
    /// - Parameters:
    ///   - mimeType: The MIME type string.
    ///   - url: The URL of the file, used for extension checking as a fallback.
    /// - Returns: `true` if the MIME type or file extension suggests a text-based format, `false` otherwise.
    func isTextFile(mimeType: String, url: URL) -> Bool {
        let lowercasedMimeType = mimeType.lowercased()
        
        // Check based on UTType conformance from the URL first
        if let type = UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) {
                logger.trace("File '\(url.lastPathComponent, privacy: .public)' (UTType) is text/source code.")
                return true
            }
        }

        // Check based on MIME type string
        let textMimeTypePrefixes = ["text/"]
        let commonTextMimeTypes = [
            "application/json", "application/xml", "application/javascript", "application/ecmascript",
            "application/xhtml+xml", "application/sql", "application/rtf",
            "image/svg+xml" // SVG is XML-based text
        ]

        for prefix in textMimeTypePrefixes {
            if lowercasedMimeType.starts(with: prefix) {
                // Make sure it's not something like text/vcard or other less "LLM-promptable" text types,
                // unless explicitly desired. For now, any "text/*" is fine.
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
            logger.trace("File extension for '\(url.lastPathComponent, privacy: .public)' is a known source code type, evaluated as text.")
            return true
        }
        
        logger.trace("MIME type '\(mimeType)' for URL '\(url.lastPathComponent, privacy: .public)' evaluated as non-text.")
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
                logger.trace("File '\(url.lastPathComponent, privacy: .public)' (UTType) is an image.")
                return true
            }
        }
        
        // Fallback to MIME string check
        if lowercasedMimeType.starts(with: "image/") {
             // image/svg+xml is an image, but also text-based.
             // The isTextFile method also handles svg+xml as text.
             // The MessageAssembler will decide how to treat it based on context (e.g., prefer inlining for text LLMs).
            logger.trace("MIME type '\(mimeType)' starts with 'image/', evaluated as image.")
            return true
        }
        logger.trace("MIME type '\(mimeType)' for URL '\(url.lastPathComponent, privacy: .public)' evaluated as non-image.")
        return false
    }
}
