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
