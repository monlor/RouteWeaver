import Foundation
import RoutingCore

@MainActor
public final class MobileRemoteClient: ObservableObject {
    @Published public private(set) var snapshot: RemoteSnapshotDTO?
    @Published public private(set) var fullState: RemoteFullStateDTO?
    @Published public private(set) var isUsingRelayTransport: Bool = false
    @Published public private(set) var isSyncing: Bool = false
    @Published public var lastError: String?
    @Published public var feedbackMessage: String?

    private let store: AppGroupStore
    private let relayClient: LumzelRelayClient
    private let lanSession: URLSession

    public init(
        store: AppGroupStore = .shared,
        relayClient: LumzelRelayClient = .shared
    ) {
        self.store = store
        self.relayClient = relayClient

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 5.0
        self.lanSession = URLSession(configuration: config)
    }

    // MARK: - Pairing

    @discardableResult
    public func pair(bundle: RelayPairingBundle, deviceName: String) async -> Bool {
        isSyncing = true
        lastError = nil
        feedbackMessage = nil
        defer { isSyncing = false }

        let pairReq = RemotePairingRequest(
            deviceId: store.stableDeviceID,
            deviceName: deviceName,
            pairingCode: bundle.pairingCode
        )

        let relayConfig = RelayEndpointConfig(
            isEnabled: (bundle.relayServerURL?.isEmpty == false) && (bundle.relayHostID?.isEmpty == false),
            serverURL: bundle.relayServerURL ?? "",
            password: bundle.relayPassword ?? "",
            hostID: bundle.relayHostID ?? "",
            hostPublicKeyBase64: bundle.relayHostPublicKeyBase64 ?? ""
        )

        var matchedLANIP: String?
        var pairingResponse: RemotePairingResponse?
        var usedRelay = false

        for lanIP in bundle.lanIPs where !lanIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let resp: RemotePairingResponse = try? await sendLANJSON(
                host: lanIP,
                port: bundle.remotePort,
                method: "POST",
                path: "/api/v1/pair",
                token: nil,
                body: pairReq
            ) {
                matchedLANIP = lanIP
                pairingResponse = resp
                usedRelay = false
                break
            }
        }

        if pairingResponse == nil, relayConfig.isEnabled {
            do {
                let resp: RemotePairingResponse = try await sendRelayJSON(
                    relayConfig: relayConfig,
                    token: bundle.pairingCode,
                    mode: "pair",
                    method: "POST",
                    path: "/api/v1/pair",
                    bearerToken: nil,
                    body: pairReq,
                    socks5ProxyPort: nil
                )
                pairingResponse = resp
                usedRelay = true
            } catch {
                lastError = "配对失败：\(error.localizedDescription)"
                return false
            }
        }

        guard let pairingResponse else {
            lastError = "无法连接到主机（局域网和 Relay 均不可达）"
            return false
        }

        isUsingRelayTransport = usedRelay

        let savedHost = RemoteSavedHost(
            hostDeviceId: pairingResponse.hostDeviceId,
            hostName: pairingResponse.hostName,
            host: matchedLANIP ?? bundle.lanIPs.first ?? "",
            port: bundle.remotePort,
            token: pairingResponse.token,
            pairedAt: Date()
        )

        store.relayConfig = relayConfig

        // Persist initial synced host state immediately; then fetch full state in background/inline.
        let existingProfile = store.syncedHostState?.profile ?? RoutingProfile()
        store.syncedHostState = MobileSyncedHostState(
            savedHost: savedHost,
            profile: existingProfile,
            pcInterfaces: store.syncedHostState?.pcInterfaces ?? [],
            pcMixedPort: bundle.mixedPort,
            lanIPs: bundle.lanIPs,
            lastSyncedAt: Date()
        )

        await syncFullState(
            host: savedHost,
            relayConfig: relayConfig.isEnabled ? relayConfig : nil,
            chainProxyPort: nil
        )
        feedbackMessage = "已成功配对 \(savedHost.hostName)"
        return true
    }

    @discardableResult
    public func pairManual(host: String, port: UInt16, pairingCode: String, deviceName: String) async -> Bool {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !cleanCode.isEmpty else {
            lastError = "请输入主机地址和配对码。"
            return false
        }

        isSyncing = true
        lastError = nil
        feedbackMessage = nil
        defer { isSyncing = false }

        let pairReq = RemotePairingRequest(
            deviceId: store.stableDeviceID,
            deviceName: deviceName,
            pairingCode: cleanCode
        )

        do {
            let resp: RemotePairingResponse = try await sendLANJSON(
                host: cleanHost,
                port: port,
                method: "POST",
                path: "/api/v1/pair",
                token: nil,
                body: pairReq
            )
            isUsingRelayTransport = false

            let savedHost = RemoteSavedHost(
                hostDeviceId: resp.hostDeviceId,
                hostName: resp.hostName,
                host: cleanHost,
                port: port,
                token: resp.token,
                pairedAt: Date()
            )
            let existingProfile = store.syncedHostState?.profile ?? RoutingProfile()
            store.syncedHostState = MobileSyncedHostState(
                savedHost: savedHost,
                profile: existingProfile,
                pcInterfaces: store.syncedHostState?.pcInterfaces ?? [],
                pcMixedPort: store.syncedHostState?.pcMixedPort ?? 7890,
                lanIPs: [cleanHost],
                lastSyncedAt: Date()
            )

            await syncFullState(host: savedHost, relayConfig: nil, chainProxyPort: nil)
            feedbackMessage = "已成功配对 \(savedHost.hostName)"
            return true
        } catch {
            lastError = "配对失败：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Snapshot & Full State Sync

    public func refreshSnapshot(
        host: RemoteSavedHost,
        relayConfig: RelayEndpointConfig?,
        chainProxyPort: Int? = nil
    ) async {
        do {
            let snap: RemoteSnapshotDTO = try await sendWithFallback(
                host: host,
                relayConfig: relayConfig,
                chainProxyPort: chainProxyPort,
                method: "GET",
                path: "/api/v1/snapshot",
                body: Optional<RemoteDelayTestRequest>.none
            )
            self.snapshot = snap
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    public func syncFullState(
        host: RemoteSavedHost,
        relayConfig: RelayEndpointConfig?,
        chainProxyPort: Int? = nil
    ) async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let state: RemoteFullStateDTO = try await sendWithFallback(
                host: host,
                relayConfig: relayConfig,
                chainProxyPort: chainProxyPort,
                method: "GET",
                path: "/api/v1/state",
                body: Optional<RemoteDelayTestRequest>.none
            )
            self.fullState = state

            if self.snapshot == nil {
                if let snap: RemoteSnapshotDTO = try? await sendWithFallback(
                    host: host,
                    relayConfig: relayConfig,
                    chainProxyPort: chainProxyPort,
                    method: "GET",
                    path: "/api/v1/snapshot",
                    body: Optional<RemoteDelayTestRequest>.none
                ) {
                    self.snapshot = snap
                }
            }

            let mixedPort = self.snapshot?.status.mixedPort ?? store.syncedHostState?.pcMixedPort ?? 7890
            let lanIPs = self.snapshot?.status.lanIPAddresses ?? store.syncedHostState?.lanIPs ?? (host.host.isEmpty ? [] : [host.host])

            store.syncedHostState = MobileSyncedHostState(
                savedHost: host,
                profile: state.profile,
                pcInterfaces: state.interfaces,
                pcMixedPort: mixedPort,
                lanIPs: lanIPs,
                lastSyncedAt: Date()
            )

            // Automatically sync PC-configured relay connection details while preserving iOS-local chain/rotation preferences.
            if let relayInfo = state.relayInfo {
                var updatedRelay = store.relayConfig
                updatedRelay.isEnabled = relayInfo.isEnabled && !relayInfo.serverURL.isEmpty && !relayInfo.hostID.isEmpty
                updatedRelay.serverURL = relayInfo.serverURL
                updatedRelay.password = relayInfo.password
                updatedRelay.hostID = relayInfo.hostID
                updatedRelay.hostPublicKeyBase64 = relayInfo.hostPublicKeyBase64
                store.relayConfig = updatedRelay
            }

            // Seed interface mappings for any newly discovered PC interfaces while preserving user choices.
            var mappings = store.interfaceMappings
            let knownBSD = Set(mappings.map(\.bsdName))
            var changed = false
            for iface in state.interfaces where !knownBSD.contains(iface.bsdName) {
                mappings.append(PCInterfaceMappingRule(
                    bsdName: iface.bsdName,
                    displayName: iface.displayName,
                    action: .useMobileDefault
                ))
                changed = true
            }
            if changed {
                store.interfaceMappings = mappings
            }

            self.lastError = nil
            self.feedbackMessage = "已同步配置与接口列表"
        } catch {
            self.lastError = "同步失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Remote Actions

    public func selectProxy(
        host: RemoteSavedHost,
        relayConfig: RelayEndpointConfig?,
        group: String,
        node: String,
        chainProxyPort: Int? = nil
    ) async {
        await performAction(
            host: host,
            relayConfig: relayConfig,
            chainProxyPort: chainProxyPort,
            path: "/api/v1/proxies/select",
            body: RemoteSelectProxyRequest(group: group, node: node)
        )
    }

    public func testDelay(
        host: RemoteSavedHost,
        relayConfig: RelayEndpointConfig?,
        group: String,
        chainProxyPort: Int? = nil
    ) async {
        await performAction(
            host: host,
            relayConfig: relayConfig,
            chainProxyPort: chainProxyPort,
            path: "/api/v1/proxies/delay",
            body: RemoteDelayTestRequest(group: group)
        )
    }

    public func startPCEngine(
        host: RemoteSavedHost,
        relayConfig: RelayEndpointConfig?,
        chainProxyPort: Int? = nil
    ) async {
        await performAction(
            host: host,
            relayConfig: relayConfig,
            chainProxyPort: chainProxyPort,
            path: "/api/v1/engine/start",
            body: Optional<RemoteDelayTestRequest>.none
        )
    }

    public func stopPCEngine(
        host: RemoteSavedHost,
        relayConfig: RelayEndpointConfig?,
        chainProxyPort: Int? = nil
    ) async {
        await performAction(
            host: host,
            relayConfig: relayConfig,
            chainProxyPort: chainProxyPort,
            path: "/api/v1/engine/stop",
            body: Optional<RemoteDelayTestRequest>.none
        )
    }

    public func hotReloadPC(
        host: RemoteSavedHost,
        relayConfig: RelayEndpointConfig?,
        chainProxyPort: Int? = nil
    ) async {
        await performAction(
            host: host,
            relayConfig: relayConfig,
            chainProxyPort: chainProxyPort,
            path: "/api/v1/engine/hot-reload",
            body: Optional<RemoteDelayTestRequest>.none
        )
    }

    public func closeConnection(
        host: RemoteSavedHost,
        relayConfig: RelayEndpointConfig?,
        id: String,
        chainProxyPort: Int? = nil
    ) async {
        await performAction(
            host: host,
            relayConfig: relayConfig,
            chainProxyPort: chainProxyPort,
            path: "/api/v1/connections/close",
            body: RemoteCloseConnectionRequest(id: id)
        )
    }

    public func closeAllConnections(
        host: RemoteSavedHost,
        relayConfig: RelayEndpointConfig?,
        chainProxyPort: Int? = nil
    ) async {
        await performAction(
            host: host,
            relayConfig: relayConfig,
            chainProxyPort: chainProxyPort,
            path: "/api/v1/connections/close-all",
            body: Optional<RemoteDelayTestRequest>.none
        )
    }

    public func flushDNS(
        host: RemoteSavedHost,
        relayConfig: RelayEndpointConfig?,
        includeFakeIP: Bool = false,
        chainProxyPort: Int? = nil
    ) async {
        await performAction(
            host: host,
            relayConfig: relayConfig,
            chainProxyPort: chainProxyPort,
            path: "/api/v1/dns/flush",
            body: RemoteFlushDNSRequest(includeFakeIP: includeFakeIP)
        )
    }

    // MARK: - Transport Helpers (LAN Direct 2.5s -> Relay Fallback)

    private func performAction<B: Encodable>(
        host: RemoteSavedHost,
        relayConfig: RelayEndpointConfig?,
        chainProxyPort: Int?,
        path: String,
        body: B?
    ) async {
        do {
            let result: RemoteActionResult = try await sendWithFallback(
                host: host,
                relayConfig: relayConfig,
                chainProxyPort: chainProxyPort,
                method: "POST",
                path: path,
                body: body
            )
            if result.ok {
                feedbackMessage = result.message
                lastError = nil
            } else {
                lastError = result.message
            }
            await refreshSnapshot(host: host, relayConfig: relayConfig, chainProxyPort: chainProxyPort)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func sendWithFallback<B: Encodable, R: Decodable>(
        host: RemoteSavedHost,
        relayConfig: RelayEndpointConfig?,
        chainProxyPort: Int?,
        method: String,
        path: String,
        body: B?
    ) async throws -> R {
        var lanError: Error?

        // 1. Try LAN direct first (2.5s timeout).
        let cleanHost = host.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanHost.isEmpty {
            do {
                let result: R = try await sendLANJSON(
                    host: cleanHost,
                    port: host.port,
                    method: method,
                    path: path,
                    token: host.token,
                    body: body
                )
                isUsingRelayTransport = false
                return result
            } catch {
                lanError = error
            }
        }

        // 2. Fallback to LumzelRelayClient over /control.
        if let relayConfig, relayConfig.isEnabled {
            let result: R = try await sendRelayJSON(
                relayConfig: relayConfig,
                token: host.token,
                mode: "auth",
                method: method,
                path: path,
                bearerToken: host.token,
                body: body,
                socks5ProxyPort: chainProxyPort
            )
            isUsingRelayTransport = true
            return result
        }

        if let lanError {
            throw lanError
        }
        throw LumzelRelayClientError.invalidRelayConfig("无可用的局域网地址或 Relay 配置")
    }

    private func sendLANJSON<B: Encodable, R: Decodable>(
        host: String,
        port: UInt16,
        method: String,
        path: String,
        token: String?,
        body: B?
    ) async throws -> R {
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(formattedHost):\(port)\(path)") else {
            throw NSError(domain: "MobileRemoteClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效的主机地址：\(host):\(port)"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 2.5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await lanSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "MobileRemoteClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "无效的 HTTP 响应"])
        }
        return try decodeHTTPPayload(statusCode: httpResponse.statusCode, data: data)
    }

    private func sendRelayJSON<B: Encodable, R: Decodable>(
        relayConfig: RelayEndpointConfig,
        token: String,
        mode: String,
        method: String,
        path: String,
        bearerToken: String?,
        body: B?,
        socks5ProxyPort: Int?
    ) async throws -> R {
        let bodyData: Data?
        if let body {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            bodyData = try encoder.encode(body)
        } else {
            bodyData = nil
        }

        let req = RelayControlHTTPRequest(
            method: method,
            path: path,
            bearerToken: bearerToken,
            body: bodyData
        )
        let resp = try await relayClient.sendControlRequest(
            req,
            relayConfig: relayConfig,
            token: token,
            mode: mode,
            socks5ProxyPort: socks5ProxyPort
        )
        let rawBody = resp.bodyData ?? Data()
        return try decodeHTTPPayload(statusCode: resp.statusCode, data: rawBody)
    }

    private func decodeHTTPPayload<R: Decodable>(statusCode: Int, data: Data) throws -> R {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard (200...299).contains(statusCode) else {
            if let actionErr = try? decoder.decode(RemoteActionResult.self, from: data) {
                throw NSError(domain: "MobileRemoteClient", code: statusCode, userInfo: [NSLocalizedDescriptionKey: actionErr.message])
            }
            throw NSError(domain: "MobileRemoteClient", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "请求失败（HTTP \(statusCode)）"])
        }
        return try decoder.decode(R.self, from: data)
    }
}
