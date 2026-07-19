//
//  CallActivityAttributes.swift
//  ClawWatch
//
//  Shared between the app (starts/updates) and the widget extension
//  (renders). Compiled into BOTH targets.
//

import ActivityKit

struct CallActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String      // e.g. "Ringing", "Connected"
        var elapsed: Int        // seconds
    }
    var callerName: String
}
