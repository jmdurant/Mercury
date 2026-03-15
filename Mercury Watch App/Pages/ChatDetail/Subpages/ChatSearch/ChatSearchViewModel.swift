//
//  ChatSearchViewModel.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation
import TDLibKit

@Observable
class ChatSearchViewModel {

    let chatId: Int64
    var query: String = ""
    var results: [SearchResult] = []
    var isSearching: Bool = false

    private let logger = LoggerService(ChatSearchViewModel.self)
    private var searchTask: Task<Void, Never>?

    struct SearchResult: Identifiable {
        let id: Int64
        let senderName: String
        let preview: String
        let date: String
    }

    init(chatId: Int64) {
        self.chatId = chatId
    }

    func search() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            return
        }

        searchTask?.cancel()
        searchTask = Task {
            await MainActor.run { isSearching = true }

            do {
                guard let result = try await TDLibManager.shared.client?.searchChatMessages(
                    chatId: chatId,
                    filter: nil,
                    fromMessageId: 0,
                    limit: 20,
                    offset: 0,
                    query: trimmed,
                    senderId: nil,
                    topicId: nil
                ) else { return }

                var items: [SearchResult] = []
                for message in result.messages {
                    let senderName = await message.senderId.username() ?? "Unknown"
                    let date = Date(timeIntervalSince1970: TimeInterval(message.date))
                    let preview = String(message.description.characters.prefix(80))

                    items.append(SearchResult(
                        id: message.id,
                        senderName: senderName,
                        preview: preview,
                        date: date.formatted(.dateTime.month().day().hour().minute())
                    ))
                }

                await MainActor.run {
                    self.results = items
                    self.isSearching = false
                }
            } catch {
                logger.log(error, level: .error)
                await MainActor.run { isSearching = false }
            }
        }
    }
}
