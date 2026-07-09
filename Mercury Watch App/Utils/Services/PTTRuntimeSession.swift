//
//  PTTRuntimeSession.swift
//  Mercury Watch App
//
//  Created on 09/07/26.
//

import WatchKit

/// Keeps the app running during a walkie-talkie conversation so a
/// wrist-lowered send (and incoming auto-play) completes instead of the
/// app suspending. Uses a "self-care" extended runtime session (declared
/// in WKBackgroundModes); those have a per-session time cap, so a fresh
/// session is chained just before the old one expires.
class PTTRuntimeSession: NSObject {

    private let logger = LoggerService(PTTRuntimeSession.self)
    private var session: WKExtendedRuntimeSession?

    func start() {
        guard session == nil else { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        self.session = session
        logger.log("Starting extended runtime session")
    }

    func stop() {
        session?.invalidate()
        session = nil
        logger.log("Stopped extended runtime session")
    }
}

extension PTTRuntimeSession: WKExtendedRuntimeSessionDelegate {

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        let remaining = Int(extendedRuntimeSession.expirationDate?.timeIntervalSinceNow ?? 0)
        logger.log("Extended runtime session started (~\(remaining)s)")
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // Chain a new session before the cap so the conversation keeps
        // its runtime across the boundary
        logger.log("Extended runtime session expiring — chaining a fresh one")
        let next = WKExtendedRuntimeSession()
        next.delegate = self
        next.start()
        session = next
    }

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        // An old session invalidating after a chain must not nil the new one
        if extendedRuntimeSession === session {
            session = nil
        }
        logger.log("Extended runtime session invalidated: \(reason.rawValue)\(error.map { " — \($0)" } ?? "")")
    }
}
