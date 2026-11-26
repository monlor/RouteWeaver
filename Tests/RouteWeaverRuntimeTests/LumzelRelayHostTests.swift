import CryptoKit
import Darwin
import Foundation
import RoutingCore
import XCTest

@testable import RouteWeaverRuntime

final class LumzelRelayHostTests: XCTestCase {
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "LumzelRelayHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    func testPairingBundleShareStringRoundtripAndJSONFallback() throws {
        let bundle = RelayPairingBundle(
            hostDeviceId: "host-123",
            hostName: "MacStudio",
            lanIPs: ["192.168.1.10", "10.0.0.5"],
            remotePort: 19098,
            mixedPort: 7890,
            pairingCode: "654321",
            relayServerURL: "wss://relay.example.com",
            relayPassword: "secret-password",
            relayHostID: "abcdefghijklmnopqrstuvwx234567ab",
            relayHostPublicKeyBase64: Data(repeating: 0xAB, count: 32).base64EncodedString()
        )

        let shareString = try bundle.encodeShareString()
        XCTAssertTrue(shareString.hasPrefix(RelayPairingBundle.uriPrefix))

        let decoded = try RelayPairingBundle.decodeShareString(shareString)
        XCTAssertEqual(decoded, bundle)

        // JSON fallback should also decode cleanly
        let jsonData = try JSONEncoder().encode(bundle)
        let jsonString = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
        let decodedJSON = try RelayPairingBundle.decodeShareString(jsonString)
        XCTAssertEqual(decodedJSON, bundle)
    }

    @MainActor
    func testRemoteAPIHandlerPairingCodeAndTokenAuthorizationHelpers() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var now = Date(timeIntervalSince1970: 1_000_000)
        let handler = RemoteAPIHandler(
            deviceId: "mac-host-1",
            hostNameProvider: { "TestMac" },
            userDefaults: defaults,
            pairedClientsDefaultsKey: "clients",
            nowProvider: { now }
        )

        let code = handler.activePairingCode
        XCTAssertTrue(handler.isPairingCodeValid(code))
        XCTAssertTrue(handler.isPairingCodeValid("  \(code) \n"))
        XCTAssertFalse(handler.isPairingCodeValid("000000"))
        XCTAssertFalse(handler.isTokenAuthorized("non-existent-token"))

        // Pair a client over /api/v1/pair
        let pairReqBody = try JSONEncoder().encode(
            RemotePairingRequest(deviceId: "ios-1", deviceName: "iPhone", pairingCode: code)
        )
        let pairRespPayload = await handler.handle(
            RemoteHTTPRequest(method: "POST", path: "/api/v1/pair", body: pairReqBody)
        )
        XCTAssertEqual(pairRespPayload.status, 200)
        let pairResp = try JSONDecoder().decode(RemotePairingResponse.self, from: pairRespPayload.body)

        // Token should now be authorized, and old pairing code should have been rotated
        XCTAssertTrue(handler.isTokenAuthorized(pairResp.token))
        XCTAssertFalse(handler.isPairingCodeValid(code))

        // Revoking client invalidates token
        handler.revokeClient("ios-1")
        XCTAssertFalse(handler.isTokenAuthorized(pairResp.token))

        // Advancing time past expiry (300s) invalidates the active pairing code
        let currentCode = handler.activePairingCode
        XCTAssertTrue(handler.isPairingCodeValid(currentCode))
        now = now.addingTimeInterval(301)
        XCTAssertFalse(handler.isPairingCodeValid(currentCode))
    }

    @MainActor
    func testMakePairingBundleIncludesRelayFieldsOnlyWhenEnabled() throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = RemoteServerService()
        let relayHost = LumzelRelayHostService(userDefaults: defaults, defaultsKeyPrefix: "test.relay.")
        relayHost.serverURL = "wss://relay.example.com"
        relayHost.password = "pw123"
        relayHost.isEnabled = false

        let disabledBundle = relayHost.makePairingBundle(server: server, lanIPs: ["192.168.1.2"], mixedPort: 7890)
        XCTAssertNil(disabledBundle.relayServerURL)
        XCTAssertNil(disabledBundle.relayPassword)
        XCTAssertNil(disabledBundle.relayHostID)
        XCTAssertNil(disabledBundle.relayHostPublicKeyBase64)

        relayHost.isEnabled = true
        let enabledBundle = relayHost.makePairingBundle(server: server, lanIPs: ["192.168.1.2"], mixedPort: 7890)
        XCTAssertEqual(enabledBundle.relayServerURL, "wss://relay.example.com")
        XCTAssertEqual(enabledBundle.relayPassword, "pw123")
        XCTAssertEqual(enabledBundle.relayHostID, relayHost.hostID)
        XCTAssertEqual(enabledBundle.relayHostPublicKeyBase64, relayHost.publicKeyBase64)
        XCTAssertEqual(enabledBundle.mixedPort, 7890)
    }

    @MainActor
    func testControlPlaneEncryptedRequestResponseRoundtrip() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let handler = RemoteAPIHandler(
            deviceId: "mac-host-ctrl",
            hostNameProvider: { "MacHost" },
            userDefaults: defaults,
            pairedClientsDefaultsKey: "clients"
        )
        let hostID = "test-host-id-123456"
        let sid = "ctrl-session-1"
        let pairingCode = handler.activePairingCode

        let clientPriv = Curve25519.KeyAgreement.PrivateKey()
        let hostPriv = Curve25519.KeyAgreement.PrivateKey()

        let clientKeys = try LumzelRelayCrypto.deriveDirectionalSessionKeys(
            localPrivateKeyRaw: clientPriv.rawRepresentation,
            remotePublicKeyRaw: hostPriv.publicKey.rawRepresentation,
            pairingToken: pairingCode,
            sid: sid
        )
        let hostKeys = try LumzelRelayCrypto.deriveDirectionalSessionKeys(
            localPrivateKeyRaw: hostPriv.rawRepresentation,
            remotePublicKeyRaw: clientPriv.publicKey.rawRepresentation,
            pairingToken: pairingCode,
            sid: sid
        )

        var clientSession = try LumzelRelaySession(
            sendKey: clientKeys.initiatorToResponder,
            recvKey: clientKeys.responderToInitiator,
            sid: sid
        )
        var hostSession = try LumzelRelaySession(
            sendKey: hostKeys.responderToInitiator,
            recvKey: hostKeys.initiatorToResponder,
            sid: sid
        )

        let controlReq = RelayControlHTTPRequest(
            requestID: "req-info-1",
            method: "GET",
            path: "/api/v1/info"
        )
        let sealedReq = try clientSession.seal(host: hostID, plaintext: JSONEncoder().encode(controlReq))

        // Host opens encrypted frame, dispatches in-memory to RemoteAPIHandler, and seals response
        let openedReq = try hostSession.open(sealedReq)
        let respPlaintext = await LumzelRelayHostService.handleControlRequestPlaintext(
            openedReq.plaintext,
            apiHandler: handler
        )
        let sealedResp = try hostSession.seal(host: hostID, plaintext: respPlaintext)

        // Client opens encrypted response and verifies contents
        let openedResp = try clientSession.open(sealedResp)
        let controlResp = try JSONDecoder().decode(RelayControlHTTPResponse.self, from: openedResp.plaintext)
        XCTAssertEqual(controlResp.requestID, "req-info-1")
        XCTAssertEqual(controlResp.statusCode, 200)
        let bodyData = try XCTUnwrap(controlResp.bodyData)
        let info = try JSONDecoder().decode([String: String].self, from: bodyData)
        XCTAssertEqual(info["hostDeviceId"], "mac-host-ctrl")
        XCTAssertEqual(info["hostName"], "MacHost")
    }

    func testDataPlaneKeepaliveAndTCPEgressRoundtrip() async throws {
        let hostID = "data-host-1"
        let sid = "data-session-1"
        let token = "123456"

        let clientPriv = Curve25519.KeyAgreement.PrivateKey()
        let hostPriv = Curve25519.KeyAgreement.PrivateKey()

        let clientKeys = try LumzelRelayCrypto.deriveDirectionalSessionKeys(
            localPrivateKeyRaw: clientPriv.rawRepresentation,
            remotePublicKeyRaw: hostPriv.publicKey.rawRepresentation,
            pairingToken: token,
            sid: sid
        )
        let hostKeys = try LumzelRelayCrypto.deriveDirectionalSessionKeys(
            localPrivateKeyRaw: hostPriv.rawRepresentation,
            remotePublicKeyRaw: clientPriv.publicKey.rawRepresentation,
            pairingToken: token,
            sid: sid
        )

        var clientSession = try LumzelRelaySession(
            sendKey: clientKeys.initiatorToResponder,
            recvKey: clientKeys.responderToInitiator,
            sid: sid
        )
        let hostSession = try LumzelRelaySession(
            sendKey: hostKeys.responderToInitiator,
            recvKey: hostKeys.initiatorToResponder,
            sid: sid
        )

        let collector = OutboundFrameCollector()
        let dataSession = RelayDataPlaneSession(
            hostID: hostID,
            cryptoSession: hostSession,
            sendFrame: { data in
                await collector.append(data)
            },
            onActiveStreamsChanged: { _ in }
        )

        // 1. Test .keepalive echo
        let keepaliveMux = RelayMuxFrame(command: .keepalive, streamID: 0, payload: Data("ping".utf8))
        let sealedPing = try clientSession.seal(host: hostID, plaintext: keepaliveMux.encode())
        try await dataSession.handleIncomingEncryptedFrame(sealedPing)

        let pingReplyData = try await collector.popFirst(timeoutSeconds: 2)
        let openedPingReply = try clientSession.open(pingReplyData)
        let decodedPingReply = try RelayMuxFrame.decode(openedPingReply.plaintext)
        XCTAssertEqual(decodedPingReply.command, .keepalive)
        XCTAssertEqual(decodedPingReply.payload, Data("ping".utf8))

        // 2. Test .openTCP against a local loopback POSIX echo server
        let (listenFD, port) = try Self.makeLoopbackListener()
        defer { Darwin.close(listenFD) }

        let acceptExpectation = expectation(description: "Loopback server echoed")
        DispatchQueue.global(qos: .userInitiated).async {
            var addr = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFD, $0, &len)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }
            var buf = [UInt8](repeating: 0, count: 1024)
            let n = Darwin.recv(clientFD, &buf, buf.count, 0)
            if n > 0 {
                _ = Darwin.send(clientFD, buf, n, 0)
            }
            acceptExpectation.fulfill()
        }

        let openReq = RelayMuxOpenRequest(targetInterface: nil, destinationHost: "127.0.0.1", destinationPort: port)
        let openMux = RelayMuxFrame(command: .openTCP, streamID: 7, payload: try JSONEncoder().encode(openReq))
        try await dataSession.handleIncomingEncryptedFrame(clientSession.seal(host: hostID, plaintext: openMux.encode()))

        let ackData = try await collector.popFirst(timeoutSeconds: 3)
        let ackMux = try RelayMuxFrame.decode(clientSession.open(ackData).plaintext)
        XCTAssertEqual(ackMux.command, .openAck)
        XCTAssertEqual(ackMux.streamID, 7)
        let ack = try JSONDecoder().decode(RelayMuxOpenAck.self, from: ackMux.payload)
        XCTAssertTrue(ack.ok, "Expected openAck ok, got error: \(ack.error ?? "nil")")

        // Send data on stream 7 and expect echoed data back
        let dataMux = RelayMuxFrame(command: .data, streamID: 7, payload: Data("hello-relay".utf8))
        try await dataSession.handleIncomingEncryptedFrame(clientSession.seal(host: hostID, plaintext: dataMux.encode()))

        await fulfillment(of: [acceptExpectation], timeout: 3)

        let echoData = try await collector.popFirst(timeoutSeconds: 3)
        let echoMux = try RelayMuxFrame.decode(clientSession.open(echoData).plaintext)
        XCTAssertEqual(echoMux.command, .data)
        XCTAssertEqual(echoMux.streamID, 7)
        XCTAssertEqual(echoMux.payload, Data("hello-relay".utf8))

        // Close stream
        let closeMux = RelayMuxFrame(command: .close, streamID: 7)
        try await dataSession.handleIncomingEncryptedFrame(clientSession.seal(host: hostID, plaintext: closeMux.encode()))
        await dataSession.closeAll()
    }

    private static func makeLoopbackListener() throws -> (Int32, UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(fd, 0)

        var yes: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindRes, 0)
        XCTAssertEqual(Darwin.listen(fd, 4), 0)

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRes = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLen)
            }
        }
        XCTAssertEqual(nameRes, 0)
        return (fd, UInt16(bigEndian: boundAddr.sin_port))
    }
}

private actor OutboundFrameCollector {
    private var queue: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []

    func append(_ data: Data) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: data)
        } else {
            queue.append(data)
        }
    }

    func popFirst(timeoutSeconds: TimeInterval) async throws -> Data {
        if !queue.isEmpty {
            return queue.removeFirst()
        }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.enqueueWaiter(continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw NSError(domain: "OutboundFrameCollector", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for outbound frame"])
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func enqueueWaiter(_ continuation: CheckedContinuation<Data, Error>) {
        if !queue.isEmpty {
            continuation.resume(returning: queue.removeFirst())
        } else {
            waiters.append(continuation)
        }
    }
}
