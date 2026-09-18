// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

// `SpotlightSearcher` was removed on 2026-08-01: an @MainActor NSMetadataQuery wrapper with a
// continuation-based `search(queryStr:scope:)`, referenced by nothing. `fs_smart_search` uses
// `HybridSearchService`, which supersedes it — two-phase name-then-content querying, permission
// scoping, and a filesystem fallback for unindexed locations, none of which this had. Kept out
// rather than left as a second, worse search path for someone to find and wire up.
