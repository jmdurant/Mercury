import Foundation
import Network

// In-memory boundaries: these tests never touch HealthKit, Keychain, iCloud,
// Telegram, a real gateway, or an audio device.
final class TestKeyValueStore {
    static let `default` = TestKeyValueStore()
    static let didChangeExternallyNotification = Notification.Name("test.config.changed")
    private var values: [String: Any] = [:]
    func synchronize() {}
    func string(forKey key: String) -> String? { values[key] as? String }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

enum KeychainService {
    static var values: [String: Data] = [:]
    static func load(key: String) -> Data? { values[key] }
    static func save(key: String, data: Data) -> Bool { values[key] = data; return true }
    static func delete(key: String) { values[key] = nil }
}

struct LoggerService {
    enum Level { case info, error }
    init(_ type: Any) {}
    func log(_ message: Any, level: Level = .info) {}
}

enum CloudflareAccess {
    static let isConfigured = false
    static let clientId = ""
    static let clientSecret = ""
}

final class NodeDiscoveryService {
    static let shared = NodeDiscoveryService()
    func resolveEndpoint(forHost host: String, completion: @escaping (NWEndpoint?, Bool) -> Void) {
        completion(nil, false)
    }
}

final class LiveVoiceService {
    static let shared = LiveVoiceService()
    var defaultAgentId = ""
    func stop() {}
}

enum AgentAlertService {
    static var count = 0
    static func raise(_ text: String, critical: Bool) { count += 1 }
}

final class WSClient {
    static var instances: [WSClient] = []
    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?
    var onWaiting: ((String) -> Void)?
    var sent: [[String: Any]] = []
    var closed = false
    init() { Self.instances.append(self) }
    func connect(url: URL, headers: [(String, String)] = []) {}
    func connect(endpoint: NWEndpoint, tls: Bool, headers: [(String, String)] = []) {}
    func close() { closed = true }
    func sendText(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }
    func frame(_ frame: [String: Any]) {
        onText?(String(decoding: try! JSONSerialization.data(withJSONObject: frame), as: UTF8.self))
    }
}

final class FakeInput {
    var removals = 0
    func removeTap(onBus: Int) { removals += 1 }
}
final class FakeEngine {
    let inputNode = FakeInput()
    var running = false
    var isRunning: Bool { running }
    func stop() { running = false }
}
final class FakePlayer {
    func stop() {}
    func playAudio() throws {}
}
final class AVAudioSession {
    enum Options { case notifyOthersOnDeactivation }
    static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }
    var deactivations = 0
    func setActive(_ active: Bool, options: Options) throws {
        if !active { deactivations += 1 }
    }
}

enum TestError: Error { case capture }

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: " + message) }
}

func consent(_ enabled: Bool) {
    for category in AutoResponderStore.Consent.allCases {
        AutoResponderStore.setConsent(category, enabled)
    }
    UserDefaults.standard.removeObject(forKey: "agentRateTimestamps")
    StatusDataService.calls = []
    StatusDataService.unavailable = []
}

func pause(_ seconds: Double = 0.05) async {
    try! await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
        await pause(0.025)
    }
    return condition()
}
