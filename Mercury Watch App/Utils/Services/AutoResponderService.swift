//
//  AutoResponderService.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation
import TDLibKit
import Intents
import CoreMotion

class AutoResponderService: TDLibManagerProtocol {

    private let logger = LoggerService(AutoResponderService.self)
    private let motionManager = CMMotionActivityManager()
    private var isAutomotive: Bool = false
    private var isWorkoutActive: Bool = false

    init() {
        startActivityMonitoring()
        TDLibManager.shared.subscribe(self)
    }

    deinit {
        TDLibManager.shared.unsubscribe(self)
    }

    /// Tracks chats we've already DND-replied to this session to avoid spam
    private var dndRepliedChats: Set<Int64> = []

    func updateHandler(update: Update) {
        guard case .updateNewMessage(let msg) = update else { return }
        let message = msg.message
        guard !message.isOutgoing else { return }

        let chatId = message.chatId

        // Focus auto-reply: respond to ALL chats when Focus is active
        if AutoResponderStore.isFocusAutoReplyEnabled,
           INFocusStatusCenter.default.focusStatus.isFocused == true,
           !dndRepliedChats.contains(chatId) {

            dndRepliedChats.insert(chatId)
            let profile = AutoResponderStore.autoDetectProfile(
                isAutomotive: isAutomotive,
                isWorkout: isWorkoutActive
            )
            var reply = profile.message

            Task {
                var context: [String] = []

                // Profile-specific enhanced context
                switch profile.id {
                case "sleep":
                    if let sleepCtx = await StatusDataService.buildSleepContextStatus() {
                        context.append(sleepCtx)
                    }
                case "driving":
                    if let driveCtx = await StatusDataService.buildDrivingContextStatus() {
                        context.append(driveCtx)
                    }
                case "work":
                    if let availability = await StatusDataService.buildWorkAvailabilityStatus() {
                        context.append(availability)
                    }
                case "workout":
                    if let workoutCtx = await StatusDataService.buildWorkoutContextStatus() {
                        context.append(workoutCtx)
                    }
                default:
                    break
                }

                // Generic context from profile toggles
                if profile.includeCalendar, profile.id != "work",
                   let cal = await StatusDataService.buildCalendarStatus() {
                    context.append(cal)
                }
                if profile.includeWorkout, profile.id != "workout",
                   let workout = await StatusDataService.buildWorkoutStatus() {
                    context.append(workout)
                }
                if profile.includeHealth,
                   let health = await StatusDataService.buildHealthStatus() {
                    context.append(health)
                }
                if profile.includeLocation, profile.id != "driving",
                   let loc = await StatusDataService.buildLocationStatus() {
                    context.append(loc)
                }
                if profile.includeBattery,
                   let bat = StatusDataService.buildBatteryStatus() {
                    context.append(bat)
                }
                if !context.isEmpty {
                    reply += "\n" + context.joined(separator: "\n")
                }
                SendMessageService.sendQuickReply(text: reply, chatId: chatId)
                self.logger.log("Focus auto-replied [\(profile.name)] to chat \(chatId)")
            }
            return
        }

        // Reset DND tracking when Focus turns off
        if INFocusStatusCenter.default.focusStatus.isFocused != true {
            dndRepliedChats.removeAll()
        }

        // AI assistant auto-reply for designated chats
        guard AutoResponderStore.isAssistantChat(chatId) else { return }

        guard case .messageText(let textContent) = message.content else { return }
        let rawText = textContent.text.text
        let text = rawText.lowercased().trimmingCharacters(in: .whitespaces)

        // Check for silent tags — suppress notification and auto-respond
        let isSilent = text.hasPrefix("#")
        if isSilent {
            suppressNotification(messageId: message.id, chatId: chatId)
        }

        Task {
            let response: String?

            // Handle tagged commands
            if text == "#status" || text == "#full" || text == "#dump" {
                response = await buildFullStatus()
            } else if text == "#health" {
                response = await StatusDataService.buildHealthStatus()
            } else if text == "#location" || text == "#loc" {
                response = await StatusDataService.buildLocationStatus()
            } else if text == "#weather" {
                response = await StatusDataService.buildWeatherStatus()
            } else if text == "#calendar" || text == "#cal" {
                response = await StatusDataService.buildWorkAvailabilityStatus()
                    ?? (await StatusDataService.buildCalendarStatus())
            } else if text == "#workout" {
                response = await StatusDataService.buildWorkoutContextStatus()
                    ?? (await StatusDataService.buildWorkoutStatus())
            } else if text == "#sleep" {
                response = await StatusDataService.buildSleepContextStatus()
                    ?? (await StatusDataService.buildSleepStatus())
            } else if text == "#heart" || text == "#hr" || text == "#heartrate" {
                if let hr = await StatusDataService.getCurrentHeartRate() {
                    response = "Heart rate: \(hr) bpm"
                } else { response = nil }
            } else if text == "#steps" {
                if let steps = await StatusDataService.getTodaySteps() {
                    response = "Steps today: \(steps.formatted())"
                } else { response = nil }
            } else if text == "#battery" || text == "#bat" {
                response = StatusDataService.buildBatteryStatus()
            } else if text == "#music" || text == "#playing" {
                response = await StatusDataService.buildNowPlayingWithLink()
            } else if text.hasPrefix("#music ") {
                // Bot sent a song recommendation — look it up
                let searchTerm = String(rawText.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                response = await StatusDataService.lookupSongLink(query: searchTerm)
            } else if text.hasPrefix("#play ") {
                // Same as #music but also includes a "now opening" message
                let searchTerm = String(rawText.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                response = await StatusDataService.lookupSongLink(query: searchTerm)
            } else if text == "#rings" || text == "#activity" {
                response = await StatusDataService.buildActivityRingsStatus()
            } else if text == "#o2" || text == "#oxygen" {
                response = await StatusDataService.buildBloodOxygenStatus()
            } else if text == "#focus" || text == "#dnd" {
                response = StatusDataService.buildFocusStatus() ?? "Focus mode is not active"
            } else if text == "#noise" {
                response = await StatusDataService.buildNoiseLevelStatus()
            } else if text == "#temp" {
                response = await StatusDataService.buildWristTemperatureStatus()
            } else if text == "#vo2" {
                response = await StatusDataService.buildVO2MaxStatus()
            } else if text == "#distance" || text == "#dist" {
                response = await StatusDataService.buildDistanceStatus()
            } else if text == "#speed" {
                response = await StatusDataService.buildWalkingSpeedStatus()
            } else if text == "#respiratory" || text == "#breathing" {
                response = await StatusDataService.buildRespiratoryRateStatus()
            } else if text == "#reminder" || text == "#reminders" {
                response = await StatusDataService.buildRemindersStatus()
            } else if text == "#altitude" || text == "#alt" {
                response = await StatusDataService.buildAltitudeStatus()
            } else if text == "#help" {
                response = """
                Available commands:
                #status — Full status dump
                #health — Steps, calories, heart rate
                #heart — Heart rate
                #steps — Step count
                #rings — Activity rings
                #o2 — Blood oxygen
                #sleep — Sleep data
                #workout — Workout status
                #calendar — Calendar/availability
                #location — Current location
                #weather — Weather conditions
                #music — Now playing
                #battery — Battery level
                #focus — Focus mode status
                #noise — Ambient noise
                #temp — Wrist temperature
                #vo2 — VO2 Max
                #speed — Walking speed
                #distance — Distance today
                #respiratory — Respiratory rate
                #reminder — Next reminder
                #altitude — Altitude
                """
            } else if text.hasPrefix("#") {
                // Unknown tag — ignore silently
                response = nil
            } else {
                // Natural language query
                response = await matchAndFetch(text)
            }

            if let response {
                SendMessageService.sendQuickReply(text: response, chatId: chatId)
                logger.log("Auto-responded\(isSilent ? " (silent)" : "") to assistant chat \(chatId)")
            }
        }
    }

    func connectionStateUpdate(state: ConnectionState) {}
    func authorizationStateUpdate(state: AuthorizationState) {}

    private func suppressNotification(messageId: Int64, chatId: Int64) {
        // Mark message as read immediately to suppress notification
        Task {
            do {
                try await TDLibManager.shared.client?.openChat(chatId: chatId)
                try await TDLibManager.shared.client?.viewMessages(
                    chatId: chatId,
                    forceRead: true,
                    messageIds: [messageId],
                    source: nil
                )
                try await TDLibManager.shared.client?.closeChat(chatId: chatId)
            } catch {
                logger.log(error, level: .error)
            }
        }
    }

    private func startActivityMonitoring() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            self?.isAutomotive = activity.automotive
            self?.isWorkoutActive = activity.running || activity.cycling
        }
    }

    // MARK: - Query Matching

    private func matchAndFetch(_ text: String) async -> String? {
        // Match multiple queries and combine responses
        var responses: [String] = []

        if matches(text, keywords: ["heart rate", "heart", "bpm", "pulse"]) {
            if let hr = await StatusDataService.getCurrentHeartRate() {
                responses.append("Heart rate: \(hr) bpm")
            }
        }

        if matches(text, keywords: ["steps", "step count", "walking"]) {
            if let steps = await StatusDataService.getTodaySteps() {
                responses.append("Steps today: \(steps.formatted())")
            }
        }

        if matches(text, keywords: ["calories", "energy", "active energy"]) {
            if let cal = await StatusDataService.getActiveCalories() {
                responses.append("Active calories: \(cal) cal")
            }
        }

        if matches(text, keywords: ["location", "where are you", "where r u", "position", "gps"]) {
            if let loc = await StatusDataService.buildLocationStatus() {
                responses.append(loc)
            }
        }

        if matches(text, keywords: ["weather", "temperature", "forecast", "outside"]) {
            if let weather = await StatusDataService.buildWeatherStatus() {
                responses.append(weather)
            }
        }

        if matches(text, keywords: ["workout", "exercise", "training", "running", "gym"]) {
            if let workout = await StatusDataService.buildWorkoutStatus() {
                responses.append(workout)
            }
        }

        if matches(text, keywords: ["busy", "calendar", "schedule", "meeting", "free", "available"]) {
            if let cal = await StatusDataService.buildCalendarStatus() {
                responses.append(cal)
            }
        }

        if matches(text, keywords: ["sleep", "slept", "rest", "how did you sleep"]) {
            if let sleep = await StatusDataService.buildSleepStatus() {
                responses.append(sleep)
            }
        }

        if matches(text, keywords: ["activity", "rings", "move ring", "stand"]) {
            if let rings = await StatusDataService.buildActivityRingsStatus() {
                responses.append(rings)
            }
        }

        if matches(text, keywords: ["oxygen", "spo2", "blood oxygen", "o2"]) {
            if let spo2 = await StatusDataService.buildBloodOxygenStatus() {
                responses.append(spo2)
            }
        }

        if matches(text, keywords: ["noise", "loud", "sound", "decibel", "db"]) {
            if let noise = await StatusDataService.buildNoiseLevelStatus() {
                responses.append(noise)
            }
        }

        if matches(text, keywords: ["altitude", "elevation", "height"]) {
            if let alt = await StatusDataService.buildAltitudeStatus() {
                responses.append(alt)
            }
        }

        if matches(text, keywords: ["listening", "music", "playing", "song", "what are you listening"]) {
            if let np = await StatusDataService.buildNowPlayingWithLink() {
                responses.append(np)
            }
        }

        if matches(text, keywords: ["battery", "charge", "power"]) {
            if let bat = StatusDataService.buildBatteryStatus() {
                responses.append(bat)
            }
        }

        if matches(text, keywords: ["reminder", "task", "todo", "to do", "to-do"]) {
            if let rem = await StatusDataService.buildRemindersStatus() {
                responses.append(rem)
            }
        }

        if matches(text, keywords: ["temperature", "wrist temp", "body temp"]) {
            if let temp = await StatusDataService.buildWristTemperatureStatus() {
                responses.append(temp)
            }
        }

        if matches(text, keywords: ["vo2", "vo2 max", "cardio fitness", "fitness level"]) {
            if let vo2 = await StatusDataService.buildVO2MaxStatus() {
                responses.append(vo2)
            }
        }

        if matches(text, keywords: ["breathing", "respiratory", "breath rate", "respiration"]) {
            if let resp = await StatusDataService.buildRespiratoryRateStatus() {
                responses.append(resp)
            }
        }

        if matches(text, keywords: ["walking speed", "pace", "how fast"]) {
            if let speed = await StatusDataService.buildWalkingSpeedStatus() {
                responses.append(speed)
            }
        }

        if matches(text, keywords: ["distance", "how far", "miles", "km"]) {
            if let dist = await StatusDataService.buildDistanceStatus() {
                responses.append(dist)
            }
        }

        if matches(text, keywords: ["focus", "do not disturb", "dnd", "focus mode"]) {
            if let focus = StatusDataService.buildFocusStatus() {
                responses.append(focus)
            }
        }

        if matches(text, keywords: ["health", "vitals", "health status", "how are you", "status", "check in"]) {
            if let health = await StatusDataService.buildHealthStatus() {
                responses.append(health)
            }
        }

        if matches(text, keywords: ["available", "free", "when can you", "when will you", "availability", "when are you free"]) {
            if let avail = await StatusDataService.buildWorkAvailabilityStatus() {
                responses.append(avail)
            } else {
                responses.append("No meetings on my calendar — I'm free")
            }
        }

        if matches(text, keywords: ["driving", "commute", "eta", "how long", "when will you arrive", "where are you heading"]) {
            if let drive = await StatusDataService.buildDrivingContextStatus() {
                responses.append(drive)
            }
        }

        if matches(text, keywords: ["sleep", "slept", "rest", "how did you sleep", "when did you go to bed", "bedtime"]) {
            if let sleep = await StatusDataService.buildSleepContextStatus() {
                responses.append(sleep)
            }
        }

        if matches(text, keywords: ["workout detail", "how long have you been", "when did you start", "exercise detail"]) {
            if let workoutCtx = await StatusDataService.buildWorkoutContextStatus() {
                responses.append(workoutCtx)
            }
        }

        // "Give me everything" / "full status" returns all available data
        if matches(text, keywords: ["full status", "all data", "everything", "full report", "all sensors", "all stats"]) {
            return await buildFullStatus()
        }

        guard !responses.isEmpty else { return nil }
        return responses.joined(separator: "\n")
    }

    private func matches(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private func buildFullStatus() async -> String? {
        var sections: [String] = []

        // Lead with the Focus profile summary (human-readable)
        let profile = AutoResponderStore.autoDetectProfile(
            isAutomotive: isAutomotive,
            isWorkout: isWorkoutActive
        )
        var summary = "[\(profile.name.uppercased())] \(profile.message)"

        // Add the profile-specific rich context
        var profileContext: [String] = []
        switch profile.id {
        case "sleep":
            if let ctx = await StatusDataService.buildSleepContextStatus() { profileContext.append(ctx) }
        case "driving":
            if let ctx = await StatusDataService.buildDrivingContextStatus() { profileContext.append(ctx) }
        case "work":
            if let ctx = await StatusDataService.buildWorkAvailabilityStatus() { profileContext.append(ctx) }
        case "workout":
            if let ctx = await StatusDataService.buildWorkoutContextStatus() { profileContext.append(ctx) }
        default:
            break
        }
        if !profileContext.isEmpty {
            summary += "\n" + profileContext.joined(separator: "\n")
        }
        sections.append(summary)

        // Separator
        sections.append("---")

        // Full data dump
        var data: [String] = []
        if let health = await StatusDataService.buildHealthStatus() { data.append(health) }
        if let rings = await StatusDataService.buildActivityRingsStatus() { data.append(rings) }
        if let spo2 = await StatusDataService.buildBloodOxygenStatus() { data.append(spo2) }
        if let cal = await StatusDataService.buildCalendarStatus() { data.append(cal) }
        if let avail = await StatusDataService.buildWorkAvailabilityStatus() { data.append(avail) }
        if let rem = await StatusDataService.buildRemindersStatus() { data.append(rem) }
        if let loc = await StatusDataService.buildLocationStatus() { data.append(loc) }
        if let weather = await StatusDataService.buildWeatherStatus() { data.append(weather) }
        if let np = StatusDataService.buildNowPlayingStatus() { data.append(np) }
        if let noise = await StatusDataService.buildNoiseLevelStatus() { data.append(noise) }
        if let alt = await StatusDataService.buildAltitudeStatus() { data.append(alt) }
        if let temp = await StatusDataService.buildWristTemperatureStatus() { data.append(temp) }
        if let vo2 = await StatusDataService.buildVO2MaxStatus() { data.append(vo2) }
        if let resp = await StatusDataService.buildRespiratoryRateStatus() { data.append(resp) }
        if let speed = await StatusDataService.buildWalkingSpeedStatus() { data.append(speed) }
        if let dist = await StatusDataService.buildDistanceStatus() { data.append(dist) }
        if let focus = StatusDataService.buildFocusStatus() { data.append(focus) }
        if let bat = StatusDataService.buildBatteryStatus() { data.append(bat) }

        if !data.isEmpty {
            sections.append(data.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n")
    }
}
