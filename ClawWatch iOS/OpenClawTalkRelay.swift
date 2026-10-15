import Foundation

/// OpenClaw v4 Talk relay. All methods and callbacks run on the main queue.
/// The Gateway owns GPT-Live credentials, delegation, and transcript persistence.
final class OpenClawTalkRelay {
    struct AudioContract {
        let inputRate: Double
        let outputRate: Double
        let model: String
    }

    struct Failure: Error {
        let message: String
    }

    var onReady: ((AudioContract) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onClear: (() -> Void)?
    var onMark: ((String) -> Void)?
    var onTranscript: ((String, String) -> Void)?
    var onError: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    var onEnded: (() -> Void)?
    var onAuthenticated: ((String) -> Void)?

    private struct Pending {
        let timeout: DispatchWorkItem
        let completion: (Result<[String: Any], Failure>) -> Void
    }
    private let client: WSClient
    private let connectParameters: (String) -> [String: Any]?
    private let agentId: String
    private let model: String?
    private var pending: [String: Pending] = [:]
    private var startupTimeout: DispatchWorkItem?
    private var sessionId: String?
    private var contract: AudioContract?
    private var earlyEvents: [[String: Any]] = []
    private var earlyEventBytes = 0
    private var authenticated = false
    private var challenged = false
    private var creating = false
    private var ready = false
    private var closing = false
    private var closed = false
    private var closeRequested = false
    // Retain the connection through close acknowledgement, including a late create response.
    private var shutdownHold: OpenClawTalkRelay?
    private var audioRequests = 0
    private var audioBytes = 0
    private var inputSamples: Int64 = 0
    private let inputOrigin = ProcessInfo.processInfo.systemUptime * 1000
    private var outputTurn: String?
    private var retiredTurns: [String] = []

    init(agentId: String, model: String?, client: WSClient = WSClient(),
         connectParameters: @escaping (String) -> [String: Any]?) {
        self.agentId = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.client = client
        self.connectParameters = connectParameters
    }

    func start(dial: (WSClient) -> Void) {
        guard !closing, !closed else { return }
        client.onText = { [weak self] in self?.receive($0) }
        client.onClose = { [weak self] _ in
            guard let self else { return }
            if self.closing { self.finishClose() }
            else { self.fail("OpenClaw voice disconnected. Tap Talk to reconnect.") }
        }
        client.onWaiting = { [weak self] _ in
            self?.fail("Cannot reach the OpenClaw Gateway. Check its address or remote connection.")
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.fail("OpenClaw voice did not become ready. Check Talk configuration and device approval.")
        }
        startupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
        dial(client)
    }

    func appendAudio(_ data: Data) {
        guard ready, !closing, !closed, let sessionId, let contract, !data.isEmpty else { return }
        guard data.count.isMultiple(of: 2), data.count <= 48000,
              audioRequests < 48, audioBytes + data.count <= 96000 else {
            fail("Voice upload fell behind. Check the connection and try again.")
            return
        }
        audioRequests += 1
        audioBytes += data.count
        let timestamp = inputOrigin + Double(inputSamples) * 1000 / contract.inputRate
        inputSamples += Int64(data.count / 2)
        request("talk.session.appendAudio", ["sessionId": sessionId,
                    "audioBase64": data.base64EncodedString(), "timestamp": timestamp], timeout: 8) { [weak self] result in
            guard let self else { return }
            self.audioRequests -= 1
            self.audioBytes -= data.count
            guard !self.closing else { return }
            if case .failure(let error) = result { self.fail(error.message) }
        }
    }

    func acknowledgeMark(_ name: String) {
        guard ready, !closing, let sessionId else { return }
        request("talk.session.acknowledgeMark", ["sessionId": sessionId, "markName": name]) { [weak self] result in
            if case .failure(let error) = result { self?.fail(error.message) }
        }
    }

    func close() {
        guard !closed, !closing else { return }
        closing = true
        ready = false
        shutdownHold = self
        startupTimeout?.cancel(); startupTimeout = nil
        onReady = nil; onAudio = nil; onClear = nil; onMark = nil
        onTranscript = nil; onError = nil; onNotice = nil; onEnded = nil
        earlyEvents.removeAll(); earlyEventBytes = 0
        if sessionId != nil { closeSession() }
        else if !creating { finishClose() }
        // A create already sent still owns cleanup. Its response or deadline closes us.
    }

    private func closeSession() {
        guard !closeRequested, let sessionId else { return }
        closeRequested = true
        request("talk.session.close", ["sessionId": sessionId], timeout: 10) { [weak self] _ in
            self?.finishClose()
        }
    }

    private func finishClose() {
        closed = true
        startupTimeout?.cancel(); startupTimeout = nil
        for item in pending.values { item.timeout.cancel() }
        pending.removeAll()
        earlyEvents.removeAll()
        client.close()
        shutdownHold = nil
    }

    private func fail(_ message: String) {
        guard !closed, !closing else { return }
        let callback = onError
        close()
        callback?(message)
    }

    private func request(_ method: String, _ params: [String: Any], timeout: Double = 10,
                         completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        guard !closed else { return }
        guard pending.count < 64 || method == "talk.session.close" else {
            completion(.failure(Failure(message: "The voice connection fell behind. Please reconnect.")))
            return
        }
        let id = UUID().uuidString
        let work = DispatchWorkItem { [weak self] in
            guard let self, let request = self.pending.removeValue(forKey: id) else { return }
            request.completion(.failure(Failure(message: "OpenClaw \(method) timed out.")))
        }
        let frame: [String: Any] = ["type": "req", "id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else {
            completion(.failure(Failure(message: "Could not encode the OpenClaw voice request.")))
            return
        }
        pending[id] = Pending(timeout: work, completion: completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        client.sendText(String(decoding: data, as: UTF8.self))
    }

    private func receive(_ text: String) {
        guard !closed, text.utf8.count <= 2_000_000,
              let frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if frame["type"] as? String == "res", let id = frame["id"] as? String,
           let request = pending.removeValue(forKey: id) {
            request.timeout.cancel()
            if frame["ok"] as? Bool == true {
                request.completion(.success(frame["payload"] as? [String: Any] ?? [:]))
            } else {
                let error = frame["error"] as? [String: Any] ?? [:]
                let raw = error["message"] as? String ?? "OpenClaw rejected the voice request."
                let message = String(raw.prefix(700))
                request.completion(.failure(Failure(message: message)))
            }
            return
        }
        guard !closing, frame["type"] as? String == "event",
              let event = frame["event"] as? String,
              let payload = frame["payload"] as? [String: Any] else { return }
        if event == "connect.challenge" {
            guard !challenged, let nonce = payload["nonce"] as? String, !nonce.isEmpty else { return }
            challenged = true
            guard let params = connectParameters(nonce) else {
                fail("Add your Gateway token in Agent settings to authorize voice. Node pairing alone does not grant Talk access.")
                return
            }
            request("connect", params) { [weak self] result in
                guard let self, !self.closing else { return }
                switch result {
                case .failure(let error):
                    self.fail("Voice access: \(error.message) Approve this device’s Talk access on the Gateway, then retry.")
                case .success(let hello):
                    self.authenticated = true
                    if let auth = hello["auth"] as? [String: Any],
                       let token = auth["deviceToken"] as? String, !token.isEmpty {
                        self.onAuthenticated?(token)
                    }
                    self.createSession()
                }
            }
        } else if event == "talk.event", authenticated {
            if sessionId == nil, creating {
                guard earlyEvents.count < 200, earlyEventBytes + text.utf8.count <= 1_000_000 else {
                    fail("Too many voice events arrived before the session was ready.")
                    return
                }
                earlyEvents.append(payload)
                earlyEventBytes += text.utf8.count
            } else {
                handleEvent(payload)
            }
        }
    }

    private func createSession() {
        guard !closing else { return }
        if !agentId.isEmpty,
           agentId.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) == nil {
            fail("Choose a valid OpenClaw agent ID in Agent settings.")
            return
        }
        var params: [String: Any] = ["mode": "realtime", "transport": "gateway-relay",
                                     "brain": "agent-consult", "provider": "openai"]
        // Voice history is stable per agent and separate from Telegram chat history.
        if !agentId.isEmpty { params["sessionKey"] = "agent:\(agentId.lowercased()):clawwatch-voice" }
        if let model { params["model"] = model }
        creating = true
        request("talk.session.create", params, timeout: 25) { [weak self] result in
            guard let self else { return }
            self.creating = false
            switch result {
            case .failure(let error):
                if self.closing { self.finishClose() }
                else { self.fail("Could not start OpenClaw Talk: \(error.message)") }
            case .success(let payload):
                guard let id = (payload["sessionId"] ?? payload["relaySessionId"]) as? String, !id.isEmpty else {
                    if self.closing { self.finishClose() }
                    else { self.fail("The Gateway returned no voice session ID. Update OpenClaw and try again.") }
                    return
                }
                self.sessionId = id
                if self.closing { self.closeSession(); return }
                let selectedModel = payload["model"] as? String ?? ""
                guard ["gpt-live-1", "gpt-live-1-codex"].contains(selectedModel) else {
                    self.fail("Choose GPT-Live API or GPT-Live ChatGPT in Voice settings. This client requires a GPT-Live model with Gateway-owned agent delegation.")
                    return
                }
                guard let audio = payload["audio"] as? [String: Any],
                      audio["inputEncoding"] as? String == "pcm16",
                      audio["outputEncoding"] as? String == "pcm16",
                      let input = audio["inputSampleRateHz"] as? Double,
                      let output = audio["outputSampleRateHz"] as? Double,
                      input == 24000, output == 24000 else {
                    self.fail("The Gateway returned an unsupported voice audio format. Expected 24 kHz PCM16.")
                    return
                }
                self.contract = AudioContract(inputRate: input, outputRate: output, model: selectedModel)
                let events = self.earlyEvents
                self.earlyEvents.removeAll(); self.earlyEventBytes = 0
                for event in events where !self.closing { self.handleEvent(event) }
            }
        }
    }

    private func handleEvent(_ payload: [String: Any]) {
        guard !closing, !closed, let sessionId,
              payload["relaySessionId"] as? String == sessionId,
              let type = payload["type"] as? String else { return }
        let turn = (payload["talkEvent"] as? [String: Any])?["turnId"] as? String
        switch type {
        case "ready":
            guard !ready, let contract else { return }
            ready = true
            startupTimeout?.cancel(); startupTimeout = nil
            onReady?(contract)
        case "audio":
            guard ready, let turn, !retiredTurns.contains(turn) else { return }
            guard let base64 = payload["audioBase64"] as? String, base64.utf8.count <= 128000,
                  let data = Data(base64Encoded: base64), !data.isEmpty, data.count.isMultiple(of: 2) else {
                fail("OpenClaw sent invalid voice audio."); return
            }
            if let current = outputTurn, current != turn { retire(current); onClear?() }
            outputTurn = turn
            onAudio?(data)
        case "clear":
            guard turn == nil || turn == outputTurn else { return }
            if let current = outputTurn { retire(current) }
            outputTurn = nil
            onClear?()
        case "mark":
            if ready, let name = payload["markName"] as? String { onMark?(name) }
        case "transcript":
            if let role = payload["role"] as? String, let text = payload["text"] as? String {
                onTranscript?(role, String(text.suffix(4000)))
            }
        case "toolCall":
            // GPT-Live delegates on the Gateway. Never run arbitrary provider tools locally.
            fail("This Gateway requested client-owned voice tools. Select a GPT-Live model and update OpenClaw.")
        case "error":
            let message = String((payload["message"] as? String ?? "OpenClaw voice failed.").prefix(700))
            // Provider warnings can be recoverable; a terminal provider also sends close.
            if ready, payload["phase"] as? String == "stream" { onNotice?(message) }
            else { fail(message) }
        case "close":
            let callback = onEnded
            close()
            callback?()
        default: break
        }
    }

    private func retire(_ turn: String) {
        retiredTurns.append(turn)
        if retiredTurns.count > 128 { retiredTurns.removeFirst() }
    }
}
