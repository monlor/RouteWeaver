import Foundation
import RoutingCore

public enum RouteWeaverAppGroup {
    public static let identifier = "group.com.bytevela.routeweaver"
}

public enum AppTunnelCommand: String, Codable, Sendable {
    case reloadConfig
    case getStatus
    case setManualOverride
}

public struct AppTunnelMessage: Codable, Sendable {
    public let command: AppTunnelCommand
    public let manualOverride: MobileVPNMode?

    public init(command: AppTunnelCommand, manualOverride: MobileVPNMode? = nil) {
        self.command = command
        self.manualOverride = manualOverride
    }
}

public struct MobileTunnelRuntimeStatus: Codable, Equatable, Sendable {
    public var activeMode: MobileVPNMode
    public var networkKind: String
    public var wifiSSID: String?
    public var relayedInterfaces: [String]
    public var relayConnected: Bool
    public var engineVersion: String
    public var lastError: String?
    public var updatedAt: Date

    public init(
        activeMode: MobileVPNMode = .disabled,
        networkKind: String = "other",
        wifiSSID: String? = nil,
        relayedInterfaces: [String] = [],
        relayConnected: Bool = false,
        engineVersion: String = "",
        lastError: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.activeMode = activeMode
        self.networkKind = networkKind
        self.wifiSSID = wifiSSID
        self.relayedInterfaces = relayedInterfaces
        self.relayConnected = relayConnected
        self.engineVersion = engineVersion
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

public struct MobileSyncedHostState: Codable, Equatable, Sendable {
    public var savedHost: RemoteSavedHost
    public var profile: RoutingProfile
    public var pcInterfaces: [RemoteInterfaceDTO]
    public var pcMixedPort: Int
    public var lanIPs: [String]
    public var lastSyncedAt: Date

    public init(
        savedHost: RemoteSavedHost,
        profile: RoutingProfile,
        pcInterfaces: [RemoteInterfaceDTO],
        pcMixedPort: Int,
        lanIPs: [String],
        lastSyncedAt: Date = Date()
    ) {
        self.savedHost = savedHost
        self.profile = profile
        self.pcInterfaces = pcInterfaces
        self.pcMixedPort = pcMixedPort
        self.lanIPs = lanIPs
        self.lastSyncedAt = lastSyncedAt
    }
}

public final class AppGroupStore: @unchecked Sendable {
    public static let shared = AppGroupStore()

    private let lock = NSLock()
    private let fileManager = FileManager.default

    public var containerDirectory: URL

    private enum FileName {
        static let syncedHostState = "synced_host_state.json"
        static let relayConfig = "relay_config.json"
        static let interfaceMappings = "interface_mappings.json"
        static let switchPolicy = "switch_policy.json"
        static let runtimeStatus = "runtime_status.json"
        static let deviceID = "device_id.txt"
    }

    public init(containerDirectory: URL? = nil) {
        if let containerDirectory {
            self.containerDirectory = containerDirectory
        } else if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: RouteWeaverAppGroup.identifier
        ) {
            self.containerDirectory = groupURL.appendingPathComponent("RouteWeaver", isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.containerDirectory = base.appendingPathComponent("RouteWeaver", isDirectory: true)
        }
    }

    public var syncedHostState: MobileSyncedHostState? {
        get { readJSON(MobileSyncedHostState.self, fileName: FileName.syncedHostState) }
        set {
            if let newValue {
                writeJSON(newValue, fileName: FileName.syncedHostState)
            } else {
                removeFile(fileName: FileName.syncedHostState)
            }
        }
    }

    public var relayConfig: RelayEndpointConfig {
        get { readJSON(RelayEndpointConfig.self, fileName: FileName.relayConfig) ?? RelayEndpointConfig() }
        set { writeJSON(newValue, fileName: FileName.relayConfig) }
    }

    public var interfaceMappings: [PCInterfaceMappingRule] {
        get { readJSON([PCInterfaceMappingRule].self, fileName: FileName.interfaceMappings) ?? [] }
        set { writeJSON(newValue, fileName: FileName.interfaceMappings) }
    }

    public var switchPolicy: NetworkSwitchPolicy {
        get { readJSON(NetworkSwitchPolicy.self, fileName: FileName.switchPolicy) ?? NetworkSwitchPolicy() }
        set { writeJSON(newValue, fileName: FileName.switchPolicy) }
    }

    public var runtimeStatus: MobileTunnelRuntimeStatus? {
        get { readJSON(MobileTunnelRuntimeStatus.self, fileName: FileName.runtimeStatus) }
        set {
            if let newValue {
                writeJSON(newValue, fileName: FileName.runtimeStatus)
            } else {
                removeFile(fileName: FileName.runtimeStatus)
            }
        }
    }

    public var stableDeviceID: String {
        lock.lock()
        defer { lock.unlock() }
        let url = containerDirectory.appendingPathComponent(FileName.deviceID)
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        ensureContainerDirectoryLocked()
        try? Data(generated.utf8).write(to: url, options: .atomic)
        return generated
    }

    public func mihomoHomeDirectory() -> URL {
        lock.lock()
        defer { lock.unlock() }
        let dir = containerDirectory.appendingPathComponent("mihomo", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Private JSON Helpers

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func ensureContainerDirectoryLocked() {
        if !fileManager.fileExists(atPath: containerDirectory.path) {
            try? fileManager.createDirectory(at: containerDirectory, withIntermediateDirectories: true)
        }
    }

    private func readJSON<T: Decodable>(_ type: T.Type, fileName: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        let url = containerDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode(T.self, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, fileName: String) {
        lock.lock()
        defer { lock.unlock() }
        ensureContainerDirectoryLocked()
        let url = containerDirectory.appendingPathComponent(fileName)
        guard let data = try? makeEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func removeFile(fileName: String) {
        lock.lock()
        defer { lock.unlock() }
        let url = containerDirectory.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: url)
    }
}
