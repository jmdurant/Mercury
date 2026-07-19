//
//  WatchBridge.swift
//  ClawWatch (shared: iOS + watchOS)
//
//  WatchConnectivity relay. Lets the phone reach watch-exclusive sensors
//  over the paired-device link — no internet needed on the watch. This is
//  what makes the node work against a private/Tailscale-only gateway: the
//  phone holds the gateway connection and fetches watch data through here.
//

import Foundation
import WatchConnectivity

final class WatchBridge: NSObject, WCSessionDelegate {

    static let shared = WatchBridge()

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }
    private let logger = LoggerService(WatchBridge.self)

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// True when the counterpart app is reachable for a live round-trip.
    var isWatchReachable: Bool { session?.isReachable ?? false }

    #if os(iOS)
    /// Phone → watch: run a sensor command on the watch and await its JSON.
    func fetchFromWatch(_ command: String) async -> [String: Any] {
        guard let session, session.isReachable else {
            return ["error": "watch not reachable"]
        }
        return await withCheckedContinuation { cont in
            session.sendMessage(["command": command], replyHandler: { reply in
                cont.resume(returning: reply)
            }, errorHandler: { error in
                cont.resume(returning: ["error": error.localizedDescription])
            })
        }
    }
    #endif

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        #if os(watchOS)
        guard let command = message["command"] as? String else {
            replyHandler(["error": "no command"]); return
        }
        Task {
            replyHandler(await Self.runWatchCommand(command))
        }
        #else
        replyHandler([:])
        #endif
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error { logger.log("WCSession activation: \(error)", level: .error) }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif

    // MARK: - Watch-side command execution

    #if os(watchOS)
    /// Watch-exclusive sensors the phone can't measure itself.
    static func runWatchCommand(_ command: String) async -> [String: Any] {
        switch command {
        case "watch.heart", "heart.get":
            if let hr = await StatusDataService.getCurrentHeartRate() { return ["bpm": hr] }
            return ["error": "no recent heart rate"]
        case "watch.temp":
            return ["summary": await StatusDataService.buildWristTemperatureStatus() ?? "no wrist temp"]
        case "watch.o2":
            return ["summary": await StatusDataService.buildBloodOxygenStatus() ?? "no blood oxygen"]
        case "watch.rings":
            return ["summary": await StatusDataService.buildActivityRingsStatus() ?? "no activity data"]
        case "watch.health":
            return ["json": await StatusDataService.buildJSONStatus()]
        default:
            return ["error": "unsupported watch command \(command)"]
        }
    }
    #endif
}
