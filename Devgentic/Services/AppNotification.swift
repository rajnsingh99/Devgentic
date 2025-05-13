//
//  AppNotification.swift
//  Devgentic
//
//  Created by Raj Singh on 13/05/25.
//
import Foundation

public struct AppNotifications { // Made public
    /// Notification posted when an edit is requested for a prompt from the brief view (e.g., popover).
    /// The `object` of the notification will be the `Prompt` to edit.
    public static let editPromptRequestedFromBriefView = Notification.Name("devgentic.editPromptRequestedFromBriefView") // Made public
}
