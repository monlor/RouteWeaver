import Foundation
import Network
import NetworkExtension
import RoutingCore

public final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let store = AppGroupStore.shared
    private let engine = MihomoKitEngineAdapter()
    private let bridgeServer = LocalRelayBridgeServer()

    private let stateQueue = DispatchQueue(label: "local.routeweaver.packet-tunnel.state", qos: .userInitiated)
    private var pathMonitor: NWPathMonitor?
    private var currentSnapshot = MobileNetworkSnapshot(interfaceKind: .other, wifiSSID: nil)
    private var activeMode: MobileVPNMode?
    private var isStopping = false

    public override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        isStopping = false

        Task {
            do {
                startPathMonitoring()
                let initialPath = pathMonitor?.currentPath
                let snapshot = await captureCurrentNetworkSnapshot(path: initialPath)
                let initialMode = store.switchPolicy.resolve(for: snapshot)

                if initialMode == .disabled {
                    activeMode = .disabled
                    updateRuntimeStatus(
                        mode: .disabled,
                        snapshot: snapshot,
                        relayedInterfaces: [],
                        relayConnected: false,
                        lastError: nil
                    )
                    completionHandler(nil)
                    cancelTunnelWithError(nil)
                    return
                }

                let settings = buildTunnelSettings(ipv6Enabled: store.syncedHostState?.profile.ipv6Enabled ?? false)
                try await setTunnelNetworkSettingsAsync(settings)

                await applySnapshotAndConfigure(snapshot, forceReload: true)
                completionHandler(nil)
            } catch {
                updateRuntimeStatus(
                    mode: .disabled,
                    snapshot: currentSnapshot,
                    relayedInterfaces: [],
                    relayConnected: false,
                    lastError: error.localizedDescription
                )
                completionHandler(error)
            }
        }
    }

    public override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        isStopping = true
        pathMonitor?.cancel()
        pathMonitor = nil

        bridgeServer.stop()
        engine.stop()
        activeMode = nil

        updateRuntimeStatus(
            mode: .disabled,
            snapshot: currentSnapshot,
            relayedInterfaces: [],
            relayConnected: false,
            lastError: nil
        )
        completionHandler()
    }

    public override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        guard let message = try? makeDecoder().decode(AppTunnelMessage.self, from: messageData) else {
            completionHandler?(nil)
            return
        }

        Task {
            switch message.command {
            case .getStatus:
                let status = await refreshStatusSnapshot()
                completionHandler?(try? makeEncoder().encode(status))

            case .reloadConfig:
                let snapshot = await captureCurrentNetworkSnapshot(path: nil)
                await applySnapshotAndConfigure(snapshot, forceReload: true)
                let status = await refreshStatusSnapshot()
                completionHandler?(try? makeEncoder().encode(status))

            case .setManualOverride:
                var policy = store.switchPolicy
                policy.manualOverride = message.manualOverride
                store.switchPolicy = policy

                let snapshot = await captureCurrentNetworkSnapshot(path: nil)
                await applySnapshotAndConfigure(snapshot, forceReload: true)
                let status = await refreshStatusSnapshot()
                completionHandler?(try? makeEncoder().encode(status))
            }
        }
    }

    // MARK: - Network Path Monitoring

    private func startPathMonitoring() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, !self.isStopping else { return }
            Task {
                let snapshot = await self.captureCurrentNetworkSnapshot(path: path)
                await self.applySnapshotAndConfigure(snapshot, forceReload: false)
            }
        }
        self.pathMonitor = monitor
        monitor.start(queue: stateQueue)
    }

    private func captureCurrentNetworkSnapshot(path: Network.NWPath?) async -> MobileNetworkSnapshot {
        var interfaceKind: MobileNetworkSnapshot.InterfaceKind
        if let path {
            if path.usesInterfaceType(.wifi) {
                interfaceKind = .wifi
            } else if path.usesInterfaceType(.cellular) {
                interfaceKind = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                interfaceKind = .wired
            } else {
                interfaceKind = .other
            }
        } else {
            interfaceKind = currentSnapshot.interfaceKind
        }

        var ssid: String? = nil
        if interfaceKind == .wifi || path == nil {
            ssid = await fetchCurrentWiFiSSID()
            if let ssid, !ssid.isEmpty {
                interfaceKind = .wifi
            }
        }

        let snapshot = MobileNetworkSnapshot(interfaceKind: interfaceKind, wifiSSID: ssid)
        stateQueue.sync {
            self.currentSnapshot = snapshot
        }
        return snapshot
    }

    private func fetchCurrentWiFiSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }

    // MARK: - Mode Resolution & Engine Application

    private func applySnapshotAndConfigure(_ snapshot: MobileNetworkSnapshot, forceReload: Bool) async {
        guard !isStopping else { return }

        let policy = store.switchPolicy
        let resolvedMode = policy.resolve(for: snapshot)

        if !forceReload, let activeMode, activeMode == resolvedMode {
            _ = await refreshStatusSnapshot()
            return
        }

        do {
            switch resolvedMode {
            case .disabled:
                bridgeServer.stop()
                engine.stop()
                activeMode = .disabled
                updateRuntimeStatus(
                    mode: .disabled,
                    snapshot: snapshot,
                    relayedInterfaces: [],
                    relayConnected: false,
                    lastError: nil
                )
                try? await setTunnelNetworkSettingsAsync(nil)
                cancelTunnelWithError(nil)

            case .localCore, .directPCSocks5:
                let syncedState = store.syncedHostState
                let profile = syncedState?.profile ?? RoutingProfile()
                let relayConfig = store.relayConfig
                let mappings = store.interfaceMappings

                let adapted = try MobileProfileAdapter.render(
                    pcProfile: profile,
                    mode: resolvedMode,
                    relayConfig: relayConfig,
                    interfaceMappings: mappings
                )

                let needsRelayBridge = !adapted.relayedPCInterfaces.isEmpty
                    && relayConfig.isEnabled
                    && !(syncedState?.savedHost.token.isEmpty ?? true)

                if needsRelayBridge, let token = syncedState?.savedHost.token {
                    try bridgeServer.start(
                        port: UInt16(adapted.relayBridgePort),
                        relayConfig: relayConfig,
                        pairingToken: token,
                        socks5ChainPort: adapted.relayChainEntryPort
                    )
                } else {
                    bridgeServer.stop()
                }

                if engine.isRunning {
                    try engine.reload(configData: adapted.configData)
                } else {
                    let tunFD = resolveTunFileDescriptor()
                    try engine.start(
                        homeDirectory: store.mihomoHomeDirectory(),
                        configData: adapted.configData,
                        tunFileDescriptor: tunFD
                    )
                }

                activeMode = resolvedMode
                let relayConnected = await bridgeServer.isRelayConnected
                updateRuntimeStatus(
                    mode: resolvedMode,
                    snapshot: snapshot,
                    relayedInterfaces: adapted.relayedPCInterfaces,
                    relayConnected: relayConnected,
                    lastError: nil
                )
            }
        } catch {
            updateRuntimeStatus(
                mode: activeMode ?? resolvedMode,
                snapshot: snapshot,
                relayedInterfaces: [],
                relayConnected: await bridgeServer.isRelayConnected,
                lastError: error.localizedDescription
            )
        }
    }

    private func refreshStatusSnapshot() async -> MobileTunnelRuntimeStatus {
        let relayConnected = await bridgeServer.isRelayConnected
        var status = store.runtimeStatus ?? MobileTunnelRuntimeStatus()
        status.activeMode = activeMode ?? status.activeMode
        status.networkKind = currentSnapshot.interfaceKind.rawValue
        status.wifiSSID = currentSnapshot.wifiSSID
        status.relayConnected = relayConnected
        status.engineVersion = engine.engineVersion
        status.updatedAt = Date()
        store.runtimeStatus = status
        return status
    }

    private func updateRuntimeStatus(
        mode: MobileVPNMode,
        snapshot: MobileNetworkSnapshot,
        relayedInterfaces: [String],
        relayConnected: Bool,
        lastError: String?
    ) {
        let status = MobileTunnelRuntimeStatus(
            activeMode: mode,
            networkKind: snapshot.interfaceKind.rawValue,
            wifiSSID: snapshot.wifiSSID,
            relayedInterfaces: relayedInterfaces,
            relayConnected: relayConnected,
            engineVersion: engine.engineVersion,
            lastError: lastError,
            updatedAt: Date()
        )
        store.runtimeStatus = status
    }

    // MARK: - TUN Settings & Helpers

    private func buildTunnelSettings(ipv6Enabled: Bool) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 4096

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0")
        ]
        settings.ipv4Settings = ipv4

        if ipv6Enabled {
            let ipv6 = NEIPv6Settings(addresses: ["fd00::1"], networkPrefixLengths: [64])
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }

        let dns = NEDNSSettings(servers: ["198.18.0.2"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        return settings
    }

    private func setTunnelNetworkSettingsAsync(_ settings: NEPacketTunnelNetworkSettings?) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    private func resolveTunFileDescriptor() -> Int32 {
        if let fd = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            return fd
        }
        return -1
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
