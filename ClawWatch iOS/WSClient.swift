//
//  WSClient.swift
//  ClawWatch (shared: iOS + watchOS)
//
//  A WebSocket client on Network.framework (NWConnection + NWProtocolWebSocket)
//  instead of URLSessionWebSocketTask. Retains the full request URL so the
//  upgrade includes the path and authentication/routing query parameters.
//

import Foundation
import Network

final class WSClient {

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
    func connect(url: URL, headers: [(String, String)] = []) {
        guard let host = url.host, !host.isEmpty,
              url.scheme == "ws" || url.scheme == "wss",
              (1...65535).contains(url.port ?? (url.scheme == "wss" ? 443 : 80)) else {
            onClose?("bad url"); return
        }
        open(endpoint: .url(url), tls: url.scheme == "wss", label: host, headers: headers)
    }

    /// Connect directly to a Bonjour/Network.framework endpoint (e.g. the
    /// `NWBrowser` service result). This uses the default root request path;
    /// use connect(url:) for endpoints with a path or query string.
    func connect(endpoint: NWEndpoint, tls: Bool, headers: [(String, String)] = []) {
        open(endpoint: endpoint, tls: tls, label: "\(endpoint)", headers: headers)
    }

    private func open(endpoint: NWEndpoint, tls: Bool, label: String,
                      headers: [(String, String)]) {
        close()
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        if !headers.isEmpty { ws.setAdditionalHeaders(headers) }

        let params: NWParameters = tls ? .tls : .tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        NSLog("WSCLIENT dialing \(label) tls=\(tls) headers=\(headers.count)")

        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, self.connection === conn else { return }
            switch state {
            case .preparing:
                NSLog("WSCLIENT state: preparing")
            case .ready:
                NSLog("WSCLIENT state: READY (socket open)")
                self.onOpen?()
                self.receive(on: conn)
            case .waiting(let error):
                NSLog("WSCLIENT state: WAITING — \(String(describing: error))")
                self.onWaiting?(error.localizedDescription)
            case .failed(let error):
                NSLog("WSCLIENT state: FAILED — \(String(describing: error))")
                self.finish(conn, reason: error.localizedDescription)
            case .cancelled:
                NSLog("WSCLIENT state: cancelled")
                self.finish(conn, reason: nil)
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, context, _, error in
            guard let self, let conn, self.connection === conn else { return }
            if let error {
                NSLog("WSCLIENT receive error — \(String(describing: error))")
                self.finish(conn, reason: error.localizedDescription); return
            }
            if let context,
               let meta = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .text:
                    if let data {
                        let s = String(decoding: data, as: UTF8.self)
                        self.onText?(s)
                    }
                case .binary:
                    if let data { self.onData?(data) }
                case .close:
                    NSLog("WSCLIENT rx CLOSE frame")
                    self.finish(conn, reason: nil); return
                default:
                    break
                }
            }
            if self.connection === conn { self.receive(on: conn) }
        }
    }

    func sendText(_ string: String) {
        send(Data(string.utf8), opcode: .text)
    }
    func sendData(_ data: Data) {
        send(data, opcode: .binary)
    }
    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        // Audio arrives off the main queue; serialize sends with socket teardown.
        DispatchQueue.main.async { [weak self] in
            guard let self, let conn = self.connection else { return }
            let meta = NWProtocolWebSocket.Metadata(opcode: opcode)
            let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
            conn.send(content: data, contentContext: context, isComplete: true,
                      completion: .contentProcessed { [weak self, weak conn] error in
                guard let self, let conn, let error else { return }
                self.finish(conn, reason: error.localizedDescription)
            })
        }
    }

    private func finish(_ conn: NWConnection, reason: String?) {
        guard connection === conn else { return }
        close()
        onClose?(reason)
    }

    func close() {
        let old = connection
        connection = nil
        old?.stateUpdateHandler = nil
        old?.cancel()
    }
}
