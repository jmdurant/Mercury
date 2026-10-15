import Foundation
import CryptoKit

extension AgentRegression {
    @MainActor static func reply(_ client: WSClient, method: String,
                                 payload: [String: Any] = [:], error: String? = nil) {
        let request = client.sent.last { $0["method"] as? String == method }!
        var frame: [String: Any] = ["type": "res", "id": request["id"]!, "ok": error == nil]
        if let error { frame["error"] = ["message": error] }
        else { frame["payload"] = payload }
        client.frame(frame)
    }

    @MainActor static func talkEvent(_ client: WSClient, _ type: String,
                                     session: String = "relay-1", extra: [String: Any] = [:]) {
        var payload: [String: Any] = ["type": type, "relaySessionId": session]
        payload.merge(extra) { _, new in new }
        client.frame(["type": "event", "event": "talk.event", "payload": payload])
    }

    @MainActor static func talkSession(_ client: WSClient, model: String = "gpt-live-1",
                                       inputRate: Int = 24000) {
        reply(client, method: "talk.session.create", payload: [
            "sessionId": "relay-1", "model": model, "provider": "openai",
            "audio": ["inputEncoding": "pcm16", "inputSampleRateHz": inputRate,
                      "outputEncoding": "pcm16", "outputSampleRateHz": 24000],
        ])
    }

    @MainActor static func authenticateTalk(_ client: WSClient) {
        client.frame(["type": "event", "event": "connect.challenge", "payload": ["nonce": "talk-test"]])
        reply(client, method: "connect", payload: ["auth": ["deviceToken": "scoped-voice-test"]])
    }

    @MainActor static func testTalk() {
        let node = OpenClawNodeService.shared
        node.gatewayURL = "wss://gateway.test/route"
        node.remoteURL = ""
        node.token = "MASTER_TEST_ONLY"
        node.deviceToken = "NODE_TEST_ONLY"
        node.resetVoiceAccess()
        let params = node.voiceConnectParameters(nonce: "proof", credential: "MASTER_TEST_ONLY", authField: "token")!
        check(params["role"] as? String == "operator", "Talk must use operator role")
        check(params["scopes"] as? [String] == ["operator.talk"], "Talk requests only its own scope")
        let device = params["device"] as! [String: Any]
        let clientInfo = params["client"] as! [String: Any]
        func decode(_ value: String) -> Data {
            var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while text.count % 4 != 0 { text += "=" }
            return Data(base64Encoded: text)!
        }
        let proof = ["v3", device["id"] as! String, clientInfo["id"] as! String,
                     "ui", "operator", "operator.talk", String(device["signedAt"] as! Int64),
                     "MASTER_TEST_ONLY", "proof", clientInfo["platform"] as! String,
                     clientInfo["deviceFamily"] as! String].joined(separator: "|")
        let key = try! Curve25519.Signing.PublicKey(rawRepresentation: decode(device["publicKey"] as! String))
        check(key.isValidSignature(decode(device["signature"] as! String), for: Data(proof.utf8)), "Talk signature covers role, scope, token and challenge")
        check(node.voiceCredential()?.value == "MASTER_TEST_ONLY", "Do not use a node-role device token for Talk")
        node.saveVoiceToken("VOICE_TEST_ONLY", gatewayIdentity: node.voiceGatewayIdentity)
        check(node.voiceCredential()?.field == "deviceToken", "Approved Talk credential is reused")
        node.gatewayURL = "wss://another.test"
        check(node.voiceCredential()?.value == "MASTER_TEST_ONLY", "Talk token must not follow a changed Gateway")
        node.token = ""
        check(node.voiceCredential() == nil, "Node pairing does not grant voice access")
        node.token = "MASTER_TEST_ONLY"
        node.resetVoiceAccess()

        let ws = WSClient()
        let relay = OpenClawTalkRelay(agentId: "nurse", model: "gpt-live-1-codex", client: ws) { _ in params }
        var starts = 0
        var audio = 0
        var clears = 0
        var transcript = ""
        var errors: [String] = []
        relay.onReady = { contract in
            check(contract.inputRate == 24000 && contract.outputRate == 24000, "Negotiated PCM rate")
            starts += 1
        }
        relay.onAudio = { data in check(data.count == 4, "PCM payload decoded"); audio += 1 }
        relay.onClear = { clears += 1 }
        relay.onTranscript = { _, text in transcript = text }
        relay.onError = { errors.append($0) }
        relay.start { _ in }
        talkEvent(ws, "ready")
        check(starts == 0, "Ignore Talk events before authentication")
        authenticateTalk(ws)
        let creation = ws.sent.last!["params"] as! [String: Any]
        check(creation["sessionKey"] as? String == "agent:nurse:clawwatch-voice", "Route to selected agent's stable voice history")
        check(creation["model"] as? String == "gpt-live-1-codex", "Respect explicit subscription model")
        check(creation["transport"] as? String == "gateway-relay", "Use Gateway relay, not provider media")
        relay.appendAudio(Data([1, 0]))
        check(ws.sent.last?["method"] as? String == "talk.session.create", "No audio before ready")
        talkEvent(ws, "ready") // The real Gateway may emit this before the create response.
        talkEvent(ws, "transcript", extra: ["role": "user", "text": "hello"])
        talkSession(ws, model: "gpt-live-1-codex")
        check(starts == 1 && transcript == "hello", "Preserve events racing the create response")
        talkEvent(ws, "ready")
        check(starts == 1, "Do not start the microphone twice")
        let pcm = Data([1, 0, 2, 0]).base64EncodedString()
        talkEvent(ws, "audio", session: "another-call", extra: ["audioBase64": pcm, "talkEvent": ["turnId": "old"]])
        check(audio == 0, "Never play another session's audio")
        talkEvent(ws, "audio", extra: ["audioBase64": pcm, "talkEvent": ["turnId": "turn-1"]])
        talkEvent(ws, "audio", extra: ["audioBase64": pcm, "talkEvent": ["turnId": "turn-2"]])
        talkEvent(ws, "clear", extra: ["talkEvent": ["turnId": "turn-1"]])
        check(clears == 1, "A delayed clear must not cut off a newer response")
        talkEvent(ws, "clear", extra: ["talkEvent": ["turnId": "turn-2"]])
        talkEvent(ws, "audio", extra: ["audioBase64": pcm, "talkEvent": ["turnId": "turn-2"]])
        check(audio == 2 && clears == 2, "Discard audio arriving after interruption")
        relay.appendAudio(Data([1, 0, 2, 0]))
        let upload = ws.sent.last!["params"] as! [String: Any]
        check(upload["audioBase64"] as? String == pcm && upload["sessionId"] as? String == "relay-1", "Audio is a Talk RPC, not a raw binary frame")
        reply(ws, method: "talk.session.appendAudio", payload: ["ok": true])
        relay.close()
        check(!ws.closed && ws.sent.last?["method"] as? String == "talk.session.close", "Keep socket through close acknowledgement")
        reply(ws, method: "talk.session.close", payload: ["ok": true])
        check(ws.closed && errors.isEmpty, "Cleanly close the provider session")

        // Stop while creation is in flight; never abandon the late provider allocation.
        let lateWS = WSClient()
        let late = OpenClawTalkRelay(agentId: "nurse", model: nil, client: lateWS) { _ in params }
        late.onReady = { _ in fatalError("Stopped session became ready") }
        late.start { _ in }; authenticateTalk(lateWS)
        late.close()
        talkSession(lateWS)
        check(lateWS.sent.last?["method"] as? String == "talk.session.close", "Close a late-created session")
        reply(lateWS, method: "talk.session.close", payload: ["ok": true])

        for (model, rate) in [("gpt-realtime-2.1", 24000), ("gpt-live-1", 16000)] {
            let invalidWS = WSClient()
            let invalid = OpenClawTalkRelay(agentId: "nurse", model: nil, client: invalidWS) { _ in params }
            var rejected = false
            invalid.onError = { _ in rejected = true }
            invalid.onReady = { _ in fatalError("Unsupported session started capture") }
            invalid.start { _ in }; authenticateTalk(invalidWS)
            talkSession(invalidWS, model: model, inputRate: rate)
            check(rejected, "Reject unsupported models/audio before microphone capture")
            reply(invalidWS, method: "talk.session.close", payload: ["ok": true])
        }

        let slowWS = WSClient()
        let slow = OpenClawTalkRelay(agentId: "nurse", model: nil, client: slowWS) { _ in params }
        var stalled = false
        slow.onError = { _ in stalled = true }
        slow.start { _ in }; authenticateTalk(slowWS); talkSession(slowWS); talkEvent(slowWS, "ready")
        for _ in 0..<49 { slow.appendAudio(Data([0, 0])) }
        check(stalled, "Bound unacknowledged microphone uploads")
        reply(slowWS, method: "talk.session.close", payload: ["ok": true])
        print("PASS: Talk auth, subscription/API contract, ordering, session isolation, interruption, cleanup and backpressure")
    }

    @MainActor static func testTalkVoiceLifecycle() {
        let node = OpenClawNodeService.shared
        node.gatewayURL = "wss://gateway.test"
        node.token = "MASTER_TEST_ONLY"
        node.resetVoiceAccess()
        let voice = VoiceHarness()
        voice.backend = .openClaw
        voice.start(agentId: "assistant")
        let ws = WSClient.instances.last!
        ws.onOpen?()
        check(!voice.engine.running, "Gateway socket open alone must not capture audio")
        authenticateTalk(ws)
        talkSession(ws)
        check(!voice.engine.running, "Session allocation alone must not capture audio")
        talkEvent(ws, "ready")
        check(voice.state == .live && voice.engine.running, "Capture starts only after Talk is ready")
        talkEvent(ws, "audio", extra: ["audioBase64": "AQA=", "talkEvent": ["turnId": "turn"]])
        talkEvent(ws, "mark", extra: ["markName": "played"])
        check(!ws.sent.contains { $0["method"] as? String == "talk.session.acknowledgeMark" }, "Do not acknowledge unplayed audio")
        voice.completePlayback()
        check(ws.sent.last?["method"] as? String == "talk.session.acknowledgeMark", "Acknowledge actual playback completion")
        reply(ws, method: "talk.session.acknowledgeMark", payload: ["ok": true])
        talkEvent(ws, "error", extra: ["message": "recoverable audio warning", "phase": "stream"])
        check(voice.state == .live && voice.engine.running && voice.notice != nil, "Recoverable provider warnings keep the call alive")
        talkEvent(ws, "error", extra: ["message": "provider failed"])
        check(voice.state == .error && !voice.engine.running && voice.lastError == "provider failed", "Visible provider error releases microphone")
        reply(ws, method: "talk.session.close", payload: ["ok": true])
        voice.start()
        let next = WSClient.instances.last!
        check(next !== ws && voice.lastError == nil, "Retry opens a fresh Talk session")
        ws.onClose?("late callback")
        check(voice.state == .connecting, "Old relay callbacks cannot stop a replacement")
        voice.stop()
        check(next.closed, "Stop before authentication closes immediately")
        voice.microphoneAllowed = false
        let beforeDenied = WSClient.instances.count
        voice.start()
        check(voice.state == .error && WSClient.instances.count == beforeDenied, "Denied microphone must not allocate a provider session")
        print("PASS: native Talk microphone gating, playback acknowledgement, failure teardown and retry")
    }
}
