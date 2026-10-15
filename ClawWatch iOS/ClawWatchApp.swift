//
//  ClawWatchApp.swift
//  ClawWatch iOS
//
//  iOS companion built on the shared TDLib service core.
//

import SwiftUI

@main
struct ClawWatchApp: App {

    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Auto-plays incoming voice notes in walkie-talkie chats
    private let pttService = PTTService()
    // Retain the subscriber for the lifetime of the app, as on watchOS.
    private let autoResponder = AutoResponderService()

    init() {
        // Touch the singleton so the TDLib client is created at launch and
        // starts driving AppState.isAuthenticated
        _ = TDLibManager.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, OpenClawNodeService.shared.isAutoConnect {
                        OpenClawNodeService.shared.start()
                    }
                }
        }
    }
}
