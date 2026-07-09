//
//  Message+.swift
//  Mercury Watch App
//
//  Created by Marco Tammaro on 09/05/24.
//

import TDLibKit
import Foundation

extension MessageContent {
    /// A textual desctiption of the message content
    var description: AttributedString {
        var stringMessage = ""
        
        switch self {
        case .messageText(let message):
            return message.text.attributedString
        case .messagePhoto(_):
            stringMessage = "📷 Photo"
        case .messageLocation(_):
            stringMessage = "📍 Location"
        case .messageVenue(let message):
            stringMessage = "📍 \(message.venue.title)"
        case .messagePoll(let message):
            return "📊 " + message.poll.question.attributedString
        case .messageDocument(let doc):
            stringMessage = "📎 \(doc.document.fileName)"
        case .messageVideo(let message):
            let caption = message.caption.text
            stringMessage = "📹 \(caption.isEmpty ? "Video" : caption)"
        case .messageVideoNote(_):
            stringMessage = "📺 Video message"
        case .messageAnimation(let message):
            let caption = message.caption.text
            stringMessage = "📹 \(caption.isEmpty ? "GIF" : caption)"
        case .messageContact(let message):
            stringMessage = "👤 \(message.contact.firstName) \(message.contact.lastName)"
        case .messageChatChangePhoto(_):
            stringMessage = "📷 Changed group photo"
        case .messageChatChangeTitle(let change):
            stringMessage = change.title
        case .messageAnimatedEmoji(let data):
            stringMessage = data.emoji
        case .messageVoiceNote(_):
            stringMessage = "🎤 Voice message"
        case .messageCall(let message):
            let isVideo = message.isVideo
            stringMessage = isVideo ? "📹" : "📞" + " Call"
        case .messageSticker(let sticker):
            let emoji = sticker.sticker.emoji
            stringMessage = emoji.isEmpty ? "Sticker" : emoji
        case .messagePinMessage(_):
            stringMessage = "📌 Pinned a message"
        default:
            stringMessage = "\(self)"
        }
        
        return AttributedString(stringMessage)
    }
}

extension Message {
    var description: AttributedString {
        self.content.description
    }
    
    var senderID: Int64 {
        switch senderId {
        case .messageSenderUser(let messageSenderUser):
            messageSenderUser.userId
        case .messageSenderChat(let messageSenderChat):
           messageSenderChat.chatId
        }
    }
    
    var errorSending: Bool {
        
        switch self.sendingState {
        case .messageSendingStateFailed(_):
            return true
        default:
            return false
        }
        
    }
    
    
}

