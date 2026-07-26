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

    @Environment(\.systemPrefersReducedResourceUsage) private var prefersReducedResourceUsage
    @State private var voice = LiveVoiceService.shared
    @State private var ptt = PTTChannelService.shared
    @State private var node = OpenClawNodeService.shared
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
                        voice.start(agentId: agentId)
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

                pttToggle
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
            if isPerChat {
                let stored = voice.agentId(forChat: chatId!)
                // Fall back to the agent whose name matches this chat's title.
                agentId = stored.isEmpty ? (node.agent(forChatTitle: agentLabel)?.id ?? "") : stored
            } else {
                agentId = voice.defaultAgentId
            }
        }
    }

    // MARK: - System Push-to-Talk

    private var pttToggle: some View {
        VStack(spacing: 4) {
            Toggle("System Push-to-Talk", isOn: Binding(
                get: { ptt.isJoined },
                set: { on in
                    if on {
                        ptt.join(agentId: effectiveAgentId,
                                 agentName: isPerChat ? agentLabel : "Agent")
                    } else {
                        ptt.leave()
                    }
                }))
            .disabled(effectiveAgentId.isEmpty)
            Text(pttHint)
                .font(.caption2)
                .foregroundStyle(ptt.isTransmitting ? Color.green : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pttHint: String {
        if let err = ptt.lastError { return err }
        if !ptt.isJoined { return "Join to talk with the system PTT button — even in the background or on the lock screen." }
        return ptt.isTransmitting ? "Transmitting…" : "Joined — press the system PTT button to talk."
    }

    // MARK: - Agent selection

    private var agentConfig: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isPerChat ? "Agent id for \(agentLabel)" : "Default agent id")
                    .font(.caption).foregroundStyle(.secondary)

                // Agents from the gateway roster (if available) merged with the
                // ones you've designated by labeling chats.
                if !pickerAgents.isEmpty {
                    Menu {
                        ForEach(pickerAgents) { agent in
                            Button {
                                agentId = agent.id
                            } label: {
                                Label(agent.name, systemImage: agent.id == agentId ? "checkmark" : "person.circle")
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "person.2.wave.2")
                            Text(pickerAgents.first { $0.id == agentId }?.name
                                 ?? (agentId.isEmpty ? "Choose an agent" : agentId))
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .font(.subheadline)
                    }
                    // No manual box needed when the dropdown has agents.
                } else {
                    Text("Label a chat as an agent (chat list), or enter an id below.")
                        .font(.caption2).foregroundStyle(.tertiary)
                    TextField("agent id (what your server expects)", text: $agentId)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
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
                Text("Endpoint, token and auto-stop live in Agent settings.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .onChange(of: agentId) { _, new in
                if let chatId { voice.setAgentId(new, forChat: chatId) }
                else { voice.defaultAgentId = new }
            }
        }
    }

    /// Gateway roster (if connected) merged with agents you've registered by
    /// labeling chats. De-duplicated by id, roster names preferred.
    private var pickerAgents: [OpenClawNodeService.OCAgent] {
        var byId: [String: OpenClawNodeService.OCAgent] = [:]
        for a in voice.registeredAgents { byId[a.id] = .init(id: a.id, name: a.name) }
        for a in node.agents { byId[a.id] = a }   // roster wins on name
        return byId.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The reactive local selection drives enablement + start for both modes.
    private var effectiveAgentId: String { agentId }

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
            .animation(
                prefersReducedResourceUsage
                    ? .default
                    : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                value: voice.state
            )
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
