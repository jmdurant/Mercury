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
}
