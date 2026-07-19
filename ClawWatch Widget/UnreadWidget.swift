//
//  UnreadWidget.swift
//  ClawWatch Widget
//
//  Home-screen widget showing total unread count from the shared app group.
//

import WidgetKit
import SwiftUI

private let appGroupId = "group.com.doctordurant.clawwatch"

struct UnreadEntry: TimelineEntry {
    let date: Date
    let unread: Int
    let lastSender: String?
}

struct UnreadProvider: TimelineProvider {
    private func read() -> UnreadEntry {
        let defaults = UserDefaults(suiteName: appGroupId)
        return UnreadEntry(
            date: Date(),
            unread: defaults?.integer(forKey: "totalUnreadCount") ?? 0,
            lastSender: defaults?.string(forKey: "lastSenderName"))
    }
    func placeholder(in context: Context) -> UnreadEntry {
        UnreadEntry(date: Date(), unread: 3, lastSender: "Alex")
    }
    func getSnapshot(in context: Context, completion: @escaping (UnreadEntry) -> Void) {
        completion(read())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadEntry>) -> Void) {
        completion(Timeline(entries: [read()], policy: .after(Date().addingTimeInterval(300))))
    }
}

struct UnreadWidgetView: View {
    var entry: UnreadEntry
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "message.fill").foregroundStyle(.blue)
                Spacer()
                Text("\(entry.unread)").font(.title.bold())
            }
            Spacer()
            if let sender = entry.lastSender, entry.unread > 0 {
                Text(sender).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("All caught up").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct UnreadWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClawWatchUnread", provider: UnreadProvider()) { entry in
            UnreadWidgetView(entry: entry)
        }
        .configurationDisplayName("Unread Messages")
        .description("Your ClawWatch unread count.")
        .supportedFamilies([.systemSmall])
    }
}
