//
//  MessageSource.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation

/// Identifies where a message originated from.
/// Used to determine whether stream events should be mirrored to a remote transport.
enum MessageSource: String, Codable, Sendable {
    case localUI
    case telegram
    case discord
    case slack
}
