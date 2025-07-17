//
//  SyntaxHighlighterService.swift
//  Devgentic
//
//  Created by Raj Singh
//

import Foundation
import Splash
import SwiftUI

/// A wrapper class to allow storing a Swift `AttributedString` (a struct) in `NSCache` (which requires class objects).
private final class AttributedStringWrapper {
    let value: Foundation.AttributedString
    
    init(_ value: Foundation.AttributedString) {
        self.value = value
    }
}

/// A centralized service to handle syntax highlighting asynchronously and serially.
/ This prevents overwhelming the system by spawning too many concurrent highlighting tasks.
final class SyntaxHighlighterService {
    
    static let shared = SyntaxHighlighterService()
    
    // FIX: The cache now stores an `AttributedStringWrapper` object instead of the struct directly.
    private let cache = NSCache<CacheKey, AttributedStringWrapper>()
    
    private let serialQueue = DispatchQueue(label: "com.devgentic.syntax-highlighter-queue")
    private let theme: Splash.Theme = .sundellsColors(withFont: .init(size: 14))
    
    private final class CacheKey: NSObject {
        let code: String
        let language: String?

        init(code: String, language: String?) {
            self.code = code
            self.language = language
            super.init()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? CacheKey else { return false }
            return self.code == other.code && self.language == other.language
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(code)
            hasher.combine(language)
            return hasher.finalize()
        }
    }
    
    private init() {}

    func highlight(code: String, language: String?) async -> Foundation.AttributedString {
        let cacheKey = CacheKey(code: code, language: language)

        // 1. Check cache first. If the wrapper object exists, return its value.
        if let cachedWrapper = cache.object(forKey: cacheKey) {
            return cachedWrapper.value
        }
        
        return await withCheckedContinuation { continuation in
            serialQueue.async {
                let highlighter = SyntaxHighlighter(format: AttributedStringOutputFormat(theme: self.theme))
                let splashAttributedString = highlighter.highlight(code)
                let finalAttributedString = Foundation.AttributedString(splashAttributedString)
                
                // 2. Store the new result inside the wrapper object.
                self.cache.setObject(AttributedStringWrapper(finalAttributedString), forKey: cacheKey)
                
                continuation.resume(returning: finalAttributedString)
            }
        }
    }
}
