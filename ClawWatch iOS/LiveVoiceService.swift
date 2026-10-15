//
//  LiveVoiceService.swift
//  ClawWatch iOS
//
//  OpenClaw GPT-Live via its Gateway relay (24 kHz PCM16 both ways), or
//  the original custom voice server (16 kHz upload / 24 kHz playback).
//

import Foundation
import AVFoundation

/// Optional Cloudflare Access service-token headers for sockets that sit
/// behind a Cloudflare Tunnel + Access. Credentials sync from the phone via
/// iCloud. When unset, sockets are unchanged — pure-tunnel and LAN keep
/// working with no headers.
enum CloudflareAccess {

    private static func synced(_ key: String) -> String {
        NSUbiquitousKeyValueStore.default.string(forKey: key)
            ?? UserDefaults.standard.string(forKey: key) ?? ""
    }
    private static func setSynced(_ key: String, _ value: String) {
        NSUbiquitousKeyValueStore.default.set(value, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
        UserDefaults.standard.set(value, forKey: key)
    }

    static var clientId: String {
        get { synced("cfAccessClientId") } set { setSynced("cfAccessClientId", newValue) }
    }
    static var clientSecret: String {
        get { synced("cfAccessClientSecret") } set { setSynced("cfAccessClientSecret", newValue) }
    }
    static var isConfigured: Bool { !clientId.isEmpty && !clientSecret.isEmpty }

    /// A request carrying the Access headers when configured, plain otherwise.
    static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if isConfigured {
            req.setValue(clientId, forHTTPHeaderField: "CF-Access-Client-Id")
            req.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        return req
    }
}

@Observable
final class LiveVoiceService: NSObject {

    enum State: String { case idle, connecting, live, error }
    enum Backend: String, CaseIterable, Identifiable {
        case openClaw, custom
        var id: String { rawValue }
        var label: String { self == .openClaw ? "OpenClaw Talk" : "Custom voice server" }
    }
    enum TalkModel: String, CaseIterable, Identifiable {
        case gateway, subscription, api
        var id: String { rawValue }
        var label: String {
            switch self {
            case .gateway: return "Gateway default"
            case .subscription: return "GPT-Live · ChatGPT first"
            case .api: return "GPT-Live · API"
            }
        }
        var modelID: String? {
            switch self {
            case .gateway: return nil
            case .subscription: return "gpt-live-1-codex"
            case .api: return "gpt-live-1"
            }
        }
        var explanation: String {
            switch self {
            case .gateway: return "Uses OpenClaw’s OpenAI voice settings. With no model set, an API key takes precedence over ChatGPT sign-in."
            case .subscription: return "Uses ChatGPT sign-in on the Gateway first. OpenClaw may fall back to a paid API key when sign-in is unavailable; account access is required."
            case .api: return "Uses an OpenAI Platform API key configured on the Gateway. API usage is billed separately."
            }
        }
    }

    static let shared = LiveVoiceService()

    var state: State = .idle
    var lastError: String?
    var notice: String?
    var activeModel: String = ""
    var userTranscript: String = ""
    var assistantTranscript: String = ""
    var isSpeaking = false
    private var preferencesRevision = 0
    var backend: Backend {
        get { _ = preferencesRevision; return Backend(rawValue: syncedString("liveVoiceBackend")) ?? .openClaw }
        set { setSynced(newValue.rawValue, key: "liveVoiceBackend") }
    }
    var talkModel: TalkModel {
        get { _ = preferencesRevision; return TalkModel(rawValue: syncedString("liveVoiceTalkModel")) ?? .gateway }
        set { setSynced(newValue.rawValue, key: "liveVoiceTalkModel") }
    }
    private func syncedString(_ key: String) -> String {
        NSUbiquitousKeyValueStore.default.string(forKey: key)
            ?? UserDefaults.standard.string(forKey: key) ?? ""
    }
    private func setSynced(_ value: String, key: String) {
        NSUbiquitousKeyValueStore.default.set(value, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
        UserDefaults.standard.set(value, forKey: key)
        preferencesRevision += 1
    }
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(voiceSettingsChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: NSUbiquitousKeyValueStore.default)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }
    @objc private func voiceSettingsChanged() {
        DispatchQueue.main.async { [weak self] in self?.preferencesRevision += 1 }
    }
    @objc private func audioInterrupted(_ notification: Notification) {
        guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              type == AVAudioSession.InterruptionType.began.rawValue else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.usesPTTAudioSession, self.state == .live || self.state == .connecting else { return }
            self.fail("Voice was interrupted by another audio session. Tap Talk to reconnect.")
        }
    }
    /// Endpoint syncs from the phone to the watch via the shared iCloud KV
    /// store (set it once on iPhone), with a local mirror for immediacy.
    var endpoint: String {
        get {
            NSUbiquitousKeyValueStore.default.string(forKey: "liveVoiceEndpoint")
                ?? UserDefaults.standard.string(forKey: "liveVoiceEndpoint") ?? ""
        }
        set {
            NSUbiquitousKeyValueStore.default.set(newValue, forKey: "liveVoiceEndpoint")
            NSUbiquitousKeyValueStore.default.synchronize()
            UserDefaults.standard.set(newValue, forKey: "liveVoiceEndpoint")
        }
    }

    /// Off-network voice endpoint (e.g. wss://clawvoice.vr2fit.com) used when
    /// the node connected over its tunnel fallback rather than the LAN. Synced.
    var remoteEndpoint: String {
        get {
            NSUbiquitousKeyValueStore.default.string(forKey: "liveVoiceRemote")
                ?? UserDefaults.standard.string(forKey: "liveVoiceRemote") ?? ""
        }
        set {
            NSUbiquitousKeyValueStore.default.set(newValue, forKey: "liveVoiceRemote")
            NSUbiquitousKeyValueStore.default.synchronize()
            UserDefaults.standard.set(newValue, forKey: "liveVoiceRemote")
        }
    }

    /// The voice server port on the gateway box (single-box default).
    static let voicePort = 8795

    /// The endpoint actually dialed, in priority order:
    /// 1. `endpoint` — an explicit manual override, always wins.
    /// 2. `remoteEndpoint` — when the node connected via its tunnel (away).
    /// 3. derived from the node's gateway host on the voice port (home, one box).
    var effectiveEndpoint: String {
        if !endpoint.isEmpty { return endpoint }
        if OpenClawNodeService.shared.connectedViaRemote, !remoteEndpoint.isEmpty {
            return remoteEndpoint
        }
        return Self.voiceURL(fromGateway: OpenClawNodeService.shared.gatewayURL) ?? ""
    }

    /// Derive the custom server URL from the node's gateway host.
    static func voiceURL(fromGateway gatewayURL: String) -> String? {
        guard var comps = URLComponents(string: gatewayURL),
              comps.host != nil, comps.scheme?.hasPrefix("ws") == true else { return nil }
        comps.port = voicePort
        comps.path = ""
        comps.query = nil
        return comps.string
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    // Retained so ARC can't dealloc the session and cancel the task.
    private var ws: WSClient?
    private var relay: OpenClawTalkRelay?
    private var sessionBackend: Backend = .custom
    private var socketTimeout: DispatchWorkItem?
    private var hasCaptureTap = false
    private var captureGeneration = UUID()
    private var usesPTTAudioSession = false
    private var pttAudioActive = false
    private var playbackGeneration = UUID()
    private var queuedAudioBytes = 0
    private var queuedAudibleBuffers = 0
    private var scheduledAudio = 0
    private var playedAudio = 0
    private var playbackMarks: [(name: String, after: Int)] = []
    private var cfHeaders: [(String, String)] {
        CloudflareAccess.isConfigured
            ? [("CF-Access-Client-Id", CloudflareAccess.clientId),
               ("CF-Access-Client-Secret", CloudflareAccess.clientSecret)]
            : []
    }
    private let logger = LoggerService(LiveVoiceService.self)

    private var uploadFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!

    /// Auth token for the voice server, synced from the phone via iCloud KV.
    var voiceToken: String {
        get {
            NSUbiquitousKeyValueStore.default.string(forKey: "liveVoiceToken")
                ?? UserDefaults.standard.string(forKey: "liveVoiceToken") ?? ""
        }
        set {
            NSUbiquitousKeyValueStore.default.set(newValue, forKey: "liveVoiceToken")
            NSUbiquitousKeyValueStore.default.synchronize()
            UserDefaults.standard.set(newValue, forKey: "liveVoiceToken")
        }
    }

    #if os(watchOS)
    private let deviceParam = "watch"
    #else
    private let deviceParam = "phone"
    #endif

    // MARK: - Agent routing

    /// The agent the global Live Voice button talks to, sent as ?agent=<id>.
    /// Synced from the phone to the watch via iCloud KV.
    var defaultAgentId: String {
        get {
            NSUbiquitousKeyValueStore.default.string(forKey: "liveVoiceDefaultAgent")
                ?? UserDefaults.standard.string(forKey: "liveVoiceDefaultAgent") ?? ""
        }
        set {
            NSUbiquitousKeyValueStore.default.set(newValue, forKey: "liveVoiceDefaultAgent")
            NSUbiquitousKeyValueStore.default.synchronize()
            UserDefaults.standard.set(newValue, forKey: "liveVoiceDefaultAgent")
        }
    }

    /// Per-chat agent ids (assistant chat -> agent id), synced as JSON.
    private func agentMap() -> [String: String] {
        let raw = NSUbiquitousKeyValueStore.default.string(forKey: "liveVoiceAgentMap")
            ?? UserDefaults.standard.string(forKey: "liveVoiceAgentMap") ?? "{}"
        return (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
    }
    func agentId(forChat chatId: Int64) -> String { agentMap()[String(chatId)] ?? "" }
    func setAgentId(_ id: String, forChat chatId: Int64) {
        var map = agentMap()
        map[String(chatId)] = id
        let raw = String(decoding: (try? JSONEncoder().encode(map)) ?? Data("{}".utf8), as: UTF8.self)
        NSUbiquitousKeyValueStore.default.set(raw, forKey: "liveVoiceAgentMap")
        NSUbiquitousKeyValueStore.default.synchronize()
        UserDefaults.standard.set(raw, forKey: "liveVoiceAgentMap")
    }

    // MARK: - Registered agents (from manually-labeled chats)
    //
    // When the gateway roster (agents.list) isn't available, the picker is built
    // from agents the user has designated by labeling chats. id -> display name.

    private func registeredMap() -> [String: String] {
        let raw = NSUbiquitousKeyValueStore.default.string(forKey: "liveVoiceRegisteredAgents")
            ?? UserDefaults.standard.string(forKey: "liveVoiceRegisteredAgents") ?? "{}"
        return (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
    }
    /// (id, name) pairs for the picker, sorted by name.
    var registeredAgents: [(id: String, name: String)] {
        registeredMap().map { ($0.key, $0.value) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
    func registerAgent(id: String, name: String) {
        guard !id.isEmpty else { return }
        var map = registeredMap()
        map[id] = name
        let raw = String(decoding: (try? JSONEncoder().encode(map)) ?? Data("{}".utf8), as: UTF8.self)
        NSUbiquitousKeyValueStore.default.set(raw, forKey: "liveVoiceRegisteredAgents")
        NSUbiquitousKeyValueStore.default.synchronize()
        UserDefaults.standard.set(raw, forKey: "liveVoiceRegisteredAgents")
    }
    func unregisterAgent(id: String) {
        var map = registeredMap()
        map[id] = nil
        let raw = String(decoding: (try? JSONEncoder().encode(map)) ?? Data("{}".utf8), as: UTF8.self)
        NSUbiquitousKeyValueStore.default.set(raw, forKey: "liveVoiceRegisteredAgents")
        NSUbiquitousKeyValueStore.default.synchronize()
        UserDefaults.standard.set(raw, forKey: "liveVoiceRegisteredAgents")
    }

    /// A stable agent id derived from a chat title (e.g. "Nurse Claw 🩺" ->
    /// "nurse-claw"), used as the default when labeling a chat as an agent.
    static func defaultAgentId(fromTitle title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastDash = false
            } else if ch == " " || ch == "-" || ch == "_" {
                if !out.isEmpty && !lastDash { out.append("-"); lastDash = true }
            }
            // emoji/punctuation dropped
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// The agent for the session currently being opened.
    private var activeAgentId: String = ""

    // Auto-stop on silence: ends the session after a stretch with neither the
    // user speaking nor the agent replying (matches how dictation gives up on
    // quiet). Resets on either side making sound, so it won't cut off a reply.
    // Both settings sync phone→watch via iCloud KV.
    var autoStopOnSilence: Bool {
        get {
            let key = backend == .openClaw ? "liveVoiceTalkAutoStop" : "liveVoiceAutoStop"
            return (NSUbiquitousKeyValueStore.default.object(forKey: key) as? Bool)
                ?? (UserDefaults.standard.object(forKey: key) as? Bool) ?? (backend == .custom)
        }
        set {
            let key = backend == .openClaw ? "liveVoiceTalkAutoStop" : "liveVoiceAutoStop"
            NSUbiquitousKeyValueStore.default.set(newValue, forKey: key)
            NSUbiquitousKeyValueStore.default.synchronize()
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
    /// Seconds of silence before auto-stop (clamped 3…30).
    var silenceTimeout: TimeInterval {
        get {
            let stored = (NSUbiquitousKeyValueStore.default.object(forKey: "liveVoiceSilenceTimeout") as? Double)
                ?? (UserDefaults.standard.object(forKey: "liveVoiceSilenceTimeout") as? Double) ?? 8
            return min(30, max(3, stored))
        }
        set {
            let clamped = min(30, max(3, newValue))
            NSUbiquitousKeyValueStore.default.set(clamped, forKey: "liveVoiceSilenceTimeout")
            NSUbiquitousKeyValueStore.default.synchronize()
            UserDefaults.standard.set(clamped, forKey: "liveVoiceSilenceTimeout")
        }
    }
    private let voiceRMSThreshold: Float = 0.02
    private var lastActivityAt = Date()

    /// Appends ?token=…&device=…&agent=… to the configured base endpoint.
    private func connectURL() -> URL? {
        guard var comps = URLComponents(string: effectiveEndpoint),
              comps.scheme?.hasPrefix("ws") == true else { return nil }
        var items = comps.queryItems ?? []
        if !voiceToken.isEmpty { items.append(URLQueryItem(name: "token", value: voiceToken)) }
        items.append(URLQueryItem(name: "device", value: deviceParam))
        if !activeAgentId.isEmpty { items.append(URLQueryItem(name: "agent", value: activeAgentId)) }
        comps.queryItems = items
        return comps.url
    }

    #if os(watchOS)
    // Keeps the app running when the wrist drops so the live session survives
    // (chained self-care extended runtime sessions — same keeper PTT uses).
    private let runtimeSession = PTTRuntimeSession()
    #endif

    // MARK: - Lifecycle

    /// Starts a live session. Pass an agent id to talk to a specific agent
    /// (e.g. from an assistant chat); omit it to use the default agent.
    func start(agentId: String? = nil) {
        guard state == .idle || state == .error else { return }
        stop()
        self.activeAgentId = (agentId?.isEmpty == false ? agentId! : defaultAgentId)
        prepareVoiceSession()
        usesPTTAudioSession = false
        state = .connecting
        #if os(watchOS)
        runtimeSession.start()
        #endif
        let generation = captureGeneration
        requestMicrophoneAccess { [weak self] granted in
            guard let self, self.state == .connecting, self.captureGeneration == generation else { return }
            guard granted else { self.fail("Allow microphone access for ClawWatch in Settings, then try again."); return }
            do {
                try self.configureSession()
                self.openVoiceConnection()
            } catch {
                self.fail("Voice audio setup failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        tearDown(finalState: .idle)
        lastError = nil
        notice = nil
        usesPTTAudioSession = false
        pttAudioActive = false
    }

    private func fail(_ reason: String) {
        lastError = reason
        tearDown(finalState: .error)
    }

    private func tearDown(finalState: State) {
        state = finalState
        socketTimeout?.cancel(); socketTimeout = nil
        stopCapture()
        ws?.close(); ws = nil
        relay?.close(); relay = nil
        // PushToTalk owns activation/deactivation of its audio session.
        if !usesPTTAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #if os(watchOS)
        runtimeSession.stop()
        #endif
    }

    private func stopCapture() {
        captureGeneration = UUID()
        if hasCaptureTap {
            engine.inputNode.removeTap(onBus: 0)
            hasCaptureTap = false
        }
        engine.stop()
        playerNode.stop()
        resetPlayback()
    }

    // MARK: - Push to Talk hooks (iOS)
    //
    // PushToTalk (PTChannelManager) owns the audio session, so these open the
    // socket and drive capture without configuring/activating audio here —
    // the framework calls resume/pause via its didActivate/didDeactivate.

    #if os(iOS)
    /// Open the socket for a PTT channel bound to an agent (no audio yet).
    func pttConnect(agentId: String?) {
        guard ws == nil, relay == nil else { return }
        self.activeAgentId = (agentId?.isEmpty == false ? agentId! : defaultAgentId)
        prepareVoiceSession()
        usesPTTAudioSession = true
        state = .connecting
        lastActivityAt = Date()
        openVoiceConnection()
    }

    /// Start streaming only when both the socket and the system audio session are ready.
    func pttResumeAudio() {
        pttAudioActive = true
        if ws == nil, relay == nil { pttConnect(agentId: activeAgentId) }
        guard usesPTTAudioSession, state == .live else { return }
        do {
            try startCapture()
            lastActivityAt = Date()
        } catch {
            fail("PTT capture failed: \(error)")
        }
    }

    func pttPauseAudio() {
        pttAudioActive = false
        acknowledgeAllMarks()
        stopCapture()
    }

    func pttDisconnect() {
        stop()
    }

    /// The ephemeral PTT push token — hand to the voice server so it can push
    /// us when the agent has audio (background receive).
    func registerPTTPushToken(_ hex: String) {
        // TODO(server): POST to the voice server's PTT push endpoint.
    }
    #endif

    // MARK: - Backend selection

    private func prepareVoiceSession() {
        lastError = nil; notice = nil
        userTranscript = ""; assistantTranscript = ""; activeModel = ""
        sessionBackend = backend
        uploadFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: sessionBackend == .openClaw ? 24000 : 16000,
                                     channels: 1, interleaved: true)!
    }

    private func openVoiceConnection() {
        if sessionBackend == .custom {
            guard let url = connectURL() else { fail("Set a valid custom voice endpoint in Agent settings."); return }
            openSocket(url)
            return
        }
        let node = OpenClawNodeService.shared
        let credential = node.voiceCredential()
        let gatewayIdentity = node.voiceGatewayIdentity
        let connection = OpenClawTalkRelay(agentId: activeAgentId, model: talkModel.modelID) { nonce in
            guard let credential else { return nil }
            return node.voiceConnectParameters(nonce: nonce, credential: credential.value, authField: credential.field)
        }
        relay = connection
        connection.onAuthenticated = { token in node.saveVoiceToken(token, gatewayIdentity: gatewayIdentity) }
        connection.onReady = { [weak self, weak connection] contract in
            guard let self, let connection, self.relay === connection, self.state == .connecting else { return }
            do {
                if !self.usesPTTAudioSession || self.pttAudioActive { try self.startCapture() }
                self.activeModel = contract.model
                self.lastActivityAt = Date()
                self.state = .live
            } catch { self.fail("Voice capture failed: \(error.localizedDescription)") }
        }
        connection.onAudio = { [weak self, weak connection] data in
            guard let self, let connection, self.relay === connection, self.state == .live else { return }
            if !self.usesPTTAudioSession || self.pttAudioActive { self.playIncoming(data) }
        }
        connection.onClear = { [weak self, weak connection] in
            guard let self, let connection, self.relay === connection else { return }
            self.clearPlayback()
        }
        connection.onMark = { [weak self, weak connection] name in
            guard let self, let connection, self.relay === connection else { return }
            guard self.playbackMarks.count < 256 else {
                self.fail("Voice playback acknowledgements fell behind. Please reconnect.")
                return
            }
            self.playbackMarks.append((name, self.scheduledAudio))
            self.acknowledgePlayedMarks()
        }
        connection.onTranscript = { [weak self, weak connection] role, text in
            guard let self, let connection, self.relay === connection else { return }
            self.notice = nil
            if role == "user" { self.userTranscript = text }
            if role == "assistant" { self.assistantTranscript = text }
        }
        connection.onError = { [weak self, weak connection] reason in
            guard let self, let connection, self.relay === connection else { return }
            self.fail(reason)
        }
        connection.onNotice = { [weak self, weak connection] message in
            guard let self, let connection, self.relay === connection else { return }
            self.notice = message
        }
        connection.onEnded = { [weak self, weak connection] in
            guard let self, let connection, self.relay === connection else { return }
            if let notice = self.notice { self.fail(notice) }
            else { self.stop() }
        }
        connection.start { [weak self, weak connection] client in
            node.connectVoiceGateway(client, isCurrent: {
                guard let self, let connection else { return false }
                return self.relay === connection && self.state == .connecting
            }, failure: { reason in
                guard let self, let connection, self.relay === connection else { return }
                self.fail(reason)
            })
        }
    }

    // MARK: - Audio

    private func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        #if os(watchOS)
        // watchOS routes to the watch speaker / paired BT automatically;
        // the iOS-only routing options aren't available here.
        try session.setCategory(.playAndRecord, mode: .voiceChat)
        #else
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                 options: [.defaultToSpeaker, .allowBluetoothHFP])
        #endif
        try session.setActive(true)
    }

    private func startCapture() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        // Echo cancellation (+ noise suppression / AGC): keeps the agent's
        // own voice out of the mic so barge-in triggers on the user, not the
        // speaker. Must be set before the engine starts. Full-duplex — no
        // need for the server's CW_BARGE_IN=0 half-duplex fallback.
        try? input.setVoiceProcessingEnabled(true)

        if playerNode.engine == nil {
            engine.attach(playerNode)
            try engine.connectNode(
                playerNode,
                to: engine.mainMixerNode,
                format: playbackFormat
            )
        }

        let inputFormat = input.outputFormat(forBus: 0)
        let targetFormat = uploadFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "ClawWatchVoice", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The microphone audio format is unavailable."])
        }
        if hasCaptureTap { input.removeTap(onBus: 0); hasCaptureTap = false }
        captureGeneration = UUID()
        let generation = captureGeneration
        try input.__installTap(
            onBus: 0,
            bufferSize: sessionBackend == .openClaw ? 2048 : 4096,
            format: inputFormat,
            error: ()
        ) { [weak self] buffer, _ in
            self?.sendCaptured(buffer, converter: converter, format: targetFormat, generation: generation)
        }
        hasCaptureTap = true
        engine.prepare()
        try engine.start()
        try playerNode.playAudio()
    }

    private func sendCaptured(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                              format: AVAudioFormat, generation: UUID) {
        let isSpeaking = rms(of: buffer) > voiceRMSThreshold
        guard let converted = convert(buffer, using: converter, to: format),
              let data = pcmData(from: converted) else { return }
        // State and the silence clock are shared with socket callbacks on main.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state == .live, self.captureGeneration == generation else { return }
            if self.autoStopOnSilence {
                if isSpeaking {
                    self.lastActivityAt = Date()
                } else if !self.isSpeaking, Date().timeIntervalSince(self.lastActivityAt) > self.silenceTimeout {
                    self.logger.log("Auto-stopping: \(Int(self.silenceTimeout))s of silence")
                    self.stop()
                    return
                }
            }
            if self.sessionBackend == .openClaw { self.relay?.appendAudio(data) }
            else { self.ws?.sendData(data) }
        }
    }

    /// Root-mean-square level of a capture buffer (0…1), for silence detection.
    private func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        if let ch = buffer.floatChannelData {
            let p = ch[0]
            for i in 0..<frames { sum += p[i] * p[i] }
        } else if let ch = buffer.int16ChannelData {
            let p = ch[0]
            for i in 0..<frames { let v = Float(p[i]) / 32768; sum += v * v }
        } else {
            return 0
        }
        return (sum / Float(frames)).squareRoot()
    }

    /// Open the WebSocket (Network.framework) and wire incoming audio.
    private func openSocket(_ url: URL) {
        let client = WSClient()
        ws = client
        client.onOpen = { [weak self, weak client] in
            guard let self, let client, self.ws === client, self.state == .connecting else { return }
            self.socketTimeout?.cancel(); self.socketTimeout = nil
            do {
                if !self.usesPTTAudioSession || self.pttAudioActive { try self.startCapture() }
                self.lastActivityAt = Date()
                self.state = .live
            } catch {
                self.fail("Voice capture failed: \(error)")
            }
        }
        client.onData = { [weak self, weak client] data in
            guard let self, let client, self.ws === client, self.state == .live else { return }
            if !self.usesPTTAudioSession || self.pttAudioActive { self.playIncoming(data) }
        }
        client.onClose = { [weak self, weak client] reason in
            guard let self, let client, self.ws === client else { return }
            self.fail("Voice socket closed: \(reason ?? "connection closed")")
        }
        client.onWaiting = { [weak self, weak client] reason in
            guard let self, let client, self.ws === client else { return }
            self.fail("Voice connection unavailable: \(reason)")
        }
        let timeout = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client, self.ws === client, self.state == .connecting else { return }
            self.fail("Voice connection timed out")
        }
        socketTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        client.connect(url: url, headers: cfHeaders)
    }

    private func playIncoming(_ data: Data) {
        guard data.count.isMultiple(of: 2), let buffer = pcmBuffer(from: data, format: playbackFormat) else { return }
        guard queuedAudioBytes + data.count <= 2_880_000 else {
            fail("Voice playback fell behind. End the call and try again.")
            return
        }
        // GPT-Live can send continuous silent PCM. Only audible output resets silence.
        let audible = rms(of: buffer) > 0.002
        if audible { lastActivityAt = Date(); queuedAudibleBuffers += 1 }
        scheduledAudio += 1
        let sequence = scheduledAudio
        let generation = playbackGeneration
        queuedAudioBytes += data.count
        isSpeaking = queuedAudibleBuffers > 0
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == generation else { return }
                self.queuedAudioBytes -= data.count
                self.playedAudio = max(self.playedAudio, sequence)
                if audible { self.queuedAudibleBuffers -= 1; self.lastActivityAt = Date() }
                self.isSpeaking = self.queuedAudibleBuffers > 0
                self.acknowledgePlayedMarks()
            }
        }
    }

    private func acknowledgePlayedMarks() {
        let marks = playbackMarks.filter { $0.after <= playedAudio }
        playbackMarks.removeAll { $0.after <= playedAudio }
        for mark in marks { relay?.acknowledgeMark(mark.name) }
    }

    private func acknowledgeAllMarks() {
        for mark in playbackMarks { relay?.acknowledgeMark(mark.name) }
        playbackMarks.removeAll()
    }

    private func resetPlayback() {
        playbackGeneration = UUID()
        queuedAudioBytes = 0; scheduledAudio = 0; playedAudio = 0
        queuedAudibleBuffers = 0
        playbackMarks.removeAll()
        isSpeaking = false
    }

    private func clearPlayback() {
        playerNode.stop()
        acknowledgeAllMarks()
        resetPlayback()
        if engine.isRunning {
            do { try playerNode.playAudio() }
            catch { fail("Could not resume voice playback.") }
        }
    }

    // MARK: - PCM helpers

    private func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
                         to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var fed = false
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    private func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let ch = buffer.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(buffer.frameLength) * 2)
    }

    private func pcmBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let dst = buffer.int16ChannelData {
                dst[0].update(from: base.assumingMemoryBound(to: Int16.self), count: Int(frames))
            }
        }
        return buffer
    }
}
