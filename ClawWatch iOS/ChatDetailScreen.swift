//
//  ChatDetailScreen.swift
//  ClawWatch iOS
//
//  Minimal chat detail on the shared services: text, photo (PHPicker),
//  and canned quick replies.
//

import SwiftUI
import PhotosUI
import TDLibKit

struct MessageRow: Identifiable {
    let id: Int64
    let text: String
    let isOutgoing: Bool
}

@Observable
final class ChatDetailStore: TDLibManagerProtocol {

    let chatId: Int64
    var messages: [MessageRow] = []
    var sendService: SendMessageService?

    init(chatId: Int64) {
        self.chatId = chatId
        TDLibManager.shared.subscribe(self)
    }
    deinit { TDLibManager.shared.unsubscribe(self) }

    func updateHandler(update: Update) {
        if case .updateNewMessage(let m) = update, m.message.chatId == chatId {
            Task { @MainActor in append(m.message) }
        }
    }
    func connectionStateUpdate(state: ConnectionState) {}
    func authorizationStateUpdate(state: AuthorizationState) {}

    @MainActor private func append(_ m: Message) {
        messages.append(MessageRow(
            id: m.id,
            text: String(m.content.description.characters),
            isOutgoing: m.isOutgoing))
    }

    @MainActor func load() async {
        do {
            if sendService == nil,
               let chat = try await TDLibManager.shared.client?.getChat(chatId: chatId) {
                sendService = SendMessageService(chat: chat)
            }
            let history = try await TDLibManager.shared.client?.getChatHistory(
                chatId: chatId, fromMessageId: 0, limit: 40, offset: 0, onlyLocal: false)
            messages = (history?.messages ?? []).reversed().map {
                MessageRow(id: $0.id,
                           text: String($0.content.description.characters),
                           isOutgoing: $0.isOutgoing)
            }
        } catch {
            LoggerService(ChatDetailStore.self).log(error, level: .error)
        }
    }
}

struct ChatDetailScreen: View {

    let title: String
    @State private var store: ChatDetailStore
    @State private var draft = ""
    @State private var pickedItem: PhotosPickerItem?

    private let quickReplies = ["👍", "On my way", "Thanks!", "Give me a minute", "Call you soon"]

    init(chatId: Int64, title: String) {
        self.title = title
        _store = State(initialValue: ChatDetailStore(chatId: chatId))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.messages) { row in
                        HStack {
                            if row.isOutgoing { Spacer(minLength: 40) }
                            Text(row.text)
                                .padding(8)
                                .background(row.isOutgoing ? Color.blue : Color(.secondarySystemBackground),
                                            in: RoundedRectangle(cornerRadius: 14))
                                .foregroundStyle(row.isOutgoing ? .white : .primary)
                            if !row.isOutgoing { Spacer(minLength: 40) }
                        }
                    }
                }
                .padding()
            }
            composeBar
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await sendPickedPhoto(item) }
        }
    }

    private var composeBar: some View {
        HStack(spacing: 8) {
            PhotosPicker(selection: $pickedItem, matching: .images) {
                Image(systemName: "photo").font(.title3)
            }
            Menu {
                ForEach(quickReplies, id: \.self) { reply in
                    Button(reply) { store.sendService?.sendTextMessage(reply) }
                }
            } label: {
                Image(systemName: "bolt.fill").font(.title3)
            }
            TextField("Message", text: $draft)
                .textFieldStyle(.roundedBorder)
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                store.sendService?.sendTextMessage(text)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
        }
        .padding(8)
        .background(.bar)
    }

    private func sendPickedPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        try? data.write(to: url)
        store.sendService?.sendPhoto(fileURL: url, caption: draft)
        draft = ""
        pickedItem = nil
    }
}
