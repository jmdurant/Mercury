//
//  LiveActivityService.swift
//  ClawWatch iOS
//
//  Starts / updates / ends the call Live Activity (Dynamic Island +
//  lock screen).
//

import Foundation
import ActivityKit

enum LiveActivityService {

    private static var current: Activity<CallActivityAttributes>?

    static func startCall(caller: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = CallActivityAttributes(callerName: caller)
        let state = CallActivityAttributes.ContentState(status: "Ringing", elapsed: 0)
        do {
            current = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
        } catch {
            LoggerService(String(describing: LiveActivityService.self))
                .log("Live Activity start failed: \(error)", level: .error)
        }
    }

    static func update(status: String, elapsed: Int) {
        Task {
            await current?.update(
                .init(state: .init(status: status, elapsed: elapsed), staleDate: nil))
        }
    }

    static func end() {
        Task {
            await current?.end(nil, dismissalPolicy: .immediate)
            current = nil
        }
    }
}
