//
//  MessageOptionsViewModel.swift
//  Mercury Watch App
//
//  Created by Alessandro Alberti on 11/09/24.
//

import SwiftUI
import TDLibKit

@Observable
class MessageOptionsViewModel {
    
    var emojis: [String] = []
    var selectedEmoji: String? = nil
    var showReportMessageOptions: Bool = false
    var showDeleteConfirmation: Bool = false
    var showMessageInfo: Bool = false
    var canDeleteForEveryone: Bool = false
    var onReply: (() -> Void)?
    var messageInfo: MessageInfoData?
    var shareText: String?
    var shareImage: UIImage?
    var shareFileURL: URL?
    var showShareSheet: Bool = false
    
    var shouldDisplayReportButton: Bool {
        if case .chatTypeBasicGroup(_) = model.chatType { return true }
        if case .chatTypeSupergroup(_) = model.chatType { return true }
        return false
    }
    
    let model: MessageOptionsModel
    let reportMessageOptions: [ReportReason] = [.reportReasonSpam, .reportReasonViolence, .reportReasonPornography, .reportReasonChildAbuse, .reportReasonCopyright, .reportReasonUnrelatedLocation, .reportReasonFake, .reportReasonIllegalDrugs, .reportReasonPersonalDetails]
    
    private let logger = LoggerService(MessageOptionsViewModel.self)
    
    init(model: MessageOptionsModel, onReply: (() -> Void)? = nil) {
        self.model = model
        self.onReply = onReply
        Task.detached(priority: .high) {
            await self.getReactions()
            await self.getSelectedEmoji()
            await self.checkCanDelete()
        }
    }
    
    fileprivate func getReactions() async {
        
        let chatId = model.chatId
        let messageId = model.messageId
        
        let reactions = try? await TDLibManager.shared.client?.getMessageAvailableReactions(
            chatId: chatId,
            messageId: messageId,
            rowSize: 4
        )
        
        let availableEmojis = reactions?.topReactions.map { reaction in
            if case .reactionTypeEmoji(let emojiReaction) = reaction.type {
                return emojiReaction.emoji
            }
            return "?"
        }
        
        await MainActor.run {
            self.emojis = availableEmojis ?? []
        }
    }
    
    fileprivate func getSelectedEmoji() async {
        
        let chatId = model.chatId
        let messageId = model.messageId
        
        do {
            
            guard let message = try await TDLibManager.shared.client?.getMessage(
                chatId: chatId,
                messageId: messageId
            ) else { return }
            
            let reactions = message.interactionInfo?.reactions?.reactions
            let chosenReaction =  reactions?.first(where: { $0.isChosen })
            
            if case .reactionTypeEmoji(let type) = chosenReaction?.type {
                await MainActor.run {
                    self.selectedEmoji = type.emoji
                }
            }
            
        } catch {
            self.logger.log(error, level: .error)
        }
    }
    
    func sendReaction(_ emoji: String) async {
        
        let chatId = model.chatId
        let messageId = model.messageId
        
        WKInterfaceDevice.current().play(.click)
        await MainActor.run {
            self.selectedEmoji = emoji
        }
        
        model.sendService.sendReaction(
            emoji,
            chatId: chatId,
            messageId: messageId
        )
        
    }
    
    fileprivate func checkCanDelete() async {
        do {
            guard let message = try await TDLibManager.shared.client?.getMessage(
                chatId: model.chatId,
                messageId: model.messageId
            ) else { return }

            await MainActor.run {
                self.canDeleteForEveryone = message.canBeDeletedForAllUsers
            }
        } catch {
            logger.log(error, level: .error)
        }
    }

    func deleteMessage(forEveryone: Bool) {
        Task {
            do {
                try await TDLibManager.shared.client?.deleteMessages(
                    chatId: model.chatId,
                    messageIds: [model.messageId],
                    revoke: forEveryone
                )
            } catch {
                logger.log(error, level: .error)
            }
        }
    }

    func replyToMessage() {
        onReply?()
    }

    func loadShareContent() {
        Task {
            do {
                guard let message = try await TDLibManager.shared.client?.getMessage(
                    chatId: model.chatId,
                    messageId: model.messageId
                ) else { return }

                await MainActor.run {
                    switch message.content {
                    case .messageText(let msg):
                        self.shareText = msg.text.text
                        self.showShareSheet = true

                    case .messagePhoto(let msg):
                        self.shareText = msg.caption.text.isEmpty ? nil : msg.caption.text
                        Task {
                            if let photo = msg.photo.lowRes,
                               let image = await FileService.getImage(for: photo) {
                                await MainActor.run {
                                    self.shareImage = image
                                    self.showShareSheet = true
                                }
                            }
                        }

                    case .messageVideo(let msg):
                        self.shareText = msg.caption.text.isEmpty ? nil : msg.caption.text
                        Task {
                            if let url = await FileService.getFilePath(for: msg.video.video) {
                                await MainActor.run {
                                    self.shareFileURL = url
                                    self.showShareSheet = true
                                }
                            }
                        }

                    case .messageAnimation(let msg):
                        Task {
                            if let url = await FileService.getFilePath(for: msg.animation.animation) {
                                await MainActor.run {
                                    self.shareFileURL = url
                                    self.showShareSheet = true
                                }
                            }
                        }

                    case .messageVoiceNote(let msg):
                        Task {
                            if let url = await FileService.getFilePath(for: msg.voiceNote.voice) {
                                await MainActor.run {
                                    self.shareFileURL = url
                                    self.showShareSheet = true
                                }
                            }
                        }

                    case .messageLocation(let msg):
                        self.shareText = "https://maps.apple.com/?ll=\(msg.location.latitude),\(msg.location.longitude)"
                        self.showShareSheet = true

                    default:
                        self.shareText = message.description
                        self.showShareSheet = true
                    }
                }
            } catch {
                logger.log(error, level: .error)
            }
        }
    }

    func loadMessageInfo() {
        Task {
            do {
                guard let message = try await TDLibManager.shared.client?.getMessage(
                    chatId: model.chatId,
                    messageId: model.messageId
                ) else { return }

                let senderName = await message.senderId.username() ?? "Unknown"
                let date = Date(timeIntervalSince1970: TimeInterval(message.date))

                var forwardedFrom: String? = nil
                if let forwardInfo = message.forwardInfo {
                    let forwardDate = Date(timeIntervalSince1970: TimeInterval(forwardInfo.date))
                    switch forwardInfo.origin {
                    case .messageOriginUser(let user):
                        let u = try? await TDLibManager.shared.client?.getUser(userId: user.senderUserId)
                        forwardedFrom = "\(u?.fullName ?? "User") on \(forwardDate.formatted(.dateTime.month().day().hour().minute()))"
                    case .messageOriginChat(let chat):
                        forwardedFrom = chat.senderChatId != 0 ? "Chat" : "Unknown"
                    case .messageOriginChannel(let channel):
                        let c = try? await TDLibManager.shared.client?.getChat(chatId: channel.chatId)
                        forwardedFrom = c?.title ?? "Channel"
                    case .messageOriginHiddenUser(let hidden):
                        forwardedFrom = hidden.senderName
                    }
                }

                let viewCount = message.interactionInfo?.viewCount ?? 0
                let forwardCount = message.interactionInfo?.forwardCount ?? 0

                let info = MessageInfoData(
                    senderName: senderName,
                    date: date,
                    messageId: message.id,
                    forwardedFrom: forwardedFrom,
                    viewCount: viewCount > 0 ? viewCount : nil,
                    forwardCount: forwardCount > 0 ? forwardCount : nil,
                    isOutgoing: message.isOutgoing
                )

                await MainActor.run {
                    self.messageInfo = info
                    self.showMessageInfo = true
                }
            } catch {
                logger.log(error, level: .error)
            }
        }
    }

    func reportMessage(_ reason: ReportReason) {
        let chatId = model.chatId
        let messageId = model.messageId
        
        Task {
            do {
                try await TDLibManager.shared.client?.reportChat(chatId: chatId, messageIds: [messageId], reason: reason, text: nil)
            } catch {
                logger.log(error)
            }
            
            await MainActor.run {
                self.showReportMessageOptions = false
            }
        }
    }
}

struct MessageInfoData {
    let senderName: String
    let date: Date
    let messageId: Int64
    let forwardedFrom: String?
    let viewCount: Int?
    let forwardCount: Int?
    let isOutgoing: Bool
}

class MessageOptionsViewModelMock: MessageOptionsViewModel {
    init() {
        super.init(
            model: MessageOptionsModel(
                chatId: 0,
                messageId: 0,
                sendService: SendMessageServiceMock { _ in }
            ),
            onReply: nil
        )
    }
    
    override var shouldDisplayReportButton: Bool {
        return true
    }
    
    override func getReactions() async {
        self.emojis = ["🤣", "❤️", "🤝", "🔥",
                       "👌", "😱", "👀", "‍‍❤️‍🔥",
                       "🤯", "😢", "😭", "🗿"]
    }
    
    override func getSelectedEmoji() async {}
    override func reportMessage(_ reason: ReportReason) {
        self.showReportMessageOptions = false
    }
}
