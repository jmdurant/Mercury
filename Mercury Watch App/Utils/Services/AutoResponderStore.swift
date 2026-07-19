//
//  AutoResponderStore.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation

enum AutoResponderStore {

    // MARK: - Agent session identity

    private static let sessionIdKey = "agentSessionId"

    /// Stable per-install identifier so the agent knows which device it is
    /// talking to across a multi-turn conversation.
    static var sessionId: String {
        if let existing = UserDefaults.standard.string(forKey: sessionIdKey) {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: sessionIdKey)
        return new
    }

    // MARK: - Double Tap Action

    private static let doubleTapActionKey = "doubleTapAction"

    enum DoubleTapAction: String, CaseIterable {
        case thumbsUp = "thumbsUp"
        case heart = "heart"
        case fire = "fire"
        case markRead = "markRead"
        case quickReply = "quickReply"

        var displayName: String {
            switch self {
            case .thumbsUp: return "👍 Thumbs Up"
            case .heart: return "❤️ Heart"
            case .fire: return "🔥 Fire"
            case .markRead: return "Mark as Read"
            case .quickReply: return "Open Quick Reply"
            }
        }

        var emoji: String? {
            switch self {
            case .thumbsUp: return "👍"
            case .heart: return "❤️"
            case .fire: return "🔥"
            case .markRead, .quickReply: return nil
            }
        }
    }

    static var doubleTapAction: DoubleTapAction {
        get {
            let raw = UserDefaults.standard.string(forKey: doubleTapActionKey) ?? "thumbsUp"
            return DoubleTapAction(rawValue: raw) ?? .thumbsUp
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: doubleTapActionKey) }
    }

    // MARK: - Assistant Chat IDs

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
            id: "driving",
            name: "Driving",
            message: "I'm driving right now. I'll reply when I arrive.",
            includeCalendar: true, includeWorkout: false,
            includeLocation: false, includeBattery: false, includeHealth: false
        ),
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

    static func autoDetectProfile(isAutomotive: Bool = false, isWorkout: Bool = false) -> FocusProfile {
        let profiles = getProfiles()

        // Auto-detect driving
        if isAutomotive {
            return profiles.first { $0.id == "driving" } ?? getActiveProfile()
        }

        // Auto-detect workout
        if isWorkout {
            return profiles.first { $0.id == "workout" } ?? getActiveProfile()
        }

        // Auto-detect sleep by time of day
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 22 || hour < 7 {
            return profiles.first { $0.id == "sleep" } ?? getActiveProfile()
        }

        return getActiveProfile()
    }

    static func isAssistantChat(_ chatId: Int64) -> Bool {
        getAssistantChatIds().contains(chatId)
    }

    /// All chats designated as assistant chats (for proactive pushes).
    static func assistantChatIds() -> [Int64] {
        Array(getAssistantChatIds())
    }

    private static let contextPushKey = "agentContextPushEnabled"
    static var isContextPushEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: contextPushKey) }
        set { UserDefaults.standard.set(newValue, forKey: contextPushKey) }
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

    // MARK: - Trust layer

    /// Categories of data/actions the agent may access. Commands are gated
    /// by category so the user can grant e.g. health but not location.
    enum Consent: String, CaseIterable, Identifiable {
        case health, location, calendar, media, actions
        var id: String { rawValue }
        var label: String {
            switch self {
            case .health: return "Health"
            case .location: return "Location"
            case .calendar: return "Calendar"
            case .media: return "Media"
            case .actions: return "Actions (call, remind, open)"
            }
        }
    }

    private static let consentKey = "agentConsent"
    private static let tokenKey = "agentToken"
    private static let auditKey = "agentAuditLog"
    private static let rateWindowKey = "agentRateTimestamps"

    /// Consent defaults to all-granted (opt-out) to preserve current behaviour.
    static func isConsented(_ c: Consent) -> Bool {
        guard let raw = UserDefaults.standard.array(forKey: consentKey) as? [String]
        else { return true }
        return raw.contains(c.rawValue)
    }
    static func setConsent(_ c: Consent, _ on: Bool) {
        var set = Set(UserDefaults.standard.array(forKey: consentKey) as? [String]
                      ?? Consent.allCases.map(\.rawValue))
        if on { set.insert(c.rawValue) } else { set.remove(c.rawValue) }
        UserDefaults.standard.set(Array(set), forKey: consentKey)
    }

    /// Optional shared secret. When set, commands must be prefixed with it
    /// (e.g. "#<token> status") or they are ignored.
    static var token: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }

    /// Rate limit: max queries per rolling minute. Returns false if exceeded.
    static func allowRequest(limitPerMinute: Int = 30) -> Bool {
        let now = Date().timeIntervalSince1970
        var stamps = (UserDefaults.standard.array(forKey: rateWindowKey) as? [Double] ?? [])
            .filter { now - $0 < 60 }
        guard stamps.count < limitPerMinute else {
            UserDefaults.standard.set(stamps, forKey: rateWindowKey)
            return false
        }
        stamps.append(now)
        UserDefaults.standard.set(stamps, forKey: rateWindowKey)
        return true
    }

    /// Append a reviewable record of what the agent queried and when.
    static func audit(command: String, chatId: Int64) {
        var log = UserDefaults.standard.array(forKey: auditKey) as? [String] ?? []
        let ts = ISO8601DateFormatter().string(from: Date())
        log.append("\(ts)\tchat \(chatId)\t\(command)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
        UserDefaults.standard.set(log, forKey: auditKey)
    }
    static func auditLog() -> [String] {
        (UserDefaults.standard.array(forKey: auditKey) as? [String] ?? []).reversed()
    }
    static func clearAudit() {
        UserDefaults.standard.removeObject(forKey: auditKey)
    }

    /// Maps a command to the consent category it requires (nil = always allowed).
    static func requiredConsent(for command: String) -> Consent? {
        let c = command.lowercased()
        if c.hasPrefix("#health") || c.hasPrefix("#heart") || c.hasPrefix("#steps")
            || c.hasPrefix("#sleep") || c.hasPrefix("#o2") || c.hasPrefix("#rings")
            || c.hasPrefix("#temp") || c.hasPrefix("#vo2") || c.hasPrefix("#respiratory")
            || c.hasPrefix("#json") { return .health }
        if c.hasPrefix("#location") || c.hasPrefix("#loc") || c.hasPrefix("#navigate")
            || c.hasPrefix("#directions") { return .location }
        if c.hasPrefix("#calendar") || c.hasPrefix("#cal") || c.hasPrefix("#reminder") { return .calendar }
        if c.hasPrefix("#music") || c.hasPrefix("#play") { return .media }
        if c.hasPrefix("#call") || c.hasPrefix("#remind") || c.hasPrefix("#open") { return .actions }
        return nil
    }
}
