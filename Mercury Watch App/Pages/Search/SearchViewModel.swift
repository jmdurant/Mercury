//
//  SearchViewModel.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation
import TDLibKit
import SwiftUI

@Observable
class SearchViewModel {

    var query: String = ""
    var chatResults: [ChatCellModel] = []
    var messageResults: [MessageSearchResult] = []
    var isSearching: Bool = false

    private let logger = LoggerService(SearchViewModel.self)
    private var searchTask: Task<Void, Never>?

    struct MessageSearchResult: Identifiable {
        let id: Int64
        let chatId: Int64
        let chatTitle: String
        let preview: String
        let date: String
    }

    func search() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            chatResults = []
            messageResults = []
            return
        }

        searchTask?.cancel()
        searchTask = Task {
            isSearching = true
            await searchChats(trimmed)
            await searchMessages(trimmed)
            await MainActor.run { isSearching = false }
        }
    }

    private func searchChats(_ query: String) async {
        do {
            guard let result = try await TDLibManager.shared.client?.searchChats(
                limit: 10,
                query: query
            ) else { return }

            var items: [ChatCellModel] = []
            for chatId in result.chatIds {
                guard let chat = try await TDLibManager.shared.client?.getChat(chatId: chatId)
                else { continue }

                let avatar = chat.toAvatarModel()
                let date = Date(timeIntervalSince1970: TimeInterval(chat.lastMessage?.date ?? 0))

                items.append(ChatCellModel(
                    id: chat.id,
                    title: chat.title,
                    time: date.stringDescription,
                    avatar: avatar,
                    isMuted: chat.notificationSettings.muteFor != 0,
                    isPinned: false
                ))
            }

            await MainActor.run {
                self.chatResults = items
            }
        } catch {
            logger.log(error, level: .error)
        }
    }

    private func searchMessages(_ query: String) async {
        do {
            guard let result = try await TDLibManager.shared.client?.searchMessages(
                chatList: .chatListMain,
                chatTypeFilter: nil,
                filter: nil,
                limit: 20,
                maxDate: 0,
                minDate: 0,
                offset: nil,
                query: query
            ) else { return }

            var items: [MessageSearchResult] = []
            for message in result.messages {
                let chatTitle: String
                if let chat = try? await TDLibManager.shared.client?.getChat(chatId: message.chatId) {
                    chatTitle = chat.title
                } else {
                    chatTitle = "Chat"
                }

                let date = Date(timeIntervalSince1970: TimeInterval(message.date))
                let preview = String(message.description.characters.prefix(80))

                items.append(MessageSearchResult(
                    id: message.id,
                    chatId: message.chatId,
                    chatTitle: chatTitle,
                    preview: preview,
                    date: date.stringDescription
                ))
            }

            await MainActor.run {
                self.messageResults = items
            }
        } catch {
            logger.log(error, level: .error)
        }
    }
}
