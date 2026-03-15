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

            Button {
                vm.showDndSettings = true
            } label: {
                Label("Focus Auto-Reply", systemImage: "moon.fill")
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
        @State var profiles = AutoResponderStore.getProfiles()
        @State var activeId = AutoResponderStore.activeProfileId

        List {
            Section {
                Toggle("Enable", isOn: Binding(
                    get: { AutoResponderStore.isFocusAutoReplyEnabled },
                    set: { AutoResponderStore.isFocusAutoReplyEnabled = $0 }
                ))
            } footer: {
                Text("Auto-reply when Focus/DND is active")
            }

            Section("Active Profile") {
                Picker("Profile", selection: Binding(
                    get: { AutoResponderStore.activeProfileId },
                    set: { AutoResponderStore.activeProfileId = $0 }
                )) {
                    ForEach(profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
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
