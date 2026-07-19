//
//  ClawWatchApp.swift
//  ClawWatch iOS
//
//  iOS companion built on the shared TDLib service core.
//

import SwiftUI

@main
struct ClawWatchApp: App {

    init() {
        // Touch the singleton so the TDLib client is created at launch and
        // starts driving AppState.isAuthenticated
        _ = TDLibManager.shared
        NotificationService.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
