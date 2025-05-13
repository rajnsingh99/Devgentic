//
//  AttributedStringKeys.swift
//  Devgentic
//
//  Created by Raj Singh on 12/05/25.
//

import Foundation

extension NSAttributedString.Key {
    /// Custom attribute key to store the URL of a file mentioned in an attributed string.
    static let devgenticFileURL = NSAttributedString.Key("devgentic_fileURL_key")
    
    /// Custom attributed string key for storing a prompt's unique identifier.
       static let promptID = NSAttributedString.Key("devgenticPromptID")
}
