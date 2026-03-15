//
//  LoginViewModel.swift
//  Mercury Watch App
//
//  Created by Marco Tammaro on 02/11/24.
//

import Foundation
import SwiftUI
import TDLibKit

@Observable
class SettingsViewModel: TDLibViewModel {
    
    var user: UserModel?
    var firstName: String = ""
    var lastName: String = ""
    var bio: String = ""
    var sessions: [SessionItem] = []
    var showAccountSettings: Bool = false
    var showSessions: Bool = false
    var isSaving: Bool = false

    struct SessionItem: Identifiable {
        let id: Int64
        let name: String
        let device: String
        let location: String
        let lastActive: String
        let isCurrent: Bool
    }

    override init() {
        super.init()
        getUser()
    }

    func logout() {
        LoginViewModel.logout()
    }

    func loadAccountDetails() {
        Task.detached {
            do {
                guard let user = try await TDLibManager.shared.client?.getMe()
                else { return }

                let fullInfo = try await TDLibManager.shared.client?.getUserFullInfo(userId: user.id)

                await MainActor.run {
                    self.firstName = user.firstName
                    self.lastName = user.lastName
                    self.bio = fullInfo?.bio?.text ?? ""
                    self.showAccountSettings = true
                }
            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }

    func saveName() {
        guard !firstName.isEmpty else { return }
        isSaving = true
        Task.detached {
            do {
                try await TDLibManager.shared.client?.setName(
                    firstName: self.firstName,
                    lastName: self.lastName
                )
                try await TDLibManager.shared.client?.setBio(bio: self.bio)
                await MainActor.run {
                    self.isSaving = false
                    self.getUser()
                }
            } catch {
                self.logger.log(error, level: .error)
                await MainActor.run { self.isSaving = false }
            }
        }
    }

    func loadSessions() {
        Task.detached {
            do {
                guard let result = try await TDLibManager.shared.client?.getActiveSessions()
                else { return }

                let items = result.sessions.map { session in
                    let lastActive = Date(timeIntervalSince1970: TimeInterval(session.lastActiveDate))
                    return SessionItem(
                        id: session.id.rawValue,
                        name: "\(session.applicationName) \(session.applicationVersion)",
                        device: session.deviceModel,
                        location: "\(session.country), \(session.region)".trimmingCharacters(in: CharacterSet(charactersIn: ", ")),
                        lastActive: session.isCurrent ? "Current session" : lastActive.formatted(.dateTime.month().day().hour().minute()),
                        isCurrent: session.isCurrent
                    )
                }

                await MainActor.run {
                    self.sessions = items
                    self.showSessions = true
                }
            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }

    func terminateSession(_ session: SessionItem) {
        Task.detached {
            do {
                try await TDLibManager.shared.client?.terminateSession(
                    sessionId: TdInt64(session.id)
                )
                await MainActor.run {
                    self.sessions.removeAll { $0.id == session.id }
                }
            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }

    fileprivate func getUser() {
        
        Task.detached(priority: .userInitiated) {
            
            do {
                guard let user = try await TDLibManager.shared.client?.getMe()
                else { return }
                
                await MainActor.run {
                    withAnimation {
                        self.user = user.toUserModel()
                    }
                }
                
            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }
}

struct UserModel {
    let thumbnail: UIImage?
    let avatar: AvatarModel
    let fullName: String
    let mainUserName: String
    let phoneNumber: String
}

// MARK: - Mock
@Observable
class SettingsViewModelMock: SettingsViewModel {
    override func getUser() {
        self.user = .init(
            thumbnail: UIImage(named: "alessandro"),
            avatar: .alessandro,
            fullName: "John Appleseed",
            mainUserName: "@johnappleseed",
            phoneNumber: "+39 0000000000"
        )
    }
    override func loadAccountDetails() {
        firstName = "John"
        lastName = "Appleseed"
        bio = "Hello world"
        showAccountSettings = true
    }
    override func loadSessions() {
        sessions = [SessionItem(id: 1, name: "Mercury 1.0", device: "Apple Watch", location: "US", lastActive: "Current session", isCurrent: true)]
        showSessions = true
    }
}
