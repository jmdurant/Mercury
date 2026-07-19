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
    @State private var cfId: String = CloudflareAccess.clientId
    @State private var cfSecret: String = CloudflareAccess.clientSecret

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
                    Button(node.status == .connected || node.status == .connecting || node.status == .pending
                           ? "Disconnect Node" : "Connect as Node") {
                        if node.status == .idle || node.status == .error { node.start() }
                        else { node.stop() }
                    }
                } header: {
                    Text("OpenClaw node")
                } footer: {
                    Text("Registers this phone as an OpenClaw node so the agent can query location, health, and battery directly. First connect needs approval on the gateway (openclaw nodes approve).")
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
