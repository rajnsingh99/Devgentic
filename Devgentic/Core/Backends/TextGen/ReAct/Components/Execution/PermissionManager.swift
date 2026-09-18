// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PermissionManager.swift
//  Devgentic
//
//  Created by Raj Singh on 26/02/26.
//
//


import Foundation
@preconcurrency import ApplicationServices // Required for Accessibility checks
import CoreGraphics
import EventKit
import Contacts

/// Defines the macOS system permissions required by various tools.
enum SystemPermission: Sendable {
    case desktop
    case documents
    case downloads
    case accessibility
    case screenRecording
    case calendar
    case contacts
}

/// A centralized manager to check and trigger macOS TCC (Transparency, Consent, and Control) prompts.
actor PermissionManager {
    static let shared = PermissionManager()
    
    /// Checks all requested permissions and triggers native macOS prompts if undetermined.
    /// Returns `true` only if all requested permissions are granted.
    func ensurePermissions(for permissions: [SystemPermission]) -> Bool {
        for permission in permissions {
            let hasAccess = checkAndTriggerPrompt(for: permission)
            if !hasAccess { return false }
        }
        return true
    }
    
    private func checkAndTriggerPrompt(for permission: SystemPermission) -> Bool {
        switch permission {
        case .desktop:
            return checkFolderAccess(for: .desktopDirectory)
        case .documents:
            return checkFolderAccess(for: .documentDirectory)
        case .downloads:
            return checkFolderAccess(for: .downloadsDirectory)
        case .accessibility:
            // This triggers the native macOS "requires accessibility" prompt if undetermined
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        case .calendar:
            let status = EKEventStore.authorizationStatus(for: .event)
            return status == .fullAccess
        case .contacts:
            let status = CNContactStore.authorizationStatus(for: .contacts)
            return status == .authorized
        }
    }
    
    /// Intentionally attempts to read the root of a protected directory.
    /// This forces macOS to show the permissions dialog to the user if they haven't decided yet.
    private func checkFolderAccess(for directory: FileManager.SearchPathDirectory) -> Bool {
        guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else {
            return false
        }
        
        do {
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return true
        } catch {
            let nsError = error as NSError
            // Cocoa Error 257 is NSFileReadNoPermissionError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == 257 {
                return false
            }
            // If it fails for another reason (e.g., folder doesn't exist), we assume
            // permission isn't the blocking factor.
            return true
        }
    }
}
