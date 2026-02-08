//
//  SettingsViewModel.swift
//  Mercury
//
//  Created by Marco Tammaro on 08/02/26.
//

import SwiftUI
import TDLibKit

@Observable
class ProfileDetailViewModel: TDLibViewModel {
    
    var title: String?
    var subtitle: String?
    var avatarModel: AvatarModel?
    
    init(type: ProfileDetailPageType) {
        super.init()
        Task.detached { [weak self] in
            try await self?.fetchData(type)
        }
    }
    
    func fetchData(_ type: ProfileDetailPageType) async throws {
        
        switch type {
        case .user(let id):
            
            let user = try await TDLibManager.shared.client?.getUser(userId: id)
            self.title = user?.firstName
            self.subtitle = user?.statusDescription
            self.avatarModel = user?.toAvatarModel(isFullScreen: true)
            
        case .basicGroup(let groupId, let chatId):
            let group = try await TDLibManager.shared.client?.getBasicGroup(basicGroupId: groupId)
            let chat = try await TDLibManager.shared.client?.getChat(chatId: chatId)
            self.title = chat?.title
            self.subtitle = "\(group?.memberCount ?? 0) members"
            self.avatarModel = chat?.toAvatarModel(isFullScreen: true)
            
        case .superGroup(groupId: let groupId, chatId: let chatId):
            let group = try await TDLibManager.shared.client?.getSupergroup(supergroupId: groupId)
            let chat = try await TDLibManager.shared.client?.getChat(chatId: chatId)
            self.title = chat?.title
            self.subtitle = "\(group?.memberCount ?? 0) members"
            self.avatarModel = chat?.toAvatarModel(isFullScreen: true)
        }
    }
}

class ProfileDetailViewModelMock: ProfileDetailViewModel {
    init() {
        super.init(type: .user(userId: 0))
        self.title = "Title"
        self.subtitle = "Subtitle"
        self.avatarModel = .alessandro
    }
    
    override func fetchData(_ type: ProfileDetailPageType) async throws { }
}
