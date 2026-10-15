#!/usr/bin/env python3
"""Run focused regressions on macOS with Xcode installed.

The app has no XCTest target. Compile its real policy/node/transport code and
extract the responder, watch handler, and voice lifecycle method bodies into
small harnesses. Only OS/device boundaries are faked; the decision-making code
under test is read from the working tree. An unsigned iOS/watchOS build remains
necessary to verify the full classes against the real SDKs.
"""

import base64
import hashlib
import json
from pathlib import Path
import re
import socket
import struct
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def source(path):
    return (ROOT / path).read_text()


def section(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


def compile_swift(files, executable):
    result = subprocess.run(
        ["xcrun", "swiftc", "-swift-version", "5", *map(str, files), "-o", str(executable)],
        text=True, capture_output=True, timeout=120,
    )
    if result.returncode:
        raise RuntimeError(result.stderr)


def lifecycle_tests(tmp):
    responder = source("Mercury Watch App/Utils/Services/AutoResponderService.swift")
    query = responder.split("    // MARK: - Query Matching\n", 1)[1].rsplit("\n}", 1)[0]
    query = """import Foundation
final class ResponderHarness {
    var isAutomotive = false
    var isWorkoutActive = false
    func query(_ text: String) async -> String? { await matchAndFetch(text) }
""" + query + "\n}\n"

    watch = source("ClawWatch iOS/WatchBridge.swift")
    watch_method = section(watch, "    /// Watch-exclusive sensors the phone can't measure itself.\n", "    #endif")
    watch = """import Foundation
final class WatchBridge {
    static let shared = WatchBridge()
    func fetchFromWatch(_ command: String) async -> [String: Any] { await Self.runWatchCommand(command) }
""" + watch_method + "\n}\n"

    node = source("ClawWatch iOS/OpenClawNodeService.swift")
    node = "import Observation\n" + node.replace("NSUbiquitousKeyValueStore", "TestKeyValueStore")
    node = node.replace("#if os(iOS)", "#if true")  # Exercise the phone relay branch on the Mac.

    voice = source("ClawWatch iOS/LiveVoiceService.swift")
    lifecycle = "    func start(agentId: String? = nil) {" + section(
        voice, "    func start(agentId: String? = nil) {", "    // MARK: - Push to Talk hooks")
    ptt = "    func pttConnect(agentId: String?) {" + section(
        voice, "    func pttConnect(agentId: String?) {", "    /// The ephemeral PTT push token")
    transport = "    private func openSocket(_ url: URL) {" + section(
        voice, "    private func openSocket(_ url: URL) {", "    private func playIncoming(")
    relay = "    private func openVoiceConnection() {" + section(
        voice, "    private func openVoiceConnection() {", "    // MARK: - Audio")
    playback = "    private func acknowledgePlayedMarks() {" + section(
        voice, "    private func acknowledgePlayedMarks() {", "    // MARK: - PCM helpers")
    voice = """import Foundation
final class VoiceHarness {
    enum State { case idle, connecting, live, error }
    enum Backend { case custom, openClaw }
    enum Model { case gateway; var modelID: String? { nil } }
    var state: State = .idle
    var backend: Backend = .custom
    var sessionBackend: Backend = .custom
    var talkModel: Model = .gateway
    var lastError: String?
    var notice: String?
    var userTranscript = ""
    var assistantTranscript = ""
    var activeModel = ""
    var activeAgentId = ""
    var defaultAgentId = "test-agent"
    var ws: WSClient?
    var relay: OpenClawTalkRelay?
    var socketTimeout: DispatchWorkItem?
    var hasCaptureTap = false
    var captureGeneration = UUID()
    var usesPTTAudioSession = false
    var pttAudioActive = false
    var lastActivityAt = Date()
    var failCapture = false
    var playbackGeneration = UUID()
    var queuedAudioBytes = 0
    var queuedAudibleBuffers = 0
    var scheduledAudio = 0
    var playedAudio = 0
    var playbackMarks: [(name: String, after: Int)] = []
    var isSpeaking = false
    let engine = FakeEngine()
    let playerNode = FakePlayer()
    let logger = LoggerService("voice")
    var cfHeaders: [(String, String)] { [] }
    func connectURL() -> URL? { URL(string: "ws://voice.test:8795/?agent=test") }
    func configureSession() throws {}
    var microphoneAllowed = true
    func requestMicrophoneAccess(_ completion: (Bool) -> Void) { completion(microphoneAllowed) }
    func prepareVoiceSession() { lastError = nil; sessionBackend = backend }
    func startCapture() throws {
        hasCaptureTap = true
        engine.running = true
        if failCapture { throw TestError.capture }
    }
    func playIncoming(_ data: Data) { scheduledAudio += 1 }
    func completePlayback() { playedAudio = scheduledAudio; acknowledgePlayedMarks() }
""" + lifecycle + ptt + transport + relay + playback + "\n}\n"

    # Every sensor stub records access. Denial tests fail if a request even
    # touches a protected source, rather than only checking its final response.
    getters = sorted(set(re.findall(r"StatusDataService\.(\w+)\(", query + watch + node)))
    sensors = """import Foundation
enum StatusDataService {
    static var calls: [String] = []
    static var unavailable: Set<String> = []
"""
    for name in getters:
        is_number = name in {"getCurrentHeartRate", "getTodaySteps", "getActiveCalories"}
        is_json = name == "buildJSONStatus"
        result_type = "Int?" if is_number else ("String" if is_json else "String?")
        value = "72" if is_number else ('"{}"' if is_json else '"SENSOR_' + name + '"')
        returned = value if is_json else f'unavailable.contains("{name}") ? nil : {value}'
        sensors += f'    static func {name}() -> {result_type} {{ calls.append("{name}"); return {returned} }}\n'
    sensors += "}\n"

    generated = []
    for name, text in [("Responder", query), ("Watch", watch), ("Node", node), ("Voice", voice), ("Sensors", sensors)]:
        path = tmp / (name + ".swift")
        path.write_text(text)
        generated.append(path)
    executable = tmp / ("AgentRegression_" + uuid.uuid4().hex)
    compile_swift([
        ROOT / "Mercury Watch App/Utils/Services/AutoResponderStore.swift",
        ROOT / "ClawWatch iOS/OpenClawTalkRelay.swift",
        HERE / "Fixtures.swift", HERE / "Cases.swift", HERE / "TalkCases.swift", *generated,
    ], executable)
    subprocess.run([str(executable)], check=True, timeout=45)


def websocket_tests(tmp):
    main = tmp / "main.swift"
    main.write_text("""import Foundation
let client = WSClient()
var closes = 0
var texts = 0
let cancel = CommandLine.arguments[2] == "cancel"
client.onOpen = {
    if cancel {
        client.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            precondition(closes == 0, "Explicit close must not report a transport failure")
            print("PASS: explicit WebSocket teardown")
            exit(0)
        }
    }
}
client.onText = { text in
    precondition(text == "challenge", "Server frame received intact")
    texts += 1
    client.sendText("ack")
}
client.onClose = { reason in
    closes += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        precondition(closes == 1, "Close callback must fire only once")
        precondition(texts == 1, "Immediate post-upgrade challenge must be received")
        print("PASS: WebSocket handshake, frame reception, remote close")
        exit(0)
    }
}
for address in ["http://localhost", "ws://localhost:65536", "ws://localhost:0"] {
    let invalid = WSClient()
    var rejected = false
    invalid.onClose = { _ in rejected = true }
    invalid.connect(url: URL(string: address)!)
    precondition(rejected, "Invalid WebSocket URL must be rejected")
}
client.connect(url: URL(string: CommandLine.arguments[1])!, headers: [("X-Regression", "test")])
DispatchQueue.main.asyncAfter(deadline: .now() + 5) { fatalError("WebSocket test timed out") }
dispatchMain()
""")
    executable = tmp / "TransportRegression"
    compile_swift([ROOT / "ClawWatch iOS/WSClient.swift", main], executable)
    for mode in ["receive", "cancel"]:
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen()
            server.settimeout(8)
            path = "/voice?token=TEST_ONLY&device=phone&agent=review"
            url = f"ws://127.0.0.1:{server.getsockname()[1]}{path}"
            process = subprocess.Popen([str(executable), url, mode], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                conn, _ = server.accept()
                with conn:
                    conn.settimeout(5)
                    request = b""
                    while b"\r\n\r\n" not in request:
                        chunk = conn.recv(8192)
                        if not chunk:
                            raise AssertionError("WebSocket closed before HTTP upgrade")
                        request += chunk
                    lines = request.decode().split("\r\n")
                    assert lines[0] == f"GET {path} HTTP/1.1", lines[0]
                    headers = dict(line.split(": ", 1) for line in lines[1:] if ": " in line)
                    headers = {key.lower(): value for key, value in headers.items()}
                    assert headers["x-regression"] == "test"
                    key = headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                    accept = base64.b64encode(hashlib.sha1(key.encode()).digest()).decode()
                    conn.sendall(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n".encode())
                    if mode == "receive":
                        conn.sendall(b"\x81\x09challenge")
                        assert conn.recv(8192), "Client did not acknowledge the challenge"
                        conn.sendall(b"\x88\x02\x03\xe8")
                    output, error = process.communicate(timeout=8)
                    assert process.returncode == 0, error
                    print(output.strip())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()


def talk_wire_tests(tmp):
    """Exercise the actual relay + Network.framework socket against a local Gateway fixture."""
    main = tmp / "main.swift"
    main.write_text("""import Foundation
let relay = OpenClawTalkRelay(agentId: "assistant", model: "gpt-live-1") { nonce in
    ["role": "operator", "scopes": ["operator.talk"], "testNonce": nonce]
}
var receivedAudio = false
var receivedTranscript = false
relay.onError = { fatalError($0) }
relay.onReady = { contract in
    precondition(contract.inputRate == 24000)
    relay.appendAudio(Data([1, 0, 2, 0]))
}
relay.onAudio = { data in
    precondition(data == Data([3, 0, 4, 0]))
    receivedAudio = true
}
relay.onTranscript = { role, text in
    precondition(role == "assistant" && text == "Wire test")
    receivedTranscript = true
}
relay.onMark = { mark in
    precondition(receivedAudio && receivedTranscript)
    relay.acknowledgeMark(mark)
    relay.close()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        print("PASS: Talk relay over a real WebSocket, PCM exchange, captions, marks and graceful close")
        exit(0)
    }
}
relay.start { client in
    client.connect(url: URL(string: CommandLine.arguments[1])!, headers: [("X-Talk-Test", "fixture")])
}
DispatchQueue.main.asyncAfter(deadline: .now() + 6) { fatalError("Talk wire test timed out") }
dispatchMain()
""")
    executable = tmp / "TalkWireRegression"
    compile_swift([ROOT / "ClawWatch iOS/WSClient.swift", ROOT / "ClawWatch iOS/OpenClawTalkRelay.swift", main], executable)
    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        server.listen()
        server.settimeout(8)
        url = f"ws://127.0.0.1:{server.getsockname()[1]}/gateway?route=talk-test"
        process = subprocess.Popen([str(executable), url], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            conn, _ = server.accept()
            with conn:
                conn.settimeout(5)

                def read_bytes(count):
                    data = b""
                    while len(data) < count:
                        chunk = conn.recv(count - len(data))
                        assert chunk, "Socket closed before Talk cleanup completed"
                        data += chunk
                    return data

                def receive():
                    first, second = read_bytes(2)
                    assert first & 0x0f == 1, "Expected a JSON text frame"
                    length = second & 0x7f
                    if length == 126:
                        length = struct.unpack("!H", read_bytes(2))[0]
                    elif length == 127:
                        length = struct.unpack("!Q", read_bytes(8))[0]
                    assert second & 0x80, "Client frames must be masked"
                    mask = read_bytes(4)
                    data = read_bytes(length)
                    return json.loads(bytes(byte ^ mask[i % 4] for i, byte in enumerate(data)))

                def send(frame):
                    data = json.dumps(frame).encode()
                    prefix = bytes([0x81, len(data)]) if len(data) < 126 else b"\x81\x7e" + struct.pack("!H", len(data))
                    conn.sendall(prefix + data)

                def reply(request, payload):
                    send({"type": "res", "id": request["id"], "ok": True, "payload": payload})

                def event(kind, **fields):
                    send({"type": "event", "event": "talk.event", "payload": {"relaySessionId": "wire-session", "type": kind, **fields}})

                request = b""
                while not request.endswith(b"\r\n\r\n"):
                    request += read_bytes(1)
                lines = request.decode().split("\r\n")
                assert lines[0] == "GET /gateway?route=talk-test HTTP/1.1"
                headers = {key.lower(): value for key, value in (line.split(": ", 1) for line in lines if ": " in line)}
                assert headers["x-talk-test"] == "fixture"
                accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                conn.sendall(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n".encode())
                send({"type": "event", "event": "connect.challenge", "payload": {"nonce": "wire-nonce"}})
                connect = receive()
                assert connect["method"] == "connect" and connect["params"]["testNonce"] == "wire-nonce"
                reply(connect, {"type": "hello-ok"})
                create = receive()
                assert create["method"] == "talk.session.create"
                assert create["params"]["sessionKey"] == "agent:assistant:clawwatch-voice"
                event("ready")  # Real ordering race: ready precedes the create response.
                reply(create, {"sessionId": "wire-session", "model": "gpt-live-1", "audio": {
                    "inputEncoding": "pcm16", "outputEncoding": "pcm16", "inputSampleRateHz": 24000, "outputSampleRateHz": 24000}})
                upload = receive()
                assert upload["method"] == "talk.session.appendAudio"
                assert base64.b64decode(upload["params"]["audioBase64"]) == b"\x01\x00\x02\x00"
                reply(upload, {"ok": True})
                event("audio", audioBase64=base64.b64encode(b"\x03\x00\x04\x00").decode(), talkEvent={"turnId": "wire-turn"})
                event("transcript", role="assistant", text="Wire test", final=True)
                event("mark", markName="wire-mark")
                mark = receive()
                assert mark["method"] == "talk.session.acknowledgeMark" and mark["params"]["markName"] == "wire-mark"
                reply(mark, {"ok": True})
                close = receive()
                assert close["method"] == "talk.session.close" and close["params"]["sessionId"] == "wire-session"
                reply(close, {"ok": True})
                output, error = process.communicate(timeout=8)
                assert process.returncode == 0, error
                print(output.strip())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="mercury-regressions-") as directory:
        tmp = Path(directory)
        lifecycle_tests(tmp)
        websocket_tests(tmp)
        talk_wire_tests(tmp)
