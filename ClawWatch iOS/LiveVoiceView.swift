//
//  LiveVoiceView.swift
//  ClawWatch iOS
//
//  Start/stop the live agent voice channel. Used two ways:
//   • Global (chatId == nil): talks to the default agent.
//   • Per assistant chat (chatId set): talks to that chat's agent, and can
//     promote it to the default.
//

import SwiftUI

struct LiveVoiceView: View {

    @Binding var isPresented: Bool
    var chatId: Int64? = nil
    var agentLabel: String = ""

    @State private var voice = LiveVoiceService.shared
    @State private var endpoint = LiveVoiceService.shared.endpoint
    @State private var token = LiveVoiceService.shared.voiceToken
    @State private var agentId: String = ""

    private var isPerChat: Bool { chatId != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                statusOrb

                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                // Who you're about to talk to
                Text(agentDescription)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)

                Button {
                    if voice.state == .live || voice.state == .connecting {
                        voice.stop()
                    } else {
                        voice.start(agentId: isPerChat ? agentId : nil)
                    }
                } label: {
                    Label(voice.state == .live ? "End" : "Talk",
                          systemImage: voice.state == .live ? "phone.down.fill" : "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(voice.state == .live ? .red : .blue)
                .controlSize(.large)
                .disabled(voice.state == .idle && effectiveAgentId.isEmpty)

                agentConfig
                Spacer()
            }
            .padding()
            .navigationTitle(isPerChat ? "Live Voice" : "Live Voice")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { voice.stop(); isPresented = false }
                }
            }
        }
        .onAppear {
            agentId = isPerChat ? voice.agentId(forChat: chatId!) : voice.defaultAgentId
        }
    }

    // MARK: - Agent + endpoint config

    private var agentConfig: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isPerChat ? "Agent id for \(agentLabel)" : "Default agent id")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("agent id (what your server expects)", text: $agentId)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: agentId) { _, new in
                        if let chatId { voice.setAgentId(new, forChat: chatId) }
                        else { voice.defaultAgentId = new }
                    }
                if isPerChat {
                    Button {
                        voice.defaultAgentId = agentId
                    } label: {
                        Label(
                            voice.defaultAgentId == agentId && !agentId.isEmpty
                                ? "Default agent" : "Make default agent",
                            systemImage: voice.defaultAgentId == agentId && !agentId.isEmpty
                                ? "star.fill" : "star")
                            .font(.caption)
                    }
                    .disabled(agentId.isEmpty)
                }
            }

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
                Text("The app adds ?token=…&device=…&agent=…. Endpoint, token and agents sync to the watch via iCloud.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var effectiveAgentId: String {
        isPerChat ? agentId : voice.defaultAgentId
    }

    private var agentDescription: String {
        if isPerChat {
            return agentId.isEmpty ? "Set an agent id for \(agentLabel) below" : "Talking to \(agentLabel)"
        }
        return voice.defaultAgentId.isEmpty
            ? "No default agent set — pick one from an assistant chat"
            : "Talking to default agent (\(voice.defaultAgentId))"
    }

    // MARK: - Status visuals

    private var statusOrb: some View {
        Circle()
            .fill(orbColor.gradient)
            .frame(width: 110, height: 110)
            .overlay(Image(systemName: "brain.head.profile").font(.system(size: 40)).foregroundStyle(.white))
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
