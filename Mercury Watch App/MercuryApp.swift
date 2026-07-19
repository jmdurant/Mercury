//
//  MercuryApp.swift
//  Mercury Watch App
//
//  Created by Marco Tammaro on 18/04/24.
//

import SwiftUI
import WidgetKit

@main
struct MercuryApp: App {
    @Environment(\.isLuminanceReduced) var isLuminanceReduced
    @WKApplicationDelegateAdaptor var appDelegate: AppDelegate
    private let unreadCountBridge = UnreadCountBridge()
    private let autoResponder = AutoResponderService()
    private let pttService = PTTService()

    var body: some Scene {
        WindowGroup {

            let isMock = AppState.shared.isMock
            let isAuthenticated = AppState.shared.isAuthenticated

            if isMock || isAuthenticated == true {
                HomePage()
            } else if isAuthenticated == false {
                LoginPage()
            } else {
                ProgressView()
            }

        }
        .onChange(of: isLuminanceReduced) {
            if isLuminanceReduced {
                LoginViewModel.setOfflineStatus()
                OpenClawNodeService.shared.stop()   // node is foreground-only
            } else {
                LoginViewModel.setOnlineStatus()
                if OpenClawNodeService.shared.isAutoConnect {
                    OpenClawNodeService.shared.start()
                }
            }
        }
        .backgroundTask(.appRefresh("mercury.sync")) {
            await BackgroundSyncService.performSync()
        }

    }
}
