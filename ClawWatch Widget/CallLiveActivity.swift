//
//  CallLiveActivity.swift
//  ClawWatch Widget
//
//  Live Activity UI (lock screen + Dynamic Island) for an active call.
//

import WidgetKit
import SwiftUI
import ActivityKit

@available(iOS 16.1, *)
struct CallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            // Lock screen / banner
            HStack(spacing: 12) {
                Image(systemName: "phone.fill").font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text(context.attributes.callerName).font(.headline)
                    Text(context.state.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(timeString(context.state.elapsed)).font(.title3.monospacedDigit())
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "phone.fill").foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.callerName).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.status).font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "phone.fill").foregroundStyle(.green)
            } compactTrailing: {
                Text(timeString(context.state.elapsed)).monospacedDigit()
            } minimal: {
                Image(systemName: "phone.fill").foregroundStyle(.green)
            }
        }
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}
