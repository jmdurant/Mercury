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
        AppShortcut(
            intent: TalkToAgentAppIntent(),
            phrases: [
                "Talk to my \(.applicationName) agent",
                "Start \(.applicationName) voice",
                "Talk to \(.applicationName)"
            ],
            shortTitle: "Talk to Agent",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: PushToTalkAgentIntent(),
            phrases: [
                "Push to talk with \(.applicationName)",
                "Arm \(.applicationName) push to talk"
            ],
            shortTitle: "Push-to-Talk",
            systemImageName: "dot.radiowaves.left.and.right"
        )
    }
}
