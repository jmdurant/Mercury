//
//  AppDelegate.swift
//  ClawWatch iOS
//
//  APNs registration → TDLib, plus notification actions (quick reply,
//  mark as read) on top of the shared NotificationService.
//

import UIKit
import UserNotifications
import BackgroundTasks
import TDLibKit

class AppDelegate: NSObject, UIApplicationDelegate {

    let logger = LoggerService(AppDelegate.self)

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        UNUserNotificationCenter.current().delegate = self
        NotificationService.registerCategories()
        NotificationService.requestAuthorization()

        // Health data for status replies / the agent channel
        StatusDataService.requestHealthPermissions()

        // Background refresh
        BackgroundSyncService.registerBackgroundTask()
        BackgroundSyncService.scheduleNextRefresh()

        // CallKit + VoIP push
        CallService.shared.start()

        // Proactive location-context push to the agent
        ContextPushService.shared.start()

        // Reconnect as an OpenClaw node if the user enabled it
        if OpenClawNodeService.shared.isAutoConnect {
            OpenClawNodeService.shared.start()
        }

        return true
    }

    // MARK: - Remote notifications (APNs → TDLib)

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        logger.log("APNs token registered")

        Task {
            do {
                #if DEBUG
                let isAppSandbox = true
                #else
                let isAppSandbox = false
                #endif
                let token = DeviceTokenApplePush(deviceToken: tokenString, isAppSandbox: isAppSandbox)
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

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Swift.Error
    ) {
        logger.log("APNs registration failed: \(error)", level: .error)
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension AppDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Donate a communication intent so iOS shows the sender avatar and
        // honours per-contact Focus
        NotificationService.donateCommunicationIntent(
            from: notification.request.content,
            userInfo: notification.request.content.userInfo
        )
        return [.banner, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let chatId = NotificationService.extractChatId(from: userInfo) else { return }

        switch response.actionIdentifier {
        case NotificationService.replyActionIdentifier:
            if let textResponse = response as? UNTextInputNotificationResponse {
                SendMessageService.sendQuickReply(text: textResponse.userText, chatId: chatId)
            }

        case NotificationService.markReadActionIdentifier:
            do {
                try await TDLibManager.shared.client?.openChat(chatId: chatId)
                if let chat = try await TDLibManager.shared.client?.getChat(chatId: chatId),
                   let lastMessageId = chat.lastMessage?.id {
                    try await TDLibManager.shared.client?.viewMessages(
                        chatId: chatId, forceRead: true, messageIds: [lastMessageId], source: nil
                    )
                }
                try await TDLibManager.shared.client?.closeChat(chatId: chatId)
            } catch {
                logger.log(error, level: .error)
            }

        case let action where action.hasPrefix(NotificationService.openLinkActionIdentifier):
            let indexStr = action.replacingOccurrences(
                of: NotificationService.openLinkActionIdentifier + "_", with: "")
            let index = Int(indexStr) ?? 0
            if let urlString = userInfo["mercury_link_\(index)"] as? String,
               let url = URL(string: urlString) {
                await UIApplication.shared.open(url)
            }

        case UNNotificationDefaultActionIdentifier:
            AppState.shared.pendingNotificationChatId = chatId

        default:
            break
        }
    }
}
