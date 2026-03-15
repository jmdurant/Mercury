//
//  SendMessageAppIntent.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import AppIntents

struct SendMessageAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Mercury Message"
    static var description = IntentDescription("Send a Telegram message via Mercury")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Recipient")
    var recipientName: String

    @Parameter(title: "Message")
    var messageText: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await SendMessageService.sendToContact(
            name: recipientName,
            text: messageText
        )
        return .result(dialog: "Message sent to \(recipientName)")
    }
}
