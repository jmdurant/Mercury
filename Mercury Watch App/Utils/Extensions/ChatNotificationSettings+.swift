//
//  ChatNotificationSettings+.swift
//  Mercury Watch App
//
//  Created by Marco Tammaro on 04/11/24.
//

import TDLibKit

extension ChatNotificationSettings {
    public func copyWith(
            disableMentionNotifications: Bool? = nil,
            disablePinnedMessageNotifications: Bool? = nil,
            muteFor: Int? = nil,
            muteStories: Bool? = nil,
            showPreview: Bool? = nil,
            showStoryPoster: Bool? = nil,
            soundId: TdInt64? = nil,
            storySoundId: TdInt64? = nil,
            useDefaultDisableMentionNotifications: Bool? = nil,
            useDefaultDisablePinnedMessageNotifications: Bool? = nil,
            useDefaultMuteFor: Bool? = nil,
            useDefaultMuteStories: Bool? = nil,
            useDefaultShowPreview: Bool? = nil,
            useDefaultShowStoryPoster: Bool? = nil,
            useDefaultSound: Bool? = nil,
            useDefaultStorySound: Bool? = nil
        ) -> ChatNotificationSettings {
            // Hoisted into typed locals: one expression with 16 `??` chains
            // exceeds the type checker's time budget
            let disableMention: Bool = disableMentionNotifications ?? self.disableMentionNotifications
            let disablePinned: Bool = disablePinnedMessageNotifications ?? self.disablePinnedMessageNotifications
            let newMuteFor: Int = muteFor ?? self.muteFor
            let newMuteStories: Bool = muteStories ?? self.muteStories
            let newShowPreview: Bool = showPreview ?? self.showPreview
            let newShowStoryPoster: Bool = showStoryPoster ?? self.showStoryPoster
            let newSoundId: TdInt64 = soundId ?? self.soundId
            let newStorySoundId: TdInt64 = storySoundId ?? self.storySoundId
            let defaultDisableMention: Bool = useDefaultDisableMentionNotifications ?? self.useDefaultDisableMentionNotifications
            let defaultDisablePinned: Bool = useDefaultDisablePinnedMessageNotifications ?? self.useDefaultDisablePinnedMessageNotifications
            let defaultMuteFor: Bool = useDefaultMuteFor ?? self.useDefaultMuteFor
            let defaultMuteStories: Bool = useDefaultMuteStories ?? self.useDefaultMuteStories
            let defaultShowPreview: Bool = useDefaultShowPreview ?? self.useDefaultShowPreview
            let defaultShowStoryPoster: Bool = useDefaultShowStoryPoster ?? self.useDefaultShowStoryPoster
            let defaultSound: Bool = useDefaultSound ?? self.useDefaultSound
            let defaultStorySound: Bool = useDefaultStorySound ?? self.useDefaultStorySound

            return ChatNotificationSettings(
                disableMentionNotifications: disableMention,
                disablePinnedMessageNotifications: disablePinned,
                muteFor: newMuteFor,
                muteStories: newMuteStories,
                showPreview: newShowPreview,
                showStoryPoster: newShowStoryPoster,
                soundId: newSoundId,
                storySoundId: newStorySoundId,
                useDefaultDisableMentionNotifications: defaultDisableMention,
                useDefaultDisablePinnedMessageNotifications: defaultDisablePinned,
                useDefaultMuteFor: defaultMuteFor,
                useDefaultMuteStories: defaultMuteStories,
                useDefaultShowPreview: defaultShowPreview,
                useDefaultShowStoryPoster: defaultShowStoryPoster,
                useDefaultSound: defaultSound,
                useDefaultStorySound: defaultStorySound
            )
        }
}
