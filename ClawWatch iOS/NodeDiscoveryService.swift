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
        let id: String     // Bonjour instance name
        let name: String
        let url: String    // ws:// or wss:// host:port
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
                    let gateway = Gateway(id: name, name: name, url: url)
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
