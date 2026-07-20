//
//  LoginPage.swift
//  Mercury Watch App
//
//  Created by Marco Tammaro on 02/11/24.
//

import SwiftUI

struct SettingsPage: View {
    
    @State
    @Mockable(mockInit: SettingsViewModelMock.init)
    var vm = SettingsViewModel.init

    @State private var voiceAgentId = LiveVoiceService.shared.defaultAgentId
    @State private var deviceName = OpenClawNodeService.shared.displayName
    @State private var showResetConfirm = false
    
    var body: some View {
        ScrollView {
            avatarHeader()
            Spacer()

            Button {
                vm.loadAccountDetails()
            } label: {
                Label("Account", systemImage: "person.circle")
            }

            Button {
                vm.loadSessions()
            } label: {
                Label("Devices", systemImage: "desktopcomputer")
            }

            Picker(selection: Binding(
                get: { AutoResponderStore.doubleTapAction },
                set: { AutoResponderStore.doubleTapAction = $0 }
            )) {
                ForEach(AutoResponderStore.DoubleTapAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            } label: {
                Label("Double Tap", systemImage: "hand.tap.fill")
            }

            Button {
                vm.showDndSettings = true
            } label: {
                Label("Focus Auto-Reply", systemImage: "moon.fill")
            }

            Button {
                vm.showPTTSettings = true
            } label: {
                Label("Walkie-Talkie", systemImage: "antenna.radiowaves.left.and.right")
            }

            Button {
                vm.showAgentSettings = true
            } label: {
                Label("Agent Access", systemImage: "brain.head.profile")
            }

            Button("Logout", role: .destructive) {
                vm.logout()
            }
            .padding(.top)

            credits()
                .padding(.top)
        }
        .sheet(isPresented: $vm.showAccountSettings) {
            accountSettingsView()
        }
        .sheet(isPresented: $vm.showDndSettings) {
            dndSettingsView()
        }
        .sheet(isPresented: $vm.showSessions) {
            sessionsView()
        }
        .sheet(isPresented: $vm.showPTTSettings) {
            pttSettingsView()
        }
        .sheet(isPresented: $vm.showAgentSettings) {
            agentSettingsView()
        }
    }

    @ViewBuilder
    func agentSettingsView() -> some View {
        List {
            Section {
                ForEach(AutoResponderStore.Consent.allCases) { c in
                    Toggle(c.label, isOn: Binding(
                        get: { AutoResponderStore.isConsented(c) },
                        set: { AutoResponderStore.setConsent(c, $0) }
                    ))
                    .font(.caption)
                }
            } header: {
                Text("Agent may access")
            } footer: {
                Text("Controls which data/actions designated assistant chats can request")
            }

            Section {
                let node = OpenClawNodeService.shared
                Text("Node: \(node.status.rawValue)").font(.caption)
                if !node.lastEvent.isEmpty {
                    Text(node.lastEvent).font(.caption2).foregroundStyle(.secondary)
                }
                Button(node.status == .connected || node.status == .connecting ? "Disconnect" : "Connect Node") {
                    if node.status == .idle || node.status == .error { node.start() } else { node.stop() }
                }
                .font(.caption)

                // Standalone setup: discover the gateway on Wi-Fi
                let discovery = NodeDiscoveryService.shared
                Button {
                    discovery.isBrowsing ? discovery.stop() : discovery.start()
                } label: {
                    Text(discovery.isBrowsing ? "Searching…" : "Find on network").font(.caption)
                }
                ForEach(discovery.gateways) { gw in
                    Button {
                        node.useDiscovered(endpoint: gw.endpoint, tls: gw.tls, url: gw.url)
                        discovery.stop()
                    } label: {
                        Text(gw.name).font(.caption2)
                    }
                }

                TextField("Device name", text: $deviceName)
                    .font(.caption2)
                    .onChange(of: deviceName) { _, v in node.displayName = v }

                Button("Reset Setup", role: .destructive) { showResetConfirm = true }
                    .font(.caption)
                    .confirmationDialog("Reset OpenClaw setup?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                        Button("Reset everything", role: .destructive) {
                            node.resetSetup()
                            deviceName = node.displayName
                            voiceAgentId = ""
                        }
                        Button("Cancel", role: .cancel) {}
                    }
            } header: {
                Text("OpenClaw node")
            } footer: {
                Text("Config syncs from iPhone via iCloud. Standalone, tap Find on network to discover the gateway on Wi-Fi. Connects while in the foreground.")
            }

            Section {
                let voice = LiveVoiceService.shared
                let node = OpenClawNodeService.shared
                Text("Voice: \(voice.state.rawValue)").font(.caption)

                // Agent picker — fed by the gateway roster (node connected)
                if !node.agents.isEmpty {
                    Picker("Agent", selection: $voiceAgentId) {
                        ForEach(node.agents) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                    }
                    .font(.caption)
                    .onChange(of: voiceAgentId) { _, id in voice.defaultAgentId = id }
                } else if !voice.defaultAgentId.isEmpty {
                    Text("Agent: \(voice.defaultAgentId)").font(.caption2).foregroundStyle(.secondary)
                }

                Button(voice.state == .live || voice.state == .connecting ? "End" : "Talk to Agent") {
                    if voice.state == .live || voice.state == .connecting { voice.stop() }
                    else { voice.start(agentId: voiceAgentId.isEmpty ? nil : voiceAgentId) }
                }
                .font(.caption)
            } header: {
                Text("Live voice")
            } footer: {
                Text("Talks to the selected agent (roster synced from your gateway). Stays connected while the session runs, even when your wrist drops.")
            }

            Section("Recent agent activity") {
                let log = AutoResponderStore.auditLog()
                if log.isEmpty {
                    Text("No activity yet").font(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(log.prefix(20), id: \.self) { entry in
                        Text(entry).font(.system(.caption2, design: .monospaced))
                    }
                    Button("Clear Log", role: .destructive) {
                        AutoResponderStore.clearAudit()
                    }
                }
            }
        }
        .navigationTitle("Agent Access")
    }

    @ViewBuilder
    func pttSettingsView() -> some View {
        List {
            Section {
                Toggle("Auto-play voice notes", isOn: Binding(
                    get: { PTTStore.isAutoPlayEnabled },
                    set: { PTTStore.isAutoPlayEnabled = $0 }
                ))
            } footer: {
                Text("Incoming voice notes in walkie-talkie chats play automatically")
            }

            Section {
                Text("\(PTTStore.chatCount) walkie-talkie \(PTTStore.chatCount == 1 ? "chat" : "chats")")
                    .foregroundStyle(.secondary)
                Button("Remove All", role: .destructive) {
                    PTTStore.clearAll()
                    vm.showPTTSettings = false
                }
            } footer: {
                Text("Enable walkie-talkie per chat from the antenna button in the chat toolbar")
            }
        }
        .navigationTitle("Walkie-Talkie")
    }

    @ViewBuilder
    func accountSettingsView() -> some View {
        ScrollView {
            VStack(spacing: 12) {
                TextField("First Name", text: $vm.firstName)
                TextField("Last Name", text: $vm.lastName)
                TextField("Bio", text: $vm.bio)

                Button {
                    vm.saveName()
                    vm.showAccountSettings = false
                } label: {
                    if vm.isSaving {
                        ProgressView()
                    } else {
                        Label("Save", systemImage: "checkmark.circle")
                    }
                }
                .tint(.blue)
                .disabled(vm.isSaving || vm.firstName.isEmpty)
            }
        }
        .navigationTitle("Account")
    }

    @ViewBuilder
    func dndSettingsView() -> some View {
        let profiles = AutoResponderStore.getProfiles()

        List {
            Section {
                Toggle("Enable", isOn: Binding(
                    get: { AutoResponderStore.isFocusAutoReplyEnabled },
                    set: { AutoResponderStore.isFocusAutoReplyEnabled = $0 }
                ))
            } footer: {
                Text("Auto-reply when Focus/DND is active")
            }

            Section {
                Picker("Profile", selection: Binding(
                    get: { AutoResponderStore.activeProfileId },
                    set: { AutoResponderStore.activeProfileId = $0 }
                )) {
                    ForEach(profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
            } header: {
                Text("Active Profile")
            } footer: {
                Text("Auto-detects Sleep mode at night")
            }

            ForEach(profiles) { profile in
                Section(profile.name) {
                    Text(profile.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        if profile.includeCalendar { Label("Cal", systemImage: "calendar").font(.caption2) }
                        if profile.includeWorkout { Label("Workout", systemImage: "figure.run").font(.caption2) }
                        if profile.includeHealth { Label("Health", systemImage: "heart").font(.caption2) }
                        if profile.includeLocation { Label("Loc", systemImage: "location").font(.caption2) }
                        if profile.includeBattery { Label("Bat", systemImage: "battery.50percent").font(.caption2) }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Focus Auto-Reply")
    }

    @ViewBuilder
    func sessionsView() -> some View {
        List {
            ForEach(vm.sessions) { session in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(session.name)
                            .font(.headline)
                            .lineLimit(1)
                        if session.isCurrent {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                    Text(session.device)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(session.lastActive)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .swipeActions(edge: .trailing) {
                    if !session.isCurrent {
                        Button("Terminate", role: .destructive) {
                            vm.terminateSession(session)
                        }
                    }
                }
            }
        }
        .navigationTitle("Devices")
    }
    
    @ViewBuilder
    func avatarHeader() -> some View {
        ZStack {
            Image(uiImage: vm.user?.thumbnail ?? UIImage())
            .resizable()
            .frame(height: 120)
            .clipShape(Ellipse())
            .blur(radius: 30)
            .opacity(0.8)
            .liquidGlass()
            
            VStack {
                
                if let avatar = vm.user?.avatar {
                    AvatarView(model: avatar)
                        .frame(width: 50, height: 50)
                }
                
                Text(vm.user?.fullName ?? "")
                    .fontDesign(.rounded)
                    .fontWeight(.semibold)
                Text(vm.user?.mainUserName ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(vm.user?.phoneNumber ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 120)
    }
    
    @ViewBuilder
    func credits() -> some View {
        VStack {
            TextDivider("by")
            HStack {
                creditsAvatar(
                    name: "Alessandro\nAlberti",
                    image: "alessandro"
                )
                Spacer()
                creditsAvatar(
                    name: "Marco\nTammaro",
                    image: "marco"
                )
            }
        }
        .padding(.horizontal)
    }
    
    @ViewBuilder
    func creditsAvatar(name: String, image: String) -> some View {
        VStack {
            Image(image)
                .resizable()
                .frame(width: 50, height: 50)
                .clipShape(Circle())
            Text(name)
                .multilineTextAlignment(.center)
        }
    }
}

#Preview(traits: .mock()) {
    SettingsPage()
}
