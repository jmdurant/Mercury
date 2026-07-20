//
//  WSClient.swift
//  ClawWatch (shared: iOS + watchOS)
//
//  A WebSocket client on Network.framework (NWConnection + NWProtocolWebSocket)
//  instead of URLSessionWebSocketTask. The OpenClaw gateway pushes its
//  connect.challenge frame immediately after the HTTP upgrade, and
//  URLSessionWebSocketTask drops that (handshake 101 succeeds, then the socket
//  is cancelled with "Socket is not connected"). NWConnection handles a server
//  that sends data right at the upgrade.
//

import Foundation
import Network
import os

final class WSClient {

    private let log = Logger(subsystem: "Mercury", category: "WSClient")

    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?
    /// Fired when the connection parks in `.waiting` — the route isn't usable
    /// yet (host unreachable, Local Network permission pending, etc). NWConnection
    /// does NOT fail here; it retries silently, so surface it or we look stuck.
    var onWaiting: ((String) -> Void)?

    private var connection: NWConnection?

    /// Connect to a ws:// or wss:// URL. Extra headers are added to the upgrade
    /// request (e.g. Cloudflare Access).
    ///
    /// NOTE: dialing a raw LAN IP literal is aborted by iOS Local Network
    /// privacy (ECONNABORTED in `.waiting`) even when the toggle reads "on".
    /// For LAN gateways, prefer `connect(endpoint:tls:)` with the live Bonjour
    /// endpoint — that's the path iOS honours (and what the official app uses).
    func connect(url: URL, headers: [(String, String)] = []) {
        guard let host = url.host, url.scheme?.hasPrefix("ws") == true else {
            onClose?("bad url"); return
        }
        let port = UInt16(url.port ?? (url.scheme == "wss" ? 443 : 80))
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: port)!)
        open(endpoint: endpoint, tls: url.scheme == "wss", label: "\(host):\(port)", headers: headers)
    }

    /// Connect directly to a Bonjour/Network.framework endpoint (e.g. the
    /// `NWBrowser` service result). This is the LAN path that survives iOS
    /// Local Network privacy — a raw-IP dial does not.
    func connect(endpoint: NWEndpoint, tls: Bool, headers: [(String, String)] = []) {
        open(endpoint: endpoint, tls: tls, label: "\(endpoint)", headers: headers)
    }

    private func open(endpoint: NWEndpoint, tls: Bool, label: String,
                      headers: [(String, String)]) {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        if !headers.isEmpty { ws.setAdditionalHeaders(headers) }

        let params: NWParameters = tls ? .tls : .tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        NSLog("WSCLIENT dialing \(label) tls=\(tls) headers=\(headers.count)")

        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .preparing:
                NSLog("WSCLIENT state: preparing")
            case .ready:
                NSLog("WSCLIENT state: READY (socket open)")
                self.onOpen?()
                self.receive()
            case .waiting(let error):
                NSLog("WSCLIENT state: WAITING — \(String(describing: error))")
                self.onWaiting?(error.localizedDescription)
            case .failed(let error):
                NSLog("WSCLIENT state: FAILED — \(String(describing: error))")
                self.onClose?(error.localizedDescription)
            case .cancelled:
                NSLog("WSCLIENT state: cancelled")
                self.onClose?(nil)
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    private func receive() {
        connection?.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                NSLog("WSCLIENT receive error — \(String(describing: error))")
                self.onClose?(error.localizedDescription); return
            }
            if let context,
               let meta = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .text:
                    if let data {
                        let s = String(decoding: data, as: UTF8.self)
                        NSLog("WSCLIENT rx text (\(data.count)B): \(s.prefix(200))")
                        self.onText?(s)
                    }
                case .binary:
                    if let data { self.onData?(data) }
                case .close:
                    NSLog("WSCLIENT rx CLOSE frame")
                    self.onClose?(nil); return
                default:
                    break
                }
            }
            self.receive()
        }
    }

    func sendText(_ string: String) {
        send(Data(string.utf8), opcode: .text)
    }
    func sendData(_ data: Data) {
        send(data, opcode: .binary)
    }
    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        let meta = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        connection?.send(content: data, contentContext: context, isComplete: true,
                         completion: .contentProcessed { _ in })
    }

    func close() {
        connection?.cancel()
        connection = nil
    }
}
