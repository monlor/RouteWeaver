import Foundation
import Network
import RoutingCore

public final class LocalRelayBridgeServer: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local.routeweaver.relay-bridge", qos: .userInitiated)
    private var listener: NWListener?
    private var multiplexer: LumzelRelayDataMultiplexer?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    public init() {}

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil
    }

    public var isRelayConnected: Bool {
        get async {
            let mux: LumzelRelayDataMultiplexer? = {
                lock.lock()
                defer { lock.unlock() }
                return multiplexer
            }()
            guard let mux else { return false }
            return await mux.isConnected()
        }
    }

    public func start(
        port: UInt16 = UInt16(MobileProfileAdapter.defaultRelayBridgePort),
        relayConfig: RelayEndpointConfig,
        pairingToken: String,
        socks5ChainPort: Int? = nil
    ) throws {
        stop()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw LumzelRelayClientError.socks5Failed("无效的本地桥接端口：\(port)")
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: nwPort)

        let newListener = try NWListener(using: params, on: nwPort)
        let newMultiplexer = LumzelRelayDataMultiplexer(
            relayConfig: relayConfig,
            pairingToken: pairingToken,
            socks5ProxyPort: socks5ChainPort
        )

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleAcceptedConnection(connection, multiplexer: newMultiplexer)
        }

        lock.lock()
        self.listener = newListener
        self.multiplexer = newMultiplexer
        lock.unlock()

        newListener.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        let currentListener = listener
        let currentMux = multiplexer
        let conns = Array(activeConnections.values)
        listener = nil
        multiplexer = nil
        activeConnections.removeAll()
        lock.unlock()

        currentListener?.cancel()
        for conn in conns {
            conn.cancel()
        }
        if let currentMux {
            Task {
                await currentMux.disconnect()
            }
        }
    }

    private func handleAcceptedConnection(_ connection: NWConnection, multiplexer: LumzelRelayDataMultiplexer) {
        let connID = ObjectIdentifier(connection)
        lock.lock()
        activeConnections[connID] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removeConnection(connID)
            default:
                break
            }
        }

        connection.start(queue: queue)

        Task { [weak self] in
            await self?.runSOCKS5Session(connection: connection, connID: connID, multiplexer: multiplexer)
        }
    }

    private func removeConnection(_ id: ObjectIdentifier) {
        lock.lock()
        activeConnections.removeValue(forKey: id)
        lock.unlock()
    }

    private func runSOCKS5Session(
        connection: NWConnection,
        connID: ObjectIdentifier,
        multiplexer: LumzelRelayDataMultiplexer
    ) async {
        defer {
            connection.cancel()
            removeConnection(connID)
        }

        do {
            // 1. RFC 1928 greeting: [VER, NMETHODS, METHODS...]
            let greeting = try await receiveExact(2, on: connection)
            guard greeting[0] == 0x05 else { return }
            let nMethods = Int(greeting[1])
            guard nMethods > 0 else { return }
            let methods = try await receiveExact(nMethods, on: connection)

            var targetInterface: String? = nil
            if methods.contains(0x02) {
                // RFC 1929 Username/Password auth -> username carries PC targetInterface (e.g. "en5").
                try await sendRaw(Data([0x05, 0x02]), on: connection)
                let authHead = try await receiveExact(2, on: connection)
                guard authHead[0] == 0x01 else {
                    try? await sendRaw(Data([0x01, 0x01]), on: connection)
                    return
                }
                let uLen = Int(authHead[1])
                let uBytes = uLen > 0 ? try await receiveExact(uLen, on: connection) : Data()
                let pLenByte = try await receiveExact(1, on: connection)
                let pLen = Int(pLenByte[0])
                if pLen > 0 {
                    _ = try await receiveExact(pLen, on: connection)
                }
                let rawUser = String(decoding: uBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                targetInterface = rawUser.isEmpty ? nil : rawUser
                try await sendRaw(Data([0x01, 0x00]), on: connection)
            } else if methods.contains(0x00) {
                try await sendRaw(Data([0x05, 0x00]), on: connection)
            } else {
                try? await sendRaw(Data([0x05, 0xFF]), on: connection)
                return
            }

            // 2. RFC 1928 request: [VER, CMD, RSV, ATYP, DST.ADDR, DST.PORT]
            let reqHead = try await receiveExact(4, on: connection)
            guard reqHead[0] == 0x05 else { return }
            let cmd = reqHead[1]
            let atyp = reqHead[3]

            guard cmd == 0x01 else {
                // Command not supported
                try? await sendRaw(Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), on: connection)
                return
            }

            let destHost: String
            switch atyp {
            case 0x01: // IPv4
                let addr = try await receiveExact(4, on: connection)
                destHost = addr.map { String($0) }.joined(separator: ".")
            case 0x03: // Domain
                let lenByte = try await receiveExact(1, on: connection)
                let domainData = try await receiveExact(Int(lenByte[0]), on: connection)
                destHost = String(decoding: domainData, as: UTF8.self)
            case 0x04: // IPv6
                let addr = try await receiveExact(16, on: connection)
                var parts: [String] = []
                for i in stride(from: 0, to: 16, by: 2) {
                    let word = (UInt16(addr[i]) << 8) | UInt16(addr[i + 1])
                    parts.append(String(word, radix: 16))
                }
                destHost = parts.joined(separator: ":")
            default:
                try? await sendRaw(Data([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), on: connection)
                return
            }

            let portBytes = try await receiveExact(2, on: connection)
            let destPort = (UInt16(portBytes[0]) << 8) | UInt16(portBytes[1])

            // 3. Open multiplexed stream over lumzel/relay /data plane.
            let stream: RelayMuxStreamHandle
            do {
                stream = try await multiplexer.openStream(
                    targetInterface: targetInterface,
                    destinationHost: destHost,
                    destinationPort: destPort
                )
            } catch {
                try? await sendRaw(Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), on: connection)
                return
            }

            // 4. Send SOCKS5 success reply and pump bidirectionally.
            try await sendRaw(Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), on: connection)

            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    while !Task.isCancelled {
                        do {
                            guard let chunk = try await self.receiveChunk(on: connection) else {
                                break
                            }
                            try await stream.send(chunk)
                        } catch {
                            break
                        }
                    }
                    await stream.close()
                }

                group.addTask { [weak self] in
                    guard let self else { return }
                    while !Task.isCancelled {
                        guard let chunk = await stream.receive() else {
                            break
                        }
                        do {
                            try await self.sendRaw(chunk, on: connection)
                        } catch {
                            break
                        }
                    }
                    connection.cancel()
                }

                await group.next()
                group.cancelAll()
            }
            await stream.close()
        } catch {
            // Connection closed or malformed SOCKS5 handshake.
        }
    }

    private func sendRaw(_ data: Data, on connection: NWConnection) async throws {
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

    private func receiveChunk(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, isComplete, err in
                if let err {
                    cont.resume(throwing: err)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func receiveExact(_ count: Int, on connection: NWConnection) async throws -> Data {
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
