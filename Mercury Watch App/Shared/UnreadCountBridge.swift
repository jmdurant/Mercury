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
        default:
            break
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
