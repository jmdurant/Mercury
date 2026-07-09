//
//  LoginPage.swift
//  Mercury Watch App
//
//  Created by Marco Tammaro on 02/11/24.
//

import SwiftUI

struct ChatListPage: View {
    
    @State
    @Mockable
    var vm: ChatListViewModel

    @State private var showComposeOptions = false

    init(folder: ChatFolder) {
        _vm = Mockable.state(
            value: { ChatListViewModel(folder: folder) },
            mock: { ChatListViewModelMock() }
        )
    }
    
    var body: some View {
        if vm.isLoading {
            ProgressView()
        } else {
            
            List(vm.chats) { chat in
                NavigationLink(value: chat) {
                    ChatCellView(model: chat) {
                        vm.didPressPin(on: chat)
                    } onPressMuteButton: {
                        vm.didPressMute(on: chat)
                    }
                }
                .listItemTint(chat.isPinned ? .blue : nil)
            }
            .listStyle(.carousel)
            .navigationTitle(vm.folder.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Menu is unavailable on watchOS; use a confirmation dialog
                    Button("New", systemImage: "square.and.pencil") {
                        showComposeOptions = true
                    }
                    .confirmationDialog("New", isPresented: $showComposeOptions) {
                        Button("New Chat", systemImage: "square.and.pencil") {
                            vm.didPressOnNewMessage()
                        }
                        Button("Secret Chat", systemImage: "lock.fill") {
                            vm.showNewSecretChat = true
                        }
                    }
                }
            }
            .sheet(isPresented: $vm.showNewMessage) {
                NewChatSubpage(isPresented: $vm.showNewMessage) { chatId in
                    AppState.shared.pendingNotificationChatId = chatId
                }
            }
            .sheet(isPresented: $vm.showNewSecretChat) {
                NewChatSubpage(
                    isPresented: $vm.showNewSecretChat,
                    onChatSelected: { chatId in
                        AppState.shared.pendingNotificationChatId = chatId
                    },
                    secretChat: true
                )
            }
        }
    }
}

#Preview(traits: .mock()) {
    NavigationStack {
        ChatListPage(folder: .main)
    }
}
