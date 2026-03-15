//
//  LoginPage.swift
//  Mercury Watch App
//
//  Created by Marco Tammaro on 02/11/24.
//

import SwiftUI

struct HomePage: View {
    
    @State
    @Mockable(mockInit: HomeViewModelMock.init)
    var vm = HomeViewModel.init
    
    var body: some View {
        NavigationStack(path: $vm.navigationPath) {
            List {
                NavigationLink {
                    SettingsPage()
                } label: {
                    UserCellView(model: vm.userCellModel)
                }
                
                Section {
                    ForEach(AppState.shared.folders, id: \.self) { folder in
                        NavigationLink(value: folder) {
                            Label {
                                Text(folder.title)
                            } icon: {
                                Image(systemName: folder.iconName)
                                    .font(.caption)
                                    .foregroundStyle(folder.color)
                            }
                        }
                        .listItemTint(folder.color)
                    }
                }
                
            }
            .navigationTitle("Mercury")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SearchPage { chatId in
                            AppState.shared.pendingNotificationChatId = chatId
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .navigationDestination(for: ChatFolder.self) { folder in
                return ChatListPage(folder: folder)
            }
            .navigationDestination(for: ChatCellModel.self) { chat in
                if let id = chat.id {
                    ChatDetailPage(chatId: id)
                }
            }
            .onChange(of: AppState.shared.pendingNotificationChatId) { _, chatId in
                guard let chatId else { return }
                let stub = ChatCellModel(
                    id: chatId,
                    title: "",
                    time: "",
                    avatar: AvatarModel(),
                    isMuted: false,
                    isPinned: false
                )
                vm.navigationPath = NavigationPath()
                vm.navigationPath.append(ChatFolder.main)
                vm.navigationPath.append(stub)
                AppState.shared.pendingNotificationChatId = nil
            }
        }
    }
}


#Preview(traits: .mock()) {
    HomePage()
}
