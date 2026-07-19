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

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var socket: URLSessionWebSocketTask?
    private let logger = LoggerService(LiveVoiceService.self)

    private let uploadFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!

    // MARK: - Lifecycle

    func start() {
        guard state == .idle, let url = URL(string: endpoint), url.scheme?.hasPrefix("ws") == true else {
            state = .error
            return
        }
        state = .connecting
        configureSession()

        socket = URLSession(configuration: .default).webSocketTask(with: url)
        socket?.resume()
        receiveLoop()

        do {
            try startCapture()
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
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
    }

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
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.sendCaptured(buffer)
        }
        engine.prepare()
        try engine.start()
        playerNode.play()
    }

    private func sendCaptured(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer, to: uploadFormat),
              let data = pcmData(from: converted) else { return }
        socket?.send(.data(data)) { [weak self] error in
            if let error { self?.logger.log("Voice send: \(error)", level: .error) }
        }
    }

    private func receiveLoop() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let data)):
                self.playIncoming(data)
            case .success(.string):
                break
            case .failure(let error):
                self.logger.log("Voice receive: \(error)", level: .error)
                self.state = .error
                return
            @unknown default:
                break
            }
            if self.state != .idle { self.receiveLoop() }
        }
    }

    private func playIncoming(_ data: Data) {
        guard let buffer = pcmBuffer(from: data, format: playbackFormat) else { return }
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
