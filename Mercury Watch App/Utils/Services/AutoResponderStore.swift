//
//  AutoResponderStore.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation

enum AutoResponderStore {

    private static let key = "assistantChatIds"

    static func isAssistantChat(_ chatId: Int64) -> Bool {
        getAssistantChatIds().contains(chatId)
    }

    static func toggleAssistantChat(_ chatId: Int64) {
        var ids = getAssistantChatIds()
        if ids.contains(chatId) {
            ids.remove(chatId)
        } else {
            ids.insert(chatId)
        }
        saveAssistantChatIds(ids)
    }

    static func setAssistantChat(_ chatId: Int64, enabled: Bool) {
        var ids = getAssistantChatIds()
        if enabled {
            ids.insert(chatId)
        } else {
            ids.remove(chatId)
        }
        saveAssistantChatIds(ids)
    }

    private static func getAssistantChatIds() -> Set<Int64> {
        let array = UserDefaults.standard.array(forKey: key) as? [Int64] ?? []
        return Set(array)
    }

    private static func saveAssistantChatIds(_ ids: Set<Int64>) {
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}
