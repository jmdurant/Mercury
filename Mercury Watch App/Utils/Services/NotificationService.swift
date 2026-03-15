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

        let messageCategory = UNNotificationCategory(
            identifier: messageCategoryIdentifier,
            actions: [replyAction, markReadAction],
            intentIdentifiers: [],
            options: []
        )

        // We'll register link categories dynamically per notification
        // Start with just the base message category
        UNUserNotificationCenter.current().setNotificationCategories([messageCategory])
    }

    /// Creates a dynamic notification category with typed action labels
    static func registerLinkCategory(for urls: [URL]) -> String {
        let categoryId = "LINK_\(urls.count)_\(urls.hashValue)"

        var actions: [UNNotificationAction] = []
        for (i, url) in urls.prefix(3).enumerated() {
            let action = UNNotificationAction(
                identifier: openLinkActionIdentifier + "_\(i)",
                title: labelForURL(url),
                options: [.foreground]
            )
            actions.append(action)
        }

        // Add reply and mark read
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
        actions.append(replyAction)
        actions.append(markReadAction)

        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )

        // Merge with existing categories
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var categories = existing
            categories.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(categories)
        }

        return categoryId
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
        return extractAllURLs(from: text).first
    }

    static func extractAllURLs(from text: String) -> [URL] {
        let types: NSTextCheckingResult.CheckingType = [.link, .address, .phoneNumber]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)

        var urls: [URL] = []
        for match in matches {
            if match.resultType == .link, let url = match.url {
                urls.append(url)
            } else if match.resultType == .address,
                      let components = match.addressComponents {
                let parts = [
                    components[.street],
                    components[.city],
                    components[.state],
                    components[.zip],
                    components[.country]
                ].compactMap { $0 }
                let query = parts.joined(separator: ", ")
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let url = URL(string: "https://maps.apple.com/?q=\(query)") {
                    urls.append(url)
                }
            } else if match.resultType == .phoneNumber,
                      let phoneRange = Range(match.range, in: text) {
                let phone = String(text[phoneRange]).replacingOccurrences(of: " ", with: "")
                if let url = URL(string: "tel:\(phone)") {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    static func labelForURL(_ url: URL) -> String {
        let str = url.absoluteString.lowercased()
        if str.hasPrefix("tel:") { return "Call" }
        if str.contains("maps.apple.com") { return "Open in Maps" }
        if str.contains("music.apple.com") { return "Open in Music" }
        return "Open Link"
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
