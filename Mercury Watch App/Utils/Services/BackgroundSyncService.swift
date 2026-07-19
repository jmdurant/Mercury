//
//  BackgroundSyncService.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation
#if os(watchOS)
import WatchKit
#else
import BackgroundTasks
#endif
import WidgetKit

enum BackgroundSyncService {

    private static let logger = LoggerService(BackgroundSyncService.self)
    static let taskIdentifier = "mercury.sync"

    #if os(iOS)
    /// Register the BGTask handler. Call once from didFinishLaunching, and
    /// list `mercury.sync` under BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: nil
        ) { task in
            let refresh = task as? BGAppRefreshTask
            Task {
                await performSync()
                refresh?.setTaskCompleted(success: true)
            }
        }
    }
    #endif

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
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.log("BGTask scheduling failed: \(error)", level: .error)
        }
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
