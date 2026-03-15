//
//  StatusDataService.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation
import HealthKit
import EventKit

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
        ]
        let workoutType = HKObjectType.workoutType()
        var allTypes = types as Set<HKObjectType>
        allTypes.insert(workoutType)

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
