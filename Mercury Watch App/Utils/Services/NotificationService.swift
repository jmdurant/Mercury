//
//  NotificationService.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation
import UserNotifications

enum NotificationService {

    static let replyActionIdentifier = "REPLY_ACTION"
    static let markReadActionIdentifier = "MARK_READ_ACTION"
    static let messageCategoryIdentifier = "MESSAGE_CATEGORY"

    private static let logger = LoggerService(NotificationService.self)

    static func registerCategories() {
        let replyAction = UNTextInputNotificationAction(
            identifier: replyActionIdentifier,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )

        let markReadAction = UNNotificationAction(
            identifier: markReadActionIdentifier,
            title: "Mark as Read",
            options: []
        )

        let messageCategory = UNNotificationCategory(
            identifier: messageCategoryIdentifier,
            actions: [replyAction, markReadAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([messageCategory])
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, error in
            if let error {
                logger.log(error, level: .error)
            }

            if granted {
                DispatchQueue.main.async {
                    WKExtension.shared().registerForRemoteNotifications()
                }
            }
        }
    }

    static func extractChatId(from userInfo: [AnyHashable: Any]) -> Int64? {
        // Telegram push payloads may nest chat_id in different locations
        if let chatId = userInfo["chat_id"] as? Int64 {
            return chatId
        }
        if let chatId = userInfo["chat_id"] as? String, let id = Int64(chatId) {
            return id
        }
        if let custom = userInfo["custom"] as? [String: Any] {
            if let chatId = custom["chat_id"] as? Int64 { return chatId }
            if let chatId = custom["chat_id"] as? String, let id = Int64(chatId) { return id }
        }
        if let data = userInfo["data"] as? [String: Any] {
            if let chatId = data["chat_id"] as? Int64 { return chatId }
            if let chatId = data["chat_id"] as? String, let id = Int64(chatId) { return id }
        }

        logger.log("Could not extract chat_id from notification payload", level: .error)
        return nil
    }
}
