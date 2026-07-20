//
//  NodeDiscoveryService.swift
//  ClawWatch iOS
//
//  Finds OpenClaw gateways on the local network. The gateway advertises a
//  Bonjour service (_openclaw-gw._tcp) on its port, with a TXT record telling
//  us whether it's TLS — so we can build a ready-to-use ws:// / wss:// URL and
//  offer it for the node/voice config. iOS only (needs the Local Network
//  permission + NSBonjourServices in Info.plist).
//

#if os(iOS)
import Foundation

@Observable
final class NodeDiscoveryService: NSObject {

    static let shared = NodeDiscoveryService()

    struct Gateway: Identifiable, Hashable {
        let id: String     // Bonjour instance name
        let name: String
        let url: String    // ws:// or wss:// host:port
    }

    var gateways: [Gateway] = []
    var isBrowsing = false

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []

    func start() {
        gateways = []
        resolving = []
        isBrowsing = true
        browser.delegate = self
        browser.stop()
        browser.searchForServices(ofType: "_openclaw-gw._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        isBrowsing = false
    }
}

extension NodeDiscoveryService: NetServiceBrowserDelegate, NetServiceDelegate {

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        isBrowsing = false
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName else { return }
        var tls = false
        if let data = sender.txtRecordData() {
            let txt = NetService.dictionary(fromTXTRecord: data)
            if let v = txt["gatewayTls"], String(data: v, encoding: .utf8) == "1" { tls = true }
        }
        let scheme = tls ? "wss" : "ws"
        let cleanHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let url = "\(scheme)://\(cleanHost):\(sender.port)"
        let gateway = Gateway(id: sender.name, name: sender.name, url: url)
        if !gateways.contains(gateway) { gateways.append(gateway) }
        resolving.removeAll { $0 === sender }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }
}
#endif
