import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Lumzel Relay Wire Protocol (compatible with github.com/lumzel/relay v2)

public enum LumzelRelayPlane: String, Codable, CaseIterable, Sendable {
    case control
    case data

    public var path: String {
        switch self {
        case .control: return "/control"
        case .data: return "/data"
        }
    }
}

public enum LumzelRelayError: Error, LocalizedError, Equatable, Sendable {
    case truncated
    case badMagic
    case badVersion(UInt8)
    case badHostLength
    case badSessionIDLength
    case invalidUTF8
    case truncatedCiphertext
    case replayOrOutOfOrder(received: UInt64, expectedGreaterThan: UInt64)
    case sessionIDMismatch
    case sequenceExhausted
    case unexpectedHandshakeFrame
    case expectedHandshakeFrame
    case badKeyLength
    case lowOrderPublicKey
    case aeadFailure
    case invalidMuxFrame
    case cryptoUnavailable

    public var errorDescription: String? {
        switch self {
        case .truncated: return "Relay 帧数据不完整"
        case .badMagic: return "Relay 帧魔数无效"
        case .badVersion(let v): return "不支持的 Relay 帧版本：\(v)"
        case .badHostLength: return "Relay host_id 长度无效"
        case .badSessionIDLength: return "Relay sid 长度无效"
        case .invalidUTF8: return "Relay 帧头 UTF-8 解码失败"
        case .truncatedCiphertext: return "Relay 密文长度不足"
        case .replayOrOutOfOrder(let got, let prev): return "检测到重放或乱序帧（n=\(got), last=\(prev)）"
        case .sessionIDMismatch: return "Relay 会话 ID 不匹配"
        case .sequenceExhausted: return "Relay 帧序号耗尽"
        case .unexpectedHandshakeFrame: return "收到未预期的握手帧"
        case .expectedHandshakeFrame: return "期望收到握手帧"
        case .badKeyLength: return "X25519 密钥长度必须为 32 字节"
        case .lowOrderPublicKey: return "拒绝低阶 X25519 公钥"
        case .aeadFailure: return "ChaCha20-Poly1305 认证加密失败"
        case .invalidMuxFrame: return "Relay 多路复用数据帧格式无效"
        case .cryptoUnavailable: return "当前平台不支持 CryptoKit"
        }
    }
}

public enum LumzelRelayConstants {
    public static let frameMagic = Data("LUMZEL".utf8)
    public static let frameVersion: UInt8 = 2
    public static let helloVersion: Int = 2
    public static let minIDLength = 1
    public static let maxIDLength = 256
    public static let aeadTagLength = 16
    public static let hostIDDigestBytes = 20
    public static let proofInfo = Data("lumzel-host-proof/1".utf8)
    public static let sessionKeyInfo = Data("routeweaver-lumzel-session/1".utf8)
    public static let passwordHeader = "X-Relay-Password"
    /// Default rotation threshold (450 MiB) to stay safely under default 512 MiB route cap on public relays.
    public static let defaultSessionRotateBytes: UInt64 = 450 * 1024 * 1024
}

// MARK: - Wire Header

public struct LumzelFrameHeader: Equatable, Sendable {
    public let version: UInt8
    public let host: String
    public let sid: String
    public let sequence: UInt64

    public var isHandshake: Bool { sequence == 0 }

    public init(version: UInt8 = LumzelRelayConstants.frameVersion, host: String, sid: String, sequence: UInt64) {
        self.version = version
        self.host = host
        self.sid = sid
        self.sequence = sequence
    }
}

public struct LumzelOpenedFrame: Equatable, Sendable {
    public let header: LumzelFrameHeader
    public let plaintext: Data
}

// MARK: - /host & /control /data JSON Messages

public struct LumzelHostChallenge: Codable, Equatable, Sendable {
    public let t: String
    public let key: String
    public let nonce: String

    public init(t: String = "challenge", key: String, nonce: String) {
        self.t = t
        self.key = key
        self.nonce = nonce
    }
}

public struct LumzelHostRegister: Codable, Equatable, Sendable {
    public let t: String
    public let hostPub: String
    public let proof: String
    public let host: String

    private enum CodingKeys: String, CodingKey {
        case t
        case hostPub = "host_pub"
        case proof
        case host
    }

    public init(hostPubBase64: String, proofBase64: String, hostID: String) {
        self.t = "register"
        self.hostPub = hostPubBase64
        self.proof = proofBase64
        self.host = hostID
    }
}

public struct LumzelHostWaitingNotification: Codable, Equatable, Sendable {
    public let t: String
    public let sid: String
    public let plane: String
    public let ticket: String

    public var relayPlane: LumzelRelayPlane? {
        LumzelRelayPlane(rawValue: plane)
    }

    public init(t: String = "waiting", sid: String, plane: String, ticket: String) {
        self.t = t
        self.sid = sid
        self.plane = plane
        self.ticket = ticket
    }
}

public struct LumzelLinkHello: Codable, Equatable, Sendable {
    public let type: String
    public let v: Int
    public let host: String
    public let sid: String
    public let ticket: String?

    public init(host: String, sid: String, ticket: String? = nil) {
        self.type = "link_hello"
        self.v = LumzelRelayConstants.helloVersion
        self.host = host
        self.sid = sid
        self.ticket = ticket
    }
}

// MARK: - X25519 Identity, Host ID & Challenge-Response Proof

public struct LumzelRelayIdentity: Sendable {
    public let privateKeyRaw: Data
    public let publicKeyRaw: Data
    public let hostID: String

    public init(privateKeyRaw: Data) throws {
        #if canImport(CryptoKit)
        guard privateKeyRaw.count == 32 else { throw LumzelRelayError.badKeyLength }
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRaw)
        let pub = priv.publicKey.rawRepresentation
        self.privateKeyRaw = priv.rawRepresentation
        self.publicKeyRaw = pub
        self.hostID = LumzelRelayCrypto.hostID(forPublicKey: pub)
        #else
        throw LumzelRelayError.cryptoUnavailable
        #endif
    }

    public static func generate() throws -> LumzelRelayIdentity {
        #if canImport(CryptoKit)
        let priv = Curve25519.KeyAgreement.PrivateKey()
        return try LumzelRelayIdentity(privateKeyRaw: priv.rawRepresentation)
        #else
        throw LumzelRelayError.cryptoUnavailable
        #endif
    }

    public var publicKeyBase64: String {
        publicKeyRaw.base64EncodedString()
    }

    /// Computes the 32-byte HKDF-SHA256 proof matching `lumzel_frame::proof::respond`.
    public func respondToChallenge(keyBase64: String, nonceBase64: String) throws -> Data {
        guard let keyBytes = Data(base64Encoded: keyBase64),
              let nonceBytes = Data(base64Encoded: nonceBase64),
              keyBytes.count == 32,
              nonceBytes.count == 32 else {
            throw LumzelRelayError.badKeyLength
        }
        return try LumzelRelayCrypto.computeHostProof(
            hostPrivateKeyRaw: privateKeyRaw,
            challengePublicKeyRaw: keyBytes,
            nonce: nonceBytes
        )
    }

    public func makeRegisterMessage(for challenge: LumzelHostChallenge) throws -> LumzelHostRegister {
        let proof = try respondToChallenge(keyBase64: challenge.key, nonceBase64: challenge.nonce)
        return LumzelHostRegister(
            hostPubBase64: publicKeyBase64,
            proofBase64: proof.base64EncodedString(),
            hostID: hostID
        )
    }
}

public enum LumzelRelayCrypto {
    private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
    private static let allZero32 = Data(repeating: 0, count: 32)

    /// Derives the 32-char lowercase base32 `host_id` matching `lumzel_frame::host_id`:
    /// first 20 bytes of SHA-256(publicKeyRaw) encoded in RFC 4648 lowercase base32 without padding.
    public static func hostID(forPublicKey publicKeyRaw: Data) -> String {
        #if canImport(CryptoKit)
        let digest = Array(SHA256.hash(data: publicKeyRaw).prefix(LumzelRelayConstants.hostIDDigestBytes))
        var out: [UInt8] = []
        out.reserveCapacity(LumzelRelayConstants.hostIDDigestBytes * 8 / 5)
        var buffer: UInt32 = 0
        var bits: UInt32 = 0
        for byte in digest {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let idx = Int((buffer >> bits) & 0x1F)
                out.append(base32Alphabet[idx])
            }
        }
        return String(decoding: out, as: UTF8.self)
        #else
        return ""
        #endif
    }

    /// Computes RFC 5869 HKDF-SHA256(ikm, salt, info) with L=32, matching `lumzel_frame::proof::respond`.
    public static func computeHostProof(
        hostPrivateKeyRaw: Data,
        challengePublicKeyRaw: Data,
        nonce: Data
    ) throws -> Data {
        #if canImport(CryptoKit)
        guard hostPrivateKeyRaw.count == 32, challengePublicKeyRaw.count == 32 else {
            throw LumzelRelayError.badKeyLength
        }
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hostPrivateKeyRaw)
        let peerPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: challengePublicKeyRaw)
        let shared = try priv.sharedSecretFromKeyAgreement(with: peerPub)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        guard sharedBytes != allZero32 else {
            throw LumzelRelayError.lowOrderPublicKey
        }
        return hkdfSHA256(ikm: sharedBytes, salt: nonce, info: LumzelRelayConstants.proofInfo, outputByteCount: 32)
        #else
        throw LumzelRelayError.cryptoUnavailable
        #endif
    }

    /// Derives directional 32-byte AEAD keys for an ephemeral X25519 + PSK (pairing token) handshake.
    /// Returns `(initiatorSendKey, responderSendKey)`.
    public static func deriveDirectionalSessionKeys(
        localPrivateKeyRaw: Data,
        remotePublicKeyRaw: Data,
        pairingToken: String,
        sid: String
    ) throws -> (initiatorToResponder: Data, responderToInitiator: Data) {
        #if canImport(CryptoKit)
        guard localPrivateKeyRaw.count == 32, remotePublicKeyRaw.count == 32 else {
            throw LumzelRelayError.badKeyLength
        }
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: localPrivateKeyRaw)
        let peerPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKeyRaw)
        let shared = try priv.sharedSecretFromKeyAgreement(with: peerPub)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        guard sharedBytes != allZero32 else {
            throw LumzelRelayError.lowOrderPublicKey
        }
        var salt = Data(pairingToken.utf8)
        salt.append(0)
        salt.append(Data(sid.utf8))
        let material = hkdfSHA256(
            ikm: sharedBytes,
            salt: salt,
            info: LumzelRelayConstants.sessionKeyInfo,
            outputByteCount: 64
        )
        return (Data(material.prefix(32)), Data(material.suffix(32)))
        #else
        throw LumzelRelayError.cryptoUnavailable
        #endif
    }

    public static func hkdfSHA256(ikm: Data, salt: Data, info: Data, outputByteCount: Int) -> Data {
        #if canImport(CryptoKit)
        let effectiveSalt = salt.isEmpty ? Data(repeating: 0, count: 32) : salt
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: effectiveSalt,
            info: info,
            outputByteCount: outputByteCount
        )
        return derived.withUnsafeBytes { Data($0) }
        #else
        return Data()
        #endif
    }
}

// MARK: - LUMZEL v2 Binary Frame Codec & E2EE Session

public enum LumzelFrameCodec {
    public static func encodeHeader(host: String, sid: String, sequence: UInt64) throws -> Data {
        let hostBytes = Data(host.utf8)
        let sidBytes = Data(sid.utf8)
        guard (LumzelRelayConstants.minIDLength...LumzelRelayConstants.maxIDLength).contains(hostBytes.count) else {
            throw LumzelRelayError.badHostLength
        }
        guard (LumzelRelayConstants.minIDLength...LumzelRelayConstants.maxIDLength).contains(sidBytes.count) else {
            throw LumzelRelayError.badSessionIDLength
        }

        var out = Data()
        out.reserveCapacity(6 + 1 + 2 + hostBytes.count + 2 + sidBytes.count + 8)
        out.append(LumzelRelayConstants.frameMagic)
        out.append(LumzelRelayConstants.frameVersion)
        appendUInt16BE(UInt16(hostBytes.count), to: &out)
        out.append(hostBytes)
        appendUInt16BE(UInt16(sidBytes.count), to: &out)
        out.append(sidBytes)
        appendUInt64BE(sequence, to: &out)
        return out
    }

    public static func splitHeader(_ frame: Data) throws -> (header: LumzelFrameHeader, headerLength: Int) {
        guard frame.count >= 6 else { throw LumzelRelayError.truncated }
        guard frame.prefix(6) == LumzelRelayConstants.frameMagic else { throw LumzelRelayError.badMagic }
        guard frame.count >= 7 else { throw LumzelRelayError.truncated }
        let version = frame[frame.startIndex + 6]
        guard version == LumzelRelayConstants.frameVersion else { throw LumzelRelayError.badVersion(version) }

        var offset = frame.startIndex + 7
        guard offset + 2 <= frame.endIndex else { throw LumzelRelayError.truncated }
        let hostLen = Int(readUInt16BE(frame, at: offset))
        offset += 2
        guard (LumzelRelayConstants.minIDLength...LumzelRelayConstants.maxIDLength).contains(hostLen) else {
            throw LumzelRelayError.badHostLength
        }
        guard offset + hostLen <= frame.endIndex else { throw LumzelRelayError.truncated }
        guard let host = String(data: frame[offset..<(offset + hostLen)], encoding: .utf8) else {
            throw LumzelRelayError.invalidUTF8
        }
        offset += hostLen

        guard offset + 2 <= frame.endIndex else { throw LumzelRelayError.truncated }
        let sidLen = Int(readUInt16BE(frame, at: offset))
        offset += 2
        guard (LumzelRelayConstants.minIDLength...LumzelRelayConstants.maxIDLength).contains(sidLen) else {
            throw LumzelRelayError.badSessionIDLength
        }
        guard offset + sidLen <= frame.endIndex else { throw LumzelRelayError.truncated }
        guard let sid = String(data: frame[offset..<(offset + sidLen)], encoding: .utf8) else {
            throw LumzelRelayError.invalidUTF8
        }
        offset += sidLen

        guard offset + 8 <= frame.endIndex else { throw LumzelRelayError.truncated }
        let seq = readUInt64BE(frame, at: offset)
        offset += 8

        let header = LumzelFrameHeader(version: version, host: host, sid: sid, sequence: seq)
        return (header, offset - frame.startIndex)
    }

    public static func encodeHandshakeFrame(host: String, sid: String, payload: Data) throws -> Data {
        var frame = try encodeHeader(host: host, sid: sid, sequence: 0)
        frame.append(payload)
        return frame
    }

    public static func decodeHandshakeFrame(_ frame: Data) throws -> (header: LumzelFrameHeader, payload: Data) {
        let (header, headerLen) = try splitHeader(frame)
        guard header.isHandshake else { throw LumzelRelayError.expectedHandshakeFrame }
        let body = Data(frame.dropFirst(headerLen))
        return (header, body)
    }

    fileprivate static func nonce(for sequence: UInt64) -> Data {
        var out = Data(repeating: 0, count: 4)
        appendUInt64BE(sequence, to: &out)
        return out
    }

    fileprivate static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    fileprivate static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    fileprivate static func appendUInt64BE(_ value: UInt64, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    fileprivate static func readUInt16BE(_ data: Data, at index: Data.Index) -> UInt16 {
        (UInt16(data[index]) << 8) | UInt16(data[index + 1])
    }

    fileprivate static func readUInt32BE(_ data: Data, at index: Data.Index) -> UInt32 {
        (UInt32(data[index]) << 24)
            | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8)
            | UInt32(data[index + 3])
    }

    fileprivate static func readUInt64BE(_ data: Data, at index: Data.Index) -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<8 {
            result = (result << 8) | UInt64(data[index + i])
        }
        return result
    }
}

/// Stateful ChaCha20-Poly1305 AEAD session matching `lumzel_frame::Session` wire format.
public struct LumzelRelaySession: Sendable {
    public let sid: String
    private let sendKey: Data
    private let recvKey: Data
    public private(set) var sentCount: UInt64 = 0
    public private(set) var receivedSequence: UInt64 = 0
    public private(set) var totalBytesTransferred: UInt64 = 0

    public init(sendKey: Data, recvKey: Data, sid: String) throws {
        guard sendKey.count == 32, recvKey.count == 32 else {
            throw LumzelRelayError.badKeyLength
        }
        guard (LumzelRelayConstants.minIDLength...LumzelRelayConstants.maxIDLength).contains(sid.utf8.count) else {
            throw LumzelRelayError.badSessionIDLength
        }
        self.sendKey = sendKey
        self.recvKey = recvKey
        self.sid = sid
    }

    public func shouldRotate(thresholdBytes: UInt64 = LumzelRelayConstants.defaultSessionRotateBytes) -> Bool {
        thresholdBytes > 0 && totalBytesTransferred >= thresholdBytes
    }

    public mutating func seal(host: String, plaintext: Data) throws -> Data {
        #if canImport(CryptoKit)
        guard sentCount < UInt64.max else { throw LumzelRelayError.sequenceExhausted }
        let nextSeq = sentCount + 1
        let header = try LumzelFrameCodec.encodeHeader(host: host, sid: sid, sequence: nextSeq)
        let nonce = try ChaChaPoly.Nonce(data: LumzelFrameCodec.nonce(for: nextSeq))
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: sendKey),
            nonce: nonce,
            authenticating: header
        )
        sentCount = nextSeq
        var frame = header
        frame.append(sealed.ciphertext)
        frame.append(sealed.tag)
        totalBytesTransferred = totalBytesTransferred &+ UInt64(frame.count)
        return frame
        #else
        throw LumzelRelayError.cryptoUnavailable
        #endif
    }

    public mutating func open(_ frame: Data) throws -> LumzelOpenedFrame {
        #if canImport(CryptoKit)
        let (header, headerLen) = try LumzelFrameCodec.splitHeader(frame)
        let body = Data(frame.dropFirst(headerLen))
        guard body.count >= LumzelRelayConstants.aeadTagLength else {
            throw LumzelRelayError.truncatedCiphertext
        }
        guard header.sid == sid else {
            throw LumzelRelayError.sessionIDMismatch
        }
        guard !header.isHandshake else {
            throw LumzelRelayError.unexpectedHandshakeFrame
        }
        guard header.sequence > receivedSequence else {
            throw LumzelRelayError.replayOrOutOfOrder(received: header.sequence, expectedGreaterThan: receivedSequence)
        }

        let ciphertext = body.dropLast(LumzelRelayConstants.aeadTagLength)
        let tag = body.suffix(LumzelRelayConstants.aeadTagLength)
        let nonce = try ChaChaPoly.Nonce(data: LumzelFrameCodec.nonce(for: header.sequence))
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let aad = Data(frame.prefix(headerLen))
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(box, using: SymmetricKey(data: recvKey), authenticating: aad)
        } catch {
            throw LumzelRelayError.aeadFailure
        }

        receivedSequence = header.sequence
        totalBytesTransferred = totalBytesTransferred &+ UInt64(frame.count)
        return LumzelOpenedFrame(header: header, plaintext: plaintext)
        #else
        throw LumzelRelayError.cryptoUnavailable
        #endif
    }
}

// MARK: - /data Plane Stream Multiplexer Frame (Carries target_iface for PC IP_BOUND_IF)

public enum RelayMuxCommand: UInt8, Codable, Equatable, Sendable {
    /// Open a TCP stream on PC bound to `targetInterface` (optional; nil = PC system default).
    case openTCP = 1
    /// Open acknowledgment from PC (`status == 0` OK, non-zero = error message in payload).
    case openAck = 2
    /// Stream payload chunk.
    case data = 3
    /// Graceful half/full close of stream.
    case close = 4
    /// UDP datagram relay bound to `targetInterface`.
    case udpPacket = 5
    /// Keepalive ping/pong inside encrypted session.
    case keepalive = 6
}

public struct RelayMuxOpenRequest: Codable, Equatable, Sendable {
    public let targetInterface: String?
    public let destinationHost: String
    public let destinationPort: UInt16

    public init(targetInterface: String?, destinationHost: String, destinationPort: UInt16) {
        self.targetInterface = targetInterface
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
    }
}

public struct RelayMuxOpenAck: Codable, Equatable, Sendable {
    public let ok: Bool
    public let error: String?

    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }
}

/// Binary inner payload sealed inside a `LumzelRelaySession` frame on `/data`:
/// `[1B command][4B streamID BE][payload...]`
public struct RelayMuxFrame: Equatable, Sendable {
    public let command: RelayMuxCommand
    public let streamID: UInt32
    public let payload: Data

    public init(command: RelayMuxCommand, streamID: UInt32, payload: Data = Data()) {
        self.command = command
        self.streamID = streamID
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data()
        out.reserveCapacity(5 + payload.count)
        out.append(command.rawValue)
        LumzelFrameCodec.appendUInt32BE(streamID, to: &out)
        out.append(payload)
        return out
    }

    public static func decode(_ data: Data) throws -> RelayMuxFrame {
        guard data.count >= 5 else { throw LumzelRelayError.invalidMuxFrame }
        guard let cmd = RelayMuxCommand(rawValue: data[data.startIndex]) else {
            throw LumzelRelayError.invalidMuxFrame
        }
        let sid = LumzelFrameCodec.readUInt32BE(data, at: data.startIndex + 1)
        let payload = Data(data.dropFirst(5))
        return RelayMuxFrame(command: cmd, streamID: sid, payload: payload)
    }
}

// MARK: - /control Plane Tunneled HTTP Envelope

/// JSON envelope sealed inside a `LumzelRelaySession` frame on `/control`
/// so iOS can invoke PC's `/api/v1/*` endpoints over `lumzel/relay` with E2EE.
public struct RelayControlHTTPRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let method: String
    public let path: String
    public let bearerToken: String?
    public let bodyBase64: String?

    public init(
        requestID: String = UUID().uuidString,
        method: String,
        path: String,
        bearerToken: String? = nil,
        body: Data? = nil
    ) {
        self.requestID = requestID
        self.method = method
        self.path = path
        self.bearerToken = bearerToken
        self.bodyBase64 = body?.base64EncodedString()
    }
}

public struct RelayControlHTTPResponse: Codable, Equatable, Sendable {
    public let requestID: String
    public let statusCode: Int
    public let contentType: String
    public let bodyBase64: String

    public init(requestID: String, statusCode: Int, contentType: String = "application/json; charset=utf-8", body: Data) {
        self.requestID = requestID
        self.statusCode = statusCode
        self.contentType = contentType
        self.bodyBase64 = body.base64EncodedString()
    }

    public var bodyData: Data? {
        Data(base64Encoded: bodyBase64)
    }
}
