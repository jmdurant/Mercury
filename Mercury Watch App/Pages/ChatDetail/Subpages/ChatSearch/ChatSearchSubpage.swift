//
//  ChatSearchSubpage.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import SwiftUI

struct ChatSearchSubpage: View {

    @State var vm: ChatSearchViewModel

    var body: some View {
        List {
            if vm.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }

            ForEach(vm.results) { result in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(result.senderName)
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
                        .lineLimit(3)
                }
            }

            if !vm.isSearching && vm.results.isEmpty && !vm.query.isEmpty {
                ContentUnavailableView.search(text: vm.query)
            }
        }
        .listStyle(.carousel)
        .navigationTitle("Search")
        .searchable(text: $vm.query, prompt: "Search messages")
        .onChange(of: vm.query) {
            vm.search()
        }
    }
}
