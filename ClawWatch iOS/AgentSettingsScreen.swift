//
//  AgentSettingsScreen.swift
//  ClawWatch iOS
//
//  Trust controls for the AI agent channel: per-category consent, an
//  optional shared-secret token, and a reviewable audit log.
//

import SwiftUI

struct AgentSettingsScreen: View {

    @Binding var isPresented: Bool
    @State private var token: String = AutoResponderStore.token ?? ""
    @State private var log: [String] = AutoResponderStore.auditLog()
    @State private var node = OpenClawNodeService.shared
    @State private var nodeURL: String = OpenClawNodeService.shared.gatewayURL
    @State private var nodeToken: String = OpenClawNodeService.shared.token
    @State private var deviceName: String = OpenClawNodeService.shared.displayName
    @State private var cfId: String = CloudflareAccess.clientId
    @State private var cfSecret: String = CloudflareAccess.clientSecret
    @State private var discovery = NodeDiscoveryService.shared
    @State private var voice = LiveVoiceService.shared
    @State private var voiceURL: String = LiveVoiceService.shared.endpoint
    @State private var voiceToken: String = LiveVoiceService.shared.voiceToken
    @State private var defaultAgent: String = LiveVoiceService.shared.defaultAgentId
    @State private var autoStop: Bool = LiveVoiceService.shared.autoStopOnSilence
    @State private var silenceTimeout: Double = LiveVoiceService.shared.silenceTimeout

    private let voicePort = 8790

    /// The voice endpoint implied by the gateway URL — same scheme + host on
    /// the voice port. Works for a shared host (LAN / same box); Cloudflare
    /// setups with a separate voice hostname would edit it afterward.
    private var voiceURLFromNodeHost: String? {
        guard var comps = URLComponents(string: node.gatewayURL),
              comps.host != nil, comps.scheme?.hasPrefix("ws") == true else { return nil }
        comps.port = voicePort
        comps.path = ""
        comps.query = nil
        return comps.string
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(AutoResponderStore.Consent.allCases) { c in
                        Toggle(c.label, isOn: Binding(
                            get: { AutoResponderStore.isConsented(c) },
                            set: { AutoResponderStore.setConsent(c, $0) }
                        ))
                    }
                } header: {
                    Text("Agent may access")
                } footer: {
                    Text("Controls which data and actions designated assistant chats can request.")
                }

                Section {
                    TextField("Optional shared secret", text: $token)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Save Token") {
                        AutoResponderStore.token = token.isEmpty ? nil : token
                    }
                } header: {
                    Text("Command token")
                } footer: {
                    Text("When set, commands must be sent as \"#\(token.isEmpty ? "token" : token) status\". Prevents a hijacked chat from querying you.")
                }

                Section {
                    Toggle("Push arrival/departure", isOn: Binding(
                        get: { AutoResponderStore.isContextPushEnabled },
                        set: {
                            AutoResponderStore.isContextPushEnabled = $0
                            if $0 { ContextPushService.shared.start() }
                            else { ContextPushService.shared.stop() }
                        }
                    ))
                } header: {
                    Text("Proactive context")
                } footer: {
                    Text("Sends a note to assistant chats when you arrive at or leave a place, so the agent has context without polling.")
                }

                Section {
                    LabeledContent("Status", value: node.status.rawValue)
                    if !node.lastEvent.isEmpty {
                        Text(node.lastEvent).font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("ws://127.0.0.1:18789", text: $nodeURL)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onChange(of: nodeURL) { _, v in node.gatewayURL = v }
                    TextField("Gateway token", text: $nodeToken)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onChange(of: nodeToken) { _, v in node.token = v }
                    TextField("Device name (shown in nodes list)", text: $deviceName)
                        .onChange(of: deviceName) { _, v in node.displayName = v }
                    Button(node.status == .connected || node.status == .connecting || node.status == .pending
                           ? "Disconnect Node" : "Connect as Node") {
                        if node.status == .idle || node.status == .error { node.start() }
                        else { node.stop() }
                    }

                    // Bonjour discovery on the local network
                    Button {
                        discovery.isBrowsing ? discovery.stop() : discovery.start()
                    } label: {
                        Label(discovery.isBrowsing ? "Searching…" : "Find on network",
                              systemImage: "wifi.router")
                    }
                    ForEach(discovery.gateways) { gw in
                        Button {
                            nodeURL = gw.url
                            node.gatewayURL = gw.url
                            discovery.stop()
                        } label: {
                            HStack {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                VStack(alignment: .leading) {
                                    Text(gw.name).font(.caption)
                                    Text(gw.url).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("OpenClaw node")
                } footer: {
                    Text("Registers this phone as an OpenClaw node so the agent can query location, health, and battery directly. First connect needs approval on the gateway (openclaw nodes approve).")
                }

                Section {
                    TextField("ws://127.0.0.1:8790", text: $voiceURL)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onChange(of: voiceURL) { _, v in voice.endpoint = v }
                    if let derived = voiceURLFromNodeHost, derived != voiceURL {
                        Button {
                            voiceURL = derived
                            voice.endpoint = derived
                        } label: {
                            Label("Use node host (:8790)", systemImage: "arrow.down.doc")
                                .font(.caption)
                        }
                    }
                    TextField("Voice token", text: $voiceToken)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onChange(of: voiceToken) { _, v in voice.voiceToken = v }

                    if !node.agents.isEmpty {
                        Picker("Default agent", selection: $defaultAgent) {
                            Text("None").tag("")
                            ForEach(node.agents) { a in Text(a.name).tag(a.id) }
                        }
                        .onChange(of: defaultAgent) { _, v in voice.defaultAgentId = v }
                    } else {
                        TextField("Default agent id", text: $defaultAgent)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onChange(of: defaultAgent) { _, v in voice.defaultAgentId = v }
                    }

                    Toggle("Auto-stop when quiet", isOn: $autoStop)
                        .onChange(of: autoStop) { _, v in voice.autoStopOnSilence = v }
                    if autoStop {
                        HStack {
                            Slider(value: $silenceTimeout, in: 3...30, step: 1)
                                .onChange(of: silenceTimeout) { _, v in voice.silenceTimeout = v }
                            Text("\(Int(silenceTimeout))s").monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                } header: {
                    Text("Live voice")
                } footer: {
                    Text("Same OpenClaw box as the node, usually port 8790. Agents load once the node is connected. Endpoint, token and default agent sync to the watch via iCloud.")
                }

                Section {
                    TextField("CF-Access-Client-Id", text: $cfId)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onChange(of: cfId) { _, v in CloudflareAccess.clientId = v }
                    SecureField("CF-Access-Client-Secret", text: $cfSecret)
                        .onChange(of: cfSecret) { _, v in CloudflareAccess.clientSecret = v }
                } header: {
                    Text("Cloudflare Access (optional)")
                } footer: {
                    Text("For a gateway behind Cloudflare Tunnel + Access. Leave blank for a plain tunnel or LAN. Syncs to the watch via iCloud and applies to both the node and voice connections.")
                }

                Section("Recent agent activity") {
                    if log.isEmpty {
                        Text("No activity yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(log.prefix(50), id: \.self) { entry in
                            Text(entry).font(.system(.caption, design: .monospaced))
                        }
                        Button("Clear Log", role: .destructive) {
                            AutoResponderStore.clearAudit()
                            log = []
                        }
                    }
                }
            }
            .navigationTitle("Agent Access")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }
}
