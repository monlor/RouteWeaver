import CryptoKit
import Darwin
import Foundation
import RoutingCore

// MARK: - Handshake Wire Models

private struct RelayClientHandshake: Codable {
    let clientPub: String
    let token: String
    let mode: String
}

private struct RelayHostHandshakeResponse: Codable {
    let ok: Bool
    let hostEphemeralPub: String?
    let error: String?

    init(ok: Bool, hostEphemeralPub: String? = nil, error: String? = nil) {
        self.ok = ok
        self.hostEphemeralPub = hostEphemeralPub
        self.error = error
    }
}

private struct RelayServerAck: Decodable {
    let t: String
    let error: String?
}

// MARK: - /data Plane Multiplexed TCP Egress Actor

actor RelayDataPlaneSession {
    private let hostID: String
    private var cryptoSession: LumzelRelaySession
    private let sendFrame: @Sendable (Data) async throws -> Void
    private let onActiveStreamsChanged: @Sendable (Int) -> Void

    private var streams: [UInt32: StreamEntry] = [:]
    private let ioQueue = DispatchQueue(label: "local.routeweaver.relay-data-io", qos: .userInitiated, attributes: .concurrent)

    private final class StreamEntry: @unchecked Sendable {
        let fd: Int32
        let writeQueue: DispatchQueue
        private let lock = NSLock()
        private var closed = false

        init(fd: Int32, streamID: UInt32) {
            self.fd = fd
            self.writeQueue = DispatchQueue(label: "local.routeweaver.relay-stream-\(streamID)", qos: .userInitiated)
        }

        func markClosedIfNeeded() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if closed { return false }
            closed = true
            return true
        }

        var isClosed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return closed
        }
    }

    init(
        hostID: String,
        cryptoSession: LumzelRelaySession,
        sendFrame: @escaping @Sendable (Data) async throws -> Void,
        onActiveStreamsChanged: @escaping @Sendable (Int) -> Void
    ) {
        self.hostID = hostID
        self.cryptoSession = cryptoSession
        self.sendFrame = sendFrame
        self.onActiveStreamsChanged = onActiveStreamsChanged
    }

    func handleIncomingEncryptedFrame(_ frameData: Data) async throws {
        let opened = try cryptoSession.open(frameData)
        let mux = try RelayMuxFrame.decode(opened.plaintext)
        try await handleMuxFrame(mux)
    }

    func handleMuxFrame(_ mux: RelayMuxFrame) async throws {
        switch mux.command {
        case .openTCP:
            let req = try JSONDecoder().decode(RelayMuxOpenRequest.self, from: mux.payload)
            let streamID = mux.streamID
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.openTCPStream(streamID: streamID, request: req)
            }

        case .data:
            guard let entry = streams[mux.streamID], !mux.payload.isEmpty else { return }
            let payload = mux.payload
            let streamID = mux.streamID
            entry.writeQueue.async { [weak self] in
                guard !entry.isClosed else { return }
                let ok = Self.writeAll(fd: entry.fd, data: payload)
                if !ok {
                    Task { [weak self] in
                        await self?.closeStream(streamID: streamID, sendCloseFrame: true)
                    }
                }
            }

        case .close:
            await closeStream(streamID: mux.streamID, sendCloseFrame: false)

        case .keepalive:
            let reply = RelayMuxFrame(command: .keepalive, streamID: mux.streamID, payload: mux.payload)
            try? await sealAndSend(reply)

        case .openAck, .udpPacket:
            break
        }
    }

    func closeAll() {
        let entries = Array(streams.values)
        streams.removeAll()
        for entry in entries {
            if entry.markClosedIfNeeded() {
                Darwin.shutdown(entry.fd, SHUT_RDWR)
                Darwin.close(entry.fd)
            }
        }
        onActiveStreamsChanged(0)
    }

    private func sealAndSend(_ mux: RelayMuxFrame) async throws {
        let sealed = try cryptoSession.seal(host: hostID, plaintext: mux.encode())
        try await sendFrame(sealed)
    }

    private func openTCPStream(streamID: UInt32, request: RelayMuxOpenRequest) async {
        let result = await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: Self.connectPOSIXTCP(
                    host: request.destinationHost,
                    port: request.destinationPort,
                    targetInterface: request.targetInterface
                ))
            }
        }

        switch result {
        case .success(let fd):
            let entry = StreamEntry(fd: fd, streamID: streamID)
            streams[streamID] = entry
            onActiveStreamsChanged(streams.count)

            let ackPayload = (try? JSONEncoder().encode(RelayMuxOpenAck(ok: true))) ?? Data()
            do {
                try await sealAndSend(RelayMuxFrame(command: .openAck, streamID: streamID, payload: ackPayload))
            } catch {
                await closeStream(streamID: streamID, sendCloseFrame: false)
                return
            }

            startReadPump(streamID: streamID, entry: entry)

        case .failure(let error):
            let ackPayload = (try? JSONEncoder().encode(RelayMuxOpenAck(ok: false, error: error.localizedDescription))) ?? Data()
            try? await sealAndSend(RelayMuxFrame(command: .openAck, streamID: streamID, payload: ackPayload))
        }
    }

    private func startReadPump(streamID: UInt32, entry: StreamEntry) {
        ioQueue.async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 32_768)
            while !entry.isClosed {
                let n = Darwin.recv(entry.fd, &buffer, buffer.count, 0)
                if n > 0 {
                    let chunk = Data(bytes: buffer, count: n)
                    let sem = DispatchSemaphore(value: 0)
                    var sendFailed = false
                    Task { [weak self] in
                        defer { sem.signal() }
                        guard let self else {
                            sendFailed = true
                            return
                        }
                        do {
                            try await self.sealAndSend(RelayMuxFrame(command: .data, streamID: streamID, payload: chunk))
                        } catch {
                            sendFailed = true
                        }
                    }
                    sem.wait()
                    if sendFailed { break }
                } else if n == 0 {
                    break
                } else {
                    if errno == EINTR { continue }
                    break
                }
            }

            Task { [weak self] in
                await self?.closeStream(streamID: streamID, sendCloseFrame: true)
            }
        }
    }

    private func closeStream(streamID: UInt32, sendCloseFrame: Bool) async {
        guard let entry = streams.removeValue(forKey: streamID) else { return }
        let shouldCloseFD = entry.markClosedIfNeeded()
        if shouldCloseFD {
            Darwin.shutdown(entry.fd, SHUT_RDWR)
            Darwin.close(entry.fd)
        }
        onActiveStreamsChanged(streams.count)
        if sendCloseFrame {
            try? await sealAndSend(RelayMuxFrame(command: .close, streamID: streamID))
        }
    }

    private nonisolated static func connectPOSIXTCP(
        host: String,
        port: UInt16,
        targetInterface: String?
    ) -> Result<Int32, NSError> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var res: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        let gaiStatus = getaddrinfo(host, portStr, &hints, &res)
        guard gaiStatus == 0, let firstAddr = res else {
            let msg = gaiStatus != 0 ? String(cString: gai_strerror(gaiStatus)) : "DNS 解析失败"
            return .failure(NSError(domain: "LumzelRelayTCP", code: Int(gaiStatus), userInfo: [NSLocalizedDescriptionKey: msg]))
        }
        defer { freeaddrinfo(firstAddr) }

        var boundIfIndex: UInt32 = 0
        if let iface = targetInterface?.trimmingCharacters(in: .whitespacesAndNewlines), !iface.isEmpty {
            boundIfIndex = if_nametoindex(iface)
            if boundIfIndex == 0 {
                return .failure(NSError(
                    domain: "LumzelRelayTCP",
                    code: Int(ENXIO),
                    userInfo: [NSLocalizedDescriptionKey: "未知网卡接口：\(iface)"]
                ))
            }
        }

        var lastErrno: Int32 = ECONNREFUSED
        var ptr: UnsafeMutablePointer<addrinfo>? = firstAddr
        while let current = ptr {
            let family = current.pointee.ai_family
            let fd = Darwin.socket(family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if fd < 0 {
                lastErrno = errno
                ptr = current.pointee.ai_next
                continue
            }

            var noSigPipe: Int32 = 1
            _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            if boundIfIndex != 0 {
                var ifIdx = boundIfIndex
                let level: Int32
                let optName: Int32
                if family == AF_INET {
                    level = IPPROTO_IP
                    optName = IP_BOUND_IF
                } else if family == AF_INET6 {
                    level = IPPROTO_IPV6
                    optName = IPV6_BOUND_IF
                } else {
                    Darwin.close(fd)
                    ptr = current.pointee.ai_next
                    continue
                }
                if Darwin.setsockopt(fd, level, optName, &ifIdx, socklen_t(MemoryLayout<UInt32>.size)) != 0 {
                    lastErrno = errno
                    Darwin.close(fd)
                    ptr = current.pointee.ai_next
                    continue
                }
            }

            if Darwin.connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen) == 0 {
                return .success(fd)
            }

            lastErrno = errno
            Darwin.close(fd)
            ptr = current.pointee.ai_next
        }

        let errMsg = String(cString: strerror(lastErrno))
        return .failure(NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(lastErrno),
            userInfo: [NSLocalizedDescriptionKey: "TCP 连接失败 (\(host):\(port)): \(errMsg)"]
        ))
    }

    private nonisolated static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var totalSent = 0
            let count = rawBuffer.count
            while totalSent < count {
                let sent = Darwin.send(fd, base.advanced(by: totalSent), count - totalSent, 0)
                if sent > 0 {
                    totalSent += sent
                } else if sent < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

// MARK: - LumzelRelayHostService

@MainActor
final class LumzelRelayHostService: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            userDefaults.set(isEnabled, forKey: keys.enabled)
            if isEnabled {
                restartInboxConnection()
            } else {
                stopInboxConnection()
            }
        }
    }

    @Published var serverURL: String {
        didSet {
            userDefaults.set(serverURL, forKey: keys.serverURL)
            if isEnabled {
                restartInboxConnection()
            }
        }
    }

    @Published var password: String {
        didSet {
            userDefaults.set(password, forKey: keys.password)
            if isEnabled {
                restartInboxConnection()
            }
        }
    }

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var activeControlSessions: Int = 0
    @Published private(set) var activeDataStreams: Int = 0
    @Published private(set) var lastError: String?

    let identity: LumzelRelayIdentity
    var hostID: String { identity.hostID }
    var publicKeyBase64: String { identity.publicKeyBase64 }

    private weak var apiHandler: RemoteAPIHandler?
    private let userDefaults: UserDefaults
    private let keys: DefaultsKeys
    private let urlSession: URLSession

    private var inboxTask: Task<Void, Never>?
    private var activeWebSocket: URLSessionWebSocketTask?
    private var sessionTasks: Set<UUID> = []

    private struct DefaultsKeys {
        let enabled: String
        let serverURL: String
        let password: String
        let identityKey: String

        init(prefix: String) {
            self.enabled = prefix + "enabled"
            self.serverURL = prefix + "serverURL"
            self.password = prefix + "password"
            self.identityKey = prefix + "identityPrivateKey"
        }
    }

    init(
        userDefaults: UserDefaults = .standard,
        defaultsKeyPrefix: String = "RouteWeaver.lumzelRelay."
    ) {
        self.userDefaults = userDefaults
        let keys = DefaultsKeys(prefix: defaultsKeyPrefix)
        self.keys = keys

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: config)

        if let raw = userDefaults.data(forKey: keys.identityKey),
           let loaded = try? LumzelRelayIdentity(privateKeyRaw: raw) {
            self.identity = loaded
        } else {
            let generated = (try? LumzelRelayIdentity.generate()) ?? {
                let fallback = Curve25519.KeyAgreement.PrivateKey()
                return try! LumzelRelayIdentity(privateKeyRaw: fallback.rawRepresentation)
            }()
            userDefaults.set(generated.privateKeyRaw, forKey: keys.identityKey)
            self.identity = generated
        }

        self.serverURL = userDefaults.string(forKey: keys.serverURL) ?? ""
        self.password = userDefaults.string(forKey: keys.password) ?? ""
        self.isEnabled = userDefaults.bool(forKey: keys.enabled)

        if isEnabled {
            restartInboxConnection()
        }
    }

    deinit {
        inboxTask?.cancel()
        activeWebSocket?.cancel(with: .goingAway, reason: nil)
    }

    func attach(apiHandler: RemoteAPIHandler) {
        self.apiHandler = apiHandler
    }

    func makePairingBundle(server: RemoteServerService, lanIPs: [String], mixedPort: Int) -> RelayPairingBundle {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayActive = isEnabled && !trimmedURL.isEmpty

        return RelayPairingBundle(
            hostDeviceId: server.deviceId,
            hostName: server.hostDisplayName,
            lanIPs: lanIPs,
            remotePort: server.listeningPort ?? server.port,
            mixedPort: mixedPort,
            pairingCode: server.activePairingCode,
            relayServerURL: relayActive ? trimmedURL : nil,
            relayPassword: (relayActive && !trimmedPass.isEmpty) ? trimmedPass : nil,
            relayHostID: relayActive ? identity.hostID : nil,
            relayHostPublicKeyBase64: relayActive ? identity.publicKeyBase64 : nil
        )
    }

    // MARK: - /host Inbox Connection & Reconnect Loop

    private func restartInboxConnection() {
        stopInboxConnection()
        guard isEnabled else { return }

        let endpoint = RelayEndpointConfig(serverURL: serverURL, password: password)
        guard let inboxURL = endpoint.hostInboxURL else {
            lastError = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "请填写 Relay 服务器地址（如 wss://relay.example.com）。"
                : "Relay 服务器地址格式无效。"
            return
        }

        lastError = nil
        inboxTask = Task { [weak self] in
            await self?.runInboxLoop(url: inboxURL, password: endpoint.password)
        }
    }

    private func stopInboxConnection() {
        inboxTask?.cancel()
        inboxTask = nil
        activeWebSocket?.cancel(with: .normalClosure, reason: nil)
        activeWebSocket = nil
        isConnected = false
    }

    private func runInboxLoop(url: URL, password: String) async {
        var backoffSeconds: UInt64 = 1

        while !Task.isCancelled && isEnabled {
            let wsTask = makeWebSocketTask(url: url, password: password)
            activeWebSocket = wsTask
            wsTask.resume()

            var pingTask: Task<Void, Never>?
            do {
                // 1. Receive challenge
                let challengeData = try await receiveMessageData(from: wsTask)
                let challenge = try JSONDecoder().decode(LumzelHostChallenge.self, from: challengeData)

                // 2. Reply with register proof
                let registerMsg = try identity.makeRegisterMessage(for: challenge)
                let registerData = try JSONEncoder().encode(registerMsg)
                if let registerText = String(data: registerData, encoding: .utf8) {
                    try await wsTask.send(.string(registerText))
                } else {
                    try await wsTask.send(.data(registerData))
                }

                // 3. Wait for registered ack
                let ackData = try await receiveMessageData(from: wsTask)
                let ack = try JSONDecoder().decode(RelayServerAck.self, from: ackData)
                if ack.t != "registered" {
                    let msg = ack.error ?? "Relay 注册失败：\(ack.t)"
                    throw NSError(domain: "LumzelRelayHost", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
                }

                isConnected = true
                lastError = nil
                backoffSeconds = 1

                pingTask = Task { [weak wsTask] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 25_000_000_000)
                        guard let wsTask, !Task.isCancelled else { break }
                        let ok = await withCheckedContinuation { cont in
                            wsTask.sendPing { err in
                                cont.resume(returning: err == nil)
                            }
                        }
                        if !ok { break }
                    }
                }

                // 4. Listen for waiting notifications
                while !Task.isCancelled && isEnabled {
                    let msgData = try await receiveMessageData(from: wsTask)
                    if let waiting = try? JSONDecoder().decode(LumzelHostWaitingNotification.self, from: msgData),
                       waiting.t == "waiting",
                       let plane = waiting.relayPlane {
                        handleWaitingNotification(waiting, plane: plane)
                    }
                }
            } catch is CancellationError {
                pingTask?.cancel()
                wsTask.cancel(with: .normalClosure, reason: nil)
                break
            } catch {
                pingTask?.cancel()
                wsTask.cancel(with: .goingAway, reason: nil)
                isConnected = false
                if !Task.isCancelled && isEnabled {
                    lastError = "Relay 连接断开：\(error.localizedDescription)"
                }
            }

            isConnected = false
            if Task.isCancelled || !isEnabled { break }

            try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
            backoffSeconds = min(backoffSeconds * 2, 30)
        }
    }

    // MARK: - /control & /data Session Handling

    private func handleWaitingNotification(_ notification: LumzelHostWaitingNotification, plane: LumzelRelayPlane) {
        let endpoint = RelayEndpointConfig(serverURL: serverURL, password: password)
        guard let planeURL = endpoint.websocketURL(for: plane) else { return }

        Task { [weak self] in
            guard let self else { return }
            await self.runPlaneSession(
                url: planeURL,
                password: endpoint.password,
                plane: plane,
                sid: notification.sid,
                ticket: notification.ticket
            )
        }
    }

    private func runPlaneSession(
        url: URL,
        password: String,
        plane: LumzelRelayPlane,
        sid: String,
        ticket: String
    ) async {
        let wsTask = makeWebSocketTask(url: url, password: password)
        wsTask.resume()
        defer { wsTask.cancel(with: .normalClosure, reason: nil) }

        do {
            // 1. Send link_hello
            let hello = LumzelLinkHello(host: identity.hostID, sid: sid, ticket: ticket)
            let helloData = try JSONEncoder().encode(hello)
            if let helloText = String(data: helloData, encoding: .utf8) {
                try await wsTask.send(.string(helloText))
            } else {
                try await wsTask.send(.data(helloData))
            }

            // 2. Receive n=0 binary handshake frame from client (skip forwarded `link_hello` text on /control)
            let handshakeFrameData = try await receiveBinaryFrameData(from: wsTask)
            let (header, payload) = try LumzelFrameCodec.decodeHandshakeFrame(handshakeFrameData)
            guard header.sid == sid else {
                throw LumzelRelayError.sessionIDMismatch
            }

            let clientHello = try JSONDecoder().decode(RelayClientHandshake.self, from: payload)

            // 3. Validate token according to mode ("pair" vs "auth")
            let authorized: Bool
            if let apiHandler {
                if clientHello.mode == "pair" {
                    authorized = apiHandler.isPairingCodeValid(clientHello.token)
                } else {
                    authorized = apiHandler.isTokenAuthorized(clientHello.token)
                }
            } else {
                authorized = false
            }

            guard authorized else {
                let errJSON = try JSONEncoder().encode(RelayHostHandshakeResponse(ok: false, error: "配对码或认证令牌无效"))
                let errFrame = try LumzelFrameCodec.encodeHandshakeFrame(host: identity.hostID, sid: sid, payload: errJSON)
                try? await wsTask.send(.data(errFrame))
                return
            }

            guard let clientPubRaw = Data(base64Encoded: clientHello.clientPub), clientPubRaw.count == 32 else {
                let errJSON = try JSONEncoder().encode(RelayHostHandshakeResponse(ok: false, error: "客户端公钥无效"))
                let errFrame = try LumzelFrameCodec.encodeHandshakeFrame(host: identity.hostID, sid: sid, payload: errJSON)
                try? await wsTask.send(.data(errFrame))
                return
            }

            // 4. Generate ephemeral X25519 keypair & derive directional session keys
            let ephemeralPriv = Curve25519.KeyAgreement.PrivateKey()
            let keys = try LumzelRelayCrypto.deriveDirectionalSessionKeys(
                localPrivateKeyRaw: ephemeralPriv.rawRepresentation,
                remotePublicKeyRaw: clientPubRaw,
                pairingToken: clientHello.token,
                sid: sid
            )

            // Host is responder: sends with responderToInitiator, receives with initiatorToResponder
            let session = try LumzelRelaySession(
                sendKey: keys.responderToInitiator,
                recvKey: keys.initiatorToResponder,
                sid: sid
            )

            let okJSON = try JSONEncoder().encode(
                RelayHostHandshakeResponse(
                    ok: true,
                    hostEphemeralPub: ephemeralPriv.publicKey.rawRepresentation.base64EncodedString()
                )
            )
            let okFrame = try LumzelFrameCodec.encodeHandshakeFrame(host: identity.hostID, sid: sid, payload: okJSON)
            try await wsTask.send(.data(okFrame))

            // 5. Run plane loop
            switch plane {
            case .control:
                try await runControlPlaneLoop(wsTask: wsTask, session: session)
            case .data:
                try await runDataPlaneLoop(wsTask: wsTask, session: session)
            }
        } catch {
            // Session closed or failed; keep /host inbox alive.
        }
    }

    private func runControlPlaneLoop(wsTask: URLSessionWebSocketTask, session: LumzelRelaySession) async throws {
        activeControlSessions += 1
        defer { activeControlSessions = max(0, activeControlSessions - 1) }

        var mutableSession = session
        while !Task.isCancelled && isEnabled {
            let frameData = try await receiveBinaryFrameData(from: wsTask)
            let opened = try mutableSession.open(frameData)
            let responsePlaintext = await Self.handleControlRequestPlaintext(
                opened.plaintext,
                apiHandler: apiHandler
            )
            let sealed = try mutableSession.seal(host: identity.hostID, plaintext: responsePlaintext)
            try await wsTask.send(.data(sealed))
        }
    }

    private func runDataPlaneLoop(wsTask: URLSessionWebSocketTask, session: LumzelRelaySession) async throws {
        var streamCountPerSession = 0
        let updateCount: @Sendable (Int) -> Void = { [weak self] newCount in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let delta = newCount - streamCountPerSession
                streamCountPerSession = newCount
                self.activeDataStreams = max(0, self.activeDataStreams + delta)
            }
        }

        let coordinator = RelayDataPlaneSession(
            hostID: identity.hostID,
            cryptoSession: session,
            sendFrame: { data in
                try await wsTask.send(.data(data))
            },
            onActiveStreamsChanged: updateCount
        )

        defer {
            Task {
                await coordinator.closeAll()
            }
        }

        while !Task.isCancelled && isEnabled {
            let frameData = try await receiveBinaryFrameData(from: wsTask)
            try await coordinator.handleIncomingEncryptedFrame(frameData)
        }
    }

    // MARK: - Testable Control Plane Helper

    static func handleControlRequestPlaintext(
        _ plaintext: Data,
        apiHandler: RemoteAPIHandler?
    ) async -> Data {
        guard let req = try? JSONDecoder().decode(RelayControlHTTPRequest.self, from: plaintext) else {
            let errBody = (try? JSONEncoder().encode(RemoteActionResult(ok: false, message: "无效的控制请求格式。"))) ?? Data()
            let resp = RelayControlHTTPResponse(requestID: "", statusCode: 400, body: errBody)
            return (try? JSONEncoder().encode(resp)) ?? Data()
        }

        guard let apiHandler else {
            let errBody = (try? JSONEncoder().encode(RemoteActionResult(ok: false, message: "被控端服务尚未就绪。"))) ?? Data()
            let resp = RelayControlHTTPResponse(requestID: req.requestID, statusCode: 500, body: errBody)
            return (try? JSONEncoder().encode(resp)) ?? Data()
        }

        var headers: [String: String] = [:]
        if let bearer = req.bearerToken, !bearer.isEmpty {
            headers["authorization"] = "Bearer \(bearer)"
        }
        let body = req.bodyBase64.flatMap { Data(base64Encoded: $0) } ?? Data()
        let remoteReq = RemoteHTTPRequest(method: req.method, path: req.path, headers: headers, body: body)
        let payload = await apiHandler.handle(remoteReq)

        let resp = RelayControlHTTPResponse(
            requestID: req.requestID,
            statusCode: payload.status,
            contentType: payload.contentType,
            body: payload.body
        )
        return (try? JSONEncoder().encode(resp)) ?? Data()
    }

    // MARK: - WebSocket Helpers

    private nonisolated func makeWebSocketTask(url: URL, password: String) -> URLSessionWebSocketTask {
        var request = URLRequest(url: url)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPassword.isEmpty {
            request.setValue(trimmedPassword, forHTTPHeaderField: LumzelRelayConstants.passwordHeader)
        }
        return urlSession.webSocketTask(with: request)
    }

    private nonisolated func receiveBinaryFrameData(from task: URLSessionWebSocketTask) async throws -> Data {
        while true {
            let message = try await task.receive()
            switch message {
            case .data(let data):
                return data
            case .string:
                // `lumzel/relay` forwards sanitized `link_hello` / punch JSON text frames on `/control`; skip them here.
                continue
            @unknown default:
                throw LumzelRelayError.truncated
            }
        }
    }

    private nonisolated func receiveMessageData(from task: URLSessionWebSocketTask) async throws -> Data {
        let message = try await task.receive()
        switch message {
        case .data(let data):
            return data
        case .string(let text):
            return Data(text.utf8)
        @unknown default:
            throw LumzelRelayError.truncated
        }
    }
}
