//
//  SceneDelegate.swift
//  Mercury Watch App
//
//  Created by Marco Tammaro on 18/05/24.
//

import Foundation
import WatchKit
import AVFAudio
import UserNotifications
import TDLibKit

class AppDelegate: NSObject, WKApplicationDelegate {

    let logger = LoggerService(AppDelegate.self)

    func applicationDidFinishLaunching() {
        cleanTmpFolder()
        cleanDirectoryFolder()

        // Notifications
        UNUserNotificationCenter.current().delegate = self
        NotificationService.registerCategories()
        NotificationService.requestAuthorization()

        // Background refresh
        BackgroundSyncService.scheduleNextRefresh()

        // Health data permissions (for status replies)
        StatusDataService.requestHealthPermissions()
    }

    func applicationDidBecomeActive() {
        LoginViewModel.setOnlineStatus()
    }

    func applicationDidEnterBackground() {
        LoginViewModel.setOfflineStatus()
    }

    func applicationWillResignActive() {
        LoginViewModel.setOfflineStatus()
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        logger.log("APNs token registered")

        Task {
            do {
                #if DEBUG
                let isAppSandbox = true
                #else
                let isAppSandbox = false
                #endif

                let token = DeviceTokenApplePush(
                    deviceToken: tokenString,
                    isAppSandbox: isAppSandbox
                )
                let result = try await TDLibManager.shared.client?.registerDevice(
                    deviceToken: .deviceTokenApplePush(token),
                    otherUserIds: []
                )
                logger.log(result)
            } catch {
                logger.log(error, level: .error)
            }
        }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        logger.log("APNs registration failed: \(error)", level: .error)
    }

    private func cleanTmpFolder() {
        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory
        )
    }

    #warning("Remove it in a future release")
    /// This function will remove all the files in Documents Directory since the recoder was using it as tmp storage
    /// Once all the users will have documents dir cleard, this function can be removed in order to reuse the documents directory
    private func cleanDirectoryFolder() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let path = url.first else { return }
        try? FileManager.default.removeItem(at: path)
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension AppDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Donate communication intent so Siri can announce messages
        let userInfo = notification.request.content.userInfo
        NotificationService.donateCommunicationIntent(
            from: notification.request.content,
            userInfo: userInfo
        )
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        guard let chatId = NotificationService.extractChatId(from: userInfo) else {
            completionHandler()
            return
        }

        switch response.actionIdentifier {
        case NotificationService.replyActionIdentifier:
            if let textResponse = response as? UNTextInputNotificationResponse {
                SendMessageService.sendQuickReply(
                    text: textResponse.userText,
                    chatId: chatId
                )
            }

        case NotificationService.markReadActionIdentifier:
            Task {
                do {
                    try await TDLibManager.shared.client?.openChat(chatId: chatId)
                    try await TDLibManager.shared.client?.closeChat(chatId: chatId)
                } catch {
                    logger.log(error, level: .error)
                }
            }

        case UNNotificationResponse.defaultActionIdentifier:
            DispatchQueue.main.async {
                AppState.shared.pendingNotificationChatId = chatId
            }

        default:
            break
        }

        completionHandler()
    }
}
