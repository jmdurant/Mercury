//
//  ProfileDetail.swift
//  Mercury
//
//  Created by Marco Tammaro on 08/02/26.
//

import SwiftUI

enum ProfileDetailPageType {
    case user(userId: Int64)
    case basicGroup(groupId: Int64, chatId: Int64)
    case superGroup(groupId: Int64, chatId: Int64)
}

struct ProfileDetailPage: View {
    
    @State
    @Mockable
    var vm: ProfileDetailViewModel
    
    init(type: ProfileDetailPageType) {
        _vm = Mockable.state(
            value: { ProfileDetailViewModel(type: type) },
            mock: { ProfileDetailViewModelMock() }
        )
    }
    
    var body: some View {
        
        VStack(alignment: .leading) {
            if let title = vm.title {
                Text(title)
                    .font(.title2)
                    .fontDesign(.rounded)
                    .fontWeight(.semibold)
            }
            if let subtitle = vm.subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading)
        .padding(.bottom, -6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background {
            backgroundImage()
        }
        
    }
    
    @ViewBuilder
    func backgroundImage() -> some View {
        
        if let avatarModel = vm.avatarModel {
            GeometryReader { geo in
                AvatarView(model: avatarModel)
                    .scaledToFill()
                    .frame(
                        width: geo.size.width,
                        height: geo.size.height
                    )
            }
            .overlay {
                Rectangle()
                    .foregroundStyle(Gradient(colors: [.clear, .clear, .black]))
            }
            .ignoresSafeArea()
        }
    }
    
}

#Preview(traits: .mock()) {
    ProfileDetailPage(type: .user(userId: 0))
}
