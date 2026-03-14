//
//  NewChatViewModel.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation
import TDLibKit

@Observable
class NewChatViewModel {

    var contacts: [ContactItem] = []
    var isLoading: Bool = true
    var searchQuery: String = ""

    private let logger = LoggerService(NewChatViewModel.self)

    struct ContactItem: Identifiable {
        let id: Int64
        let name: String
        let avatar: AvatarModel
        let statusText: String
    }

    func loadContacts() {
        isLoading = true
        Task.detached(priority: .high) {
            do {
                guard let result = try await TDLibManager.shared.client?.searchContacts(
                    query: "",
                    limit: 200
                ) else { return }

                var items: [ContactItem] = []
                for userId in result.userIds {
                    guard let user = try await TDLibManager.shared.client?.getUser(userId: userId)
                    else { continue }

                    items.append(ContactItem(
                        id: user.id,
                        name: user.fullName,
                        avatar: user.toAvatarModel(),
                        statusText: user.statusDescription
                    ))
                }

                items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                await MainActor.run {
                    self.contacts = items
                    self.isLoading = false
                }
            } catch {
                self.logger.log(error, level: .error)
                await MainActor.run { self.isLoading = false }
            }
        }
    }

    var filteredContacts: [ContactItem] {
        if searchQuery.isEmpty { return contacts }
        return contacts.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    func openChat(with contact: ContactItem, completion: @escaping (Int64) -> Void) {
        Task.detached {
            do {
                guard let chat = try await TDLibManager.shared.client?.createPrivateChat(
                    userId: contact.id,
                    force: false
                ) else { return }

                await MainActor.run {
                    completion(chat.id)
                }
            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }
}
