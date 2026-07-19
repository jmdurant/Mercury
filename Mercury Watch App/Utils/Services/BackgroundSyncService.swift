//
//  BackgroundSyncService.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation
#if os(watchOS)
import WatchKit
#endif
import WidgetKit

enum BackgroundSyncService {

    private static let logger = LoggerService(BackgroundSyncService.self)
    private static let taskIdentifier = "mercury.sync"

    static func scheduleNextRefresh() {
        #if os(watchOS)
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: 15 * 60),
            userInfo: taskIdentifier as NSString
        ) { error in
            if let error {
                logger.log("Background refresh scheduling failed: \(error)", level: .error)
            }
        }
        #else
        // iOS uses BGTaskScheduler; not wired up for the phone app yet
        #endif
    }

    static func performSync() async {
        logger.log("Background sync started")

        // Unread counts arrive via updateUnreadChatCount and are cached in
        // SharedDataStore by UnreadCountBridge; just refresh the widget
        WidgetCenter.shared.reloadAllTimelines()

        // Schedule next refresh
        scheduleNextRefresh()
    }
}
