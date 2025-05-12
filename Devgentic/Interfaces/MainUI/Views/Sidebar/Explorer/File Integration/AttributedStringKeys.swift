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

    /// Optional: Custom attribute key to store the display name of a file, if different from the URL's last path component.
    // static let devgenticFileDisplayName = NSAttributedString.Key("devgentic_fileDisplayName_key")
}
