//
//  RootView.swift
//  ClawWatch iOS
//

import SwiftUI

struct RootView: View {

    @State private var appState = AppState.shared

    var body: some View {
        Group {
            if appState.isMock || appState.isAuthenticated == true {
                ChatListScreen()
            } else if appState.isAuthenticated == false {
                LoginView()
            } else {
                ProgressView("Connecting…")
            }
        }
        .animation(.default, value: appState.isAuthenticated)
    }
}
