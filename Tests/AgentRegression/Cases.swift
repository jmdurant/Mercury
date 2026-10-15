import Foundation

@main
struct AgentRegression {
    @MainActor static func main() async {
        // The runner gives this process a unique executable name. Its defaults
        // domain is separate from the app and is removed when the test finishes.
        defer { UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName) }
        await testConsent()
        await testNode()
        testVoice()
        testTalk()
        testTalkVoiceLifecycle()
        print("PASS: consent, watch relay, node results/reconnection, voice lifecycle")
    }

    @MainActor static func testConsent() async {
        consent(false)
        for command in ["#hr", "#heart", "#heartrate", "#workout", "#activity", "#oxygen", "#breathing", "#dist", "#noise", "#status", "#full", "#dump"] {
            check(AutoResponderStore.consentDenial(for: command) != nil, "Denied command escaped: \(command)")
        }
        AutoResponderStore.setConsent(.calendar, true)
        check(AutoResponderStore.consentDenial(for: "#cal") == nil, "Calendar must remain available")
        check(AutoResponderStore.consentDenial(for: "#call Alice") != nil, "Calendar cannot authorize a call")
        AutoResponderStore.setConsent(.actions, true)
        AutoResponderStore.setConsent(.calendar, false)
        check(AutoResponderStore.consentDenial(for: "#CALL Alice") == nil, "Calls use Actions, not Calendar")
        check(AutoResponderStore.consentDenial(for: "#remind meeting") != nil, "Reminder requires Calendar too")
        AutoResponderStore.setConsent(.health, true)
        check(AutoResponderStore.consentDenial(for: "#json") != nil, "JSON snapshot also exposes location")
        check(AutoResponderStore.consentDenial(for: "health.snapshot") != nil, "Node snapshot also exposes location")

        consent(false)
        let responder = ResponderHarness()
        for text in ["heart rate", "where are you", "calendar", "music", "workout", "weather", "full status", "everything", "driving", "sleep", "altitude", "distance", "reminder", "breathing"] {
            let reply = await responder.query(text)
            check(reply?.contains("disabled") == true, "Natural language must report denial: \(text)")
            check(StatusDataService.calls.isEmpty, "Denied query touched sensors: \(text)")
        }
        let mixed = await responder.query("heart rate and battery")
        check(mixed?.contains("disabled") == true, "Mixed query should report denied health")
        check(StatusDataService.calls == ["buildBatteryStatus"], "Mixed query should fetch only permitted battery")

        consent(false)
        for command in ["watch.heart", "watch.temp", "watch.o2", "watch.rings", "watch.health"] {
            let result = await WatchBridge.runWatchCommand(command)
            check(result["code"] as? String == "PERMISSION_DENIED", "Watch must enforce its own consent")
        }
        check(StatusDataService.calls.isEmpty, "Denied watch relay touched sensors")
        consent(true)
        _ = await responder.query("heart rate and battery")
        check(StatusDataService.calls.contains("getCurrentHeartRate"), "Allowed health query should still work")
        let result = await WatchBridge.runWatchCommand("watch.heart")
        check(result["bpm"] as? Int == 72, "Allowed watch relay should work")
    }

    @MainActor static func testNode() async {
        consent(true)
        let node = OpenClawNodeService()
        node.gatewayURL = "ws://gateway.test:18789"
        node.remoteURL = ""
        node.token = ""
        node.start()
        let original = WSClient.instances.last!
        original.frame(["type": "event", "event": "connect.challenge", "payload": ["nonce": "test-nonce"]])
        check(original.sent.first?["method"] as? String == "connect", "Challenge must produce a connect frame")
        await invoke(original, "system.notify")
        check(AgentAlertService.count == 0, "Do not execute commands before connection is authenticated")
        hello(original)

        AutoResponderStore.setConsent(.health, false)
        let denied = await invoke(original, "watch.heart")
        check(denied["ok"] as? Bool == false, "Consent denial must fail the invocation")
        check((denied["error"] as? [String: String])?["code"] == "PERMISSION_DENIED", "Structured permission error")
        check(denied["payloadJSON"] == nil, "Failure must not carry a success payload")
        check(StatusDataService.calls.isEmpty, "Denied node request touched sensors")

        consent(true)
        let success = await invoke(original, "battery.get")
        check(success["ok"] as? Bool == true && success["payloadJSON"] != nil, "Successful node result")
        StatusDataService.unavailable.insert("getCurrentHeartRate")
        let missing = await invoke(original, "heart.get")
        check(missing["ok"] as? Bool == false, "Missing sensor data must fail")
        let unknown = await invoke(original, "unknown.command")
        check((unknown["error"] as? [String: String])?["code"] == "UNSUPPORTED_COMMAND", "Unknown command must fail")
        let bad = await invoke(original, "system.notify", paramsJSON: "not json")
        check((bad["error"] as? [String: String])?["code"] == "INVALID_PARAMS", "Invalid params must fail")
        check(AgentAlertService.count == 0, "Malformed params must not trigger the action")

        original.onClose?("network lost")
        check(node.status == .error && original.closed, "Lost connection must close and enter retry state")
        let reconnected = await waitUntil(timeout: 3) {
            WSClient.instances.last! !== original && node.status == .connecting
        }
        let replacement = WSClient.instances.last!
        check(reconnected, "Network failure must reconnect")
        hello(original)
        check(node.status == .connecting, "Old socket must not authenticate a new connection")
        hello(replacement)
        replacement.onWaiting?("route disappeared")
        check(node.status == .error && replacement.closed, "A connected socket losing its route must retry")
        node.stop()
        let count = WSClient.instances.count
        await pause(1.2)
        check(WSClient.instances.count == count && node.status == .idle, "Stop must cancel pending retries")
        check(!node.isAutoConnect, "Explicit disconnect must disable automatic reconnect")

        node.start()
        let rejected = WSClient.instances.last!
        rejected.frame(["type": "res", "id": "connect", "ok": false, "error": ["code": "AUTH_FAILED", "message": "invalid credential"]])
        rejected.onClose?(nil)
        let rejectedCount = WSClient.instances.count
        await pause(1.2)
        check(WSClient.instances.count == rejectedCount, "Credential rejection must not retry endlessly")

        node.stop()
        node.start()
        let stalled = WSClient.instances.last!
        // Dispatch timers may be coalesced, especially under build load. Wait
        // for each observable transition rather than racing a fixed sleep.
        let timedOut = await waitUntil(timeout: 20) { stalled.closed }
        check(timedOut, "A stalled handshake must time out")
        let retried = await waitUntil(timeout: 3) { WSClient.instances.last! !== stalled }
        check(retried && node.status == .connecting, "A timed-out handshake must reconnect")
        node.stop(disableAutoConnect: false)
        check(node.isAutoConnect, "Temporary watch suspension must preserve automatic reconnect")
        node.stop()
    }

    static func hello(_ client: WSClient) {
        client.frame(["type": "res", "id": "connect", "ok": true, "payload": [:]])
    }

    @MainActor @discardableResult static func invoke(_ client: WSClient, _ command: String, paramsJSON: String = "{}") async -> [String: Any] {
        client.frame(["type": "event", "event": "node.invoke.request", "payload": ["id": UUID().uuidString, "nodeId": "test-node", "command": command, "paramsJSON": paramsJSON]])
        await pause()
        return client.sent.last?["params"] as? [String: Any] ?? [:]
    }

    @MainActor static func testVoice() {
        let voice = VoiceHarness()
        voice.start()
        let original = WSClient.instances.last!
        check(voice.state == .connecting && !voice.engine.running, "Do not capture before the socket is open")
        original.onOpen?()
        check(voice.state == .live && voice.engine.running, "Open socket starts capture")
        original.onClose?("test failure")
        check(voice.state == .error && !voice.engine.running, "Failure stops microphone capture")
        check(voice.engine.inputNode.removals == 1 && original.closed, "Failure removes tap and closes socket")
        voice.start()
        let replacement = WSClient.instances.last!
        check(replacement !== original && voice.state == .connecting, "Talk retries from error")
        replacement.onOpen?()
        original.onClose?("stale close")
        check(voice.state == .live && voice.engine.running, "Old callbacks cannot stop a new voice session")
        voice.start()
        check(voice.state == .live, "Repeated start must not corrupt a live session")
        voice.stop()
        check(voice.state == .idle && !voice.engine.running, "Explicit stop releases resources")
        voice.failCapture = true
        voice.start()
        WSClient.instances.last!.onOpen?()
        check(voice.state == .error && !voice.engine.running, "Partial capture setup is cleaned up")
        voice.failCapture = false
        voice.start()
        WSClient.instances.last!.onWaiting?("unreachable")
        check(voice.state == .error && !voice.engine.running, "Unreachable connection is retryable")
        voice.stop()

        voice.pttConnect(agentId: "test-agent")
        let ptt = WSClient.instances.last!
        voice.pttResumeAudio()
        check(!voice.engine.running, "PTT waits for the socket")
        ptt.onOpen?()
        check(voice.engine.running, "PTT starts when both resources are ready")
        let deactivations = AVAudioSession.instance.deactivations
        ptt.onClose?("ptt failed")
        check(!voice.engine.running && voice.state == .error, "PTT socket failure stops capture")
        check(AVAudioSession.instance.deactivations == deactivations, "Do not deactivate the system-owned PTT session")
        voice.pttDisconnect()
    }
}
