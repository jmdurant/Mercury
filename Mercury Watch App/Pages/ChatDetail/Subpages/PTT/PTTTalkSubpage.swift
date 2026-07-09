//
//  PTTTalkSubpage.swift
//  Mercury Watch App
//
//  Created on 09/07/26.
//

import SwiftUI

/// Walkie-talkie screen: hold the big button to talk, release to send.
/// Incoming voice notes auto-play via PTTService when this chat is designated.
struct PTTTalkSubpage: View {

    @State var vm: PTTTalkViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 8) {

            talkButton()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !vm.hasPermission {
                Text("Microphone access denied")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Toggle(isOn: Binding(
                get: { vm.isAutoPlayOn },
                set: { vm.toggleAutoPlay($0) }
            )) {
                Label("Auto-play", systemImage: "speaker.wave.2.fill")
                    .font(.caption2)
            }
        }
        .navigationTitle("Walkie-Talkie")
        .task {
            await vm.onAppear()
        }
    }

    @ViewBuilder
    private func talkButton() -> some View {
        ZStack {
            Circle()
                .fill(buttonColor.gradient)
                .scaleEffect(vm.state == .recording ? 1.0 : 0.85)
                .animation(.spring(duration: 0.3), value: vm.state)

            VStack(spacing: 2) {
                Image(systemName: buttonIcon)
                    .font(.title3)
                Text(buttonLabel)
                    .font(.caption2)
                    .fontWeight(.bold)
            }
            .foregroundStyle(.black.opacity(0.7))
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if vm.state == .idle {
                        vm.startTalking()
                    }
                }
                .onEnded { _ in
                    vm.stopTalking()
                }
        )
    }

    private var buttonColor: Color {
        switch vm.state {
        case .idle: .yellow
        case .recording: .orange
        case .sending: .gray
        }
    }

    private var buttonIcon: String {
        switch vm.state {
        case .idle: "mic.fill"
        case .recording: "waveform"
        case .sending: "paperplane.fill"
        }
    }

    private var buttonLabel: String {
        switch vm.state {
        case .idle: "HOLD TO TALK"
        case .recording: "RELEASE TO SEND"
        case .sending: "SENDING"
        }
    }
}

#Preview(traits: .mock()) {
    PTTTalkSubpage(
        vm: PTTTalkViewModel(chatId: 0, sendService: SendMessageServiceMock({ _ in })),
        isPresented: .constant(true)
    )
}
