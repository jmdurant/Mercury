//
//  AutoResponderStore.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation

enum AutoResponderStore {

    private static let key = "assistantChatIds"
    private static let dndAutoReplyKey = "dndAutoReplyEnabled"
    private static let dndMessageKey = "dndAutoReplyMessage"

    // MARK: - DND Auto-Reply

    static var isDndAutoReplyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: dndAutoReplyKey) }
        set { UserDefaults.standard.set(newValue, forKey: dndAutoReplyKey) }
    }

    static var dndAutoReplyMessage: String {
        get { UserDefaults.standard.string(forKey: dndMessageKey) ?? "I'm currently unavailable. I'll get back to you soon." }
        set { UserDefaults.standard.set(newValue, forKey: dndMessageKey) }
    }

    // MARK: - DND Context Options

    private static let dndIncludeCalendarKey = "dndIncludeCalendar"
    private static let dndIncludeLocationKey = "dndIncludeLocation"
    private static let dndIncludeWorkoutKey = "dndIncludeWorkout"
    private static let dndIncludeBatteryKey = "dndIncludeBattery"

    static var dndIncludeCalendar: Bool {
        get { UserDefaults.standard.object(forKey: dndIncludeCalendarKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: dndIncludeCalendarKey) }
    }

    static var dndIncludeLocation: Bool {
        get { UserDefaults.standard.object(forKey: dndIncludeLocationKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: dndIncludeLocationKey) }
    }

    static var dndIncludeWorkout: Bool {
        get { UserDefaults.standard.object(forKey: dndIncludeWorkoutKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: dndIncludeWorkoutKey) }
    }

    static var dndIncludeBattery: Bool {
        get { UserDefaults.standard.object(forKey: dndIncludeBatteryKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: dndIncludeBatteryKey) }
    }

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
