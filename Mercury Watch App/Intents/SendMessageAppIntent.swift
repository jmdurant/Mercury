//
//  SendMessageAppIntent.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import AppIntents

#if os(iOS)
import CoreSpotlight
import GeoToolbox
import LinkPresentation
import UniformTypeIdentifiers

@UnionValue
enum MercuryMessageDestination {
    case people([IntentPerson])
}

@AppEnum(schema: .messages.messageType)
enum MercuryMessageType: String {
    case unspecified

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .unspecified: "Message",
    ]
}

@AppEntity(schema: .messages.messagePerson)
struct MercuryMessagePerson {
    static let defaultQuery = MercuryMessagePersonQuery()

    let id: String
    var person: IntentPerson

    var displayRepresentation: DisplayRepresentation {
        person.displayRepresentation
    }

    init(id: String, person: IntentPerson) {
        self.id = id
        self.person = person
    }
}

struct MercuryMessagePersonQuery: EntityQuery {
    func entities(for identifiers: [MercuryMessagePerson.ID]) async throws -> [MercuryMessagePerson] {
        []
    }
}

@AppEnum(schema: .messages.conversationAttribute)
enum MercuryConversationAttribute: String {
    case direct

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .direct: "Direct conversation",
    ]
}

@AppEntity(schema: .messages.conversation)
struct MercuryConversation {
    static let defaultQuery = MercuryConversationQuery()

    let id: String
    var recipients: [MercuryMessagePerson]
    var displayName: String
    var previewText: AttributedString
    var conversationName: String?
    var isRead: Bool
    var attributes: Set<MercuryConversationAttribute>
    var dateLastActive: Date?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "\(previewText)",
            image: .init(systemName: "bubble.left.and.bubble.right")
        )
    }

    init(
        id: String,
        recipients: [MercuryMessagePerson],
        displayName: String,
        previewText: AttributedString,
        conversationName: String?,
        isRead: Bool,
        attributes: Set<MercuryConversationAttribute>,
        dateLastActive: Date?
    ) {
        self.id = id
        self.recipients = recipients
        self.displayName = displayName
        self.previewText = previewText
        self.conversationName = conversationName
        self.isRead = isRead
        self.attributes = attributes
        self.dateLastActive = dateLastActive
    }
}

struct MercuryConversationQuery: EntityQuery {
    func entities(for identifiers: [MercuryConversation.ID]) async throws -> [MercuryConversation] {
        []
    }
}

@AppEnum(schema: .messages.messageAttribute)
enum MercuryMessageAttribute: String {
    case outgoing

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .outgoing: "Outgoing",
    ]
}

@AppEnum(schema: .messages.messageEffect)
enum MercuryMessageEffect: String {
    case mercury

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .mercury: "Mercury",
    ]
}

@AppEnum(schema: .messages.customReaction)
enum MercuryTapback: String {
    case acknowledged

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .acknowledged: "Acknowledged",
    ]
}

@UnionValue
enum MercuryReadReaction {
    case customReaction(MercuryTapback)
    case attributedString(AttributedString)
}

@AppEntity(schema: .messages.customAttachment)
struct MercuryCustomAttachment {
    static let defaultQuery = MercuryCustomAttachmentQuery()

    let id: String
    var sourceName: AttributedString?
    var description: AttributedString?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: sourceName.map { "\($0)" } ?? "Mercury attachment",
            subtitle: description.map { "\($0)" },
            image: .init(systemName: "paperclip")
        )
    }

    init(id: String, sourceName: AttributedString?, description: AttributedString?) {
        self.id = id
        self.sourceName = sourceName
        self.description = description
    }
}

struct MercuryCustomAttachmentQuery: EntityQuery {
    func entities(
        for identifiers: [MercuryCustomAttachment.ID]
    ) async throws -> [MercuryCustomAttachment] {
        []
    }
}

@AppEntity(schema: .messages.message)
struct MercurySentMessage: IndexedEntity {
    static let defaultQuery = MercurySentMessageQuery()

    let id: String
    var messageType: MercuryMessageType
    var author: MercuryMessagePerson
    var isRead: Bool
    var attributes: Set<MercuryMessageAttribute>
    var conversation: MercuryConversation
    var date: Date
    var subject: AttributedString?
    var body: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var customAttachments: [MercuryCustomAttachment]
    var locations: [PlaceDescriptor]
    var links: [LinkMetadata]
    var messageEffect: MercuryMessageEffect?
    var reaction: MercuryReadReaction?
    var referencedMessage: MercurySentMessage? { nil }
    var notificationIdentifier: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: body.map { "\($0)" } ?? "Mercury message",
            subtitle: "Sent with Mercury",
            image: .init(systemName: "paperplane.fill")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = body.map(String.init)
        attributes.contentCreationDate = date
        return attributes
    }

    init(
        id: String,
        messageType: MercuryMessageType,
        author: MercuryMessagePerson,
        isRead: Bool,
        attributes: Set<MercuryMessageAttribute>,
        conversation: MercuryConversation,
        date: Date,
        subject: AttributedString?,
        body: AttributedString?,
        attachments: [IntentFile],
        audioMessage: IntentFile?,
        customAttachments: [MercuryCustomAttachment],
        locations: [PlaceDescriptor],
        links: [LinkMetadata],
        messageEffect: MercuryMessageEffect?,
        reaction: MercuryReadReaction?,
        notificationIdentifier: String?
    ) {
        self.id = id
        self.messageType = messageType
        self.author = author
        self.isRead = isRead
        self.attributes = attributes
        self.conversation = conversation
        self.date = date
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.audioMessage = audioMessage
        self.customAttachments = customAttachments
        self.locations = locations
        self.links = links
        self.messageEffect = messageEffect
        self.reaction = reaction
        self.notificationIdentifier = notificationIdentifier
    }
}

struct MercurySentMessageQuery: EntityQuery {
    func entities(for identifiers: [MercurySentMessage.ID]) async throws -> [MercurySentMessage] {
        []
    }
}

@AppIntent(schema: .messages.sendMessage)
struct SendMessageAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Mercury Message"
    static var description = IntentDescription("Send a Telegram message via Mercury")
    static var supportedModes: IntentModes = .background

    var content: AttributedString?
    var destination: MercuryMessageDestination
    var subject: AttributedString?

    @Parameter(default: [], supportedContentTypes: [.item, .image, .audio])
    var attachments: [IntentFile]

    @Parameter(supportedContentTypes: [.audio])
    var audioMessage: IntentFile?

    @Parameter(default: [])
    var locations: [PlaceDescriptor]

    @Parameter(default: [])
    var links: [URL]

    var scheduledDate: Date?

    func perform() async throws -> some IntentResult & ReturnsValue<[MercurySentMessage]> & ProvidesDialog {
        guard scheduledDate == nil || scheduledDate! <= Date() else {
            return .result(value: [], dialog: "Mercury does not support scheduled messages yet.")
        }
        guard attachments.isEmpty, audioMessage == nil else {
            return .result(
                value: [],
                dialog: "Mercury can send text and links from Siri, but not attachments yet."
            )
        }

        var messageParts: [String] = []
        if let subject {
            let text = String(subject.characters)
            if !text.isEmpty { messageParts.append(text) }
        }
        if let content {
            let text = String(content.characters)
            if !text.isEmpty { messageParts.append(text) }
        }
        messageParts.append(contentsOf: links.map(\.absoluteString))
        messageParts.append(contentsOf: locations.map(\.description))

        let message = messageParts.joined(separator: "\n")
        guard !message.isEmpty else {
            return .result(value: [], dialog: "What would you like to send?")
        }

        let people: [IntentPerson]
        switch destination {
        case .people(let recipients):
            people = recipients
        }

        let names = people.compactMap(\.mercuryDisplayName)
        guard !names.isEmpty else {
            return .result(value: [], dialog: "I couldn't determine the Mercury recipient.")
        }

        for name in names {
            try await SendMessageService.sendToContact(name: name, text: message)
        }

        let recipientSummary = names.count == 1 ? names[0] : "\(names.count) recipients"
        let author = MercuryMessagePerson(
            id: "mercury-current-user",
            person: IntentPerson(
                identifier: .applicationDefined("mercury-current-user"),
                name: .displayName("You"),
                handle: nil,
                isMe: true
            )
        )
        let sentAt = Date()
        let results = names.map { name in
            let recipientPerson = MercuryMessagePerson(
                id: "mercury-recipient-\(name)",
                person: IntentPerson(
                    identifier: .applicationDefined("mercury-recipient-\(name)"),
                    name: .displayName(name),
                    handle: nil
                )
            )
            let conversation = MercuryConversation(
                id: "mercury-conversation-\(name)",
                recipients: [recipientPerson],
                displayName: name,
                previewText: AttributedString(message),
                conversationName: nil,
                isRead: true,
                attributes: [.direct],
                dateLastActive: sentAt
            )
            return MercurySentMessage(
                id: UUID().uuidString,
                messageType: .unspecified,
                author: author,
                isRead: true,
                attributes: [.outgoing],
                conversation: conversation,
                date: sentAt,
                subject: subject,
                body: AttributedString(message),
                attachments: [],
                audioMessage: nil,
                customAttachments: [],
                locations: locations,
                links: links.map(LinkMetadata.init(url:)),
                messageEffect: nil,
                reaction: nil,
                notificationIdentifier: nil
            )
        }
        return .result(value: results, dialog: "Message sent to \(recipientSummary)")
    }
}

private extension IntentPerson {
    var mercuryDisplayName: String? {
        switch name {
        case .displayName(let value):
            return value
        case .components(let components):
            return PersonNameComponentsFormatter.localizedString(
                from: components,
                style: .default
            )
        case .unknown:
            if let handle {
                switch handle.value {
                case .applicationDefined(let value),
                     .emailAddress(let value),
                     .phoneNumber(let value):
                    return value
                @unknown default:
                    return nil
                }
            }
            return nil
        @unknown default:
            return nil
        }
    }
}
#else
struct SendMessageAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Mercury Message"
    static var description = IntentDescription("Send a Telegram message via Mercury")
    static var supportedModes: IntentModes = .background

    @Parameter(title: "Recipient")
    var recipientName: String

    @Parameter(title: "Message")
    var messageText: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await SendMessageService.sendToContact(
            name: recipientName,
            text: messageText
        )
        return .result(dialog: "Message sent to \(recipientName)")
    }
}
#endif
