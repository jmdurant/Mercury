//
//  SearchPage.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import SwiftUI

struct SearchPage: View {

    @State private var vm = SearchViewModel()
    let onChatSelected: (Int64) -> Void

    var body: some View {
        List {
            if vm.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }

            if !vm.chatResults.isEmpty {
                Section("Chats") {
                    ForEach(vm.chatResults) { chat in
                        Button {
                            if let id = chat.id {
                                onChatSelected(id)
                            }
                        } label: {
                            HStack {
                                AvatarView(model: chat.avatar)
                                    .frame(width: 32, height: 32)
                                Text(chat.title)
                                    .font(.headline)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            if !vm.messageResults.isEmpty {
                Section("Messages") {
                    ForEach(vm.messageResults) { result in
                        Button {
                            onChatSelected(result.chatId)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(result.chatTitle)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                    Spacer()
                                    Text(result.date)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Text(result.preview)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

            if !vm.isSearching && vm.chatResults.isEmpty && vm.messageResults.isEmpty && !vm.query.isEmpty {
                ContentUnavailableView.search(text: vm.query)
            }
        }
        .listStyle(.carousel)
        .navigationTitle("Search")
        .searchable(text: $vm.query, prompt: "Chats and messages")
        .onChange(of: vm.query) {
            vm.search()
        }
    }
}
