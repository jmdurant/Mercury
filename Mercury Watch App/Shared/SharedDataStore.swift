//
//  SharedDataStore.swift
//  Mercury Watch App
//
//  Created by Security Hardening on 14/03/26.
//

import Foundation

enum SharedDataStore {

    static let appGroupId = "group.com.alessandroalberti.mercury"

    private static var sharedDefaults: UserDefaults? = {
        UserDefaults(suiteName: appGroupId)
    }()

    // MARK: - Unread Count

    private static let unreadCountKey = "totalUnreadCount"

    static func saveTotalUnreadCount(_ count: Int) {
        sharedDefaults?.set(count, forKey: unreadCountKey)
    }

    static func getTotalUnreadCount() -> Int {
        sharedDefaults?.integer(forKey: unreadCountKey) ?? 0
    }

    // MARK: - Last Sender

    private static let lastSenderNameKey = "lastSenderName"
    private static let lastChatIdKey = "lastChatId"

    static func saveLastMessage(senderName: String, chatId: Int64) {
        sharedDefaults?.set(senderName, forKey: lastSenderNameKey)
        sharedDefaults?.set(chatId, forKey: lastChatIdKey)
    }

    static func getLastSenderName() -> String? {
        sharedDefaults?.string(forKey: lastSenderNameKey)
    }

    static func getLastChatId() -> Int64? {
        let value = sharedDefaults?.object(forKey: lastChatIdKey) as? Int64
        return value
    }
}
