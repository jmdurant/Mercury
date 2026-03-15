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

        await MainActor.run {
            statusMessages = messages
            isLoadingStatus = false
        }
    }
}
