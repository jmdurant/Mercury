//
//  ChatDetailScreen.swift
//  ClawWatch iOS
//
//  Minimal chat detail on the shared services: text, photo (PHPicker),
//  and canned quick replies.
//

import SwiftUI
import PhotosUI
import AVFoundation
import TDLibKit

struct MessageRow: Identifiable {
    let id: Int64
    let text: String
    let isOutgoing: Bool
    let buttonRows: [[InlineKeyboardButton]]
}

@Observable
final class ChatDetailStore: TDLibManagerProtocol {

    let chatId: Int64
    var messages: [MessageRow] = []
    var sendService: SendMessageService?
    var autoDelete: AutoDeleteOption = .off

    // Push-to-talk (walkie-talkie)
    var isRecording = false
    var isPTTChat = false
    private var recorder: RecorderService?
    private var recURL: URL?

    // Agent live voice — only offered in assistant chats
    let isAssistantChat: Bool

    init(chatId: Int64) {
        self.chatId = chatId
        self.isPTTChat = PTTStore.isPTTChat(chatId)
        self.isAssistantChat = AutoResponderStore.isAssistantChat(chatId)
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
        messages.append(row(from: m))
    }

    private func row(from m: Message) -> MessageRow {
        MessageRow(
            id: m.id,
            text: String(m.content.description.characters),
            isOutgoing: m.isOutgoing,
            buttonRows: InlineButtonService.buttons(for: m))
    }

    @MainActor func tap(_ button: InlineKeyboardButton, messageId: Int64) async {
        if let toast = await InlineButtonService.tap(button, chatId: chatId, messageId: messageId),
           !toast.isEmpty {
            // Surface the bot's callback answer as a transient system row
            messages.append(MessageRow(id: Int64.random(in: Int64.min ... -1),
                                       text: toast, isOutgoing: false, buttonRows: []))
        }
    }

    func togglePTT() {
        isPTTChat.toggle()
        PTTStore.setPTTChat(chatId, enabled: isPTTChat)
    }

    /// Press-and-hold to talk: start recording a voice note.
    @MainActor func startTalking() async {
        guard !isRecording, await AVAudioApplication.requestRecordPermission() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        let rec = RecorderService(recFilePath: url)
        rec.initAudioRecorder()
        rec.startRecordingAudio()
        recorder = rec; recURL = url; isRecording = true
        HapticService.pttTalkStarted()
    }

    /// Release to send. Sub-half-second holds are discarded as accidental taps.
    @MainActor func stopTalkingAndSend() {
        guard isRecording, let rec = recorder, let url = recURL else { return }
        rec.stopRecordingAudio()
        let duration = rec.elapsedTime
        isRecording = false; recorder = nil; recURL = nil
        guard duration >= 0.5 else {
            try? FileManager.default.removeItem(at: url)
            HapticService.actionFailed()
            return
        }
        sendService?.sendVoiceNote(url, Int(duration)) {
            DispatchQueue.main.async { HapticService.messageSent() }
        }
    }

    @MainActor func load() async {
        do {
            if let chat = try await TDLibManager.shared.client?.getChat(chatId: chatId) {
                if sendService == nil { sendService = SendMessageService(chat: chat) }
                autoDelete = AutoDeleteOption.from(seconds: chat.messageAutoDeleteTime)
            }
            let history = try await TDLibManager.shared.client?.getChatHistory(
                chatId: chatId, fromMessageId: 0, limit: 40, offset: 0, onlyLocal: false)
            messages = (history?.messages ?? []).reversed().map { row(from: $0) }
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
    @State private var showLiveVoice = false

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
                        VStack(alignment: row.isOutgoing ? .trailing : .leading, spacing: 4) {
                            HStack {
                                if row.isOutgoing { Spacer(minLength: 40) }
                                Text(row.text)
                                    .padding(8)
                                    .background(row.isOutgoing ? Color.blue : Color(.secondarySystemBackground),
                                                in: RoundedRectangle(cornerRadius: 14))
                                    .foregroundStyle(row.isOutgoing ? .white : .primary)
                                if !row.isOutgoing { Spacer(minLength: 40) }
                            }
                            inlineButtons(for: row)
                        }
                    }
                }
                .padding()
            }
            composeBar
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLiveVoice) {
            LiveVoiceView(isPresented: $showLiveVoice, chatId: store.chatId, agentLabel: title)
        }
        .toolbar {
            if store.isAssistantChat {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showLiveVoice = true
                    } label: {
                        Image(systemName: "waveform.circle")
                    }
                    .accessibilityLabel("Live voice with \(title)")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.togglePTT()
                } label: {
                    Image(systemName: store.isPTTChat
                          ? "antenna.radiowaves.left.and.right.circle.fill"
                          : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(store.isPTTChat ? Color.green : Color.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Disappearing Messages", selection: Binding(
                        get: { store.autoDelete },
                        set: { option in
                            store.autoDelete = option
                            store.sendService?.setAutoDeleteTime(option.rawValue)
                        }
                    )) {
                        ForEach(AutoDeleteOption.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: store.autoDelete == .off ? "timer" : "timer.circle.fill")
                        .foregroundStyle(store.autoDelete == .off ? Color.secondary : Color.blue)
                }
            }
        }
        .task { await store.load() }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await sendPickedPhoto(item) }
        }
    }

    @ViewBuilder
    private func inlineButtons(for row: MessageRow) -> some View {
        ForEach(Array(row.buttonRows.enumerated()), id: \.offset) { _, buttons in
            HStack {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    Button(button.text) {
                        Task { await store.tap(button, messageId: row.id) }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
            }
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
            if draft.trimmingCharacters(in: .whitespaces).isEmpty {
                // Hold to talk (walkie-talkie)
                Image(systemName: store.isRecording ? "waveform.circle.fill" : "mic.fill")
                    .font(.title2)
                    .foregroundStyle(store.isRecording ? .red : .blue)
                    .scaleEffect(store.isRecording ? 1.25 : 1)
                    .animation(.spring(duration: 0.25), value: store.isRecording)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !store.isRecording { Task { await store.startTalking() } }
                            }
                            .onEnded { _ in store.stopTalkingAndSend() }
                    )
            } else {
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    store.sendService?.sendTextMessage(text)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
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
