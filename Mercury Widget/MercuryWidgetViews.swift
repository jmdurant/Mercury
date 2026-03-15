//
//  MercuryWidgetViews.swift
//  Mercury Widget
//
//  Created on 14/03/26.
//

import SwiftUI
import WidgetKit

struct MercuryWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: MercuryWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryCorner:
            cornerView
        case .accessoryRectangular:
            rectangularView
        case .accessoryInline:
            inlineView
        default:
            circularView
        }
    }

    // MARK: - Circular

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            if entry.totalUnreadCount > 0 {
                VStack(spacing: 0) {
                    Image(systemName: "message.fill")
                        .font(.caption2)
                    Text("\(entry.totalUnreadCount)")
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.semibold)
                        .minimumScaleFactor(0.5)
                }
            } else {
                Image(systemName: "message")
                    .font(.title3)
            }
        }
    }

    // MARK: - Corner

    private var cornerView: some View {
        Text("\(entry.totalUnreadCount)")
            .font(.system(.title, design: .rounded))
            .fontWeight(.medium)
            .widgetCurvesContent()
            .widgetLabel {
                Label(
                    entry.totalUnreadCount == 1 ? "message" : "messages",
                    systemImage: "message.fill"
                )
            }
    }

    // MARK: - Rectangular

    private var rectangularView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Mercury", systemImage: "message.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if entry.totalUnreadCount > 0 {
                    if let sender = entry.lastSenderName {
                        Text(sender)
                            .font(.system(.headline, design: .rounded))
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                    Text("\(entry.totalUnreadCount) unread")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("All read")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if entry.totalUnreadCount > 0 {
                // Deep link to open the app
                Link(destination: URL(string: "mercury://open")!) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title3)
                }
            }
        }
    }

    // MARK: - Inline

    private var inlineView: some View {
        Group {
            if entry.totalUnreadCount > 0 {
                Label(
                    "Mercury \u{2014} \(entry.totalUnreadCount) unread",
                    systemImage: "message.fill"
                )
            } else {
                Label(
                    "Mercury \u{2014} All read",
                    systemImage: "message"
                )
            }
        }
    }
}

#Preview(as: .accessoryCircular) {
    MercuryWidget()
} timeline: {
    MercuryWidgetEntry(date: .now, totalUnreadCount: 0, lastSenderName: nil)
    MercuryWidgetEntry(date: .now, totalUnreadCount: 5, lastSenderName: "Alex")
    MercuryWidgetEntry(date: .now, totalUnreadCount: 42, lastSenderName: "Marco")
}

#Preview(as: .accessoryRectangular) {
    MercuryWidget()
} timeline: {
    MercuryWidgetEntry(date: .now, totalUnreadCount: 0, lastSenderName: nil)
    MercuryWidgetEntry(date: .now, totalUnreadCount: 12, lastSenderName: "Alessandro")
}
