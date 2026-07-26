//
//  TalkToAgentAppIntent.swift
//  ClawWatch (shared: iOS + watchOS)
//
//  Toggles a live voice session with the default agent. Bind this to the
//  Apple Watch Ultra Action Button (Settings → Action Button → Shortcut) for
//  a hardware press-to-talk, or run it from Shortcuts / Siri.
//

import AppIntents

struct TalkToAgentAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Agent"
    static var description = IntentDescription("Start or end a live voice session with your agent.")
    // Live voice needs the app foregrounded to capture audio.
    static var supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let wasActive = await MainActor.run { () -> Bool in
            let voice = LiveVoiceService.shared
            let active = voice.state == .live || voice.state == .connecting
            if active { voice.stop() } else { voice.start() }
            return active
        }
        return .result(dialog: wasActive ? "Ended." : "Talking to your agent…")
    }
}
