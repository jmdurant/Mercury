//
//  SendMessageViewModel.swift
//  Mercury Watch App
//
//  Created by Marco Tammaro on 28/05/24.
//

import Foundation
import TDLibKit
import SwiftOGG
import UIKit

/// Handles taps on inline-keyboard buttons the agent/bot attaches to a
/// message, turning the chat into an interactive agent UI.
enum InlineButtonService {

    private static let logger = LoggerService(String(describing: InlineButtonService.self))

    /// Rows of buttons on a message, if any.
    static func buttons(for message: Message) -> [[InlineKeyboardButton]] {
        guard case .replyMarkupInlineKeyboard(let kb) = message.replyMarkup else { return [] }
        return kb.rows
    }

    /// Perform a button tap. Returns the bot's answer text (a toast) for
    /// callback buttons, nil for URL buttons (which just open).
    @discardableResult
    static func tap(_ button: InlineKeyboardButton, chatId: Int64, messageId: Int64) async -> String? {
        switch button.type {
        case .inlineKeyboardButtonTypeCallback(let cb):
            do {
                let answer = try await TDLibManager.shared.client?.getCallbackQueryAnswer(
                    chatId: chatId,
                    messageId: messageId,
                    payload: .callbackQueryPayloadData(.init(data: cb.data))
                )
                return answer?.text
            } catch {
                logger.log(error, level: .error)
                return nil
            }
        case .inlineKeyboardButtonTypeUrl(let u):
            if let url = URL(string: u.url) {
                await SystemActionService.open(url)
            }
            return nil
        default:
            return nil
        }
    }
}

/// Disappearing-messages presets (chat auto-delete timer), matching
/// Telegram's standard options. Value is seconds; 0 = off.
enum AutoDeleteOption: Int, CaseIterable, Identifiable {
    case off = 0
    case oneDay = 86400
    case oneWeek = 604800
    case oneMonth = 2678400

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .oneDay: return "1 Day"
        case .oneWeek: return "1 Week"
        case .oneMonth: return "1 Month"
        }
    }

    /// Nearest preset for an arbitrary server value (custom timers round down)
    static func from(seconds: Int) -> AutoDeleteOption {
        allCases.last { $0.rawValue <= seconds } ?? .off
    }
}

class SendMessageService {

    let chat: Chat?
    let logger: LoggerService

    init(chat: Chat?) {
        self.chat = chat
        self.logger = LoggerService(SendMessageService.self)
    }

    /// Sets the chat's disappearing-messages timer (auto-delete). 0 turns it off.
    func setAutoDeleteTime(_ seconds: Int) {
        guard let chatId = chat?.id else { return }
        Task.detached {
            do {
                let result = try await TDLibManager.shared.client?.setChatMessageAutoDeleteTime(
                    chatId: chatId,
                    messageAutoDeleteTime: seconds
                )
                self.logger.log(result)
            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }

    func sendTextMessage(_ text: String) {
        
        let formattedText: FormattedText = .init(entities: [], text: text)
        let message: InputMessageText = .init(clearDraft: true, linkPreviewOptions: nil, text: formattedText)
        let messageContent: InputMessageContent = .inputMessageText(message)
        
        Task.detached {
            do {
                let result = try await TDLibManager.shared.client?.sendMessage(
                    chatId: self.chat?.id,
                    inputMessageContent: messageContent,
                    options: nil,
                    replyMarkup: nil,
                    replyTo: nil,
                    topicId: nil
                )
                self.logger.log(result)
            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }
    
    func sendReply(_ text: String, toMessageId messageId: Int64) {

        let formattedText: FormattedText = .init(entities: [], text: text)
        let message: InputMessageText = .init(clearDraft: true, linkPreviewOptions: nil, text: formattedText)
        let messageContent: InputMessageContent = .inputMessageText(message)
        let replyTo: InputMessageReplyTo = .inputMessageReplyToMessage(
            .init(checklistTaskId: 0, messageId: messageId, quote: nil)
        )

        Task.detached {
            do {
                let result = try await TDLibManager.shared.client?.sendMessage(
                    chatId: self.chat?.id,
                    inputMessageContent: messageContent,
                    options: nil,
                    replyMarkup: nil,
                    replyTo: replyTo,
                    topicId: nil
                )
                self.logger.log(result)
            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }

    func sendVoiceNote(_ filePath: URL, _ duration: Int, didProcessAudio: @escaping () -> Void) {
        
        Task.detached {
            do {
                
                var audioFilePath = filePath
                
                // if audio file format is m4a, convert to ogg for faster upload
                if audioFilePath.pathExtension == "m4a" {
                    let dest: URL = audioFilePath.deletingPathExtension().appendingPathExtension("ogg")
                    
                    // Check if file has been already converted
                    if !FileManager.default.fileExists(atPath: dest.absoluteString) {
                        try OGGConverter.convertM4aFileToOpusOGG(src: audioFilePath, dest: dest)
                    }
                    
                    audioFilePath = dest
                }
                
                let audioFile: InputFile = .inputFileLocal(.init(path: audioFilePath.relativePath))
                let audioWaveform = try Data(contentsOf: filePath)
                
                let audio: InputMessageVoiceNote = .init(
                    caption: nil,
                    duration: duration,
                    selfDestructType: nil,
                    voiceNote: audioFile,
                    waveform: audioWaveform
                )
                
                didProcessAudio()

                let result = try await TDLibManager.shared.client?.sendMessage(
                    chatId: self.chat?.id,
                    inputMessageContent: .inputMessageVoiceNote(audio),
                    options: nil,
                    replyMarkup: nil,
                    replyTo: nil,
                    topicId: nil
                )

                self.logger.log(result)

                // Clean up voice recording files after sending
                try? FileManager.default.removeItem(at: filePath)
                if audioFilePath != filePath {
                    try? FileManager.default.removeItem(at: audioFilePath)
                }

            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }
    
    #if os(watchOS)
    // StickerModel is a watch-only presentation type; the iOS app has no
    // sticker picker yet
    func sendSticker(_ model: StickerModel) {
        guard let sticker = model.sticker else { return }
        Task.detached {
            do {
                let result = try await TDLibManager.shared.client?.sendMessage(
                    chatId: self.chat?.id,
                    inputMessageContent: .from(sticker: sticker),
                    options: nil,
                    replyMarkup: nil,
                    replyTo: nil,
                    topicId: nil
                )

                self.logger.log(result)

            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }
    #endif
    
    func sendPhoto(fileURL: URL, caption: String = "") {
        let photo: InputMessagePhoto = .init(
            addedStickerFileIds: [],
            caption: caption.isEmpty ? nil : FormattedText(entities: [], text: caption),
            hasSpoiler: false,
            height: 0,
            photo: .inputFileLocal(.init(path: fileURL.path)),
            selfDestructType: nil,
            showCaptionAboveMedia: false,
            thumbnail: nil,
            width: 0
        )
        let messageContent: InputMessageContent = .inputMessagePhoto(photo)

        Task.detached {
            do {
                let result = try await TDLibManager.shared.client?.sendMessage(
                    chatId: self.chat?.id,
                    inputMessageContent: messageContent,
                    options: nil,
                    replyMarkup: nil,
                    replyTo: nil,
                    topicId: nil
                )
                self.logger.log(result)
                // Clean up the temp copy the picker wrote
                try? FileManager.default.removeItem(at: fileURL)
            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }

    func sendLocation(latitude: Double, longitude: Double) {
        let location = InputMessageLocation(
            heading: 0,
            livePeriod: 0,
            location: Location(
                horizontalAccuracy: 0,
                latitude: latitude,
                longitude: longitude
            ),
            proximityAlertRadius: 0
        )
        let messageContent: InputMessageContent = .inputMessageLocation(location)

        Task.detached {
            do {
                let result = try await TDLibManager.shared.client?.sendMessage(
                    chatId: self.chat?.id,
                    inputMessageContent: messageContent,
                    options: nil,
                    replyMarkup: nil,
                    replyTo: nil,
                    topicId: nil
                )
                self.logger.log(result)
            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }

    func sendReaction(_ emoji: String, chatId: Int64, messageId: Int64) {
        
        Task.detached {
            do {
                
                let emoji = ReactionTypeEmoji(emoji: emoji)
                let reaction: ReactionType = .reactionTypeEmoji(emoji)
                
                let result = try await TDLibManager.shared.client?.addMessageReaction(
                    chatId: chatId,
                    isBig: false,
                    messageId: messageId,
                    reactionType: reaction,
                    updateRecentReactions: false
                )
                
                self.logger.log(result)
                
            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }

    static func sendToContact(name: String, text: String) async throws {
        guard let users = try await TDLibManager.shared.client?.searchContacts(
            limit: 1,
            query: name
        ), let userId = users.userIds.first else {
            throw MercurySendError.contactNotFound
        }

        guard let chat = try await TDLibManager.shared.client?.createPrivateChat(
            force: false,
            userId: userId
        ) else {
            throw MercurySendError.chatCreationFailed
        }

        let formattedText = FormattedText(entities: [], text: text)
        let message = InputMessageText(clearDraft: true, linkPreviewOptions: nil, text: formattedText)
        let _ = try await TDLibManager.shared.client?.sendMessage(
            chatId: chat.id,
            inputMessageContent: .inputMessageText(message),
            options: nil,
            replyMarkup: nil,
            replyTo: nil,
            topicId: nil
        )
    }

    // Swift.Error explicitly: TDLibKit declares its own `Error` type,
    // which would otherwise be picked up as a raw type here
    enum MercurySendError: Swift.Error, LocalizedError {
        case contactNotFound
        case chatCreationFailed

        var errorDescription: String? {
            switch self {
            case .contactNotFound: return "Contact not found"
            case .chatCreationFailed: return "Could not open chat"
            }
        }
    }

    static func sendQuickReply(text: String, chatId: Int64) {
        let logger = LoggerService(SendMessageService.self)
        let formattedText = FormattedText(entities: [], text: text)
        let message = InputMessageText(clearDraft: true, linkPreviewOptions: nil, text: formattedText)
        let messageContent: InputMessageContent = .inputMessageText(message)

        Task.detached {
            do {
                let result = try await TDLibManager.shared.client?.sendMessage(
                    chatId: chatId,
                    inputMessageContent: messageContent,
                    options: nil,
                    replyMarkup: nil,
                    replyTo: nil,
                    topicId: nil
                )
                logger.log(result)
            } catch {
                logger.log(error, level: .error)
            }
        }
    }
}

#if os(watchOS)
// Mock drives SwiftUI previews via watch-only presentation models
class SendMessageServiceMock: SendMessageService {
    let onSendMessage: (MessageModel.MessageContent) -> Void

    init(_ onSendMessage: @escaping (MessageModel.MessageContent) -> Void) {
        self.onSendMessage = onSendMessage
        super.init(chat: nil)
    }

    override func sendTextMessage(_ text: String) {
        self.onSendMessage(.text(AttributedString(text)))
    }

    override func sendVoiceNote(_ filePath: URL, _ duration: Int, didProcessAudio: @escaping () -> Void) {
        didProcessAudio()
        self.onSendMessage(.voiceNote(model: VoiceNoteModel(getPlayer: {
            return PlayerServiceMock()
        })))
    }

    override func sendSticker(_ sticker: StickerModel) {
        self.onSendMessage(.stickerImage(model: .init(emoji: "😃", getImage: sticker.getImage)))
    }
    override func sendReaction(_ emoji: String, chatId: Int64, messageId: Int64) {}
}
#endif
