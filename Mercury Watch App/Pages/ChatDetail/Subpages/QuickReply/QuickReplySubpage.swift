//
//  QuickReplySubpage.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import SwiftUI

struct QuickReplySubpage: View {

    @Binding var isPresented: Bool
    let sendService: SendMessageService

    @State private var statusMessages: [StatusMessage] = []
    @State private var isLoadingStatus: Bool = true

    struct StatusMessage: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let message: String
    }

    private let quickReplies = [
        ("checkmark", "OK", "OK"),
        ("figure.walk", "On my way", "On my way!"),
        ("phone.fill", "Call me", "Can you call me?"),
        ("clock.fill", "Be right back", "Be right back"),
        ("hand.wave.fill", "Hi", "Hey! How's it going?"),
        ("moon.fill", "Busy", "I'm busy right now, I'll get back to you"),
        ("face.smiling.inverse", "Thanks", "Thanks!"),
        ("questionmark.circle", "What's up?", "What's up?"),
    ]

    var body: some View {
        List {
            Section("Quick Reply") {
                ForEach(quickReplies, id: \.1) { icon, label, message in
                    Button {
                        sendService.sendTextMessage(message)
                        HapticService.messageSent()
                        isPresented = false
                    } label: {
                        Label(label, systemImage: icon)
                    }
                }
            }

            Section("Status Reply") {
                if isLoadingStatus {
                    ProgressView("Reading sensors...")
                        .frame(maxWidth: .infinity)
                } else if statusMessages.isEmpty {
                    Text("No status data available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(statusMessages) { status in
                        Button {
                            sendService.sendTextMessage(status.message)
                            HapticService.messageSent()
                            isPresented = false
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(status.label)
                                        .font(.caption)
                                    Text(status.message)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            } icon: {
                                Image(systemName: status.icon)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.carousel)
        .navigationTitle("Quick Reply")
        .task {
            await loadStatusMessages()
        }
    }

    private func loadStatusMessages() async {
        var messages: [StatusMessage] = []

        if let workout = await StatusDataService.buildWorkoutStatus() {
            messages.append(StatusMessage(icon: "figure.run", label: "Workout", message: workout))
        }

        if let calendar = await StatusDataService.buildCalendarStatus() {
            messages.append(StatusMessage(icon: "calendar", label: "Calendar", message: calendar))
        }

        if let health = await StatusDataService.buildHealthStatus() {
            messages.append(StatusMessage(icon: "heart.fill", label: "Health", message: health))
        }

        if let nowPlaying = StatusDataService.buildNowPlayingStatus() {
            messages.append(StatusMessage(icon: "music.note", label: "Now Playing", message: nowPlaying))
        }

        if let weather = await StatusDataService.buildWeatherStatus() {
            messages.append(StatusMessage(icon: "cloud.sun.fill", label: "Weather", message: weather))
        }

        if let location = await StatusDataService.buildLocationStatus() {
            messages.append(StatusMessage(icon: "location.fill", label: "Location", message: location))
        }

        if let sleep = await StatusDataService.buildSleepStatus() {
            messages.append(StatusMessage(icon: "bed.double.fill", label: "Sleep", message: sleep))
        }

        if let rings = await StatusDataService.buildActivityRingsStatus() {
            messages.append(StatusMessage(icon: "circle.circle", label: "Activity Rings", message: rings))
        }

        if let spo2 = await StatusDataService.buildBloodOxygenStatus() {
            messages.append(StatusMessage(icon: "lungs.fill", label: "Blood Oxygen", message: spo2))
        }

        if let noise = await StatusDataService.buildNoiseLevelStatus() {
            messages.append(StatusMessage(icon: "ear.fill", label: "Noise", message: noise))
        }

        if let altitude = await StatusDataService.buildAltitudeStatus() {
            messages.append(StatusMessage(icon: "mountain.2.fill", label: "Altitude", message: altitude))
        }

        if let reminder = await StatusDataService.buildRemindersStatus() {
            messages.append(StatusMessage(icon: "checklist", label: "Reminder", message: reminder))
        }

        if let wristTemp = await StatusDataService.buildWristTemperatureStatus() {
            messages.append(StatusMessage(icon: "thermometer.medium", label: "Wrist Temp", message: wristTemp))
        }

        if let vo2 = await StatusDataService.buildVO2MaxStatus() {
            messages.append(StatusMessage(icon: "lungs", label: "VO2 Max", message: vo2))
        }

        if let resp = await StatusDataService.buildRespiratoryRateStatus() {
            messages.append(StatusMessage(icon: "wind", label: "Respiratory", message: resp))
        }

        if let speed = await StatusDataService.buildWalkingSpeedStatus() {
            messages.append(StatusMessage(icon: "figure.walk", label: "Walking Speed", message: speed))
        }

        if let distance = await StatusDataService.buildDistanceStatus() {
            messages.append(StatusMessage(icon: "point.topleft.down.to.point.bottomright.curvepath", label: "Distance", message: distance))
        }

        if let focus = StatusDataService.buildFocusStatus() {
            messages.append(StatusMessage(icon: "moon.fill", label: "Focus", message: focus))
        }

        if let battery = StatusDataService.buildBatteryStatus() {
            messages.append(StatusMessage(icon: "battery.50percent", label: "Battery", message: battery))
        }

        await MainActor.run {
            statusMessages = messages
            isLoadingStatus = false
        }
    }
}
