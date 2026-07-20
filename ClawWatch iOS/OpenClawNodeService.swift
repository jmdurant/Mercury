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
import Network

@Observable
final class OpenClawNodeService: NSObject {

    static let shared = OpenClawNodeService()

    enum Status: String { case idle, connecting, pending, connected, error }
    var status: Status = .idle
    var lastEvent: String = ""

    /// An agent advertised by the gateway (agents.list). `id` is the value the
    /// live-voice channel sends as ?agent=.
    struct OCAgent: Identifiable, Hashable {
        let id: String
        let name: String
    }
    /// Agents fetched from the gateway once connected (empty until then).
    var agents: [OCAgent] = []
    var agentsDefaultId: String = ""

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
    /// Raw gateway auth token (auth.token) — the master secret. Synced.
    var token: String {
        get { syncedString("ocGatewayToken") }
        set { setSynced("ocGatewayToken", newValue) }
    }

    // Pairing credentials are LOCAL to each device (identity is per-device).
    /// Scoped, single-use token from a scanned setup QR (auth.bootstrapToken).
    var bootstrapToken: String {
        get { UserDefaults.standard.string(forKey: "ocBootstrapToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "ocBootstrapToken") }
    }
    /// Persistent per-device token issued by the gateway on approval.
    var deviceToken: String {
        get { UserDefaults.standard.string(forKey: "ocDeviceToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "ocDeviceToken") }
    }
    var lastRequestId: String = ""

    /// The credential to authenticate with, preferring the strongest we have.
    private var activeCredential: String {
        if !deviceToken.isEmpty { return deviceToken }
        if !bootstrapToken.isEmpty { return bootstrapToken }
        return token
    }
    /// The connect-frame auth field name matching activeCredential.
    private var activeAuthField: String {
        if !deviceToken.isEmpty { return "deviceToken" }
        if !bootstrapToken.isEmpty { return "bootstrapToken" }
        return "token"
    }

    /// Decode a base64url setup code into its parts (no side effects).
    static func decodeSetupCode(_ raw: String) -> (url: String, bootstrapToken: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = obj["url"] as? String, url.hasPrefix("ws") else { return nil }
        return (url, (obj["bootstrapToken"] as? String) ?? "")
    }

    /// Apply a pairing directly (used for the phone→watch hand-off over
    /// WatchConnectivity). Clears the old device token so it re-pairs.
    func applyPairing(url: String, bootstrapToken: String) {
        guard url.hasPrefix("ws") else { return }
        gatewayURL = url
        self.bootstrapToken = bootstrapToken
        deviceToken = ""
        lastEvent = "Paired from iPhone — connecting…"
    }

    /// Decode a scanned/pasted setup code (base64url JSON {url, bootstrapToken})
    /// and apply it. Clears any old device token so we re-pair cleanly.
    @discardableResult
    func applySetupCode(_ raw: String) -> Bool {
        guard let (url, bt) = Self.decodeSetupCode(raw) else { return false }
        gatewayURL = url
        bootstrapToken = bt
        deviceToken = ""
        lastEvent = "Setup code applied — connect to pair"
        return true
    }
    /// Reconnect the node automatically once the user has enabled it (synced).
    var isAutoConnect: Bool {
        get { kv.object(forKey: "ocAutoConnect") as? Bool ?? UserDefaults.standard.bool(forKey: "ocAutoConnect") }
        set { kv.set(newValue, forKey: "ocAutoConnect"); kv.synchronize()
              UserDefaults.standard.set(newValue, forKey: "ocAutoConnect") }
    }

    private let clientId = "node-host"
    private let operatorClientId = "openclaw-ios"   // official iOS client id
    private let protocolVersion = 4
    private let commands = [
        "health.snapshot", "location.get", "battery.get", "device.info",
        "heart.get", "steps.get", "sleep.get", "workout.get",
        "calendar.get", "weather.get", "system.notify",
        // relayed to the watch over WatchConnectivity (watch-exclusive sensors)
        "watch.heart", "watch.temp", "watch.o2", "watch.rings", "watch.health",
    ]

    private var ws: WSClient?

    /// The live Bonjour endpoint from "Find on network", if the user connected
    /// that way. Dialing this endpoint survives iOS Local Network privacy;
    /// re-dialing its raw IP does not. Ephemeral — valid while the mDNS entry
    /// lives; cleared on reset.
    private var discoveredEndpoint: NWEndpoint?
    private var discoveredTls = false

    // While pending approval, redial on a timer so the node connects on its own
    // once the operator runs `openclaw nodes approve` — no need to tap Connect.
    private var pendingRetryScheduled = false
    private var pendingRetries = 0
    private let maxPendingRetries = 40          // ~3.5 min at 5s intervals
    private let pendingRetryInterval: TimeInterval = 5

    private func schedulePendingRetry() {
        guard status == .pending, !pendingRetryScheduled else { return }
        guard pendingRetries < maxPendingRetries else {
            lastEvent = "Still waiting — approve this device on the gateway, then tap Connect."
            return
        }
        pendingRetryScheduled = true
        pendingRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingRetryInterval) { [weak self] in
            guard let self else { return }
            self.pendingRetryScheduled = false
            guard self.status == .pending else { return }
            self.ws?.close(); self.ws = nil
            self.dial()
        }
    }

    /// Called when the user taps a gateway found via "Find on network". Keeps
    /// the URL string for display/persistence AND the live endpoint to dial.
    func useDiscovered(endpoint: NWEndpoint, tls: Bool, url: String) {
        discoveredEndpoint = endpoint
        discoveredTls = tls
        gatewayURL = url
    }

    /// Cloudflare Access headers for the WebSocket upgrade, when configured.
    private var cfHeaders: [(String, String)] {
        CloudflareAccess.isConfigured
            ? [("CF-Access-Client-Id", CloudflareAccess.clientId),
               ("CF-Access-Client-Secret", CloudflareAccess.clientSecret)]
            : []
    }
    private let logger = LoggerService(OpenClawNodeService.self)
    private let locationManager = CLLocationManager()

    #if os(watchOS)
    private let platformName = "watchos"
    private let deviceFamilyName = "watch"
    private let defaultDisplayName = "ClawWatch Watch"
    #else
    private let platformName = "ios"
    private let deviceFamilyName = "phone"
    private let defaultDisplayName = "ClawWatch iPhone"
    #endif

    /// Friendly name shown in `openclaw nodes list` and the approval prompt.
    /// Local to each device (deliberately NOT iCloud-synced) so the phone and
    /// watch keep distinct names.
    var displayName: String {
        get { UserDefaults.standard.string(forKey: "ocDeviceName") ?? defaultDisplayName }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            UserDefaults.standard.set(trimmed.isEmpty ? defaultDisplayName : trimmed, forKey: "ocDeviceName")
        }
    }

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
            String(signedAtMs), activeCredential, nonce, platformName, deviceFamilyName,
        ].joined(separator: "|")
    }

    // MARK: - Lifecycle

    func start() {
        guard status == .idle || status == .error else { return }
        pendingRetries = 0
        dial()
    }

    private func dial() {
        guard let url = URL(string: gatewayURL), url.scheme?.hasPrefix("ws") == true else {
            status = .error
            lastEvent = gatewayURL.isEmpty ? "No gateway URL set" : "Bad gateway URL: \(gatewayURL)"
            return
        }
        status = .connecting
        isAutoConnect = true
        gotChallenge = false
        // Debug: show exactly what we're dialing + which credential/headers.
        let cred = deviceToken.isEmpty ? (bootstrapToken.isEmpty ? "raw-token" : "bootstrap") : "device-token"
        let cf = CloudflareAccess.isConfigured ? " +CF-Access" : ""
        lastEvent = "Dialing \(url.host ?? "?"):\(url.port ?? 0) [\(cred)]\(cf)"

        let client = WSClient()
        ws = client
        client.onOpen = { [weak self] in
            guard let self, self.status == .connecting else { return }
            self.lastEvent = "Socket open — awaiting challenge"
        }
        client.onWaiting = { [weak self] reason in
            guard let self, self.status == .connecting else { return }
            self.lastEvent = "Waiting (route not ready): \(reason)"
        }
        client.onText = { [weak self] text in self?.handleFrame(text) }
        client.onClose = { [weak self] reason in
            guard let self else { return }
            switch self.status {
            case .idle:
                return
            case .pending:
                // Expected: the gateway drops us until the device is approved.
                // Keep the "waiting for approval" state and retry automatically
                // instead of flipping to an error.
                self.schedulePendingRetry()
            default:
                self.status = .error
                let stage = self.gotChallenge ? "after handshake" : "before handshake"
                self.lastEvent = "Closed \(stage): \(reason ?? "connection closed")"
            }
        }
        if let ep = discoveredEndpoint {
            client.connect(endpoint: ep, tls: discoveredTls, headers: cfHeaders)
        } else {
            client.connect(url: url, headers: cfHeaders)
        }
    }

    /// Debug: whether we ever received connect.challenge (i.e. the WebSocket
    /// upgrade actually completed) before a failure.
    private var gotChallenge = false

    func stop() {
        ws?.close()
        ws = nil
        closeOperator()
        status = .idle
    }

    /// Wipe all OpenClaw + voice setup and this device's identity, and
    /// disconnect. Use when a half-finished setup is in a bad state. The
    /// gateway will treat this device as new (needs re-approval) next connect.
    func resetSetup() {
        stop()
        LiveVoiceService.shared.stop()
        let keys = [
            "ocGatewayURL", "ocGatewayToken", "ocAutoConnect", "ocDeviceName",
            "ocBootstrapToken", "ocDeviceToken",
            "liveVoiceEndpoint", "liveVoiceToken", "liveVoiceDefaultAgent",
            "liveVoiceAgentMap", "liveVoiceAutoStop", "liveVoiceSilenceTimeout",
            "cfAccessClientId", "cfAccessClientSecret",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
            NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        KeychainService.delete(key: "ocNodePrivateKey")   // new identity next time
        discoveredEndpoint = nil
        agents = []
        agentsDefaultId = ""
        status = .idle
        lastEvent = "Reset — reconfigure and re-approve on the gateway"
    }


    private func handleFrame(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return }
        let type = obj["type"] as? String

        if type == "event", let event = obj["event"] as? String {
            if event == "connect.challenge",
               let payload = obj["payload"] as? [String: Any],
               let nonce = payload["nonce"] as? String {
                gotChallenge = true
                sendConnect(nonce: nonce)
            } else if event == "node.invoke.request",
                      let payload = obj["payload"] as? [String: Any] {
                handleInvoke(payload)
            }
        } else if type == "res", let id = obj["id"] as? String, id == "connect" {
            if (obj["ok"] as? Bool) == true {
                status = .connected
                pendingRetries = 0
                lastEvent = "Connected as node"
                // Capture the device token issued on approval; it replaces the
                // one-time bootstrap token for all future connects.
                if let issued = ((obj["payload"] as? [String: Any])?["auth"] as? [String: Any])?["token"] as? String,
                   !issued.isEmpty {
                    deviceToken = issued
                    bootstrapToken = ""
                }
                fetchAgents()   // roster comes over a separate operator connection
            } else {
                let errObj = obj["error"] as? [String: Any]
                let code = (errObj?["code"] as? String)
                    ?? ((errObj?["details"] as? [String: Any])?["code"] as? String)
                let msg = (errObj?["message"] as? String) ?? (obj["error"] as? String) ?? ""
                let details = errObj?["details"] as? [String: Any]
                if let rid = details?["requestId"] as? String { lastRequestId = rid }
                let c = (code ?? "").uppercased()

                if c.contains("BOOTSTRAP") {
                    // Single-use token spent/expired — need a fresh scan.
                    bootstrapToken = ""
                    status = .error
                    lastEvent = "Setup code expired — scan a fresh QR"
                } else if c.contains("PAIRING") || c == "NOT_PAIRED"
                            || msg.lowercased().contains("pair") || msg.lowercased().contains("approv") {
                    status = .pending
                    lastEvent = lastRequestId.isEmpty
                        ? "Waiting for approval on the gateway — it'll connect automatically once approved."
                        : "Waiting for approval on the gateway (request \(lastRequestId.prefix(8))) — approve it with `openclaw nodes approve` and this connects automatically."
                    // Keep retrying so approval alone completes the pairing.
                    schedulePendingRetry()
                } else {
                    status = .error
                    lastEvent = "Gateway rejected: \(msg)\(code.map { " [\($0)]" } ?? "")"
                }
            }
        } else if type == "res", let ok = obj["ok"] as? Bool, ok == false,
                  (obj["id"] as? String) != "agents.list" {
            // Any other failed response — show it rather than swallow it.
            let msg = (obj["error"] as? [String: Any])?["message"] as? String
                ?? "\(obj["error"] ?? "error")"
            lastEvent = "Gateway: \(msg)"
        }
    }

    // MARK: - Agent roster (operator connection)
    //
    // agents.list is operator-scoped — a node role is refused. So we open a
    // short-lived second connection as an operator (client id openclaw-ios,
    // scope operator.read, which is auto-granted with the shared token), fetch
    // the roster, and close it. Verified against a live gateway.

    private var operatorWS: WSClient?

    func fetchAgents() {
        guard let url = URL(string: gatewayURL), url.scheme?.hasPrefix("ws") == true else { return }
        closeOperator()
        let client = WSClient()
        operatorWS = client
        client.onText = { [weak self] text in self?.handleOperatorFrame(text) }
        if let ep = discoveredEndpoint {
            client.connect(endpoint: ep, tls: discoveredTls, headers: cfHeaders)
        } else {
            client.connect(url: url, headers: cfHeaders)
        }
    }

    private func handleOperatorFrame(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return }
        let type = obj["type"] as? String
        if type == "event", (obj["event"] as? String) == "connect.challenge",
           let payload = obj["payload"] as? [String: Any], let nonce = payload["nonce"] as? String {
            sendOperatorConnect(nonce: nonce)
        } else if type == "res", (obj["id"] as? String) == "connect" {
            if (obj["ok"] as? Bool) == true {
                sendOperator(body: ["id": "agents.list", "method": "agents.list", "params": [:]])
            } else {
                lastEvent = "Agent list unavailable — enter ids manually"
                closeOperator()
            }
        } else if type == "res", (obj["id"] as? String) == "agents.list" {
            handleAgentsList(obj)
            closeOperator()   // one-shot fetch
        }
    }

    private func sendOperatorConnect(nonce: String) {
        let identity = loadOrCreateIdentity()
        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let scopes = "operator.read"
        let payload = [
            "v3", identity.deviceId, operatorClientId, "ui", "operator", scopes,
            String(signedAtMs), activeCredential, nonce, platformName, deviceFamilyName,
        ].joined(separator: "|")
        guard let signature = try? identity.privateKey.signature(for: Data(payload.utf8)) else {
            closeOperator(); return
        }
        let params: [String: Any] = [
            "minProtocol": protocolVersion,
            "maxProtocol": protocolVersion,
            "client": [
                "id": operatorClientId, "displayName": displayName, "version": "1.0.0",
                "platform": platformName, "deviceFamily": deviceFamilyName,
                "mode": "ui", "instanceId": identity.deviceId,
            ],
            "role": "operator",
            "scopes": ["operator.read"],
            "device": [
                "id": identity.deviceId,
                "publicKey": base64url(identity.privateKey.publicKey.rawRepresentation),
                "signature": base64url(signature),
                "signedAt": signedAtMs,
                "nonce": nonce,
            ],
            "auth": [activeAuthField: activeCredential],
        ]
        sendOperator(body: ["id": "connect", "method": "connect", "params": params])
    }

    private func sendOperator(body: [String: Any]) {
        var frame = body
        frame["type"] = "req"
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
        operatorWS?.sendText(text)
    }

    private func closeOperator() {
        operatorWS?.close()
        operatorWS = nil
    }

    private func handleAgentsList(_ obj: [String: Any]) {
        guard (obj["ok"] as? Bool) == true, let payload = obj["payload"] as? [String: Any] else {
            // Likely a scope restriction (agents.list is a management method).
            lastEvent = "Agent list unavailable — enter ids manually"
            return
        }
        agentsDefaultId = payload["defaultId"] as? String ?? ""
        let list = payload["agents"] as? [[String: Any]] ?? []
        agents = list.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let identity = entry["identity"] as? [String: Any]
            let base = (entry["name"] as? String) ?? (identity?["name"] as? String) ?? id
            if let emoji = identity?["emoji"] as? String, !emoji.isEmpty {
                return OCAgent(id: id, name: "\(emoji) \(base)")
            }
            return OCAgent(id: id, name: base)
        }
        lastEvent = "Loaded \(agents.count) agent\(agents.count == 1 ? "" : "s")"
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
            "auth": [activeAuthField: activeCredential],
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
        ws?.sendText(text)
    }
}
