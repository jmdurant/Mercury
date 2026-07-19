//
//  ClawWatchApp.swift
//  ClawWatch iOS
//
//  iOS companion built on the shared TDLib service core.
//

import SwiftUI

@main
struct ClawWatchApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Auto-plays incoming voice notes in walkie-talkie chats
    private let pttService = PTTService()

    init() {
        // Touch the singleton so the TDLib client is created at launch and
        // starts driving AppState.isAuthenticated
        _ = TDLibManager.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
