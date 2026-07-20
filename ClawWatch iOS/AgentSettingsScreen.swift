//
//  AgentSettingsScreen.swift
//  ClawWatch iOS
//
//  Trust controls for the AI agent channel, node/voice setup, and pairing.
//  Everyday controls up top; fallback + niche fields live under "Advanced".
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
    @State private var showResetConfirm = false
    @State private var showScanner = false
    @State private var pasteCode = ""
    @State private var showWatchScanner = false
    @State private var watchPairStatus = ""
    @State private var cfId: String = CloudflareAccess.clientId
    @State private var cfSecret: String = CloudflareAccess.clientSecret
    @State private var discovery = NodeDiscoveryService.shared
    @State private var voice = LiveVoiceService.shared
    @State private var voiceURL: String = LiveVoiceService.shared.endpoint
    @State private var voiceToken: String = LiveVoiceService.shared.voiceToken
    @State private var defaultAgent: String = LiveVoiceService.shared.defaultAgentId
    @State private var autoStop: Bool = LiveVoiceService.shared.autoStopOnSilence
    @State private var silenceTimeout: Double = LiveVoiceService.shared.silenceTimeout
    @State private var showAdvanced = false

    /// The voice endpoint implied by the gateway URL — same scheme + host on
    /// the voice port (shared box). Cloudflare split-hostname setups override it.
    private var voiceURLFromNodeHost: String? {
        LiveVoiceService.voiceURL(fromGateway: node.gatewayURL)
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Consent
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

                // MARK: Node (primary setup)
                Section {
                    LabeledContent("Status", value: node.status.rawValue)
                    if !node.lastEvent.isEmpty {
                        Text(node.lastEvent).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { showScanner = true } label: {
                        Label("Scan setup QR", systemImage: "qrcode.viewfinder")
                    }
                    HStack {
                        TextField("or paste setup code", text: $pasteCode)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Apply") {
                            if node.applySetupCode(pasteCode) {
                                nodeURL = node.gatewayURL; pasteCode = ""
                            }
                        }
                        .disabled(pasteCode.isEmpty)
                    }
                    Button(node.status == .connected || node.status == .connecting || node.status == .pending
                           ? "Disconnect Node" : "Connect as Node") {
                        if node.status == .idle || node.status == .error { node.start() }
                        else { node.stop() }
                    }
                    Button {
                        discovery.isBrowsing ? discovery.stop() : discovery.start()
                    } label: {
                        Label(discovery.isBrowsing ? "Searching…" : "Find on network",
                              systemImage: "wifi.router")
                    }
                    ForEach(discovery.gateways) { gw in
                        Button {
                            node.useDiscovered(endpoint: gw.endpoint, tls: gw.tls, url: gw.url)
                            nodeURL = gw.url; discovery.stop()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(gw.name).font(.caption)
                                Text(gw.url).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("OpenClaw node")
                } footer: {
                    Text("Scan the QR from `openclaw qr`, or Find on network. First connect needs approval on the gateway.")
                }

                // MARK: Live voice (knobs)
                Section {
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
                    Text("Agents load once the node is connected.")
                }

                // MARK: Advanced (fallbacks + niche, collapsed)
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        Text("Connection — normally filled by scan / Find on network")
                            .font(.caption2).foregroundStyle(.secondary)
                        TextField("ws://127.0.0.1:18789", text: $nodeURL)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onChange(of: nodeURL) { _, v in node.gatewayURL = v }
                        TextField("Gateway token", text: $nodeToken)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onChange(of: nodeToken) { _, v in node.token = v }
                        TextField("Device name (nodes list)", text: $deviceName)
                            .onChange(of: deviceName) { _, v in node.displayName = v }

                        TextField("Voice endpoint override (optional)", text: $voiceURL)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onChange(of: voiceURL) { _, v in voice.endpoint = v }
                        if voiceURL.isEmpty {
                            Text("Using node host: \(voice.effectiveEndpoint.isEmpty ? "—" : voice.effectiveEndpoint)")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else if let derived = voiceURLFromNodeHost, derived != voiceURL {
                            Button {
                                voiceURL = ""; voice.endpoint = ""
                            } label: {
                                Label("Reset to node host", systemImage: "arrow.uturn.backward").font(.caption)
                            }
                        }
                        TextField("Voice token", text: $voiceToken)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onChange(of: voiceToken) { _, v in voice.voiceToken = v }

                        TextField("CF-Access-Client-Id", text: $cfId)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onChange(of: cfId) { _, v in CloudflareAccess.clientId = v }
                        SecureField("CF-Access-Client-Secret", text: $cfSecret)
                            .onChange(of: cfSecret) { _, v in CloudflareAccess.clientSecret = v }

                        TextField("Command token (optional)", text: $token)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Save command token") {
                            AutoResponderStore.token = token.isEmpty ? nil : token
                        }

                        Toggle("Push arrival/departure", isOn: Binding(
                            get: { AutoResponderStore.isContextPushEnabled },
                            set: {
                                AutoResponderStore.isContextPushEnabled = $0
                                if $0 { ContextPushService.shared.start() }
                                else { ContextPushService.shared.stop() }
                            }))
                    }
                } footer: {
                    Text("Manual URLs/tokens, Cloudflare Access, the Telegram command token, and proactive context.")
                }

                // MARK: Activity
                Section("Recent agent activity") {
                    if log.isEmpty {
                        Text("No activity yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(log.prefix(50), id: \.self) { entry in
                            Text(entry).font(.system(.caption, design: .monospaced))
                        }
                        Button("Clear Log", role: .destructive) {
                            AutoResponderStore.clearAudit(); log = []
                        }
                    }
                }

                // MARK: Pair watch
                Section {
                    Button { showWatchScanner = true } label: {
                        Label("Pair Watch (scan its QR)", systemImage: "applewatch.radiowaves.left.and.right")
                    }
                    if !watchPairStatus.isEmpty {
                        Text(watchPairStatus).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("The watch has no camera — scan a second setup code here and the phone sends it to the watch, which pairs on its own. Approve the watch separately on the gateway.")
                }

                // MARK: Reset
                Section {
                    Button("Reset OpenClaw Setup", role: .destructive) { showResetConfirm = true }
                } footer: {
                    Text("Clears the gateway URL, tokens, agents, voice config, and this device's identity. You'll reconfigure and re-approve.")
                }
            }
            .navigationTitle("Agent Access")
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    QRScannerView { code in
                        if node.applySetupCode(code) { nodeURL = node.gatewayURL }
                        showScanner = false
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan setup QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { showScanner = false } } }
                }
            }
            .sheet(isPresented: $showWatchScanner) {
                NavigationStack {
                    QRScannerView { code in
                        if let (url, bt) = OpenClawNodeService.decodeSetupCode(code), !bt.isEmpty {
                            let sent = WatchBridge.shared.sendPairingToWatch(url: url, bootstrapToken: bt)
                            watchPairStatus = sent
                                ? "Sent to watch — open ClawWatch on the watch, then approve it on the gateway."
                                : "Couldn't reach the watch app. Make sure it's installed."
                        } else {
                            watchPairStatus = "That QR isn't an OpenClaw setup code."
                        }
                        showWatchScanner = false
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan the watch's QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { showWatchScanner = false } } }
                }
            }
            .confirmationDialog("Reset OpenClaw Setup?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("Reset everything", role: .destructive) {
                    node.resetSetup()
                    nodeURL = ""; nodeToken = ""; deviceName = node.displayName
                    voiceURL = ""; voiceToken = ""; defaultAgent = ""
                    cfId = ""; cfSecret = ""
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This unpairs this device from the gateway and clears all config.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }
}
