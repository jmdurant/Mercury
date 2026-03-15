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
        let text = textContent.text.text.lowercased()

        Task {
            if let response = await matchAndFetch(text) {
                SendMessageService.sendQuickReply(text: response, chatId: chatId)
                logger.log("Auto-responded to assistant chat \(chatId)")
            }
        }
    }

    func connectionStateUpdate(state: ConnectionState) {}
    func authorizationStateUpdate(state: AuthorizationState) {}

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
            if let np = StatusDataService.buildNowPlayingStatus() {
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
        var parts: [String] = []

        // Rich context
        if let avail = await StatusDataService.buildWorkAvailabilityStatus() { parts.append(avail) }
        if let workoutCtx = await StatusDataService.buildWorkoutContextStatus() { parts.append(workoutCtx) }
        if let driveCtx = await StatusDataService.buildDrivingContextStatus() { parts.append(driveCtx) }
        if let sleepCtx = await StatusDataService.buildSleepContextStatus() { parts.append(sleepCtx) }

        // Standard data
        if let health = await StatusDataService.buildHealthStatus() { parts.append(health) }
        if let rings = await StatusDataService.buildActivityRingsStatus() { parts.append(rings) }
        if let spo2 = await StatusDataService.buildBloodOxygenStatus() { parts.append(spo2) }
        if let cal = await StatusDataService.buildCalendarStatus() { parts.append(cal) }
        if let rem = await StatusDataService.buildRemindersStatus() { parts.append(rem) }
        if let loc = await StatusDataService.buildLocationStatus() { parts.append(loc) }
        if let weather = await StatusDataService.buildWeatherStatus() { parts.append(weather) }
        if let np = StatusDataService.buildNowPlayingStatus() { parts.append(np) }
        if let noise = await StatusDataService.buildNoiseLevelStatus() { parts.append(noise) }
        if let alt = await StatusDataService.buildAltitudeStatus() { parts.append(alt) }
        if let temp = await StatusDataService.buildWristTemperatureStatus() { parts.append(temp) }
        if let vo2 = await StatusDataService.buildVO2MaxStatus() { parts.append(vo2) }
        if let resp = await StatusDataService.buildRespiratoryRateStatus() { parts.append(resp) }
        if let speed = await StatusDataService.buildWalkingSpeedStatus() { parts.append(speed) }
        if let dist = await StatusDataService.buildDistanceStatus() { parts.append(dist) }
        if let focus = StatusDataService.buildFocusStatus() { parts.append(focus) }
        if let bat = StatusDataService.buildBatteryStatus() { parts.append(bat) }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }
}
