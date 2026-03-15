//
//  CheckUnreadAppIntent.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import AppIntents

struct CheckUnreadAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Mercury Messages"
    static var description = IntentDescription("Check your unread Telegram messages")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let count = SharedDataStore.getTotalUnreadCount()
        if count == 0 {
            return .result(dialog: "You have no unread messages on Mercury")
        } else if count == 1 {
            return .result(dialog: "You have 1 unread message on Mercury")
        } else {
            return .result(dialog: "You have \(count) unread messages on Mercury")
        }
    }
}
