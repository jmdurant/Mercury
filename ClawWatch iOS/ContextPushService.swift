//
//  ContextPushService.swift
//  ClawWatch iOS
//
//  Proactive context: on a location visit (arrive/depart) the app pushes a
//  short note to designated assistant chats, so the agent gets context
//  without having to poll. Gated by the location consent + a toggle.
//

import Foundation
import CoreLocation

final class ContextPushService: NSObject, CLLocationManagerDelegate {

    static let shared = ContextPushService()

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let logger = LoggerService(ContextPushService.self)

    func start() {
        manager.delegate = self
        guard AutoResponderStore.isContextPushEnabled,
              AutoResponderStore.isConsented(.location) else { return }
        manager.requestAlwaysAuthorization()
        manager.startMonitoringVisits()
        manager.startMonitoringSignificantLocationChanges()
    }

    func stop() {
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let arriving = visit.departureDate == Date.distantFuture
        let event = arriving ? "Arrived at" : "Left"
        let loc = CLLocation(latitude: visit.coordinate.latitude,
                             longitude: visit.coordinate.longitude)
        Task { await push(event: event, location: loc) }
    }

    private func push(event: String, location: CLLocation) async {
        guard AutoResponderStore.isContextPushEnabled,
              AutoResponderStore.isConsented(.location) else { return }
        var place = "a location"
        if let marks = try? await geocoder.reverseGeocodeLocation(location),
           let m = marks.first {
            place = [m.name, m.locality].compactMap { $0 }.first ?? place
        }
        let text = "\(event) \(place)"
        for chatId in AutoResponderStore.assistantChatIds() {
            SendMessageService.sendQuickReply(text: text, chatId: chatId)
        }
        logger.log("Pushed context: \(text)")
    }
}
