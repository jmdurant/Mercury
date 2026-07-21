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

/// Pinned chats (local to this device).
enum PinStore {
    private static let key = "pinnedChatIds"
    static var pinned: Set<Int64> {
        Set((UserDefaults.standard.array(forKey: key) as? [Int64]) ?? [])
    }
    static func setPinned(_ id: Int64, _ on: Bool) {
        var s = pinned
        if on { s.insert(id) } else { s.remove(id) }
        UserDefaults.standard.set(Array(s), forKey: key)
    }
}

struct ChatListScreen: View {

    @State private var store = ChatListStore()
    @State private var showAgentSettings = false
    @State private var showLiveVoice = false

    // Classification state, mirrored from the stores so the list updates live.
    @State private var pinned: Set<Int64> = PinStore.pinned
    @State private var agentChats: Set<Int64> = Set(AutoResponderStore.assistantChatIds())

    // "Set agent id" editor
    @State private var editing: ChatRow?
    @State private var agentIdDraft = ""

    private var pinnedRows: [ChatRow] { store.rows.filter { pinned.contains($0.id) } }
    private var agentRows: [ChatRow] {
        store.rows.filter { !pinned.contains($0.id) && agentChats.contains($0.id) }
    }
    private var peopleRows: [ChatRow] {
        store.rows.filter { !pinned.contains($0.id) && !agentChats.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                section("📌  Pinned", pinnedRows)
                section("🤖  Agents", agentRows)
                section("Chats", peopleRows)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showLiveVoice = true } label: { Image(systemName: "waveform") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAgentSettings = true } label: { Image(systemName: "brain.head.profile") }
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
            .alert("Agent id for \(editing?.title ?? "")",
                   isPresented: Binding(get: { editing != nil },
                                        set: { if !$0 { editing = nil } })) {
                TextField("agent id (e.g. nurse-claw)", text: $agentIdDraft)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Save") { saveAgentId() }
                Button("Cancel", role: .cancel) { editing = nil }
            } message: {
                Text("The id your voice server expects (?agent=…). This chat routes live voice to it.")
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [ChatRow]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { row in
                    NavigationLink {
                        ChatDetailScreen(chatId: row.id, title: row.title)
                    } label: {
                        rowLabel(row)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            togglePin(row)
                        } label: {
                            Label(pinned.contains(row.id) ? "Unpin" : "Pin",
                                  systemImage: pinned.contains(row.id) ? "pin.slash" : "pin")
                        }.tint(.yellow)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            toggleAgent(row)
                        } label: {
                            Label(agentChats.contains(row.id) ? "Not agent" : "Agent",
                                  systemImage: agentChats.contains(row.id) ? "person.crop.circle.badge.xmark" : "brain")
                        }.tint(.purple)
                    }
                    .contextMenu {
                        Button {
                            togglePin(row)
                        } label: {
                            Label(pinned.contains(row.id) ? "Unpin" : "Pin",
                                  systemImage: pinned.contains(row.id) ? "pin.slash" : "pin")
                        }
                        Button {
                            toggleAgent(row)
                        } label: {
                            Label(agentChats.contains(row.id) ? "Remove agent label" : "Mark as agent",
                                  systemImage: "brain")
                        }
                        if agentChats.contains(row.id) {
                            Button {
                                agentIdDraft = LiveVoiceService.shared.agentId(forChat: row.id)
                                editing = row
                            } label: {
                                Label("Set agent id…", systemImage: "tag")
                            }
                        }
                    }
                }
            }
        }
    }

    private func rowLabel(_ row: ChatRow) -> some View {
        HStack(spacing: 12) {
            initialsCircle(row.title, agent: agentChats.contains(row.id))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.headline).lineLimit(1)
                    if pinned.contains(row.id) {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if agentChats.contains(row.id), case let aid = LiveVoiceService.shared.agentId(forChat: row.id), !aid.isEmpty {
                    Text("agent: \(aid)").font(.caption2).foregroundStyle(.purple)
                } else {
                    Text(row.subtitle).font(.subheadline)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
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

    // MARK: - Actions

    private func togglePin(_ row: ChatRow) {
        let on = !pinned.contains(row.id)
        PinStore.setPinned(row.id, on)
        if on { pinned.insert(row.id) } else { pinned.remove(row.id) }
    }

    private func toggleAgent(_ row: ChatRow) {
        let on = !agentChats.contains(row.id)
        AutoResponderStore.setAssistantChat(row.id, enabled: on)
        if on {
            agentChats.insert(row.id)
            // Seed an agent id from the title (editable via "Set agent id").
            var aid = LiveVoiceService.shared.agentId(forChat: row.id)
            if aid.isEmpty { aid = LiveVoiceService.defaultAgentId(fromTitle: row.title) }
            LiveVoiceService.shared.setAgentId(aid, forChat: row.id)
            LiveVoiceService.shared.registerAgent(id: aid, name: row.title)
        } else {
            agentChats.remove(row.id)
            let aid = LiveVoiceService.shared.agentId(forChat: row.id)
            if !aid.isEmpty { LiveVoiceService.shared.unregisterAgent(id: aid) }
        }
    }

    private func saveAgentId() {
        guard let row = editing else { return }
        let id = agentIdDraft.trimmingCharacters(in: .whitespaces)
        LiveVoiceService.shared.setAgentId(id, forChat: row.id)
        if !id.isEmpty { LiveVoiceService.shared.registerAgent(id: id, name: row.title) }
        editing = nil
    }

    private func initialsCircle(_ title: String, agent: Bool) -> some View {
        let initials = title.split(separator: " ").prefix(2)
            .compactMap { $0.first }.map(String.init).joined()
        return Circle()
            .fill((agent ? Color.purple : Color.blue).gradient)
            .frame(width: 44, height: 44)
            .overlay(
                Group {
                    if agent { Image(systemName: "brain").foregroundStyle(.white) }
                    else { Text(initials.uppercased()).font(.headline).foregroundStyle(.white) }
                }
            )
    }
}
