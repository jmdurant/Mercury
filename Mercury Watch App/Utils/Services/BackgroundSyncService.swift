//
//  BackgroundSyncService.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation
import WatchKit
import WidgetKit

enum BackgroundSyncService {

    private static let logger = LoggerService(BackgroundSyncService.self)
    private static let taskIdentifier = "mercury.sync"

    static func scheduleNextRefresh() {
        let request = WKApplication.SharedRefreshBackgroundTask(
            preferredDate: Date(timeIntervalSinceNow: 15 * 60)
        )
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: 15 * 60),
            userInfo: taskIdentifier as NSSecureCoding & NSObjectProtocol
        ) { error in
            if let error {
                logger.log("Background refresh scheduling failed: \(error)", level: .error)
            }
        }
    }

    static func performSync() async {
        logger.log("Background sync started")

        // Update unread count for widget
        do {
            if let result = try await TDLibManager.shared.client?.getUnreadChatCount(
                chatList: .chatListMain
            ) {
                SharedDataStore.saveTotalUnreadCount(result.unreadCount)
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch {
            logger.log(error, level: .error)
        }

        // Schedule next refresh
        scheduleNextRefresh()
    }
}
