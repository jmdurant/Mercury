//
//  HapticService.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import WatchKit

enum HapticService {

    /// New text message received
    static func messageReceived() {
        WKInterfaceDevice.current().play(.notification)
    }

    /// Mentioned in a group chat
    static func mentionReceived() {
        WKInterfaceDevice.current().play(.directionUp)
    }

    /// Reaction on your message
    static func reactionReceived() {
        WKInterfaceDevice.current().play(.success)
    }

    /// Message sent successfully
    static func messageSent() {
        WKInterfaceDevice.current().play(.click)
    }

    /// Action failed
    static func actionFailed() {
        WKInterfaceDevice.current().play(.failure)
    }

    /// Message deleted
    static func messageDeleted() {
        WKInterfaceDevice.current().play(.retry)
    }
}
