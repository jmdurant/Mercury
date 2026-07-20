//
//  LoginViewModel.swift
//  Mercury Watch App
//
//  Created by Marco Tammaro on 02/11/24.
//

import Foundation
import SwiftUI
import TDLibKit

enum LoginViewModelState {
    case qrCodeLogin
    case tutorial
    
    case phoneNumberLogin
    case phoneNumberLoginFailure
    
    case authCode
    case authCodeFailure
    
    case twoFactorPassword
    case twoFactorPasswordFailure
}

@Observable
class LoginViewModel: TDLibViewModel {
    
    var state: LoginViewModelState? = nil {
        didSet {
            self.onStateChange(oldValue: oldValue, newValue: state)
        }
    }
    
    var isLoading: Bool = true
    var errorMessage: String? = nil
    var showFullscreenQR: Bool = false
    // Phone login: the app auto-requests a QR at launch (moving TDLib into
    // WaitOtherDeviceConfirmation), so a phone submit must first reset the
    // auth flow back to WaitPhoneNumber. We stash the number and submit it
    // once that state arrives.
    private var pendingPhoneNumber: String? = nil
    private var phoneResetInFlight = false
    private var watchdog: Task<Void, Never>? = nil
    var showTermsOfService: Bool = !UserDefaults.standard.bool(forKey: "hasAcceptedTermsOfService")
    var qrCodeLink: String? = nil
    var lastInputCta: String? = nil
    
    let tutorialSteps = [
        "Open Telegram on your phone",
        "Go to Settings → Devices → Link Desktop Device",
        "Point your phone at the QR code to confirm login"
    ]
    
    func onStateChange(oldValue: LoginViewModelState?, newValue: LoginViewModelState?) {
        
        self.isLoading = false
        
        switch (oldValue, newValue) {
            
        case (.phoneNumberLogin, .qrCodeLogin), // Login with phone number dismissed, request new qrcode
             (.phoneNumberLoginFailure, .qrCodeLogin), // Login with phone number failure dismissed, request new qrcode
             (.twoFactorPassword, .qrCodeLogin), // Password dismissed, request new qrcode
             (.twoFactorPasswordFailure, .qrCodeLogin): // Password failure dismissed, request new qrcode
            // After logout authorizationStateWaitPhoneNumber update will be
            // triggered and new qrcode will be requested
            self.logout()
            self.qrCodeLink = nil
            self.lastInputCta = nil
            break
        
        case (.qrCodeLogin, .twoFactorPassword): // Qrcode used, not valid anymore
            self.qrCodeLink = nil
            break
            
        case (.tutorial, .phoneNumberLogin): // Request authorization via phone number
            // Doing logout to invalide current authentication flow and start a new one
            // After logout authorizationStateWaitPhoneNumber update will be triggered
            self.logout()
            break
        
        default:
            break
        }
        
    }
    
    func didPressQR() {
        withAnimation(.bouncy) {
            showFullscreenQR.toggle()
        }
    }
    
    func didPressInfoButton() {
        self.state = .tutorial
    }
    
    func didPressLoginButton() {
        self.state = .phoneNumberLogin
    }
    
    func didPressAcceptTermsOfService() {
        showTermsOfService = false
        UserDefaults.standard.set(true, forKey: "hasAcceptedTermsOfService")
    }
    
    // MARK: - TDLib
    override func updateHandler(update: Update) {
        super.updateHandler(update: update)
        guard case .updateChatFolders(let update) = update else { return }
        Task { @MainActor in self.updateChatFolders(update) }
    }
    
    override func authorizationStateUpdate(state: AuthorizationState) {
        
        self.logger.log(state, level: .debug)
        
        switch state {
            
        case .authorizationStateWaitPhoneNumber: // Triggered at app start and after each logout
            if self.state == .phoneNumberLogin, let pending = self.pendingPhoneNumber {
                // We reset the flow specifically to submit a phone number —
                // now that we're in the right state, submit it. (Keep
                // phoneResetInFlight set so a second "unexpected" fails loudly
                // instead of looping.)
                self.submitAuthenticationPhoneNumber(pending)
            } else if self.state != .phoneNumberLogin {
                withAnimation {
                    self.isLoading = true
                }
                self.getQrcodeLink()
            }
            
        case .authorizationStateWaitOtherDeviceConfirmation(let info): // Requested qrcode login, link available
            Task { @MainActor in
                withAnimation {
                    if self.qrCodeLink == nil {
                        self.state = .qrCodeLogin
                    }
                }
                self.qrCodeLink = info.link
            }
         
        case .authorizationStateWaitPassword(_):
            Task { @MainActor in
                withAnimation {
                    self.state = .twoFactorPassword
                }
            }
        
        case .authorizationStateWaitCode(_):
            Task { @MainActor in
                withAnimation {
                    self.state = .authCode
                }
            }
            
        default:
            break
        }
    }
    
    func getQrcodeLink() {
        Task {
            do {
                let result = try await TDLibManager.shared.client?.requestQrCodeAuthentication(otherUserIds: [])
                self.logger.log(result)
                
            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }
    
    func setPhoneNumber(_ phoneNumber: String) {
        
        // Demo
        if phoneNumber == "999" {
            LoginViewModel.logout()
            AppState.shared.isMock = true
            return
        }
        
        self.isLoading = true
        self.errorMessage = nil
        self.lastInputCta = phoneNumber
        self.pendingPhoneNumber = phoneNumber
        self.state = .phoneNumberLogin   // stops WaitPhoneNumber re-requesting a QR

        // Watchdog: if TDLib neither returns nor delivers a follow-up state
        // (e.g. it can't reach a data center), don't spin forever.
        self.watchdog?.cancel()
        self.watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            if self.isLoading {
                self.isLoading = false
                self.errorMessage = "No response from Telegram — check the connection and try again."
            }
        }

        submitAuthenticationPhoneNumber(phoneNumber)
    }

    /// Calls TDLib's setAuthenticationPhoneNumber. If we're mid-QR
    /// (WaitOtherDeviceConfirmation), TDLib rejects it as "unexpected"; we
    /// reset the auth flow once (logout → WaitPhoneNumber), and the
    /// WaitPhoneNumber handler resubmits the stashed number.
    private func submitAuthenticationPhoneNumber(_ phoneNumber: String) {
        Task {
            do {
                let result = try await TDLibManager.shared.client?.setAuthenticationPhoneNumber(
                    phoneNumber: phoneNumber,
                    settings: nil
                )
                self.logger.log(result)
                await MainActor.run {
                    self.pendingPhoneNumber = nil
                    self.phoneResetInFlight = false
                }

            } catch {
                self.logger.log(error, level: .error)
                let message = (error as? TDLibKit.Error)?.message ?? String(describing: error)

                if message.localizedCaseInsensitiveContains("unexpected"), !self.phoneResetInFlight {
                    // Wrong auth state (mid-QR): reset to WaitPhoneNumber and retry once.
                    self.phoneResetInFlight = true
                    self.logout()
                    return
                }

                await MainActor.run {
                    self.watchdog?.cancel()
                    self.isLoading = false
                    self.pendingPhoneNumber = nil
                    self.phoneResetInFlight = false
                    self.errorMessage = message
                    if message == "PHONE_NUMBER_INVALID" {
                        self.state = .phoneNumberLoginFailure
                    }
                }
            }
        }
    }
    
    func validatePassword(_ password: String) {
        
        self.isLoading = true
        
        Task {
            do {
                let result = try await TDLibManager.shared.client?.checkAuthenticationPassword(password: password)
                self.logger.log(result)
                
                // Authenticated.. login will be dismissed by app
                
            } catch {
                self.logger.log(error, level: .error)
                guard let error = error as? TDLibKit.Error else { return }
                if error.message == "PASSWORD_HASH_INVALID" {
                    await MainActor.run {
                        self.state = .twoFactorPasswordFailure
                    }
                }
            }
        }
    }
    
    func validateAuthCode(_ code: String) {
        
        self.isLoading = true
        self.lastInputCta = code
        
        Task {
            do {
                let result = try await TDLibManager.shared.client?.checkAuthenticationCode(code: code)
                self.logger.log(result)
                
                // Authenticated (login will be dismissed by app) or password required
                
            } catch {
                self.logger.log(error, level: .error)
                guard let error = error as? TDLibKit.Error else { return }
                if error.message == "PHONE_CODE_INVALID" {
                    await MainActor.run {
                        self.state = .authCodeFailure
                    }
                }
                
            }
        }
    }
    
    @MainActor
    func updateChatFolders(_ update: UpdateChatFolders) {
        for chatFolderInfo in update.chatFolders {
            let chatList = ChatList.chatListFolder(ChatListFolder(chatFolderId: chatFolderInfo.id))
            let folder = ChatFolder(title: chatFolderInfo.name.text.text, chatList: chatList)
            AppState.shared.insertFolder(folder)
        }
    }
    
    func logout() {
        Task.detached {
            do {
                let result = try await TDLibManager.shared.client?.logOut()
                self.logger.log(result)
            } catch {
                self.logger.log(error, level: .error)
            }
        }
    }
    
    static func logout() {

        let logger = LoggerService(LoginViewModel.self)

        if AppState.shared.isMock {
            AppState.shared.isMock = false
            return
        }

        AppState.shared.clear()

        // Clear persisted user data
        UserDefaults.standard.removeObject(forKey: "hasAcceptedTermsOfService")
        KeychainService.deleteAll()

        // Clean temporary files
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory)

        Task.detached {
            do {
                let result = try await TDLibManager.shared.client?.logOut()
                logger.log(result)
            } catch {
                logger.log(error, level: .error)
            }

            TDLibManager.shared.close()
        }
    }
    
    static func setOnlineStatus(online: Bool = true) {
        Task {
            let logger = LoggerService(LoginViewModel.self)
            do {
                let result = try await TDLibManager.shared.client?.setOption(
                    name: "online",
                    value: .optionValueBoolean(.init(value: online))
                )
                logger.log(result)
            } catch {
                logger.log(error, level: .error)
            }
        }
    }
    
    static func setOfflineStatus() {
        setOnlineStatus(online: false)
    }
    
    // MARK: Sheets Binding
    
    var showTutorial: Binding<Bool> {
        .init(
            get: { [weak self] in
                guard let self else { return false }
                return self.state == .tutorial
            },
            set: { [weak self] in
                guard let self else { return }
                self.state = $0 ? .tutorial : .qrCodeLogin
            }
        )
    }
    
    var showPassword: Binding<Bool> {
        .init(
            get: { [weak self] in
                guard let self else { return false }
                return self.state == .twoFactorPassword || self.state == .twoFactorPasswordFailure
            },
            set: { [weak self] in
                guard let self else { return }
                if !$0 { self.state = .qrCodeLogin }
            }
        )
    }
    
    var showPhoneNumber: Binding<Bool> {
        .init(
            get: { [weak self] in
                guard let self else { return false }
                return self.state == .phoneNumberLogin || self.state == .phoneNumberLoginFailure
            },
            set: { [weak self] in
                guard let self else { return }
                if !$0 { self.state = .qrCodeLogin }
            }
       )
    }
    
    var showCode: Binding<Bool> {
        .init(
            get: { [weak self] in
                guard let self else { return false }
                return self.state == .authCode || self.state == .authCodeFailure
            },
            set: { [weak self] in
                guard let self else { return }
                if !$0 { self.state = .phoneNumberLogin }
            }
        )
    }
    
}

// MARK: - Mock
@Observable
class LoginViewModelMock: LoginViewModel {
    override init() {
        super.init()
        qrCodeLink = "Hello World"
    }
    
}
