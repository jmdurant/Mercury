//
//  PTTService.swift
//  Mercury Watch App
//
//  Created on 09/07/26.
//

import Foundation
import TDLibKit
import AVFoundation

/// Walkie-talkie receive path: auto-plays incoming voice notes
/// from PTT-designated chats, one at a time, oldest first.
class PTTService: NSObject, TDLibManagerProtocol {

    private let logger = LoggerService(PTTService.self)

    private var queue: [Message] = []
    private var isPlaying = false
    private var player: PlayerService?

    override init() {
        super.init()
        TDLibManager.shared.subscribe(self)
    }

    deinit {
        TDLibManager.shared.unsubscribe(self)
    }

    func updateHandler(update: Update) {
        guard case .updateNewMessage(let msg) = update else { return }
        let message = msg.message

        guard !message.isOutgoing,
              PTTStore.isAutoPlayEnabled,
              PTTStore.isPTTChat(message.chatId),
              case .messageVoiceNote = message.content
        else { return }

        DispatchQueue.main.async {
            self.queue.append(message)
            self.playNextIfIdle()
        }
    }

    func connectionStateUpdate(state: ConnectionState) {}
    func authorizationStateUpdate(state: AuthorizationState) {}

    private func playNextIfIdle() {
        guard !isPlaying, !queue.isEmpty else { return }
        let message = queue.removeFirst()
        isPlaying = true

        Task { @MainActor in
            guard case .messageVoiceNote(let content) = message.content,
                  let file = await FileService.getFilePath(for: content.voiceNote.voice),
                  let player = try? PlayerService(audioFilePath: file, delegate: self)
            else {
                self.logger.log("Could not play PTT voice note from chat \(message.chatId)", level: .error)
                self.isPlaying = false
                self.playNextIfIdle()
                return
            }

            HapticService.pttReceived()
            self.player = player
            player.startPlayingAudio()
            self.markListened(message)
            self.logger.log("Auto-playing PTT voice note from chat \(message.chatId)")
        }
    }

    private func markListened(_ message: Message) {
        Task {
            do {
                try await TDLibManager.shared.client?.viewMessages(
                    chatId: message.chatId,
                    forceRead: true,
                    messageIds: [message.id],
                    source: nil
                )
                try await TDLibManager.shared.client?.openMessageContent(
                    chatId: message.chatId,
                    messageId: message.id
                )
            } catch {
                logger.log(error, level: .error)
            }
        }
    }
}

extension PTTService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.player?.cleanupAudioFile()
            self.player = nil
            self.isPlaying = false
            self.playNextIfIdle()
        }
    }
}
