//
//  MessageOptionsView.swift
//  Mercury Watch App
//
//  Created by Alessandro Alberti on 11/09/24.
//

import SwiftUI
import TDLibKit

struct MessageOptionsSubpage: View {
    
    @State
    @Mockable
    var vm: MessageOptionsViewModel
    
    @Binding var isPresented: Bool
    var onReply: (() -> Void)?

    init(isPresented: Binding<Bool>, model: MessageOptionsModel, onReply: (() -> Void)? = nil) {
        self._isPresented = isPresented
        self.onReply = onReply
        _vm = Mockable.state(
            value: { MessageOptionsViewModel(model: model, onReply: onReply) },
            mock: { MessageOptionsViewModelMock() }
        )
    }
    
    private let columns = [
        GridItem(.adaptive(minimum: 40))
    ]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns) {
                ForEach(vm.emojis, id: \.self) { emoji in
                    Button(action: {
                        Task {
                            await vm.sendReaction(emoji)
                            await MainActor.run {
                                isPresented = false
                            }
                        }
                    }, label: {
                        Text(emoji)
                            .font(.system(size: 30))
                            .background {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(.white.opacity(0.2))
                                    .opacity(vm.selectedEmoji == emoji ? 1 : 0)
                                    
                            }
                    })
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal)
            
            Divider()
                .padding(.vertical, 4)

            Button {
                vm.replyToMessage()
                isPresented = false
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
            }

            Button {
                vm.loadShareContent()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
                vm.loadMessageInfo()
            } label: {
                Label("Info", systemImage: "info.circle")
            }

            Button(role: .destructive) {
                vm.showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash.fill")
            }

            if vm.shouldDisplayReportButton {
                Button(action: {
                    vm.showReportMessageOptions = true
                }, label: {
                    Label("Report content", systemImage: "exclamationmark.triangle")
                })
                .tint(.red)
            }
        }
        .sheet(isPresented: $vm.showShareSheet) {
            VStack(spacing: 12) {
                if let image = vm.shareImage {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Photo", image: Image(uiImage: image))) {
                        Label("Share Photo", systemImage: "square.and.arrow.up")
                    }
                }
                if let text = vm.shareText {
                    ShareLink(item: text) {
                        Label("Share Text", systemImage: "square.and.arrow.up")
                    }
                }
                if let url = vm.shareFileURL {
                    ShareLink(item: url) {
                        Label("Share File", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle("Share")
        }
        .sheet(isPresented: $vm.showMessageInfo) {
            if let info = vm.messageInfo {
                MessageInfoView(info: info)
            }
        }
        .confirmationDialog("Delete Message", isPresented: $vm.showDeleteConfirmation) {
            Button("Delete for Me", role: .destructive) {
                vm.deleteMessage(forEveryone: false)
                isPresented = false
            }
            if vm.canDeleteForEveryone {
                Button("Delete for Everyone", role: .destructive) {
                    vm.deleteMessage(forEveryone: true)
                    isPresented = false
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $vm.showReportMessageOptions) {
            List {
                ForEach(vm.reportMessageOptions, id: \.self) { option in
                    Button(option.description) {
                        vm.reportMessage(option)
                    }
                }
                .navigationTitle("Reason")
            }
        }

    }
}

struct MessageOptionsModel {
    var chatId: Int64
    var messageId: Int64
    var sendService: SendMessageService
    var chatType: ChatType?
}

struct MessageInfoView: View {
    let info: MessageInfoData

    var body: some View {
        List {
            Section("Sender") {
                Label(info.senderName, systemImage: info.isOutgoing ? "arrow.up.circle" : "arrow.down.circle")
            }

            Section("Date") {
                Label(
                    info.date.formatted(.dateTime.year().month().day().hour().minute()),
                    systemImage: "calendar"
                )
            }

            if let forwarded = info.forwardedFrom {
                Section("Forwarded from") {
                    Label(forwarded, systemImage: "arrowshape.turn.up.right")
                }
            }

            if let views = info.viewCount {
                Section("Views") {
                    Label("\(views)", systemImage: "eye")
                }
            }

            if let forwards = info.forwardCount {
                Section("Forwards") {
                    Label("\(forwards)", systemImage: "arrowshape.turn.up.forward")
                }
            }

            Section("Message ID") {
                Text("\(info.messageId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Message Info")
    }
}

#Preview {
    Rectangle()
        .foregroundStyle(.blue.opacity(0.8))
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true), content: {
            MessageOptionsSubpage(
                isPresented: .constant(true),
                model: .init(
                    chatId: 0,
                    messageId: 0,
                    sendService: SendMessageServiceMock { _ in }
                )
            )
        })
}
    

