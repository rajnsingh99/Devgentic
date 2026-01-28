//
//  FileSystemHelpers.swift
//  Devgentic
//
//  Created by Raj Singh on 27/01/26.
//

import Foundation

// MARK: - Extended Attribute Helper (for "Where From" URL)
struct ExtendedAttributeHelper {
    
    /// Reads the 'kMDItemWhereFroms' metadata which usually contains the download URL.
    static func getWhereFroms(at url: URL) -> [String]? {
        let key = "com.apple.metadata:kMDItemWhereFroms"
        
        // 1. Get buffer size
        let path = url.path
        let size = getxattr(path, key, nil, 0, 0, 0)
        
        guard size > 0 else { return nil }
        
        // 2. Read data
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes {
            getxattr(path, key, $0.baseAddress, size, 0, 0)
        }
        
        guard result == size else { return nil }
        
        // 3. Decode Binary Plist
        do {
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return plist as? [String]
        } catch {
            return nil
        }
    }
}

// MARK: - Async Spotlight Search Wrapper

/// Wraps NSMetadataQuery in a MainActor class to ensure RunLoop compatibility and async/await usage.
@MainActor
final class SpotlightSearcher: NSObject, NSMetadataQueryDelegate {
    
    private var continuation: CheckedContinuation<[String], Error>?
    private let query = NSMetadataQuery()
    
    func search(queryStr: String, scope: [String]? = nil) async throws -> [String] {
        // Prevent concurrent searches on the same instance
        if query.isGathering { query.stop() }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            
            // Configure Query
            // Fix: Map strings to URLs correctly and cast to [Any] to handle the default fallback which is [String]
            let searchRoots: [Any] = scope?.map { URL(fileURLWithPath: $0) } ?? [NSMetadataQueryUserHomeScope]
            query.searchScopes = searchRoots
            
            // Create a predicate that searches text content or file names
            query.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(queryStr)*")
            query.notificationBatchingInterval = 1.0
            
            // Listen for finish
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(queryDidFinishGathering(_:)),
                name: .NSMetadataQueryDidFinishGathering,
                object: query
            )
            
            query.start()
        }
    }
    
    @objc private func queryDidFinishGathering(_ notification: Notification) {
        query.stop()
        
        var results: [String] = []
        query.disableUpdates()
        
        for item in query.results {
            if let metadataItem = item as? NSMetadataItem,
               let path = metadataItem.value(forAttribute: NSMetadataItemPathKey) as? String {
                results.append(path)
            }
        }
        
        query.enableUpdates()
        NotificationCenter.default.removeObserver(self)
        
        continuation?.resume(returning: results)
        continuation = nil
    }
}
