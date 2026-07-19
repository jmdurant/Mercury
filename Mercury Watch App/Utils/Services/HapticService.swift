//
//  HapticService.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

enum HapticService {

    #if os(watchOS)
    private static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
    #else
    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    #endif

    /// New text message received
    static func messageReceived() {
        #if os(watchOS)
        play(.notification)
        #else
        notify(.success)
        #endif
    }

    /// Mentioned in a group chat
    static func mentionReceived() {
        #if os(watchOS)
        play(.directionUp)
        #else
        notify(.warning)
        #endif
    }

    /// Reaction on your message
    static func reactionReceived() {
        #if os(watchOS)
        play(.success)
        #else
        impact(.light)
        #endif
    }

    /// Message sent successfully
    static func messageSent() {
        #if os(watchOS)
        play(.click)
        #else
        impact(.rigid)
        #endif
    }

    /// Action failed
    static func actionFailed() {
        #if os(watchOS)
        play(.failure)
        #else
        notify(.error)
        #endif
    }

    /// Message deleted
    static func messageDeleted() {
        #if os(watchOS)
        play(.retry)
        #else
        impact(.medium)
        #endif
    }

    /// Incoming walkie-talkie voice note about to auto-play
    static func pttReceived() {
        #if os(watchOS)
        play(.directionDown)
        #else
        impact(.soft)
        #endif
    }

    /// Walkie-talkie recording started
    static func pttTalkStarted() {
        #if os(watchOS)
        play(.start)
        #else
        impact(.rigid)
        #endif
    }
}
