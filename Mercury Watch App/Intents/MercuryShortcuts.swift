//
//  MercuryShortcuts.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import AppIntents

struct MercuryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendMessageAppIntent(),
            phrases: [
                "Send a message on \(.applicationName)",
                "Message someone on \(.applicationName)",
                "Send a \(.applicationName) message"
            ],
            shortTitle: "Send Message",
            systemImageName: "paperplane.fill"
        )
        AppShortcut(
            intent: CheckUnreadAppIntent(),
            phrases: [
                "Check my \(.applicationName) messages",
                "How many unread \(.applicationName) messages",
                "Any new \(.applicationName) messages"
            ],
            shortTitle: "Check Messages",
            systemImageName: "message.badge.fill"
        )
    }
}
