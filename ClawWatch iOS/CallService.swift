//
//  CallService.swift
//  ClawWatch iOS
//
//  CallKit + PushKit VoIP bridge for TDLib calls. Presents native
//  incoming-call UI and maps CallKit actions to TDLib call signaling.
//  (Audio transport is TDLib/WebRTC; this layer handles call lifecycle.)
//

import Foundation
import CallKit
import PushKit
import AVFoundation
import TDLibKit

final class CallService: NSObject, TDLibManagerProtocol {

    static let shared = CallService()

    private let provider: CXProvider
    private let callController = CXCallController()
    private let voipRegistry = PKPushRegistry(queue: .main)
    private let logger = LoggerService(CallService.self)

    /// Maps our CallKit UUID ↔ TDLib call id
    private var uuidToCallId: [UUID: Int] = [:]
    private var callIdToUUID: [Int: UUID] = [:]

    private static let standardProtocol = CallProtocol(
        libraryVersions: ["4.0.0"], maxLayer: 92, minLayer: 65,
        udpP2p: true, udpReflector: true
    )

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func start() {
        voipRegistry.delegate = self
        voipRegistry.desiredPushTypes = [.voIP]
        TDLibManager.shared.subscribe(self)
    }

    // MARK: - Outgoing

    func startCall(userId: Int64, displayName: String, video: Bool = false) {
        let uuid = UUID()
        let handle = CXHandle(type: .generic, value: displayName)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = video
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error { self?.logger.log("startCall: \(error)", level: .error); return }
            Task {
                do {
                    let callId = try await TDLibManager.shared.client?.createCall(
                        isVideo: video, protocol: Self.standardProtocol, userId: userId)
                    if let id = callId?.id {
                        self?.uuidToCallId[uuid] = id
                        self?.callIdToUUID[id] = uuid
                    }
                } catch { self?.logger.log(error, level: .error) }
            }
        }
    }

    // MARK: - Report incoming (from VoIP push or updateCall)

    private func reportIncoming(callId: Int, callerName: String, video: Bool) {
        let uuid = callIdToUUID[callId] ?? UUID()
        uuidToCallId[uuid] = callId
        callIdToUUID[callId] = uuid

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = video
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error { self?.logger.log("reportIncoming: \(error)", level: .error) }
        }
        if #available(iOS 16.1, *) { LiveActivityService.startCall(caller: callerName) }
    }

    private func endCall(callId: Int) {
        guard let uuid = callIdToUUID[callId] else { return }
        provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
        uuidToCallId[uuid] = nil
        callIdToUUID[callId] = nil
        if #available(iOS 16.1, *) { LiveActivityService.end() }
    }

    // MARK: - TDLibManagerProtocol

    func updateHandler(update: Update) {
        guard case .updateCall(let payload) = update else { return }
        let call = payload.call
        switch call.state {
        case .callStatePending(let pending):
            if !call.isOutgoing && !pending.isReceived {
                reportIncoming(callId: call.id, callerName: "Incoming call", video: call.isVideo)
            }
        case .callStateDiscarded, .callStateError, .callStateHangingUp:
            endCall(callId: call.id)
        default:
            break
        }
    }
    func connectionStateUpdate(state: ConnectionState) {}
    func authorizationStateUpdate(state: AuthorizationState) {}
}

// MARK: - CXProviderDelegate
extension CallService: CXProviderDelegate {

    func providerDidReset(_ provider: CXProvider) {
        uuidToCallId.removeAll(); callIdToUUID.removeAll()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if let callId = uuidToCallId[action.callUUID] {
            Task {
                try? await TDLibManager.shared.client?.acceptCall(
                    callId: callId, protocol: Self.standardProtocol)
            }
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let callId = uuidToCallId[action.callUUID] {
            Task {
                try? await TDLibManager.shared.client?.discardCall(
                    callId: callId, connectionId: 0, duration: 0,
                    inviteLink: nil, isDisconnected: false, isVideo: false)
            }
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        try? audioSession.setCategory(.playAndRecord, mode: .voiceChat)
    }
}

// MARK: - PKPushRegistryDelegate (VoIP push)
extension CallService: PKPushRegistryDelegate {

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        logger.log("VoIP token registered")
        Task {
            #if DEBUG
            let sandbox = true
            #else
            let sandbox = false
            #endif
            let voip = DeviceTokenApplePushVoIP(
                deviceToken: token, encrypt: false, isAppSandbox: sandbox)
            _ = try? await TDLibManager.shared.client?.registerDevice(
                deviceToken: .deviceTokenApplePushVoIP(voip), otherUserIds: [])
        }
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        // A VoIP push must immediately report a call. TDLib delivers the real
        // updateCall once connected; show a provisional incoming call now.
        let caller = payload.dictionaryPayload["caller"] as? String ?? "Incoming call"
        reportIncoming(callId: Int.random(in: 1...1_000_000), callerName: caller, video: false)
        completion()
    }
}
