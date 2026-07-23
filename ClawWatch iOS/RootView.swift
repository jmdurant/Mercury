//
//  RootView.swift
//  ClawWatch iOS
//

import SwiftUI

/// User-selectable app appearance. Stored via @AppStorage ("appAppearance").
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

struct RootView: View {

    @State private var appState = AppState.shared
    @AppStorage("appAppearance") private var appearance: AppAppearance = .system

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
        .preferredColorScheme(appearance.colorScheme)
    }
}
