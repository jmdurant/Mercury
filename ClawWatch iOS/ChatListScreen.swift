//
//  ChatListScreen.swift
//  ClawWatch iOS
//
//  Thin iOS-native list built directly on the shared TDLibManager.
//

import SwiftUI
import TDLibKit

struct ChatRow: Identifiable {
    let id: Int64
    let title: String
    let subtitle: String
    let unread: Int
    let date: Int
}

@Observable
final class ChatListStore: TDLibManagerProtocol {

    var rows: [ChatRow] = []
    var isLoading = false
    private var refreshWork: DispatchWorkItem?

    init() {
        TDLibManager.shared.subscribe(self)
    }
    deinit { TDLibManager.shared.unsubscribe(self) }

    func updateHandler(update: Update) {
        switch update {
        case .updateNewMessage, .updateChatLastMessage, .updateChatReadInbox:
            scheduleRefresh()
        default:
            break
        }
    }
    func connectionStateUpdate(state: ConnectionState) {}
    func authorizationStateUpdate(state: AuthorizationState) {
        if case .authorizationStateReady = state { scheduleRefresh() }
    }

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { await self?.load() } }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    @MainActor
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let ids = try await TDLibManager.shared.client?.getChats(
                chatList: .chatListMain, limit: 50
            ).chatIds ?? []

            var loaded: [ChatRow] = []
            for id in ids {
                guard let chat = try await TDLibManager.shared.client?.getChat(chatId: id)
                else { continue }
                let subtitle = chat.lastMessage.map { String($0.content.description.characters) } ?? ""
                loaded.append(ChatRow(
                    id: chat.id,
                    title: chat.title,
                    subtitle: subtitle,
                    unread: chat.unreadCount,
                    date: chat.lastMessage?.date ?? 0
                ))
            }
            rows = loaded.sorted { $0.date > $1.date }
        } catch {
            LoggerService(ChatListStore.self).log(error, level: .error)
        }
    }
}

struct ChatListScreen: View {

    @State private var store = ChatListStore()
    @State private var showAgentSettings = false
    @State private var showLiveVoice = false

    var body: some View {
        NavigationStack {
            List(store.rows) { row in
                NavigationLink {
                    ChatDetailScreen(chatId: row.id, title: row.title)
                } label: {
                    HStack(spacing: 12) {
                        initialsCircle(row.title)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.headline).lineLimit(1)
                            Text(row.subtitle).font(.subheadline)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if row.unread > 0 {
                            Text("\(row.unread)")
                                .font(.caption2.bold())
                                .padding(6)
                                .background(.blue, in: Circle())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showLiveVoice = true
                    } label: {
                        Image(systemName: "waveform")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAgentSettings = true
                    } label: {
                        Image(systemName: "brain.head.profile")
                    }
                }
            }
            .sheet(isPresented: $showAgentSettings) {
                AgentSettingsScreen(isPresented: $showAgentSettings)
            }
            .sheet(isPresented: $showLiveVoice) {
                LiveVoiceView(isPresented: $showLiveVoice)
            }
            .overlay {
                if store.rows.isEmpty {
                    ProgressView(store.isLoading ? "Loading…" : "No chats")
                }
            }
            .refreshable { await store.load() }
            .task { await store.load() }
        }
    }

    private func initialsCircle(_ title: String) -> some View {
        let initials = title.split(separator: " ").prefix(2)
            .compactMap { $0.first }.map(String.init).joined()
        return Circle()
            .fill(.blue.gradient)
            .frame(width: 44, height: 44)
            .overlay(Text(initials.uppercased()).font(.headline).foregroundStyle(.white))
    }
}
