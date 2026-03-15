//
//  NotificationService.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation
import UserNotifications
import Intents

enum NotificationService {

    static let replyActionIdentifier = "REPLY_ACTION"
    static let markReadActionIdentifier = "MARK_READ_ACTION"
    static let openLinkActionIdentifier = "OPEN_LINK_ACTION"
    static let messageCategoryIdentifier = "MESSAGE_CATEGORY"
    static let linkMessageCategoryIdentifier = "LINK_MESSAGE_CATEGORY"

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

        let openLinkAction = UNNotificationAction(
            identifier: openLinkActionIdentifier,
            title: "Open Link",
            options: [.foreground]
        )

        let messageCategory = UNNotificationCategory(
            identifier: messageCategoryIdentifier,
            actions: [replyAction, markReadAction],
            intentIdentifiers: [],
            options: []
        )

        let linkMessageCategory = UNNotificationCategory(
            identifier: linkMessageCategoryIdentifier,
            actions: [openLinkAction, replyAction, markReadAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([messageCategory, linkMessageCategory])
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

    static func donateCommunicationIntent(
        from content: UNNotificationContent,
        userInfo: [AnyHashable: Any]
    ) {
        let senderName = content.title.isEmpty ? "Someone" : content.title
        let messageBody = content.body

        let chatId = extractChatId(from: userInfo)
        let conversationId = chatId.map { String($0) } ?? UUID().uuidString

        let sender = INPerson(
            personHandle: INPersonHandle(value: senderName, type: .unknown),
            nameComponents: nil,
            displayName: senderName,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: conversationId
        )

        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: messageBody,
            speakableGroupName: nil,
            conversationIdentifier: conversationId,
            serviceName: "Mercury",
            sender: sender,
            attachments: nil
        )

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { error in
            if let error {
                logger.log("Failed to donate communication intent: \(error)", level: .error)
            }
        }
    }

    static func extractFirstURL(from text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        if let match = detector?.firstMatch(in: text, options: [], range: range),
           let url = match.url {
            return url
        }
        return nil
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
