//
//  PTTTalkViewModel.swift
//  Mercury Watch App
//
//  Created on 09/07/26.
//

import Foundation
import SwiftUI
import AVFoundation
import CoreMotion

@Observable
class PTTTalkViewModel {

    enum TalkState {
        case idle, recording, sending
    }

    var state: TalkState = .idle
    var isAutoPlayOn: Bool
    var isLiftToSpeakOn: Bool
    var isWristRecording: Bool = false
    var hasPermission: Bool = true

    /// Releases shorter than this are treated as accidental taps
    static let minimumDuration: TimeInterval = 0.5

    /// Wrist lower waits this long before sending, so a brief tilt or
    /// glance doesn't cut the message; a raise before it fires cancels
    static let wristLowerDebounce: TimeInterval = 1.0

    let chatId: Int64
    let sendService: SendMessageService

    private var recorder: RecorderService?
    private var filePath: URL?
    private let logger = LoggerService(PTTTalkViewModel.self)

    private let motionManager = CMMotionManager()
    // Starts true so opening the screen wrist-up doesn't immediately
    // record; the first lower→raise transition arms it
    private var wristIsUp = true
    private var wristLowerWork: DispatchWorkItem?

    init(chatId: Int64, sendService: SendMessageService) {
        self.chatId = chatId
        self.sendService = sendService
        self.isAutoPlayOn = PTTStore.isPTTChat(chatId)
        self.isLiftToSpeakOn = PTTStore.isLiftToSpeakEnabled
    }

    func onAppear() async {
        hasPermission = await AVAudioApplication.requestRecordPermission()
        if isLiftToSpeakOn {
            await MainActor.run { startWristMonitoring() }
        }
    }

    func onDisappear() {
        stopWristMonitoring()
        if state == .recording {
            stopTalking()
        }
    }

    func toggleAutoPlay(_ enabled: Bool) {
        isAutoPlayOn = enabled
        PTTStore.setPTTChat(chatId, enabled: enabled)
    }

    func toggleLiftToSpeak(_ enabled: Bool) {
        isLiftToSpeakOn = enabled
        PTTStore.isLiftToSpeakEnabled = enabled
        if enabled {
            startWristMonitoring()
        } else {
            stopWristMonitoring()
        }
    }

    // MARK: - Lift to Speak (wrist gate)

    private func startWristMonitoring() {
        guard motionManager.isDeviceMotionAvailable else { return }
        // gravity.z < -0.5 = watch face toward the user; same threshold
        // and cadence as SameDayClt's Dick Tracy mode
        motionManager.deviceMotionUpdateInterval = 0.3
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else { return }
            let isUp = gravity.z < -0.5
            guard isUp != self.wristIsUp else { return }
            self.wristIsUp = isUp
            if isUp {
                self.wristRaised()
            } else {
                self.wristLowered()
            }
        }
    }

    private func stopWristMonitoring() {
        motionManager.stopDeviceMotionUpdates()
        wristLowerWork?.cancel()
        wristLowerWork = nil
    }

    private func wristRaised() {
        wristLowerWork?.cancel()
        wristLowerWork = nil
        guard state == .idle else { return }
        startTalking()
        isWristRecording = (state == .recording)
    }

    private func wristLowered() {
        // Only a wrist-started recording is wrist-stopped; a recording
        // held by button stays under the button's control
        guard isWristRecording, state == .recording else { return }
        wristLowerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isWristRecording, self.state == .recording else { return }
            self.stopTalking()
        }
        wristLowerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wristLowerDebounce, execute: work)
    }

    func startTalking() {
        guard state == .idle, hasPermission else { return }

        let recName = "\(UUID().uuidString).m4a"
        let path = FileManager.default.tmpFolder.appendingPathComponent(recName)
        let recorder = RecorderService(recFilePath: path)

        self.filePath = path
        self.recorder = recorder

        recorder.initAudioRecorder()
        recorder.startRecordingAudio()
        HapticService.pttTalkStarted()
        state = .recording
    }

    func stopTalking() {
        guard state == .recording, let recorder, let filePath else { return }
        recorder.stopRecordingAudio()

        let duration = recorder.elapsedTime
        guard duration >= Self.minimumDuration else {
            HapticService.actionFailed()
            try? FileManager.default.removeItem(at: filePath)
            reset()
            return
        }

        state = .sending
        sendService.sendVoiceNote(filePath, Int(duration)) {
            DispatchQueue.main.async {
                HapticService.messageSent()
                self.reset()
            }
        }
    }

    private func reset() {
        state = .idle
        isWristRecording = false
        recorder = nil
        filePath = nil
    }
}
