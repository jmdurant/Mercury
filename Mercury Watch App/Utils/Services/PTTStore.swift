//
//  PTTStore.swift
//  Mercury Watch App
//
//  Created on 09/07/26.
//

import Foundation

/// Persistence for walkie-talkie (push-to-talk) mode:
/// which chats auto-play incoming voice notes, and the global switch.
enum PTTStore {

    private static let chatIdsKey = "pttChatIds"
    private static let autoPlayKey = "pttAutoPlayEnabled"
    private static let liftToSpeakKey = "pttLiftToSpeakEnabled"

    /// Master switch for auto-playing incoming voice notes (default on)
    static var isAutoPlayEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoPlayKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoPlayKey) }
    }

    /// Lift to Speak: wrist raise records, wrist lower sends.
    /// Off by default — starting the mic on a gesture should be opt-in.
    static var isLiftToSpeakEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: liftToSpeakKey) }
        set { UserDefaults.standard.set(newValue, forKey: liftToSpeakKey) }
    }

    static func isPTTChat(_ chatId: Int64) -> Bool {
        getPTTChatIds().contains(chatId)
    }

    static func setPTTChat(_ chatId: Int64, enabled: Bool) {
        var ids = getPTTChatIds()
        if enabled {
            ids.insert(chatId)
        } else {
            ids.remove(chatId)
        }
        savePTTChatIds(ids)
    }

    static var chatCount: Int {
        getPTTChatIds().count
    }

    static func clearAll() {
        savePTTChatIds([])
    }

    private static func getPTTChatIds() -> Set<Int64> {
        let array = UserDefaults.standard.array(forKey: chatIdsKey) as? [Int64] ?? []
        return Set(array)
    }

    private static func savePTTChatIds(_ ids: Set<Int64>) {
        UserDefaults.standard.set(Array(ids), forKey: chatIdsKey)
    }
}
