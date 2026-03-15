//
//  StatusDataService.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation
import HealthKit
import EventKit
import MediaPlayer
import WeatherKit
import CoreLocation
import CoreMotion
import WatchKit

enum StatusDataService {

    private static let healthStore = HKHealthStore()
    private static let eventStore = EKEventStore()
    private static let logger = LoggerService(StatusDataService.self)

    // MARK: - Permissions

    static func requestHealthPermissions() {
        let types: Set<HKSampleType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.oxygenSaturation),
            HKQuantityType(.environmentalAudioExposure),
            HKCategoryType(.sleepAnalysis),
        ]
        let workoutType = HKObjectType.workoutType()
        let activityType = HKObjectType.activitySummaryType()
        var allTypes = types as Set<HKObjectType>
        allTypes.insert(workoutType)
        allTypes.insert(activityType)

        healthStore.requestAuthorization(toShare: nil, read: allTypes) { _, error in
            if let error { logger.log(error, level: .error) }
        }
    }

    static func requestCalendarPermissions() async -> Bool {
        do {
            return try await eventStore.requestFullAccessToEvents()
        } catch {
            logger.log(error, level: .error)
            return false
        }
    }

    // MARK: - Health Data

    static func getCurrentHeartRate() async -> Int? {
        let heartRateType = HKQuantityType(.heartRate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: heartRateType,
            predicate: HKQuery.predicateForSamples(
                withStart: Date().addingTimeInterval(-300),
                end: Date(),
                options: .strictEndDate
            ),
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) { _, _, _ in }

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: heartRateType,
                predicate: HKQuery.predicateForSamples(
                    withStart: Date().addingTimeInterval(-300),
                    end: Date(),
                    options: .strictEndDate
                ),
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                let bpm = Int(sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
                continuation.resume(returning: bpm)
            }
            healthStore.execute(query)
        }
    }

    static func getTodaySteps() async -> Int? {
        let stepType = HKQuantityType(.stepCount)
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())

        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: startOfDay,
                end: Date(),
                options: .strictEndDate
            )
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                guard let sum = result?.sumQuantity() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Int(sum.doubleValue(for: .count())))
            }
            healthStore.execute(query)
        }
    }

    static func getActiveCalories() async -> Int? {
        let calorieType = HKQuantityType(.activeEnergyBurned)
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())

        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: startOfDay,
                end: Date(),
                options: .strictEndDate
            )
            let query = HKStatisticsQuery(
                quantityType: calorieType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                guard let sum = result?.sumQuantity() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Int(sum.doubleValue(for: .kilocalorie())))
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Calendar

    static func getCurrentOrNextEvent() async -> (title: String, endTime: Date)? {
        let granted = await requestCalendarPermissions()
        guard granted else { return nil }

        let now = Date()
        let endOfDay = Calendar.current.date(byAdding: .hour, value: 12, to: now) ?? now
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-3600),
            end: endOfDay,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        // Current event
        if let current = events.first(where: { $0.startDate <= now && $0.endDate > now }) {
            return (current.title, current.endDate)
        }
        // Next event
        if let next = events.first(where: { $0.startDate > now }) {
            return (next.title, next.startDate)
        }
        return nil
    }

    // MARK: - Status Message Builders

    static func buildWorkoutStatus() async -> String? {
        // Check for active workout via recent workout samples
        let workoutType = HKObjectType.workoutType()
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: Date().addingTimeInterval(-7200),
                end: Date(),
                options: .strictEndDate
            )
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                guard let workout = samples?.first as? HKWorkout else {
                    continuation.resume(returning: nil)
                    return
                }
                let duration = Int(workout.duration / 60)
                let type = workout.workoutActivityType.displayName
                continuation.resume(returning: "In a workout - \(type) \(duration)min")
            }
            healthStore.execute(query)
        }
    }

    static func buildCalendarStatus() async -> String? {
        guard let event = await getCurrentOrNextEvent() else { return nil }
        let now = Date()
        if event.endTime > now {
            let until = event.endTime.formatted(.dateTime.hour().minute())
            return "Busy until \(until) - \(event.title)"
        } else {
            let at = event.endTime.formatted(.dateTime.hour().minute())
            return "Next: \(event.title) at \(at)"
        }
    }

    static func buildNowPlayingStatus() -> String? {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        guard let info else { return nil }

        let title = info[MPMediaItemPropertyTitle] as? String
        let artist = info[MPMediaItemPropertyArtist] as? String

        if let title, let artist {
            return "Listening to: \(title) - \(artist)"
        } else if let title {
            return "Listening to: \(title)"
        }
        return nil
    }

    static func buildWeatherStatus() async -> String? {
        let locationManager = CLLocationManager()
        guard let location = locationManager.location else { return nil }

        do {
            let weather = try await WeatherService.shared.weather(
                for: location,
                including: .current
            )
            let temp = weather.temperature.formatted(.measurement(width: .abbreviated))
            let condition = weather.condition.description
            return "Weather: \(temp), \(condition)"
        } catch {
            logger.log(error, level: .error)
            return nil
        }
    }

    static func buildLocationStatus() async -> String? {
        let locationManager = CLLocationManager()
        guard let location = locationManager.location else { return nil }

        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let place = placemarks.first {
                let parts = [place.locality, place.administrativeArea].compactMap { $0 }
                if !parts.isEmpty {
                    return "Currently in \(parts.joined(separator: ", "))"
                }
            }
        } catch {
            logger.log(error, level: .error)
        }

        let lat = String(format: "%.4f", location.coordinate.latitude)
        let lon = String(format: "%.4f", location.coordinate.longitude)
        return "Location: \(lat), \(lon)"
    }

    static func buildBatteryStatus() -> String? {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        guard level >= 0 else { return nil }
        let percent = Int(level * 100)
        return "Watch battery: \(percent)%"
    }

    static func buildHealthStatus() async -> String? {
        var parts: [String] = []
        if let steps = await getTodaySteps() {
            parts.append("\(steps.formatted()) steps")
        }
        if let calories = await getActiveCalories() {
            parts.append("\(calories) cal")
        }
        if let hr = await getCurrentHeartRate() {
            parts.append("\(hr) bpm")
        }
        guard !parts.isEmpty else { return nil }
        return "Today: " + parts.joined(separator: " | ")
    }
}

    static func buildSleepStatus() async -> String? {
        let sleepType = HKCategoryType(.sleepAnalysis)
        let calendar = Calendar.current
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) ?? Date()

        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: startOfYesterday,
                end: Date(),
                options: .strictEndDate
            )
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample] else {
                    continuation.resume(returning: nil)
                    return
                }
                let asleepSamples = samples.filter { $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue }
                let totalSleep = asleepSamples.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                guard totalSleep > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let hours = Int(totalSleep / 3600)
                let minutes = Int(totalSleep.truncatingRemainder(dividingBy: 3600) / 60)
                continuation.resume(returning: "Slept \(hours)h \(minutes)m last night")
            }
            healthStore.execute(query)
        }
    }

    static func buildActivityRingsStatus() async -> String? {
        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now

        let datePredicate = HKQuery.predicateForActivitySummary(
            with: calendar.dateComponents([.year, .month, .day], from: now)
        )

        return await withCheckedContinuation { continuation in
            let query = HKActivitySummaryQuery(predicate: datePredicate) { _, summaries, _ in
                guard let summary = summaries?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let move = Int(summary.activeEnergyBurned.doubleValue(for: .kilocalorie()))
                let moveGoal = Int(summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()))
                let exercise = Int(summary.appleExerciseTime.doubleValue(for: .minute()))
                let exerciseGoal = Int(summary.appleExerciseTimeGoal.doubleValue(for: .minute()))
                let stand = Int(summary.appleStandHours.doubleValue(for: .count()))
                let standGoal = Int(summary.appleStandHoursGoal.doubleValue(for: .count()))

                continuation.resume(returning: "Move: \(move)/\(moveGoal) cal | Exercise: \(exercise)/\(exerciseGoal) min | Stand: \(stand)/\(standGoal) hr")
            }
            healthStore.execute(query)
        }
    }

    static func buildBloodOxygenStatus() async -> String? {
        let oxygenType = HKQuantityType(.oxygenSaturation)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: Date().addingTimeInterval(-3600),
                end: Date(),
                options: .strictEndDate
            )
            let query = HKSampleQuery(
                sampleType: oxygenType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                let spo2 = Int(sample.quantity.doubleValue(for: .percent()) * 100)
                continuation.resume(returning: "Blood oxygen: \(spo2)%")
            }
            healthStore.execute(query)
        }
    }

    static func buildNoiseLevelStatus() async -> String? {
        let noiseType = HKQuantityType(.environmentalAudioExposure)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: Date().addingTimeInterval(-1800),
                end: Date(),
                options: .strictEndDate
            )
            let query = HKSampleQuery(
                sampleType: noiseType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                let db = Int(sample.quantity.doubleValue(for: .decibelAWeightedSoundPressureLevel()))
                continuation.resume(returning: "Ambient noise: \(db) dB")
            }
            healthStore.execute(query)
        }
    }

    static func buildAltitudeStatus() async -> String? {
        let altimeter = CMAltimeter()
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return nil }

        return await withCheckedContinuation { continuation in
            altimeter.startRelativeAltitudeUpdates(to: .main) { data, error in
                altimeter.stopRelativeAltitudeUpdates()
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                let meters = data.relativeAltitude.doubleValue
                let feet = Int(meters * 3.281)
                continuation.resume(returning: "Relative altitude: \(feet) ft")
            }
        }
    }

    static func buildRemindersStatus() async -> String? {
        let granted = await requestCalendarPermissions()
        guard granted else { return nil }

        do {
            let granted = try await eventStore.requestFullAccessToReminders()
            guard granted else { return nil }
        } catch {
            return nil
        }

        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: Calendar.current.date(byAdding: .day, value: 1, to: Date()),
            calendars: nil
        )

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                guard let reminders, let next = reminders.first else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: "Reminder: \(next.title ?? "Untitled")")
            }
        }
    }

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .hiking: return "Hiking"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining: return "Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        default: return "Workout"
        }
    }
}
