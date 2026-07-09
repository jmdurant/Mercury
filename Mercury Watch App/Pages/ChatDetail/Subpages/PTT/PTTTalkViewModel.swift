//
//  PTTTalkViewModel.swift
//  Mercury Watch App
//
//  Created on 09/07/26.
//

import Foundation
import SwiftUI
import AVFoundation

@Observable
class PTTTalkViewModel {

    enum TalkState {
        case idle, recording, sending
    }

    var state: TalkState = .idle
    var isAutoPlayOn: Bool
    var hasPermission: Bool = true

    /// Releases shorter than this are treated as accidental taps
    static let minimumDuration: TimeInterval = 0.5

    let chatId: Int64
    let sendService: SendMessageService

    private var recorder: RecorderService?
    private var filePath: URL?
    private let logger = LoggerService(PTTTalkViewModel.self)

    init(chatId: Int64, sendService: SendMessageService) {
        self.chatId = chatId
        self.sendService = sendService
        self.isAutoPlayOn = PTTStore.isPTTChat(chatId)
    }

    func onAppear() async {
        hasPermission = await AVAudioApplication.requestRecordPermission()
    }

    func toggleAutoPlay(_ enabled: Bool) {
        isAutoPlayOn = enabled
        PTTStore.setPTTChat(chatId, enabled: enabled)
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
        recorder = nil
        filePath = nil
    }
}
