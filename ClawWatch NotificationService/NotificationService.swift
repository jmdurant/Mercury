//
//  NotificationService.swift
//  ClawWatch NotificationService
//
//  Notification Service Extension — enriches incoming pushes before they
//  are shown (mutable-content). Full TDLib push decryption would require
//  running TDLib in-process here; this pass cleans up the presentation and
//  is the hook where decryption would live.
//

import UserNotifications

final class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let best = bestAttempt else {
            contentHandler(request.content)
            return
        }

        // Telegram delivers localization keys (loc-key/loc-args); surface a
        // sensible title and mark unread badge if present in the payload.
        if best.title.isEmpty { best.title = "ClawWatch" }
        if let badge = request.content.userInfo["badge"] as? Int {
            best.badge = NSNumber(value: badge)
        }

        contentHandler(best)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt {
            contentHandler(bestAttempt)
        }
    }
}
