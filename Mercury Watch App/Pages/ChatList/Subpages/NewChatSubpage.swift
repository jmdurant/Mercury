//
//  NewChatSubpage.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import SwiftUI

struct NewChatSubpage: View {

    @State private var vm = NewChatViewModel()
    @Binding var isPresented: Bool
    let onChatSelected: (Int64) -> Void

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView("Loading contacts...")
            } else if vm.filteredContacts.isEmpty {
                ContentUnavailableView.search
            } else {
                List(vm.filteredContacts) { contact in
                    Button {
                        vm.openChat(with: contact) { chatId in
                            isPresented = false
                            onChatSelected(chatId)
                        }
                    } label: {
                        HStack {
                            AvatarView(model: contact.avatar)
                                .frame(width: 36, height: 36)
                            VStack(alignment: .leading) {
                                Text(contact.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(contact.statusText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 4)
                        }
                    }
                }
                .listStyle(.carousel)
            }
        }
        .navigationTitle("New Chat")
        .searchable(text: $vm.searchQuery, prompt: "Search contacts")
        .onAppear { vm.loadContacts() }
    }
}
