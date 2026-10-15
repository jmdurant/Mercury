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
    /// Off-network fallback: a public tunnel gateway URL (e.g.
    /// wss://gateway.vr2fit.com). When the LAN gateway can't be found on the
    /// network, connect dials this instead. Synced.
    var remoteURL: String {
        get { syncedString("ocRemoteURL") }
        set { setSynced("ocRemoteURL", newValue) }
    }
    /// True when the current/last connection went out over `remoteURL` (the
    /// tunnel) rather than the LAN — lets live voice pick its remote endpoint.
    private(set) var connectedViaRemote = false
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

    /// The live Bonjour endpoint for a gateway on the local network.
    /// Ephemeral: rediscovered on reconnect and cleared on reset.
    private var discoveredEndpoint: NWEndpoint?
    private var discoveredTls = false
    /// The URL the node actually connected to (LAN or tunnel) — reused for the
    /// operator/agents.list connection so it follows the same transport.
    private var activeURL: URL?

    // While pending approval, redial on a timer so the node connects on its own
    // once the operator runs `openclaw nodes approve` — no need to tap Connect.
    private var retryWork: DispatchWorkItem?
    private var connectTimeoutWork: DispatchWorkItem?
    private var connectionGeneration = UUID()
    private var shouldReconnect = false
    private var reconnectAttempts = 0
    private var pendingRetries = 0
    private let maxPendingRetries = 40
    private let pendingRetryInterval: TimeInterval = 5

    private func schedulePendingRetry() {
        guard status == .pending, retryWork == nil, shouldReconnect else { return }
        guard pendingRetries < maxPendingRetries else {
            lastEvent = "Still waiting — approve this device on the gateway, then tap Connect."
            return
        }
        pendingRetries += 1
        scheduleRetry(after: pendingRetryInterval)
    }

    private func scheduleRetry(after delay: TimeInterval) {
        guard shouldReconnect, retryWork == nil else { return }
        let generation = connectionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldReconnect, self.connectionGeneration == generation else { return }
            self.retryWork = nil
            self.ws?.close(); self.ws = nil
            self.discoveredEndpoint = nil
            self.dial()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func connectionLost(_ reason: String) {
        guard shouldReconnect else { return }
        connectTimeoutWork?.cancel(); connectTimeoutWork = nil
        ws?.close(); ws = nil
        closeOperator()
        status = .error
        let delay = min(30, pow(2, Double(min(reconnectAttempts, 5))))
        reconnectAttempts += 1
        lastEvent = "\(reason) — reconnecting in \(Int(delay))s"
        scheduleRetry(after: delay)
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

    // Talk uses its own operator grant; a node token never authorizes voice.
    var voiceGatewayIdentity: String { gatewayURL + "|" + remoteURL }

    func voiceCredential() -> (value: String, field: String)? {
        if let data = KeychainService.load(key: "ocTalkDeviceToken"),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           saved["gateway"] == voiceGatewayIdentity, let value = saved["token"], !value.isEmpty {
            return (value, "deviceToken")
        }
        return token.isEmpty ? nil : (token, "token")
    }

    func saveVoiceToken(_ token: String, gatewayIdentity: String) {
        guard voiceGatewayIdentity == gatewayIdentity,
              let data = try? JSONSerialization.data(withJSONObject: ["gateway": gatewayIdentity, "token": token]) else { return }
        _ = KeychainService.save(key: "ocTalkDeviceToken", data: data)
    }

    func resetVoiceAccess() {
        LiveVoiceService.shared.stop()
        KeychainService.delete(key: "ocTalkDeviceToken")
    }

    func voiceConnectParameters(nonce: String, credential: String, authField: String) -> [String: Any]? {
        let identity = loadOrCreateIdentity()
        let signedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let scopes = ["operator.talk"]
        let payload = ["v3", identity.deviceId, operatorClientId, "ui", "operator",
                       scopes.joined(separator: ","), String(signedAt), credential, nonce,
                       platformName, deviceFamilyName].joined(separator: "|")
        guard let signature = try? identity.privateKey.signature(for: Data(payload.utf8)) else { return nil }
        return [
            "minProtocol": protocolVersion, "maxProtocol": protocolVersion,
            "client": ["id": operatorClientId, "displayName": displayName + " Voice",
                       "version": "1.0.0", "platform": platformName, "deviceFamily": deviceFamilyName,
                       "mode": "ui", "instanceId": identity.deviceId],
            "role": "operator", "scopes": scopes,
            "device": ["id": identity.deviceId,
                       "publicKey": base64url(identity.privateKey.publicKey.rawRepresentation),
                       "signature": base64url(signature), "signedAt": signedAt, "nonce": nonce],
            "auth": [authField: credential],
        ]
    }

    /// Voice can start independently of the sensor node, including on a standalone Watch.
    func connectVoiceGateway(_ client: WSClient, isCurrent: @escaping () -> Bool,
                             failure: @escaping (String) -> Void) {
        func validURL(_ text: String) -> URL? {
            guard let url = URL(string: text), let host = url.host, !host.isEmpty,
                  ["ws", "wss"].contains(url.scheme ?? "") else { return nil }
            return url
        }
        func dial(_ url: URL, endpoint: NWEndpoint? = nil, tls: Bool = false) {
            guard isCurrent() else { return }
            if let endpoint, (url.path.isEmpty || url.path == "/"), url.query == nil {
                client.connect(endpoint: endpoint, tls: tls, headers: cfHeaders)
            } else {
                client.connect(url: url, headers: cfHeaders)
            }
        }
        if status == .connected, let activeURL {
            dial(activeURL, endpoint: discoveredEndpoint, tls: discoveredTls)
            return
        }
        let lan = validURL(gatewayURL)
        let remote = validURL(remoteURL)
        if let lan, let host = lan.host, Self.isPrivateLANHost(host) {
            NodeDiscoveryService.shared.resolveEndpoint(forHost: host) { endpoint, tls in
                if let endpoint { dial(lan, endpoint: endpoint, tls: tls) }
                else { dial(remote ?? lan) }
            }
        } else if let url = lan ?? remote {
            dial(url)
        } else {
            failure("Set an OpenClaw Gateway address in Agent settings before starting voice.")
        }
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
        retryWork?.cancel(); retryWork = nil
        connectTimeoutWork?.cancel(); connectTimeoutWork = nil
        ws?.close(); ws = nil
        closeOperator()
        shouldReconnect = true
        isAutoConnect = true
        reconnectAttempts = 0
        pendingRetries = 0
        // Re-resolve the LAN endpoint on every fresh connect so home↔away
        // switching is reliable (a stale endpoint from home won't connect away
        // and would otherwise block the tunnel fallback).
        discoveredEndpoint = nil
        dial()
    }

    private func dial() {
        func validURL(_ raw: String) -> URL? {
            guard let url = URL(string: raw), url.host != nil,
                  url.scheme == "ws" || url.scheme == "wss",
                  (1...65535).contains(url.port ?? (url.scheme == "wss" ? 443 : 80)) else { return nil }
            return url
        }
        let lan = validURL(gatewayURL)
        let remote = validURL(remoteURL)
        guard lan != nil || remote != nil else {
            shouldReconnect = false
            status = .error
            lastEvent = gatewayURL.isEmpty ? "No gateway URL set" : "Bad gateway URL: \(gatewayURL)"
            return
        }
        connectionGeneration = UUID()
        let generation = connectionGeneration
        status = .connecting
        gotChallenge = false
        connectTimeoutWork?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.connectionGeneration == generation, self.status == .connecting else { return }
            self.connectionLost("Gateway connection timed out")
        }
        connectTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        connectedViaRemote = false

        // Already hold a live LAN Bonjour endpoint → use it (fast home path).
        if discoveredEndpoint != nil, let lan {
            openWebSocket(url: lan); return
        }

        // Discover the LAN gateway before selecting the local or tunnel route.
        if let lan, let host = lan.host, Self.isPrivateLANHost(host) {
            lastEvent = "Finding \(host) on the network…"
            NodeDiscoveryService.shared.resolveEndpoint(forHost: host) { [weak self] ep, tls in
                guard let self, self.status == .connecting, self.connectionGeneration == generation else { return }
                if let ep {
                    self.discoveredEndpoint = ep; self.discoveredTls = tls
                    self.openWebSocket(url: lan)
                } else if let remote {
                    self.connectedViaRemote = true
                    self.lastEvent = "Not on home network — using tunnel \(remote.host ?? "")…"
                    self.openWebSocket(url: remote)
                } else {
                    self.openWebSocket(url: lan)   // last resort; will surface the error
                }
            }
            return
        }

        // LAN URL is a public host (or none) → dial it, else the tunnel.
        if let lan {
            openWebSocket(url: lan)
        } else if let remote {
            connectedViaRemote = true
            openWebSocket(url: remote)
        }
    }

    /// True for hosts on the local network (private IPv4 or an mDNS `.local`
    /// name), where Bonjour discovery can establish whether we are at home.
    static func isPrivateLANHost(_ host: String) -> Bool {
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }),
              let a = Int(parts[0]), let b = Int(parts[1]) else { return false }
        if a == 10 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        return false
    }

    private func openWebSocket(url: URL) {
        // Remember the actual target so the operator (agents.list) connection
        // follows the same transport — LAN endpoint or tunnel URL, not always
        // the raw LAN IP in gatewayURL (which iOS aborts when we're on tunnel).
        activeURL = url

        // Debug: show exactly what we're dialing + which credential/headers.
        let cred = deviceToken.isEmpty ? (bootstrapToken.isEmpty ? "raw-token" : "bootstrap") : "device-token"
        let cf = CloudflareAccess.isConfigured ? " +CF-Access" : ""
        let via = discoveredEndpoint != nil ? "endpoint" : "\(url.host ?? "?"):\(url.port ?? 0)"
        lastEvent = "Dialing \(via) [\(cred)]\(cf)"

        let client = WSClient()
        let generation = connectionGeneration
        ws = client
        client.onOpen = { [weak self] in
            guard let self, self.connectionGeneration == generation, self.status == .connecting else { return }
            self.lastEvent = "Socket open — awaiting challenge"
        }
        client.onWaiting = { [weak self] reason in
            guard let self, self.connectionGeneration == generation else { return }
            if self.status == .connected {
                self.connectionLost("Connection unavailable: \(reason)")
            } else if self.status == .connecting {
                self.lastEvent = "Waiting (route not ready): \(reason)"
            }
        }
        client.onText = { [weak self] text in
            guard let self, self.connectionGeneration == generation else { return }
            self.handleFrame(text)
        }
        client.onClose = { [weak self] reason in
            guard let self, self.connectionGeneration == generation else { return }
            switch self.status {
            case .idle:
                return
            case .pending:
                // Expected: the gateway drops us until the device is approved.
                // Keep the "waiting for approval" state and retry automatically
                // instead of flipping to an error.
                self.schedulePendingRetry()
            case .error:
                // A gateway verdict (bootstrap expired, rejected, …) already set
                // a specific message. The socket then closes — don't clobber the
                // real reason with a generic "closed / socket 57" line.
                return
            default:
                let stage = self.gotChallenge ? "after handshake" : "before handshake"
                self.connectionLost("Closed \(stage): \(reason ?? "connection closed")")
            }
        }
        if let ep = discoveredEndpoint, (url.path.isEmpty || url.path == "/"), url.query == nil {
            client.connect(endpoint: ep, tls: discoveredTls, headers: cfHeaders)
        } else {
            client.connect(url: url, headers: cfHeaders)
        }
    }

    /// Debug: whether we ever received connect.challenge (i.e. the WebSocket
    /// upgrade actually completed) before a failure.
    private var gotChallenge = false

    func stop(disableAutoConnect: Bool = true) {
        shouldReconnect = false
        if disableAutoConnect { isAutoConnect = false }
        connectionGeneration = UUID()
        retryWork?.cancel(); retryWork = nil
        connectTimeoutWork?.cancel(); connectTimeoutWork = nil
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
            "ocGatewayURL", "ocRemoteURL", "ocGatewayToken", "ocAutoConnect", "ocDeviceName",
            "ocBootstrapToken", "ocDeviceToken",
            "liveVoiceEndpoint", "liveVoiceRemote", "liveVoiceToken", "liveVoiceDefaultAgent",
            "liveVoiceAgentMap", "liveVoiceAutoStop", "liveVoiceSilenceTimeout",
            "liveVoiceBackend", "liveVoiceTalkModel", "liveVoiceTalkAutoStop",
            "cfAccessClientId", "cfAccessClientSecret",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
            NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        KeychainService.delete(key: "ocNodePrivateKey")   // new identity next time
        KeychainService.delete(key: "ocTalkDeviceToken")
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
            } else if event == "node.invoke.request", status == .connected,
                      let payload = obj["payload"] as? [String: Any] {
                handleInvoke(payload)
            }
        } else if type == "res", let id = obj["id"] as? String, id == "connect" {
            connectTimeoutWork?.cancel(); connectTimeoutWork = nil
            if (obj["ok"] as? Bool) == true {
                status = .connected
                reconnectAttempts = 0
                retryWork?.cancel(); retryWork = nil
                pendingRetries = 0
                lastEvent = "Connected as node"
                // Capture the persistent device token issued on approval; it
                // replaces the one-time bootstrap token for all future connects.
                // The gateway has put it under payload.auth.token in practice,
                // but check the other plausible spots too so a reconnect never
                // has to fall back to a spent bootstrap token.
                let payload = obj["payload"] as? [String: Any]
                let auth = payload?["auth"] as? [String: Any]
                let issued = (auth?["token"] as? String)
                    ?? (auth?["deviceToken"] as? String)
                    ?? (payload?["deviceToken"] as? String)
                    ?? ((payload?["device"] as? [String: Any])?["token"] as? String)
                if let issued, !issued.isEmpty {
                    deviceToken = issued
                    bootstrapToken = ""
                    NSLog("OPENCLAW captured device token (\(issued.count) chars)")
                } else {
                    let authKeys = auth.map { Array($0.keys) } ?? []
                    let payloadKeys = payload.map { Array($0.keys) } ?? []
                    NSLog("OPENCLAW hello-ok had NO device token; auth keys=\(authKeys) payload keys=\(payloadKeys)")
                }
                fetchAgents()   // agents.list over this same node connection
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
                    shouldReconnect = false
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
                    shouldReconnect = false
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

    // MARK: - Agent roster
    //
    // agents.list is OPERATOR-scoped and the gateway refuses it on a node-role
    // connection ("unauthorized role: node") — the role check runs before scope.
    // So we open a short-lived SECOND connection with role=operator, presenting
    // the paired DEVICE token as a bearer `auth.token` (exactly what the CLI's
    // `--token <deviceToken>` does — auth.deviceToken instead enforces the node
    // binding and is rejected as AUTH_DEVICE_TOKEN_MISMATCH). No admin token.

    private var operatorWS: WSClient?

    func fetchAgents() {
        // The gateway refuses agents.list on a node-role connection and rejects
        // the paired device token on an operator connection (verified live:
        // AUTH_DEVICE_TOKEN_MISMATCH / AUTH_TOKEN_MISMATCH). Only the raw gateway
        // token authorises operator.read — so only attempt it when one is set;
        // otherwise leave agent ids to manual entry rather than erroring.
        guard !operatorCredential.isEmpty else {
            lastEvent = "Connected — enter agent ids manually (auto-list needs the gateway token, or a gateway policy change)."
            return
        }
        // Follow the transport the node used, including any path and query.
        let target = activeURL ?? URL(string: gatewayURL)
        closeOperator()
        let client = WSClient()
        operatorWS = client
        client.onText = { [weak self, weak client] text in
            guard let self, let client, self.operatorWS === client else { return }
            self.handleOperatorFrame(text)
        }
        if let ep = discoveredEndpoint, let target,
           (target.path.isEmpty || target.path == "/"), target.query == nil {
            client.connect(endpoint: ep, tls: discoveredTls, headers: cfHeaders)
        } else if let target, target.scheme?.hasPrefix("ws") == true {
            client.connect(url: target, headers: cfHeaders)
        }
    }

    /// The credential for the operator connection. Only the raw gateway token
    /// works here — the device token is rejected (mismatch) — so this is empty
    /// unless the user has entered a gateway token in Advanced.
    private var operatorCredential: String { token }

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
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "unavailable"
                lastEvent = "Agent list: \(msg) — enter ids manually"
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
        let cred = operatorCredential
        // Sign the v3 payload with the SAME token we present as the bearer, so
        // the gateway's signature reconstruction matches.
        let payload = [
            "v3", identity.deviceId, operatorClientId, "ui", "operator", "operator.read",
            String(signedAtMs), cred, nonce, platformName, deviceFamilyName,
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
            "auth": ["token": cred],   // device token as a bearer (like the CLI)
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

    /// The agent whose display name matches a chat title (ignoring emoji,
    /// spacing and case) — so a Telegram chat named after an agent auto-routes
    /// to it without a manual per-chat toggle.
    func agent(forChatTitle title: String) -> OCAgent? {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let t = norm(title)
        guard !t.isEmpty else { return nil }
        return agents.first { norm($0.name) == t }
    }

    private func handleAgentsList(_ obj: [String: Any]) {
        guard (obj["ok"] as? Bool) != false else {
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "unavailable"
            lastEvent = "Agent list \(msg) — enter ids manually"
            return
        }
        // The envelope may arrive wrapped in `payload` or at the top level.
        let env = (obj["payload"] as? [String: Any]) ?? obj
        agentsDefaultId = (env["defaultId"] as? String) ?? (env["mainKey"] as? String) ?? ""
        let list = env["agents"] as? [[String: Any]] ?? []
        agents = list.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let identity = entry["identity"] as? [String: Any]
            let base = (entry["name"] as? String)
                ?? (entry["identityName"] as? String)
                ?? (identity?["name"] as? String) ?? id
            let emoji = (entry["identityEmoji"] as? String) ?? (identity?["emoji"] as? String) ?? ""
            return OCAgent(id: id, name: emoji.isEmpty ? base : "\(emoji) \(base)")
        }
        // Adopt the gateway's default agent so live voice / system PTT is enabled
        // out of the box (no manual pick). Only when the user hasn't chosen one,
        // and only if the default id is actually in the roster.
        if LiveVoiceService.shared.defaultAgentId.isEmpty,
           !agentsDefaultId.isEmpty,
           agents.contains(where: { $0.id == agentsDefaultId }) {
            LiveVoiceService.shared.defaultAgentId = agentsDefaultId
        }
        lastEvent = agents.isEmpty
            ? "Connected — no agents configured"
            : "Loaded \(agents.count) agent\(agents.count == 1 ? "" : "s")"
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
        let generation = connectionGeneration
        var invokeParams: [String: Any] = [:]
        var invalidParams = false
        if let raw = payload["paramsJSON"], !(raw is NSNull) {
            if let text = raw as? String,
               let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                invokeParams = parsed
            } else {
                invalidParams = true
            }
        }
        Task { @MainActor in
            guard self.connectionGeneration == generation, self.status == .connected else { return }
            let result: [String: Any]
            if invalidParams {
                result = ["error": "paramsJSON must contain a JSON object", "code": "INVALID_PARAMS"]
            } else {
                result = await runCommand(command, params: invokeParams)
            }
            guard self.connectionGeneration == generation, self.status == .connected else { return }
            let params = Self.invocationResult(id: id, nodeId: nodeId, result: result)
            send(type: "req", body: ["id": UUID().uuidString, "method": "node.invoke.result", "params": params])
        }
    }

    /// Errors belong in the protocol envelope, not in a successful payload.
    static func invocationResult(id: String, nodeId: String, result: [String: Any]) -> [String: Any] {
        var envelope: [String: Any] = ["id": id, "nodeId": nodeId]
        if let message = result["error"] as? String {
            envelope["ok"] = false
            envelope["error"] = ["code": result["code"] as? String ?? "UNAVAILABLE", "message": message]
        } else if let data = try? JSONSerialization.data(withJSONObject: result) {
            envelope["ok"] = true
            envelope["payloadJSON"] = String(decoding: data, as: UTF8.self)
        } else {
            envelope["ok"] = false
            envelope["error"] = ["code": "INTERNAL_ERROR", "message": "Could not encode command result"]
        }
        return envelope
    }

    private func runCommand(_ command: String, params: [String: Any]) async -> [String: Any] {
        // Consent gate: node commands honour the same per-category consent as
        // the Telegram #-command channel.
        guard AutoResponderStore.allowRequest() else {
            return ["error": "Rate limit reached, try again shortly", "code": "RATE_LIMITED"]
        }
        AutoResponderStore.audit(command: "node: " + command, chatId: 0)
        guard commands.contains(command) else {
            return ["error": "unsupported command \(command)", "code": "UNSUPPORTED_COMMAND"]
        }
        if let denial = AutoResponderStore.consentDenial(for: command) {
            return ["error": denial, "code": "PERMISSION_DENIED"]
        }
        switch command {
        case "battery.get":
            guard let battery = StatusDataService.buildBatteryStatus() else { return ["error": "battery unavailable"] }
            return ["battery": battery]
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
            guard let summary = await StatusDataService.buildSleepStatus() else { return ["error": "no sleep data"] }
            return ["summary": summary]
        case "workout.get":
            return ["summary": await StatusDataService.buildWorkoutStatus() ?? "no active workout"]
        case "calendar.get":
            if let avail = await StatusDataService.buildWorkAvailabilityStatus() {
                return ["summary": avail]
            }
            return ["summary": await StatusDataService.buildCalendarStatus() ?? "no events"]
        case "weather.get":
            guard let summary = await StatusDataService.buildWeatherStatus() else { return ["error": "weather unavailable"] }
            return ["summary": summary]
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
            #elseif os(watchOS)
            if command.hasPrefix("watch.") {
                return await WatchBridge.runWatchCommand(command)
            }
            #endif
            return ["error": "unsupported command \(command)", "code": "UNSUPPORTED_COMMAND"]
        }
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
