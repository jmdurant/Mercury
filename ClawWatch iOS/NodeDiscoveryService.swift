//
//  NodeDiscoveryService.swift
//  ClawWatch (shared: iOS + watchOS)
//
//  Finds OpenClaw gateways on the local network via the gateway's Bonjour
//  advertisement (_openclaw-gw._tcp). Uses NWBrowser (Network framework), which
//  is available on both iOS and watchOS, so a standalone watch on Wi-Fi can try
//  to discover too — though watchOS mDNS is more restricted and may not always
//  resolve. The gatewayTls TXT record picks ws:// vs wss://.
//
//  Requires NSLocalNetworkUsageDescription + NSBonjourServices in Info.plist.
//

import Foundation
import Network

@Observable
final class NodeDiscoveryService {

    static let shared = NodeDiscoveryService()

    struct Gateway: Identifiable, Hashable {
        let id: String       // Bonjour instance name
        let name: String
        let url: String      // ws:// or wss:// host:port (for display + persistence)
        let endpoint: NWEndpoint  // the live Bonjour service endpoint to dial
        let tls: Bool
    }

    var gateways: [Gateway] = []
    var isBrowsing = false

    private var browser: NWBrowser?
    private var probes: [NWConnection] = []

    func start() {
        stop()
        gateways = []
        isBrowsing = true

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_openclaw-gw._tcp", domain: "local."),
            using: NWParameters())
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results { self?.resolve(result) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                DispatchQueue.main.async { self?.isBrowsing = false }
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        probes.forEach { $0.cancel() }
        probes = []
        isBrowsing = false
    }

    /// One-shot: find the gateway advertising `host` and hand back its live
    /// Bonjour endpoint. Lets a connect that only has a raw-IP URL (from a QR
    /// scan, or a persisted URL after relaunch) still dial the endpoint — which
    /// iOS Local Network privacy allows — instead of the raw IP, which it aborts.
    /// Runs its own browser so it doesn't disturb the UI's `gateways` list.
    func resolveEndpoint(forHost host: String, timeout: TimeInterval = 3,
                         completion: @escaping (NWEndpoint?, Bool) -> Void) {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_openclaw-gw._tcp", domain: "local."),
            using: NWParameters())
        var probes: [NWConnection] = []
        var finished = false
        func finish(_ endpoint: NWEndpoint?, _ tls: Bool) {
            guard !finished else { return }
            finished = true
            probes.forEach { $0.cancel() }
            browser.cancel()
            DispatchQueue.main.async { completion(endpoint, tls) }
        }
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case .service = result.endpoint else { continue }
                var tls = false
                if case let .bonjour(txt) = result.metadata, txt["gatewayTls"] == "1" { tls = true }
                let probe = NWConnection(to: result.endpoint, using: .tcp)
                probes.append(probe)
                probe.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if case let .hostPort(h, _)? = probe.currentPath?.remoteEndpoint {
                            let hs = "\(h)".split(separator: "%").first.map(String.init) ?? "\(h)"
                            if hs == host { finish(result.endpoint, tls) }
                        }
                        probe.cancel()
                    case .failed, .cancelled:
                        break
                    default:
                        break
                    }
                }
                probe.start(queue: .main)
            }
        }
        browser.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil, false) }
    }

    /// Resolve a discovered service to a host:port URL via a short-lived
    /// connection (NWBrowser gives a service endpoint, not a host).
    private func resolve(_ result: NWBrowser.Result) {
        guard case let .service(name, _, _, _) = result.endpoint else { return }
        var tls = false
        if case let .bonjour(txt) = result.metadata, txt["gatewayTls"] == "1" { tls = true }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        probes.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                    let h = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                    let url = "\(tls ? "wss" : "ws")://\(h):\(port.rawValue)"
                    let gateway = Gateway(id: name, name: name, url: url,
                                          endpoint: result.endpoint, tls: tls)
                    DispatchQueue.main.async {
                        if !self.gateways.contains(gateway) { self.gateways.append(gateway) }
                    }
                }
                connection.cancel()
                self.probes.removeAll { $0 === connection }
            case .failed, .cancelled:
                self.probes.removeAll { $0 === connection }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }
}
