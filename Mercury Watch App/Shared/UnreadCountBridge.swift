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
    private var debounceWorkItem: DispatchWorkItem?

    init() {
        TDLibManager.shared.subscribe(self)
    }

    deinit {
        TDLibManager.shared.unsubscribe(self)
    }

    func updateHandler(update: Update) {
        switch update {
        case .updateChatReadInbox,
             .updateChatUnreadMentionCount,
             .updateChatUnreadReactionCount,
             .updateMessageUnreadReactions:
            scheduleUnreadCountUpdate()
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
                senderName = u?.fullName ?? "Someone"
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
        case .authorizationStateReady:
            scheduleUnreadCountUpdate()
        case .authorizationStateLoggingOut, .authorizationStateClosed:
            SharedDataStore.saveTotalUnreadCount(0)
            WidgetCenter.shared.reloadAllTimelines()
        default:
            break
        }
    }

    private func scheduleUnreadCountUpdate() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.fetchAndUpdateUnreadCount()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func fetchAndUpdateUnreadCount() {
        Task {
            do {
                guard let result = try await TDLibManager.shared.client?.getUnreadChatCount(
                    chatList: .chatListMain
                ) else { return }

                let count = result.unreadCount
                SharedDataStore.saveTotalUnreadCount(count)
                WidgetCenter.shared.reloadAllTimelines()
                logger.log("Updated widget unread count: \(count)")
            } catch {
                logger.log(error, level: .error)
            }
        }
    }
}
