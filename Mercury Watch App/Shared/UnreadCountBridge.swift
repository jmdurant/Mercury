//
//  UnreadCountBridge.swift
//  Mercury Watch App
//
//  Created by Security Hardening on 14/03/26.
//

import Foundation
import TDLibKit
import WidgetKit

class UnreadCountBridge: TDLibManagerProtocol {

    private let logger = LoggerService(UnreadCountBridge.self)

    init() {
        TDLibManager.shared.subscribe(self)
    }

    deinit {
        TDLibManager.shared.unsubscribe(self)
    }

    func updateHandler(update: Update) {
        switch update {
        case .updateUnreadChatCount(let update):
            // TDLib pushes this whenever the count changes; there is no
            // request-based getter in current TDLib
            if case .chatListMain = update.chatList {
                SharedDataStore.saveTotalUnreadCount(update.unreadCount)
                WidgetCenter.shared.reloadAllTimelines()
                logger.log("Updated widget unread count: \(update.unreadCount)")
            }
        case .updateNewMessage(let msg):
            if !msg.message.isOutgoing {
                trackLastSender(message: msg.message)
            }
        default:
            break
        }
    }

    private func trackLastSender(message: Message) {
        Task {
            let senderName: String
            switch message.senderId {
            case .messageSenderUser(let user):
                let u = try? await TDLibManager.shared.client?.getUser(userId: user.userId)
                // Inlined (User.fullName lives in the watch-only User+ extension)
                senderName = u.map { "\($0.firstName) \($0.lastName)" } ?? "Someone"
            case .messageSenderChat(let chat):
                let c = try? await TDLibManager.shared.client?.getChat(chatId: chat.chatId)
                senderName = c?.title ?? "Chat"
            }
            SharedDataStore.saveLastMessage(senderName: senderName, chatId: message.chatId)
        }
    }

    func connectionStateUpdate(state: ConnectionState) {}

    func authorizationStateUpdate(state: AuthorizationState) {
        switch state {
        case .authorizationStateLoggingOut, .authorizationStateClosed:
            SharedDataStore.saveTotalUnreadCount(0)
            WidgetCenter.shared.reloadAllTimelines()
        default:
            break
        }
    }
}
