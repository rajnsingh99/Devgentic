// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SenderRole.swift
//  Devgentic
//
//  Created by Raj Singh
//

import Foundation

// Make Codable using String raw values
enum SenderRole: String, Codable {
    case user
    case agent
}
