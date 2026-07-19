//
//  LiveVoiceView.swift
//  ClawWatch iOS
//
//  Start/stop the live agent voice channel and set its endpoint.
//

import SwiftUI

struct LiveVoiceView: View {

    @Binding var isPresented: Bool
    @State private var voice = LiveVoiceService.shared
    @State private var endpoint = LiveVoiceService.shared.endpoint
    @State private var token = LiveVoiceService.shared.voiceToken

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                statusOrb

                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Button {
                    voice.state == .live || voice.state == .connecting ? voice.stop() : voice.start()
                } label: {
                    Label(voice.state == .live ? "End" : "Talk to Agent",
                          systemImage: voice.state == .live ? "phone.down.fill" : "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(voice.state == .live ? .red : .blue)
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Realtime endpoint").font(.caption).foregroundStyle(.secondary)
                    TextField("ws://box-lan-ip:8790", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: endpoint) { _, new in voice.endpoint = new }
                    TextField("token", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: token) { _, new in voice.voiceToken = new }
                    Text("Base URL only — the app adds ?token=…&device=…. Endpoint and token sync to the watch via iCloud.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Live Voice")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { voice.stop(); isPresented = false }
                }
            }
        }
    }

    private var statusOrb: some View {
        Circle()
            .fill(orbColor.gradient)
            .frame(width: 120, height: 120)
            .overlay(Image(systemName: "brain.head.profile").font(.system(size: 44)).foregroundStyle(.white))
            .scaleEffect(voice.state == .live ? 1.0 : 0.85)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: voice.state)
    }

    private var orbColor: Color {
        switch voice.state {
        case .idle: return .gray
        case .connecting: return .orange
        case .live: return .green
        case .error: return .red
        }
    }

    private var statusText: String {
        switch voice.state {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .live: return "Listening"
        case .error: return "Check the endpoint URL"
        }
    }
}
