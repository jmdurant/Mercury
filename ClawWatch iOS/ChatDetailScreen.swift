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
            // getChatHistory returns a TDLib-chosen count that can be far smaller
            // than `limit` — on the first open of a chat it's often just the last
            // message. Page older (fromMessageId = oldest so far) until we have a
            // screenful or reach the top; otherwise the thread only fills in on a
            // second open.
            var collected: [Message] = []
            var fromMessageId: Int64 = 0
            for _ in 0..<10 {
                let history = try await TDLibManager.shared.client?.getChatHistory(
                    chatId: chatId, fromMessageId: fromMessageId, limit: 40, offset: 0, onlyLocal: false)
                let batch = history?.messages ?? []
                if batch.isEmpty { break }
                collected.append(contentsOf: batch)
                guard collected.count < 30, let oldest = batch.last?.id, oldest != 0 else { break }
                fromMessageId = oldest
            }
            messages = collected.reversed().map { row(from: $0) }
        } catch {
            LoggerService(ChatDetailStore.self).log(error, level: .error)
        }
    }

    // MARK: - Read state (clears the unread badge)

    func openChat() {
        Task.detached { try? await TDLibManager.shared.client?.openChat(chatId: self.chatId) }
    }
    func closeChat() {
        Task.detached { try? await TDLibManager.shared.client?.closeChat(chatId: self.chatId) }
    }
    /// Mark the newest message seen — TDLib advances the read pointer over all
    /// older messages too, so this clears the whole unread count.
    func markNewestRead() {
        guard let last = messages.last?.id else { return }
        Task.detached {
            try? await TDLibManager.shared.client?.viewMessages(
                chatId: self.chatId, forceRead: true, messageIds: [last], source: nil)
        }
    }
}

struct ChatDetailScreen: View {

    let title: String
    @State private var store: ChatDetailStore
    @State private var draft = ""
    @State private var pickedItem: PhotosPickerItem?
    @State private var showLiveVoice = false
    @State private var node = OpenClawNodeService.shared
    @State private var didInitialScroll = false

    /// A chat is a live-voice target if it's explicitly an assistant chat, or
    /// its title matches an agent from the gateway roster (auto-routing).
    private var isVoiceChat: Bool {
        store.isAssistantChat || node.agent(forChatTitle: title) != nil
    }

    private let quickReplies = ["👍", "On my way", "Thanks!", "Give me a minute", "Call you soon"]

    init(chatId: Int64, title: String) {
        self.title = title
        _store = State(initialValue: ChatDetailStore(chatId: chatId))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
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
                            .id(row.id)
                        }
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)   // lay out anchored to newest (no top-first flash)
                .opacity(didInitialScroll ? 1 : 0)
                .onChange(of: store.messages.count) { _, _ in
                    scrollToBottom(proxy, animated: didInitialScroll)
                    store.markNewestRead()   // clear unread as messages arrive
                    if !didInitialScroll {
                        // Reveal once positioned at the bottom, killing the jump.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.easeIn(duration: 0.12)) { didInitialScroll = true }
                        }
                    }
                }
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                    // Fallback reveal (e.g. empty chat where count never changes).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        if !didInitialScroll { withAnimation(.easeIn(duration: 0.12)) { didInitialScroll = true } }
                    }
                }
            }
            composeBar
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLiveVoice) {
            LiveVoiceView(isPresented: $showLiveVoice, chatId: store.chatId, agentLabel: title)
        }
        .toolbar {
            if isVoiceChat {
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
        .onAppear { store.openChat() }
        .onDisappear { store.closeChat() }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await sendPickedPhoto(item) }
        }
    }

    /// Scroll to the newest message. Jumps on open, animates on new messages.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = store.messages.last?.id else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            } else {
                proxy.scrollTo(last, anchor: .bottom)
            }
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
