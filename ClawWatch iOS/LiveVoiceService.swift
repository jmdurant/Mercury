//
//  LiveVoiceService.swift
//  ClawWatch iOS
//
//  Live full-duplex voice channel to a realtime agent endpoint: mic →
//  16 kHz PCM → WebSocket, and 24 kHz PCM ← WebSocket → speaker. The
//  endpoint (wss://) is configurable; point it at a LiveKit/Gemini-Live
//  gateway or a realtime provider that speaks raw PCM over a socket.
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

    static let shared = LiveVoiceService()

    var state: State = .idle
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

    /// The voice server port on the gateway box (single-box default).
    static let voicePort = 8795

    /// The endpoint actually dialed. Defaults to the node's gateway host on the
    /// voice port (same box) so voice works out of the box; `endpoint` is an
    /// explicit override when the voice server lives elsewhere (e.g. a split
    /// Cloudflare hostname). Both the override and the node URL sync via iCloud.
    var effectiveEndpoint: String {
        if !endpoint.isEmpty { return endpoint }
        return Self.voiceURL(fromGateway: OpenClawNodeService.shared.gatewayURL) ?? ""
    }

    /// Derive `ws[s]://host:8790` from the node's gateway URL (same scheme+host).
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
    private var cfHeaders: [(String, String)] {
        CloudflareAccess.isConfigured
            ? [("CF-Access-Client-Id", CloudflareAccess.clientId),
               ("CF-Access-Client-Secret", CloudflareAccess.clientSecret)]
            : []
    }
    private let logger = LoggerService(LiveVoiceService.self)

    private let uploadFormat = AVAudioFormat(
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

    /// The agent for the session currently being opened.
    private var activeAgentId: String = ""

    // Auto-stop on silence: ends the session after a stretch with neither the
    // user speaking nor the agent replying (matches how dictation gives up on
    // quiet). Resets on either side making sound, so it won't cut off a reply.
    // Both settings sync phone→watch via iCloud KV.
    var autoStopOnSilence: Bool {
        get {
            (NSUbiquitousKeyValueStore.default.object(forKey: "liveVoiceAutoStop") as? Bool)
                ?? (UserDefaults.standard.object(forKey: "liveVoiceAutoStop") as? Bool) ?? true
        }
        set {
            NSUbiquitousKeyValueStore.default.set(newValue, forKey: "liveVoiceAutoStop")
            NSUbiquitousKeyValueStore.default.synchronize()
            UserDefaults.standard.set(newValue, forKey: "liveVoiceAutoStop")
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
        self.activeAgentId = (agentId?.isEmpty == false ? agentId! : defaultAgentId)
        guard state == .idle, let url = connectURL() else {
            state = .error
            return
        }
        state = .connecting
        #if os(watchOS)
        runtimeSession.start()   // survive wrist-down for the session
        #endif
        configureSession()

        openSocket(url)

        do {
            try startCapture()
            lastActivityAt = Date()
            state = .live
        } catch {
            logger.log("Voice capture failed: \(error)", level: .error)
            state = .error
            stop()
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        playerNode.stop()
        ws?.close()
        ws = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #if os(watchOS)
        runtimeSession.stop()
        #endif
        state = .idle
    }

    // MARK: - Push to Talk hooks (iOS)
    //
    // PushToTalk (PTChannelManager) owns the audio session, so these open the
    // socket and drive capture without configuring/activating audio here —
    // the framework calls resume/pause via its didActivate/didDeactivate.

    #if os(iOS)
    /// Open the socket for a PTT channel bound to an agent (no audio yet).
    func pttConnect(agentId: String?) {
        self.activeAgentId = (agentId?.isEmpty == false ? agentId! : defaultAgentId)
        guard ws == nil, let url = connectURL() else { return }
        openSocket(url)
        state = .live
    }

    /// Start streaming the mic — the PTT audio session is already active.
    func pttResumeAudio() {
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)
        if playerNode.engine == nil {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
        }
        let inputFormat = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.sendCaptured(buffer)
        }
        engine.prepare()
        try? engine.start()
        playerNode.play()
    }

    /// Stop streaming the mic (transmission ended / session deactivated).
    func pttPauseAudio() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        playerNode.stop()
    }

    func pttDisconnect() {
        pttPauseAudio()
        ws?.close()
        ws = nil
        state = .idle
    }

    /// The ephemeral PTT push token — hand to the voice server so it can push
    /// us when the agent has audio (background receive).
    func registerPTTPushToken(_ hex: String) {
        logger.log("PTT ephemeral push token: \(hex)")
        // TODO(server): POST to the voice server's PTT push endpoint.
    }
    #endif

    // MARK: - Audio

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        #if os(watchOS)
        // watchOS routes to the watch speaker / paired BT automatically;
        // the iOS-only routing options aren't available here.
        try? session.setCategory(.playAndRecord, mode: .voiceChat)
        #else
        try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        #endif
        try? session.setActive(true)
    }

    private func startCapture() throws {
        let input = engine.inputNode
        // Echo cancellation (+ noise suppression / AGC): keeps the agent's
        // own voice out of the mic so barge-in triggers on the user, not the
        // speaker. Must be set before the engine starts. Full-duplex — no
        // need for the server's CW_BARGE_IN=0 half-duplex fallback.
        try? input.setVoiceProcessingEnabled(true)

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

        let inputFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.sendCaptured(buffer)
        }
        engine.prepare()
        try engine.start()
        playerNode.play()
    }

    private func sendCaptured(_ buffer: AVAudioPCMBuffer) {
        if autoStopOnSilence {
            if rms(of: buffer) > voiceRMSThreshold {
                lastActivityAt = Date()
            } else if Date().timeIntervalSince(lastActivityAt) > silenceTimeout {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.state == .live else { return }
                    self.logger.log("Auto-stopping: \(Int(self.silenceTimeout))s of silence")
                    self.stop()
                }
                return
            }
        }
        guard let converted = convert(buffer, to: uploadFormat),
              let data = pcmData(from: converted) else { return }
        ws?.sendData(data)
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
        client.onData = { [weak self] data in self?.playIncoming(data) }
        client.onClose = { [weak self] reason in
            guard let self, self.state != .idle else { return }
            if let reason { self.logger.log("Voice socket closed: \(reason)", level: .error) }
            self.state = .error
        }
        client.connect(url: url, headers: cfHeaders)
    }

    private func playIncoming(_ data: Data) {
        guard let buffer = pcmBuffer(from: data, format: playbackFormat) else { return }
        lastActivityAt = Date()   // agent is replying — not silence
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - PCM helpers

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
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
