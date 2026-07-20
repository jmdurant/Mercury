//
//  PushToTalkAgentIntent.swift
//  ClawWatch (shared: iOS + watchOS)
//
//  One press to arm push-to-talk. On iPhone it joins the PushToTalk channel,
//  which brings up the system hold-to-talk button (Dynamic Island / lock
//  screen) — press and hold to talk, release to stop. Bind this to the
//  iPhone Action Button (Settings → Action Button → Shortcut). The Action
//  Button itself is press-only, so it arms/disarms; the actual hold-to-talk
//  is the system Talk button.
//
//  watchOS has no PushToTalk framework, so there it falls back to toggling a
//  live voice session (the watch's own hands-free talk).
//

import AppIntents

struct PushToTalkAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "Push-to-Talk with Agent"
    static var description = IntentDescription(
        "Arm push-to-talk for your agent — brings up the hold-to-talk button on iPhone.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await MainActor.run { () -> String in
            #if os(iOS)
            let ptt = PTTChannelService.shared
            if ptt.isJoined {
                ptt.leave()
                return "Push-to-Talk off."
            }
            let agentId = LiveVoiceService.shared.defaultAgentId
            ptt.join(agentId: agentId, agentName: agentId.isEmpty ? "Agent" : agentId)
            return "Push-to-Talk ready — hold the Talk button."
            #else
            let voice = LiveVoiceService.shared
            let active = voice.state == .live || voice.state == .connecting
            if active { voice.stop(); return "Ended." }
            voice.start()
            return "Listening…"
            #endif
        }
        return .result(dialog: "\(message)")
    }
}
