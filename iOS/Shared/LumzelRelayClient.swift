import CryptoKit
import Foundation
import Network
import RoutingCore
import Security

public enum LumzelRelayClientError: Error, LocalizedError, Sendable {
    case invalidRelayConfig(String)
    case handshakeFailed(String)
    case socks5Failed(String)
    case webSocketFailed(String)
    case streamOpenFailed(String)
    case connectionClosed
    case timeout

    public var errorDescription: String? {
        switch self {
        case .invalidRelayConfig(let msg): return "Relay 配置无效：\(msg)"
        case .handshakeFailed(let msg): return "Relay 握手失败：\(msg)"
        case .socks5Failed(let msg): return "前置 SOCKS5 连接失败：\(msg)"
        case .webSocketFailed(let msg): return "Relay WebSocket 通信失败：\(msg)"
        case .streamOpenFailed(let msg): return "打开 Relay 数据流失败：\(msg)"
        case .connectionClosed: return "Relay 连接已关闭"
        case .timeout: return "Relay 操作超时"
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

private final class AtomicAliveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true

    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return alive
    }

    func markDead() {
        lock.lock()
        alive = false
        lock.unlock()
    }
}

// MARK: - Handshake JSON Models

private struct RelayClientHandshakePayload: Codable {
    let clientPub: String
    let token: String
    let mode: String
}

private struct RelayHostHandshakePayload: Codable {
    let ok: Bool
    let hostEphemeralPub: String?
    let error: String?
}

// MARK: - WebSocket Transport Abstraction

private enum RelayWebSocketMessage: Sendable {
    case text(String)
    case data(Data)
}

private protocol RelayWebSocketTransport: AnyObject, Sendable {
    func send(_ message: RelayWebSocketMessage) async throws
    func receive() async throws -> RelayWebSocketMessage
    func close()
}

// MARK: - Direct URLSession WebSocket Transport

private final class URLSessionRelayWebSocketTransport: RelayWebSocketTransport, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL, password: String) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 0
        self.session = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let trimmedPass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPass.isEmpty {
            request.setValue(trimmedPass, forHTTPHeaderField: LumzelRelayConstants.passwordHeader)
        }

        self.task = session.webSocketTask(with: request)
        self.task.maximumMessageSize = 16 * 1024 * 1024
        self.task.resume()
    }

    func send(_ message: RelayWebSocketMessage) async throws {
        let wsMessage: URLSessionWebSocketTask.Message
        switch message {
        case .text(let str): wsMessage = .string(str)
        case .data(let data): wsMessage = .data(data)
        }
        try await task.send(wsMessage)
    }

    func receive() async throws -> RelayWebSocketMessage {
        let msg = try await task.receive()
        switch msg {
        case .string(let str):
            return .text(str)
        case .data(let data):
            return .data(data)
        @unknown default:
            throw LumzelRelayClientError.webSocketFailed("未知的 WebSocket 消息类型")
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

// MARK: - SOCKS5-Chained NWConnection + TLS + RFC 6455 WebSocket Transport

private final class SOCKS5ChainedWebSocketTransport: RelayWebSocketTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let loopbackBridge: LoopbackTLSBridge?
    private let queue = DispatchQueue(label: "local.routeweaver.relay-ws-socks5", qos: .userInitiated)
    private let sendLock = NSLock()
    private var readBuffer = Data()
    private var closed = false

    private init(connection: NWConnection, loopbackBridge: LoopbackTLSBridge?, initialBuffer: Data) {
        self.connection = connection
        self.loopbackBridge = loopbackBridge
        self.readBuffer = initialBuffer
    }

    static func connect(url: URL, password: String, socks5ProxyPort: Int) async throws -> SOCKS5ChainedWebSocketTransport {
        guard let host = url.host, !host.isEmpty else {
            throw LumzelRelayClientError.invalidRelayConfig("缺少 Relay 主机名")
        }
        let scheme = (url.scheme ?? "wss").lowercased()
        let isTLS = (scheme == "wss" || scheme == "https")
        let port = UInt16(url.port ?? (isTLS ? 443 : 80))

        guard (1...65535).contains(socks5ProxyPort),
              let nwSocksPort = NWEndpoint.Port(rawValue: UInt16(socks5ProxyPort)) else {
            throw LumzelRelayClientError.socks5Failed("无效的本地 SOCKS5 端口：\(socks5ProxyPort)")
        }

        // 1. Connect raw TCP to 127.0.0.1:<socks5ProxyPort> and perform RFC 1928 SOCKS5 CONNECT.
        let socksQueue = DispatchQueue(label: "local.routeweaver.socks5-tunnel", qos: .userInitiated)
        let socksConn = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: nwSocksPort, using: .tcp)
        try await waitReady(connection: socksConn, queue: socksQueue)

        do {
            try await performSOCKS5Connect(connection: socksConn, targetHost: host, targetPort: port)
        } catch {
            socksConn.cancel()
            throw error
        }

        // 2. Wrap with TLS (via local loopback bridge so NWProtocolTLS validates SNI/cert cleanly) if wss://.
        let activeConn: NWConnection
        var bridge: LoopbackTLSBridge? = nil
        if isTLS {
            let tlsBridge = try await LoopbackTLSBridge.create(upstream: socksConn, serverName: host)
            bridge = tlsBridge
            activeConn = tlsBridge.tlsConnection
        } else {
            activeConn = socksConn
        }

        let transport = SOCKS5ChainedWebSocketTransport(
            connection: activeConn,
            loopbackBridge: bridge,
            initialBuffer: Data()
        )

        do {
            try await transport.performWebSocketUpgrade(url: url, host: host, port: port, isTLS: isTLS, password: password)
            return transport
        } catch {
            transport.close()
            throw error
        }
    }

    private static func waitReady(connection: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.trySet() { cont.resume() }
                case .failed(let err):
                    if once.trySet() { cont.resume(throwing: LumzelRelayClientError.socks5Failed(err.localizedDescription)) }
                case .cancelled:
                    if once.trySet() { cont.resume(throwing: LumzelRelayClientError.connectionClosed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func performSOCKS5Connect(
        connection: NWConnection,
        targetHost: String,
        targetPort: UInt16
    ) async throws {
        // Greeting: VER=5, NMETHODS=1, METHOD=0 (No Auth)
        try await sendRaw(Data([0x05, 0x01, 0x00]), on: connection)
        let greetingReply = try await receiveExact(2, on: connection)
        guard greetingReply.count == 2, greetingReply[0] == 0x05, greetingReply[1] == 0x00 else {
            throw LumzelRelayClientError.socks5Failed("SOCKS5 认证协商失败")
        }

        // CONNECT request: VER=5, CMD=1, RSV=0, ATYP=...
        var req = Data([0x05, 0x01, 0x00])
        if let ipv4 = IPv4Address(targetHost) {
            req.append(0x01)
            req.append(ipv4.rawValue)
        } else if let ipv6 = IPv6Address(targetHost) {
            req.append(0x04)
            req.append(ipv6.rawValue)
        } else {
            let domainBytes = Data(targetHost.utf8)
            guard domainBytes.count <= 255 else {
                throw LumzelRelayClientError.socks5Failed("目标域名过长")
            }
            req.append(0x03)
            req.append(UInt8(domainBytes.count))
            req.append(domainBytes)
        }
        req.append(UInt8((targetPort >> 8) & 0xFF))
        req.append(UInt8(targetPort & 0xFF))

        try await sendRaw(req, on: connection)

        let head = try await receiveExact(4, on: connection)
        guard head[0] == 0x05, head[1] == 0x00 else {
            throw LumzelRelayClientError.socks5Failed("SOCKS5 CONNECT 被拒绝（code=\(head[1])）")
        }
        let atyp = head[3]
        switch atyp {
        case 0x01:
            _ = try await receiveExact(4 + 2, on: connection)
        case 0x03:
            let lenByte = try await receiveExact(1, on: connection)
            _ = try await receiveExact(Int(lenByte[0]) + 2, on: connection)
        case 0x04:
            _ = try await receiveExact(16 + 2, on: connection)
        default:
            throw LumzelRelayClientError.socks5Failed("未知 SOCKS5 ATYP=\(atyp)")
        }
    }

    private func performWebSocketUpgrade(
        url: URL,
        host: String,
        port: UInt16,
        isTLS: Bool,
        password: String
    ) async throws {
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        let wsKey = Data(keyBytes).base64EncodedString()

        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        let defaultPort = isTLS ? 443 : 80
        let hostHeader = (port == UInt16(defaultPort)) ? host : "\(host):\(port)"

        var requestText = "GET \(path)\(query) HTTP/1.1\r\n"
            + "Host: \(hostHeader)\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(wsKey)\r\n"
            + "Sec-WebSocket-Version: 13\r\n"
        let trimmedPass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPass.isEmpty {
            requestText += "\(LumzelRelayConstants.passwordHeader): \(trimmedPass)\r\n"
        }
        requestText += "\r\n"

        try await Self.sendRaw(Data(requestText.utf8), on: connection)

        let separator = Data("\r\n\r\n".utf8)
        while true {
            if let range = readBuffer.range(of: separator) {
                let headerData = readBuffer[..<range.lowerBound]
                readBuffer.removeSubrange(..<range.upperBound)
                guard let headerText = String(data: headerData, encoding: .utf8),
                      let statusLine = headerText.components(separatedBy: "\r\n").first,
                      statusLine.contains(" 101 ") else {
                    throw LumzelRelayClientError.webSocketFailed("WebSocket 升级握手失败")
                }
                return
            }
            if readBuffer.count > 65_536 {
                throw LumzelRelayClientError.webSocketFailed("WebSocket 升级响应头过大")
            }
            let chunk = try await Self.receiveChunk(on: connection)
            readBuffer.append(chunk)
        }
    }

    func send(_ message: RelayWebSocketMessage) async throws {
        let opcode: UInt8
        let payload: Data
        switch message {
        case .text(let str):
            opcode = 0x1
            payload = Data(str.utf8)
        case .data(let data):
            opcode = 0x2
            payload = data
        }
        let frame = encodeRFC6455Frame(opcode: opcode, payload: payload)
        try await Self.sendRaw(frame, on: connection)
    }

    func receive() async throws -> RelayWebSocketMessage {
        var assembledOpcode: UInt8?
        var assembledData = Data()

        while true {
            let (fin, opcode, payload) = try await readSingleRFC6455Frame()
            switch opcode {
            case 0x8: // Close
                close()
                throw LumzelRelayClientError.connectionClosed
            case 0x9: // Ping -> reply Pong
                let pong = encodeRFC6455Frame(opcode: 0xA, payload: payload)
                try? await Self.sendRaw(pong, on: connection)
                continue
            case 0xA: // Pong
                continue
            case 0x1, 0x2:
                assembledOpcode = opcode
                assembledData = payload
                if fin {
                    if opcode == 0x1 {
                        return .text(String(decoding: assembledData, as: UTF8.self))
                    }
                    return .data(assembledData)
                }
            case 0x0: // Continuation
                guard let initialOpcode = assembledOpcode else {
                    throw LumzelRelayClientError.webSocketFailed("收到孤立的 continuation 帧")
                }
                assembledData.append(payload)
                if fin {
                    if initialOpcode == 0x1 {
                        return .text(String(decoding: assembledData, as: UTF8.self))
                    }
                    return .data(assembledData)
                }
            default:
                throw LumzelRelayClientError.webSocketFailed("不支持的 WebSocket opcode=\(opcode)")
            }
        }
    }

    func close() {
        sendLock.lock()
        let alreadyClosed = closed
        closed = true
        sendLock.unlock()
        guard !alreadyClosed else { return }

        let closeFrame = encodeRFC6455Frame(opcode: 0x8, payload: Data())
        connection.send(content: closeFrame, completion: .contentProcessed { [weak connection] _ in
            connection?.cancel()
        })
        loopbackBridge?.cancel()
    }

    // MARK: - RFC 6455 Frame Codec

    private func encodeRFC6455Frame(opcode: UInt8, payload: Data) -> Data {
        var out = Data()
        out.reserveCapacity(14 + payload.count)
        out.append(0x80 | (opcode & 0x0F)) // FIN=1

        let len = payload.count
        if len < 126 {
            out.append(0x80 | UInt8(len))
        } else if len <= 65_535 {
            out.append(0x80 | 126)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        } else {
            out.append(0x80 | 127)
            let u64 = UInt64(len)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((u64 >> shift) & 0xFF))
            }
        }

        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mask)
        out.append(contentsOf: mask)

        var masked = [UInt8](payload)
        for i in masked.indices {
            masked[i] ^= mask[i % 4]
        }
        out.append(contentsOf: masked)
        return out
    }

    private func readSingleRFC6455Frame() async throws -> (fin: Bool, opcode: UInt8, payload: Data) {
        let header = try await readBytes(2)
        let fin = (header[0] & 0x80) != 0
        let opcode = header[0] & 0x0F
        let masked = (header[1] & 0x80) != 0
        var length = UInt64(header[1] & 0x7F)

        if length == 126 {
            let ext = try await readBytes(2)
            length = (UInt64(ext[0]) << 8) | UInt64(ext[1])
        } else if length == 127 {
            let ext = try await readBytes(8)
            var val: UInt64 = 0
            for b in ext {
                val = (val << 8) | UInt64(b)
            }
            length = val
        }

        guard length <= 32 * 1024 * 1024 else {
            throw LumzelRelayClientError.webSocketFailed("WebSocket 帧过大")
        }

        var maskKey: [UInt8]? = nil
        if masked {
            maskKey = Array(try await readBytes(4))
        }

        var payload = length > 0 ? try await readBytes(Int(length)) : Data()
        if let maskKey {
            var unmasked = [UInt8](payload)
            for i in unmasked.indices {
                unmasked[i] ^= maskKey[i % 4]
            }
            payload = Data(unmasked)
        }
        return (fin, opcode, payload)
    }

    private func readBytes(_ count: Int) async throws -> Data {
        while readBuffer.count < count {
            let chunk = try await Self.receiveChunk(on: connection)
            readBuffer.append(chunk)
        }
        let slice = readBuffer.prefix(count)
        readBuffer.removeFirst(count)
        return Data(slice)
    }

    private static func sendRaw(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private static func receiveChunk(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, err in
                if let err {
                    cont.resume(throwing: err)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(throwing: LumzelRelayClientError.connectionClosed)
                } else {
                    cont.resume(throwing: LumzelRelayClientError.connectionClosed)
                }
            }
        }
    }

    private static func receiveExact(_ count: Int, on connection: NWConnection) async throws -> Data {
        var buf = Data()
        while buf.count < count {
            let remaining = count - buf.count
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, err in
                    if let err {
                        cont.resume(throwing: err)
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(throwing: LumzelRelayClientError.connectionClosed)
                    } else {
                        cont.resume(throwing: LumzelRelayClientError.connectionClosed)
                    }
                }
            }
            buf.append(chunk)
        }
        return buf
    }
}

/// Bridges a local TLS `NWConnection` through an already-connected SOCKS5 `NWConnection`
/// via an ephemeral `127.0.0.1` `NWListener`, preserving full TLS SNI and certificate verification.
private final class LoopbackTLSBridge: @unchecked Sendable {
    let tlsConnection: NWConnection
    private let listener: NWListener
    private let upstream: NWConnection
    private var downstream: NWConnection?
    private let queue = DispatchQueue(label: "local.routeweaver.tls-loopback", qos: .userInitiated)

    private init(listener: NWListener, upstream: NWConnection, tlsConnection: NWConnection) {
        self.listener = listener
        self.upstream = upstream
        self.tlsConnection = tlsConnection
    }

    static func create(upstream: NWConnection, serverName: String) async throws -> LoopbackTLSBridge {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "local.routeweaver.tls-loopback-accept", qos: .userInitiated)

        let listeningPort: NWEndpoint.Port = try await withCheckedThrowingContinuation { cont in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port, once.trySet() {
                        cont.resume(returning: port)
                    }
                case .failed(let err):
                    if once.trySet() { cont.resume(throwing: err) }
                case .cancelled:
                    if once.trySet() { cont.resume(throwing: LumzelRelayClientError.connectionClosed) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, serverName)
        let tlsParams = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let tlsConn = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: listeningPort, using: tlsParams)

        let bridge = LoopbackTLSBridge(listener: listener, upstream: upstream, tlsConnection: tlsConn)

        listener.newConnectionHandler = { [weak bridge] accepted in
            guard let bridge else {
                accepted.cancel()
                return
            }
            listener.cancel()
            bridge.attachAccepted(accepted)
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            tlsConn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.trySet() { cont.resume() }
                case .failed(let err):
                    if once.trySet() { cont.resume(throwing: err) }
                case .cancelled:
                    if once.trySet() { cont.resume(throwing: LumzelRelayClientError.connectionClosed) }
                default:
                    break
                }
            }
            tlsConn.start(queue: queue)
        }

        return bridge
    }

    private func attachAccepted(_ accepted: NWConnection) {
        self.downstream = accepted
        accepted.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.pump(from: accepted, to: self?.upstream)
                self?.pump(from: self?.upstream, to: accepted)
            } else if case .failed = state {
                self?.cancel()
            }
        }
        accepted.start(queue: queue)
    }

    private func pump(from source: NWConnection?, to dest: NWConnection?) {
        guard let source, let dest else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, err in
            if let data, !data.isEmpty {
                dest.send(content: data, completion: .contentProcessed { sendErr in
                    if sendErr != nil {
                        self?.cancel()
                    } else if isComplete {
                        self?.cancel()
                    } else {
                        self?.pump(from: source, to: dest)
                    }
                })
            } else if err != nil || isComplete {
                self?.cancel()
            }
        }
    }

    func cancel() {
        listener.cancel()
        tlsConnection.cancel()
        downstream?.cancel()
        upstream.cancel()
    }
}

// MARK: - LumzelRelayClient

public final class LumzelRelayClient: @unchecked Sendable {
    public static let shared = LumzelRelayClient()

    public init() {}

    public func sendControlRequest(
        _ req: RelayControlHTTPRequest,
        relayConfig: RelayEndpointConfig,
        token: String,
        mode: String = "auth",
        socks5ProxyPort: Int? = nil
    ) async throws -> RelayControlHTTPResponse {
        let conn = try await openAuthenticatedSession(
            plane: .control,
            relayConfig: relayConfig,
            token: token,
            mode: mode,
            socks5ProxyPort: socks5ProxyPort
        )
        defer { conn.transport.close() }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reqData = try encoder.encode(req)

        var session = conn.session
        let sealed = try session.seal(host: relayConfig.hostID, plaintext: reqData)
        try await conn.transport.send(.data(sealed))

        while true {
            let msg = try await conn.transport.receive()
            if case .data(let frameData) = msg {
                let opened = try session.open(frameData)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(RelayControlHTTPResponse.self, from: opened.plaintext)
            }
        }
    }

    fileprivate struct AuthenticatedRelayConnection {
        let transport: any RelayWebSocketTransport
        let session: LumzelRelaySession
    }

    fileprivate func openAuthenticatedSession(
        plane: LumzelRelayPlane,
        relayConfig: RelayEndpointConfig,
        token: String,
        mode: String,
        socks5ProxyPort: Int?
    ) async throws -> AuthenticatedRelayConnection {
        guard !relayConfig.hostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LumzelRelayClientError.invalidRelayConfig("缺少 hostID")
        }
        guard let wsURL = relayConfig.websocketURL(for: plane) else {
            throw LumzelRelayClientError.invalidRelayConfig("Relay 服务器地址无效")
        }

        let transport: any RelayWebSocketTransport
        if let socksPort = socks5ProxyPort {
            transport = try await SOCKS5ChainedWebSocketTransport.connect(
                url: wsURL,
                password: relayConfig.password,
                socks5ProxyPort: socksPort
            )
        } else {
            transport = URLSessionRelayWebSocketTransport(url: wsURL, password: relayConfig.password)
        }

        do {
            let sid = UUID().uuidString.lowercased()
            let hello = LumzelLinkHello(host: relayConfig.hostID, sid: sid)
            let helloData = try JSONEncoder().encode(hello)
            let helloText = String(decoding: helloData, as: UTF8.self)
            try await transport.send(.text(helloText))

            // Generate ephemeral X25519 keypair and send n=0 handshake frame.
            let clientPriv = Curve25519.KeyAgreement.PrivateKey()
            let handshakePayload = RelayClientHandshakePayload(
                clientPub: clientPriv.publicKey.rawRepresentation.base64EncodedString(),
                token: token,
                mode: mode
            )
            let payloadData = try JSONEncoder().encode(handshakePayload)
            let handshakeFrame = try LumzelFrameCodec.encodeHandshakeFrame(
                host: relayConfig.hostID,
                sid: sid,
                payload: payloadData
            )
            try await transport.send(.data(handshakeFrame))

            // Wait for host handshake response frame (skipping any relay control JSON acks).
            while true {
                let msg = try await transport.receive()
                switch msg {
                case .text(let jsonStr):
                    if let obj = try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any],
                       let err = obj["error"] as? String, !err.isEmpty {
                        throw LumzelRelayClientError.handshakeFailed(err)
                    }
                    continue

                case .data(let frameData):
                    let (header, body) = try LumzelFrameCodec.decodeHandshakeFrame(frameData)
                    guard header.sid == sid else {
                        throw LumzelRelayError.sessionIDMismatch
                    }
                    let resp = try JSONDecoder().decode(RelayHostHandshakePayload.self, from: body)
                    guard resp.ok,
                          let pubB64 = resp.hostEphemeralPub,
                          let hostPubRaw = Data(base64Encoded: pubB64),
                          hostPubRaw.count == 32 else {
                        throw LumzelRelayClientError.handshakeFailed(resp.error ?? "主机拒绝握手")
                    }
                    let (sendKey, recvKey) = try LumzelRelayCrypto.deriveDirectionalSessionKeys(
                        localPrivateKeyRaw: clientPriv.rawRepresentation,
                        remotePublicKeyRaw: hostPubRaw,
                        pairingToken: token,
                        sid: sid
                    )
                    let session = try LumzelRelaySession(sendKey: sendKey, recvKey: recvKey, sid: sid)
                    return AuthenticatedRelayConnection(transport: transport, session: session)
                }
            }
        } catch {
            transport.close()
            throw error
        }
    }
}

// MARK: - /data Plane Stream Multiplexer & Stream Handle

public final class RelayMuxStreamHandle: @unchecked Sendable {
    public let streamID: UInt32

    private let sendHandler: @Sendable (Data) async throws -> Void
    private let closeHandler: @Sendable () async -> Void
    private let incomingStream: AsyncStream<Data>
    private var incomingIterator: AsyncStream<Data>.AsyncIterator
    private let iteratorLock = NSLock()

    fileprivate init(
        streamID: UInt32,
        incomingStream: AsyncStream<Data>,
        sendHandler: @escaping @Sendable (Data) async throws -> Void,
        closeHandler: @escaping @Sendable () async -> Void
    ) {
        self.streamID = streamID
        self.incomingStream = incomingStream
        self.incomingIterator = incomingStream.makeAsyncIterator()
        self.sendHandler = sendHandler
        self.closeHandler = closeHandler
    }

    public func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await sendHandler(data)
    }

    public func receive() async -> Data? {
        // Sequential consumer per stream handle.
        return await incomingIterator.next()
    }

    public func close() async {
        await closeHandler()
    }
}

public final class LumzelRelayDataMultiplexer: @unchecked Sendable {
    private let relayConfig: RelayEndpointConfig
    private let pairingToken: String
    private let socks5ProxyPort: Int?
    private let client: LumzelRelayClient

    private actor State {
        private let relayConfig: RelayEndpointConfig
        private let pairingToken: String
        private let socks5ProxyPort: Int?
        private let client: LumzelRelayClient

        private var activeConnection: MultiplexerConnection?
        private var retiredConnections: [ObjectIdentifier: MultiplexerConnection] = [:]
        private var connectingTask: Task<MultiplexerConnection, Error>?

        init(
            relayConfig: RelayEndpointConfig,
            pairingToken: String,
            socks5ProxyPort: Int?,
            client: LumzelRelayClient
        ) {
            self.relayConfig = relayConfig
            self.pairingToken = pairingToken
            self.socks5ProxyPort = socks5ProxyPort
            self.client = client
        }

        var isConnected: Bool {
            activeConnection?.isAlive ?? false
        }

        func openStream(
            targetInterface: String?,
            destinationHost: String,
            destinationPort: UInt16
        ) async throws -> RelayMuxStreamHandle {
            let conn = try await ensureConnection()
            return try await conn.openStream(
                targetInterface: targetInterface,
                destinationHost: destinationHost,
                destinationPort: destinationPort
            )
        }

        func disconnect() async {
            connectingTask?.cancel()
            connectingTask = nil
            if let active = activeConnection {
                activeConnection = nil
                await active.closeAll()
            }
            for (_, retired) in retiredConnections {
                await retired.closeAll()
            }
            retiredConnections.removeAll()
        }

        private func ensureConnection() async throws -> MultiplexerConnection {
            if let existing = activeConnection, existing.isAlive {
                let threshold = relayConfig.sessionRotateThresholdBytes
                if await existing.shouldRotate(thresholdBytes: threshold) {
                    retiredConnections[ObjectIdentifier(existing)] = existing
                    activeConnection = nil
                    Task { [weak self] in
                        await self?.pruneRetiredWhenEmpty(existing)
                    }
                } else {
                    return existing
                }
            }

            if let inFlight = connectingTask {
                return try await inFlight.value
            }

            let task = Task<MultiplexerConnection, Error> {
                let authConn = try await client.openAuthenticatedSession(
                    plane: .data,
                    relayConfig: relayConfig,
                    token: pairingToken,
                    mode: "auth",
                    socks5ProxyPort: socks5ProxyPort
                )
                let muxConn = MultiplexerConnection(
                    hostID: relayConfig.hostID,
                    transport: authConn.transport,
                    session: authConn.session
                )
                await muxConn.startReceiveLoop()
                return muxConn
            }
            connectingTask = task
            defer { connectingTask = nil }

            let created = try await task.value
            activeConnection = created
            return created
        }

        private func pruneRetiredWhenEmpty(_ conn: MultiplexerConnection) async {
            while await conn.activeStreamCount > 0 && conn.isAlive {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await conn.closeAll()
            retiredConnections.removeValue(forKey: ObjectIdentifier(conn))
        }
    }

    private final actor MultiplexerConnection {
        private let hostID: String
        private let transport: any RelayWebSocketTransport
        private var session: LumzelRelaySession

        private var nextStreamID: UInt32 = 1
        private var pendingOpens: [UInt32: CheckedContinuation<Void, Error>] = [:]
        private var streams: [UInt32: AsyncStream<Data>.Continuation] = [:]
        private var receiveTask: Task<Void, Never>?
        private var _isAlive = true
        private let aliveState = AtomicAliveFlag()

        nonisolated var isAlive: Bool {
            aliveState.isAlive
        }

        private func markDead() {
            _isAlive = false
            aliveState.markDead()
        }

        var activeStreamCount: Int {
            streams.count + pendingOpens.count
        }

        init(hostID: String, transport: any RelayWebSocketTransport, session: LumzelRelaySession) {
            self.hostID = hostID
            self.transport = transport
            self.session = session
        }

        func shouldRotate(thresholdBytes: UInt64) -> Bool {
            !_isAlive || session.shouldRotate(thresholdBytes: thresholdBytes)
        }

        func startReceiveLoop() {
            receiveTask = Task { [weak self] in
                await self?.runReceiveLoop()
            }
        }

        func openStream(
            targetInterface: String?,
            destinationHost: String,
            destinationPort: UInt16
        ) async throws -> RelayMuxStreamHandle {
            guard _isAlive else {
                throw LumzelRelayClientError.connectionClosed
            }

            let streamID = allocateStreamID()
            let (incomingStream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            streams[streamID] = continuation

            let openReq = RelayMuxOpenRequest(
                targetInterface: targetInterface,
                destinationHost: destinationHost,
                destinationPort: destinationPort
            )
            let reqPayload = try JSONEncoder().encode(openReq)
            let muxFrame = RelayMuxFrame(command: .openTCP, streamID: streamID, payload: reqPayload)

            do {
                try await sealAndSend(muxFrame)
                try await withCheckedThrowingContinuation { (openCont: CheckedContinuation<Void, Error>) in
                    pendingOpens[streamID] = openCont
                }
            } catch {
                pendingOpens.removeValue(forKey: streamID)
                streams.removeValue(forKey: streamID)?.finish()
                throw error
            }

            return RelayMuxStreamHandle(
                streamID: streamID,
                incomingStream: incomingStream,
                sendHandler: { [weak self] data in
                    guard let self else { throw LumzelRelayClientError.connectionClosed }
                    try await self.sendStreamData(streamID: streamID, data: data)
                },
                closeHandler: { [weak self] in
                    await self?.closeStream(streamID: streamID, notifyPeer: true)
                }
            )
        }

        func sendStreamData(streamID: UInt32, data: Data) async throws {
            guard _isAlive else { throw LumzelRelayClientError.connectionClosed }
            try await sealAndSend(RelayMuxFrame(command: .data, streamID: streamID, payload: data))
        }

        func closeStream(streamID: UInt32, notifyPeer: Bool) async {
            if let cont = streams.removeValue(forKey: streamID) {
                cont.finish()
                if notifyPeer && _isAlive {
                    try? await sealAndSend(RelayMuxFrame(command: .close, streamID: streamID))
                }
            }
        }

        func closeAll() async {
            markDead()
            receiveTask?.cancel()
            receiveTask = nil
            for (_, openCont) in pendingOpens {
                openCont.resume(throwing: LumzelRelayClientError.connectionClosed)
            }
            pendingOpens.removeAll()
            for (_, cont) in streams {
                cont.finish()
            }
            streams.removeAll()
            transport.close()
        }

        private func allocateStreamID() -> UInt32 {
            var candidate = nextStreamID
            while candidate == 0 || streams[candidate] != nil || pendingOpens[candidate] != nil {
                candidate = candidate &+ 1
            }
            nextStreamID = candidate &+ 1
            if nextStreamID == 0 { nextStreamID = 1 }
            return candidate
        }

        private func sealAndSend(_ mux: RelayMuxFrame) async throws {
            let sealed = try session.seal(host: hostID, plaintext: mux.encode())
            try await transport.send(.data(sealed))
        }

        private func runReceiveLoop() async {
            while !Task.isCancelled && _isAlive {
                do {
                    let msg = try await transport.receive()
                    guard case .data(let frameData) = msg else { continue }
                    let opened = try session.open(frameData)
                    let mux = try RelayMuxFrame.decode(opened.plaintext)
                    await handleMuxFrame(mux)
                } catch {
                    await closeAll()
                    return
                }
            }
        }

        private func handleMuxFrame(_ mux: RelayMuxFrame) async {
            switch mux.command {
            case .openAck:
                if let openCont = pendingOpens.removeValue(forKey: mux.streamID) {
                    if let ack = try? JSONDecoder().decode(RelayMuxOpenAck.self, from: mux.payload) {
                        if ack.ok {
                            openCont.resume()
                        } else {
                            openCont.resume(throwing: LumzelRelayClientError.streamOpenFailed(ack.error ?? "拒绝连接"))
                        }
                    } else {
                        openCont.resume(throwing: LumzelRelayClientError.streamOpenFailed("无效的 openAck"))
                    }
                }
            case .data:
                if let cont = streams[mux.streamID], !mux.payload.isEmpty {
                    cont.yield(mux.payload)
                }
            case .close:
                await closeStream(streamID: mux.streamID, notifyPeer: false)
            case .keepalive:
                try? await sealAndSend(RelayMuxFrame(command: .keepalive, streamID: mux.streamID, payload: mux.payload))
            case .openTCP, .udpPacket:
                break
            }
        }
    }

    private let state: State

    public init(
        relayConfig: RelayEndpointConfig,
        pairingToken: String,
        socks5ProxyPort: Int? = nil,
        client: LumzelRelayClient = .shared
    ) {
        self.relayConfig = relayConfig
        self.pairingToken = pairingToken
        self.socks5ProxyPort = socks5ProxyPort
        self.client = client
        self.state = State(
            relayConfig: relayConfig,
            pairingToken: pairingToken,
            socks5ProxyPort: socks5ProxyPort,
            client: client
        )
    }

    public func isConnected() async -> Bool {
        await state.isConnected
    }

    public func openStream(
        targetInterface: String?,
        destinationHost: String,
        destinationPort: UInt16
    ) async throws -> RelayMuxStreamHandle {
        try await state.openStream(
            targetInterface: targetInterface,
            destinationHost: destinationHost,
            destinationPort: destinationPort
        )
    }

    public func disconnect() async {
        await state.disconnect()
    }
}
