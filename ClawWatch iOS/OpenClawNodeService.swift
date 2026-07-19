//
//  OpenClawNodeService.swift
//  ClawWatch iOS
//
//  Registers the phone as a first-class OpenClaw *node*, so the agent can
//  query the device directly (location, health, battery) instead of over
//  Telegram. Mirrors OpenClaw's own node handshake: a persistent
//  Curve25519 (Ed25519) device identity, a v3 signed connect over the
//  gateway WebSocket, then handling node.invoke.request events.
//

import Foundation
import CryptoKit
import CoreLocation

@Observable
final class OpenClawNodeService: NSObject {

    static let shared = OpenClawNodeService()

    enum Status: String { case idle, connecting, pending, connected, error }
    var status: Status = .idle
    var lastEvent: String = ""

    override init() {
        super.init()
        NSUbiquitousKeyValueStore.default.synchronize()
        NotificationCenter.default.addObserver(
            self, selector: #selector(iCloudConfigChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default)
    }

    /// Config arrived from another device (e.g. the phone set it). Mirror it
    /// locally and, if enabled and idle, connect — turnkey watch setup.
    @objc private func iCloudConfigChanged() {
        Task { @MainActor in
            if !self.gatewayURL.isEmpty, self.isAutoConnect, self.status == .idle {
                self.lastEvent = "Config synced from iPhone"
                self.start()
            }
        }
    }

    // Config is stored in the iCloud key-value store (shared across the
    // user's devices via the ubiquity-kvstore entitlement) with a local
    // UserDefaults mirror for immediacy. Set it once on the phone; the watch
    // picks it up over iCloud — no typing on the watch.
    private let kv = NSUbiquitousKeyValueStore.default

    private func syncedString(_ key: String) -> String {
        kv.string(forKey: key) ?? UserDefaults.standard.string(forKey: key) ?? ""
    }
    private func setSynced(_ key: String, _ value: String) {
        kv.set(value, forKey: key); kv.synchronize()
        UserDefaults.standard.set(value, forKey: key)
    }

    /// gateway URL e.g. ws://127.0.0.1:18789 (or wss:// over Tailscale)
    var gatewayURL: String {
        get { syncedString("ocGatewayURL") }
        set { setSynced("ocGatewayURL", newValue) }
    }
    /// bootstrap/connect token from the gateway config (auth.token)
    var token: String {
        get { syncedString("ocGatewayToken") }
        set { setSynced("ocGatewayToken", newValue) }
    }
    /// Reconnect the node automatically once the user has enabled it (synced).
    var isAutoConnect: Bool {
        get { kv.object(forKey: "ocAutoConnect") as? Bool ?? UserDefaults.standard.bool(forKey: "ocAutoConnect") }
        set { kv.set(newValue, forKey: "ocAutoConnect"); kv.synchronize()
              UserDefaults.standard.set(newValue, forKey: "ocAutoConnect") }
    }

    private let clientId = "node-host"
    private let protocolVersion = 4
    private let commands = [
        "health.snapshot", "location.get", "battery.get", "device.info",
        "heart.get", "steps.get", "sleep.get", "workout.get",
        "calendar.get", "weather.get", "system.notify",
        // relayed to the watch over WatchConnectivity (watch-exclusive sensors)
        "watch.heart", "watch.temp", "watch.o2", "watch.rings", "watch.health",
    ]

    private var socket: URLSessionWebSocketTask?
    private let logger = LoggerService(OpenClawNodeService.self)
    private let locationManager = CLLocationManager()

    #if os(watchOS)
    private let platformName = "watchos"
    private let deviceFamilyName = "watch"
    private let displayName = "ClawWatch Watch"
    #else
    private let platformName = "ios"
    private let deviceFamilyName = "phone"
    private let displayName = "ClawWatch iPhone"
    #endif

    // MARK: - Persistent device identity (Ed25519)

    private struct Identity { let privateKey: Curve25519.Signing.PrivateKey; let deviceId: String }

    private func loadOrCreateIdentity() -> Identity {
        let key = "ocNodePrivateKey"
        if let raw = KeychainService.load(key: key),
           let pk = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return Identity(privateKey: pk, deviceId: deviceId(pk.publicKey))
        }
        let pk = Curve25519.Signing.PrivateKey()
        _ = KeychainService.save(key: key, data: pk.rawRepresentation)
        return Identity(privateKey: pk, deviceId: deviceId(pk.publicKey))
    }

    private func deviceId(_ pub: Curve25519.Signing.PublicKey) -> String {
        SHA256.hash(data: pub.rawRepresentation).map { String(format: "%02x", $0) }.joined()
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// v3 signature payload, byte-identical to OpenClaw's buildDeviceAuthPayloadV3
    private func v3Payload(deviceId: String, signedAtMs: Int64, nonce: String) -> String {
        [
            "v3", deviceId, clientId, "node", "node", "",
            String(signedAtMs), token, nonce, platformName, deviceFamilyName,
        ].joined(separator: "|")
    }

    // MARK: - Lifecycle

    func start() {
        guard status == .idle || status == .error,
              let url = URL(string: gatewayURL), url.scheme?.hasPrefix("ws") == true else {
            status = .error; return
        }
        status = .connecting
        isAutoConnect = true
        socket = URLSession(configuration: .default).webSocketTask(with: url)
        socket?.resume()
        receive()
    }

    func stop() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = .idle
    }

    // MARK: - Frame receive loop

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.handleFrame(text)
            case .success(.data(let data)):
                self.handleFrame(String(decoding: data, as: UTF8.self))
            case .failure(let error):
                self.logger.log("node socket: \(error)", level: .error)
                self.status = .error
                return
            @unknown default: break
            }
            if self.status != .idle { self.receive() }
        }
    }

    private func handleFrame(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return }
        let type = obj["type"] as? String

        if type == "event", let event = obj["event"] as? String {
            if event == "connect.challenge",
               let payload = obj["payload"] as? [String: Any],
               let nonce = payload["nonce"] as? String {
                sendConnect(nonce: nonce)
            } else if event == "node.invoke.request",
                      let payload = obj["payload"] as? [String: Any] {
                handleInvoke(payload)
            }
        } else if type == "res", let id = obj["id"] as? String, id == "connect" {
            if (obj["ok"] as? Bool) == true {
                status = .connected
                lastEvent = "Connected as node"
            } else {
                // A first-time node lands in pending pairing until approved.
                status = .pending
                lastEvent = "Pending pairing approval"
            }
        }
    }

    // MARK: - Connect (signed)

    private func sendConnect(nonce: String) {
        let identity = loadOrCreateIdentity()
        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let payload = v3Payload(deviceId: identity.deviceId, signedAtMs: signedAtMs, nonce: nonce)
        guard let signature = try? identity.privateKey.signature(for: Data(payload.utf8)) else {
            status = .error; return
        }
        let params: [String: Any] = [
            "minProtocol": protocolVersion,
            "maxProtocol": protocolVersion,
            "client": [
                "id": clientId,
                "displayName": displayName,
                "version": "1.0.0",
                "platform": platformName,
                "deviceFamily": deviceFamilyName,
                "mode": "node",
                "instanceId": identity.deviceId,
            ],
            "role": "node",
            "commands": commands,
            "device": [
                "id": identity.deviceId,
                "publicKey": base64url(identity.privateKey.publicKey.rawRepresentation),
                "signature": base64url(signature),
                "signedAt": signedAtMs,
                "nonce": nonce,
            ],
            "auth": ["token": token],
        ]
        send(type: "req", body: ["id": "connect", "method": "connect", "params": params])
    }

    // MARK: - Invoke handling

    private func handleInvoke(_ payload: [String: Any]) {
        guard let id = payload["id"] as? String,
              let nodeId = payload["nodeId"] as? String,
              let command = payload["command"] as? String else { return }
        lastEvent = "Agent asked: \(command)"
        var invokeParams: [String: Any] = [:]
        if let paramsJSON = payload["paramsJSON"] as? String,
           let data = paramsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            invokeParams = parsed
        }
        Task {
            let result = await runCommand(command, params: invokeParams)
            let params: [String: Any] = [
                "id": id, "nodeId": nodeId, "ok": true,
                "payloadJSON": String(decoding: (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8), as: UTF8.self),
            ]
            send(type: "req", body: ["id": UUID().uuidString, "method": "node.invoke.result", "params": params])
        }
    }

    private func runCommand(_ command: String, params: [String: Any]) async -> [String: Any] {
        // Consent gate: node commands honour the same per-category consent as
        // the Telegram #-command channel.
        if let consent = consentCategory(for: command), !AutoResponderStore.isConsented(consent) {
            return ["error": "\(consent.label) access is disabled"]
        }
        switch command {
        case "battery.get":
            return ["battery": StatusDataService.buildBatteryStatus() ?? "unknown"]
        case "location.get":
            if let loc = locationManager.location {
                return ["lat": loc.coordinate.latitude, "lon": loc.coordinate.longitude]
            }
            return ["error": "location unavailable"]
        case "health.snapshot":
            return ["json": await StatusDataService.buildJSONStatus()]
        case "heart.get":
            if let hr = await StatusDataService.getCurrentHeartRate() { return ["bpm": hr] }
            return ["error": "no recent heart rate"]
        case "steps.get":
            if let s = await StatusDataService.getTodaySteps() { return ["steps": s] }
            return ["error": "no step data"]
        case "sleep.get":
            return ["summary": await StatusDataService.buildSleepStatus() ?? "no sleep data"]
        case "workout.get":
            return ["summary": await StatusDataService.buildWorkoutStatus() ?? "no active workout"]
        case "calendar.get":
            if let avail = await StatusDataService.buildWorkAvailabilityStatus() {
                return ["summary": avail]
            }
            return ["summary": await StatusDataService.buildCalendarStatus() ?? "no events"]
        case "weather.get":
            return ["summary": await StatusDataService.buildWeatherStatus() ?? "weather unavailable"]
        case "system.notify":
            let text = params["text"] as? String ?? "Notification from your agent"
            AgentAlertService.raise(text, critical: params["critical"] as? Bool ?? false)
            return ["ok": true]
        case "device.info":
            return ["platform": platformName, "app": "ClawWatch", "session": AutoResponderStore.sessionId]
        default:
            #if os(iOS)
            // watch-exclusive sensors: relay to the watch over WatchConnectivity
            if command.hasPrefix("watch.") {
                return await WatchBridge.shared.fetchFromWatch(command)
            }
            #endif
            return ["error": "unsupported command \(command)"]
        }
    }

    private func consentCategory(for command: String) -> AutoResponderStore.Consent? {
        if command.hasPrefix("health") || command.hasPrefix("heart")
            || command.hasPrefix("steps") || command.hasPrefix("sleep")
            || command.hasPrefix("workout") { return .health }
        if command.hasPrefix("location") { return .location }
        if command.hasPrefix("calendar") { return .calendar }
        return nil
    }

    // MARK: - Send

    private func send(type: String, body: [String: Any]) {
        var frame = body
        frame["type"] = type
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { [weak self] error in
            if let error { self?.logger.log("node send: \(error)", level: .error) }
        }
    }
}
