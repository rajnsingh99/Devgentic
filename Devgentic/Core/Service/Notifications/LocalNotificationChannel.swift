//
//  LocalNotificationChannel.swift
//  Devgentic
//
//  Delivers notifications via macOS User Notification Center (UNUserNotificationCenter).
//

import Foundation
import UserNotifications
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LocalNotificationChannel")

enum LocalNotificationError: LocalizedError {
    case permissionDenied
    case permissionNotGranted

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Notification permission was denied by the user. Please enable notifications for Devgentic in System Settings → Notifications."
        case .permissionNotGranted:
            return "Notification permission was not granted."
        }
    }
}

final class LocalNotificationChannel: NotificationChannel {

    let channelID = "local_notification"
    let displayName = "Local Notification"
    var isEnabled: Bool = true
    let requiresConfiguration = false

    func send(_ payload: AppNotificationPayload) async throws {
        // Always check current authorization status before sending.
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break // Proceed to delivery.

        case .notDetermined:
            // Ask the user for permission.
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                logger.warning("Notification authorization not granted by user.")
                throw LocalNotificationError.permissionNotGranted
            }
            logger.info("Notification authorization granted.")

        case .denied:
            logger.error("Notification permission denied. Open System Settings → Notifications to re-enable.")
            throw LocalNotificationError.permissionDenied

        @unknown default:
            logger.warning("Unknown notification authorization status: \(settings.authorizationStatus.rawValue). Attempting delivery.")
        }

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default

        if let conversationID = payload.conversationID {
            content.userInfo["conversationID"] = conversationID.uuidString
        }

        // Add metadata to userInfo
        for (key, value) in payload.metadata {
            content.userInfo[key] = value
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Fire immediately
        )

        try await center.add(request)
        logger.info("Local notification delivered: \(payload.title)")
    }
}
