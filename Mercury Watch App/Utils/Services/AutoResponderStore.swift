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

    // MARK: - Focus Auto-Reply

    static var isFocusAutoReplyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: dndAutoReplyKey) }
        set { UserDefaults.standard.set(newValue, forKey: dndAutoReplyKey) }
    }

    struct FocusProfile: Codable, Identifiable {
        var id: String  // "workout", "sleep", "work", "general"
        var name: String
        var message: String
        var includeCalendar: Bool
        var includeWorkout: Bool
        var includeLocation: Bool
        var includeBattery: Bool
        var includeHealth: Bool
    }

    static let defaultProfiles: [FocusProfile] = [
        FocusProfile(
            id: "workout",
            name: "Workout",
            message: "I'm working out right now. I'll reply when I'm done.",
            includeCalendar: false, includeWorkout: true,
            includeLocation: false, includeBattery: false, includeHealth: true
        ),
        FocusProfile(
            id: "work",
            name: "Work",
            message: "I'm at work and can't chat right now.",
            includeCalendar: true, includeWorkout: false,
            includeLocation: false, includeBattery: false, includeHealth: false
        ),
        FocusProfile(
            id: "sleep",
            name: "Sleep",
            message: "I'm sleeping. I'll get back to you in the morning.",
            includeCalendar: false, includeWorkout: false,
            includeLocation: false, includeBattery: false, includeHealth: false
        ),
        FocusProfile(
            id: "general",
            name: "General",
            message: "I'm currently unavailable. I'll get back to you soon.",
            includeCalendar: true, includeWorkout: true,
            includeLocation: false, includeBattery: false, includeHealth: false
        ),
    ]

    private static let profilesKey = "focusProfiles"
    private static let activeProfileKey = "activeFocusProfile"

    static func getProfiles() -> [FocusProfile] {
        guard let data = UserDefaults.standard.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([FocusProfile].self, from: data)
        else { return defaultProfiles }
        return profiles
    }

    static func saveProfiles(_ profiles: [FocusProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    static var activeProfileId: String {
        get { UserDefaults.standard.string(forKey: activeProfileKey) ?? "general" }
        set { UserDefaults.standard.set(newValue, forKey: activeProfileKey) }
    }

    static func getActiveProfile() -> FocusProfile {
        let profiles = getProfiles()
        return profiles.first { $0.id == activeProfileId } ?? defaultProfiles.last!
    }

    static func autoDetectProfile() -> FocusProfile {
        let profiles = getProfiles()

        // Auto-detect based on context
        if let _ = StatusDataService.buildNowPlayingStatus() {
            // Could be relaxing, use general
        }

        // Check time of day for sleep
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 22 || hour < 7 {
            return profiles.first { $0.id == "sleep" } ?? getActiveProfile()
        }

        // Check for active workout
        // (buildWorkoutStatus is async, so we'll use the manually selected profile as primary)

        return getActiveProfile()
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
