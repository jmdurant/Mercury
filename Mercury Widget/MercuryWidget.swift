//
//  MercuryWidget.swift
//  Mercury Widget
//
//  Created on 14/03/26.
//

import WidgetKit
import SwiftUI

struct MercuryWidgetEntry: TimelineEntry {
    let date: Date
    let totalUnreadCount: Int
    let lastSenderName: String?
}

struct MercuryWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> MercuryWidgetEntry {
        MercuryWidgetEntry(date: .now, totalUnreadCount: 0, lastSenderName: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (MercuryWidgetEntry) -> Void) {
        let count = SharedDataStore.getTotalUnreadCount()
        let sender = SharedDataStore.getLastSenderName()
        completion(MercuryWidgetEntry(date: .now, totalUnreadCount: count, lastSenderName: sender))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MercuryWidgetEntry>) -> Void) {
        let count = SharedDataStore.getTotalUnreadCount()
        let sender = SharedDataStore.getLastSenderName()
        let entry = MercuryWidgetEntry(date: .now, totalUnreadCount: count, lastSenderName: sender)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct MercuryWidget: Widget {
    let kind = "MercuryUnreadWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MercuryWidgetProvider()) { entry in
            MercuryWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Mercury")
        .description("Shows unread Telegram messages")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

@main
struct MercuryWidgetBundle: WidgetBundle {
    var body: some Widget {
        MercuryWidget()
    }
}
