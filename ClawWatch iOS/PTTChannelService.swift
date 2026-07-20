//
//  PTTChannelService.swift
//  ClawWatch iOS
//
//  Apple Push to Talk integration: a system PTT channel wired to the live
//  voice channel, so the system PTT button (foreground, lock screen, or
//  background) streams your voice to the selected agent. iOS only —
//  PTChannelManager doesn't exist on watchOS.
//
//  Transmitting works with just the app + voice server. Receiving the
//  agent's audio in the background additionally needs the server to send a
//  Push to Talk APNs push (apns-push-type: pushtotalk) using the ephemeral
//  token surfaced in receivedEphemeralPushToken.
//

#if os(iOS)
import Foundation
import PushToTalk
import AVFoundation
import UIKit

@Observable
final class PTTChannelService: NSObject {

    static let shared = PTTChannelService()

    private(set) var isJoined = false
    private(set) var isTransmitting = false
    var lastError: String?

    private var manager: PTChannelManager?
    private var channelUUID: UUID?
    private var agentId: String = ""
    private var agentName: String = "Agent"

    /// Create the channel manager once (safe to call repeatedly).
    func prepare() async {
        guard manager == nil else { return }
        do {
            manager = try await PTChannelManager.channelManager(
                delegate: self, restorationDelegate: self)
        } catch {
            lastError = "PTT unavailable: \(error.localizedDescription)"
        }
    }

    /// Join a channel bound to a specific agent. The system then shows the
    /// PTT button and routes transmit begin/end back through the delegate.
    func join(agentId: String, agentName: String) {
        self.agentId = agentId
        self.agentName = agentName
        Task {
            await prepare()
            let uuid = UUID()
            channelUUID = uuid
            let descriptor = PTChannelDescriptor(name: agentName, image: nil)
            manager?.requestJoinChannel(channelUUID: uuid, descriptor: descriptor)
        }
    }

    func leave() {
        guard let uuid = channelUUID else { return }
        manager?.leaveChannel(channelUUID: uuid)
    }
}

// MARK: - PTChannelManagerDelegate

extension PTTChannelService: PTChannelManagerDelegate {

    func channelManager(_ channelManager: PTChannelManager,
                        didJoinChannel channelUUID: UUID,
                        reason: PTChannelJoinReason) {
        isJoined = true
        // Connect the live-voice socket up front; PushToTalk owns the audio
        // session, so this doesn't configure or activate audio itself.
        LiveVoiceService.shared.pttConnect(agentId: agentId)
    }

    func channelManager(_ channelManager: PTChannelManager,
                        didLeaveChannel channelUUID: UUID,
                        reason: PTChannelLeaveReason) {
        isJoined = false
        isTransmitting = false
        self.channelUUID = nil
        LiveVoiceService.shared.pttDisconnect()
    }

    func channelManager(_ channelManager: PTChannelManager,
                        channelUUID: UUID,
                        didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        isTransmitting = true
    }

    func channelManager(_ channelManager: PTChannelManager,
                        channelUUID: UUID,
                        didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        isTransmitting = false
    }

    // Audio session lifecycle is owned by PushToTalk. Drive capture from here.
    func channelManager(_ channelManager: PTChannelManager,
                        didActivate audioSession: AVAudioSession) {
        LiveVoiceService.shared.pttResumeAudio()
    }

    func channelManager(_ channelManager: PTChannelManager,
                        didDeactivate audioSession: AVAudioSession) {
        LiveVoiceService.shared.pttPauseAudio()
    }

    // Ephemeral APNs token for receiving PTT pushes. Hand to the voice server
    // so it can push us when the agent has audio (background receive).
    func channelManager(_ channelManager: PTChannelManager,
                        receivedEphemeralPushToken pushToken: Data) {
        let hex = pushToken.map { String(format: "%02x", $0) }.joined()
        LiveVoiceService.shared.registerPTTPushToken(hex)
    }

    func incomingPushResult(channelManager: PTChannelManager,
                            channelUUID: UUID,
                            pushPayload: [String: Any]) -> PTPushResult {
        // Server signalled the agent is speaking → make it the active speaker
        // so the system activates audio for playback.
        return .activeRemoteParticipant(PTParticipant(name: agentName, image: nil))
    }

    func channelManager(_ channelManager: PTChannelManager,
                        failedToJoinChannel channelUUID: UUID,
                        error: Error) {
        isJoined = false
        lastError = "Couldn't join PTT: \(error.localizedDescription)"
    }

    func channelManager(_ channelManager: PTChannelManager,
                        failedToBeginTransmittingInChannel channelUUID: UUID,
                        error: Error) {
        isTransmitting = false
        lastError = "Couldn't transmit: \(error.localizedDescription)"
    }
}

// MARK: - PTChannelRestorationDelegate

extension PTTChannelService: PTChannelRestorationDelegate {
    func channelDescriptor(restoredChannelUUID: UUID) -> PTChannelDescriptor {
        PTChannelDescriptor(name: agentName.isEmpty ? "Agent" : agentName, image: nil)
    }
}
#endif
