import Combine
import Foundation
import RoutingCore

protocol GatewayDeviceInspecting: Sendable {
    func currentDevices(
        records: [MonitoredConnection],
        localIPs: Set<String>,
        includeARPOnly: Bool
    ) async -> [GatewayClientDevice]
}

struct SystemGatewayDeviceInspector: GatewayDeviceInspecting {
    func currentDevices(
        records: [MonitoredConnection],
        localIPs: Set<String>,
        includeARPOnly: Bool
    ) async -> [GatewayClientDevice] {
        await Task.detached(priority: .utility) {
            GatewayDeviceInspector.currentDevices(
                records: records,
                localIPs: localIPs,
                includeARPOnly: includeARPOnly
            )
        }.value
    }
}

@MainActor
final class GatewayDeviceStore: ObservableObject {
    @Published private(set) var devices: [GatewayClientDevice] = []
    @Published var includeARPOnly: Bool = false
    @Published private(set) var lanDeviceNamesByIP: [String: String] = [:]

    private let inspector: any GatewayDeviceInspecting
    private var refreshGeneration: UInt64 = 0

    init(
        inspector: any GatewayDeviceInspecting = SystemGatewayDeviceInspector(),
        includeARPOnly: Bool = false
    ) {
        self.inspector = inspector
        self.includeARPOnly = includeARPOnly
    }

    func refresh(
        connections: [MonitoredConnection],
        localIPs: Set<String>,
        includeARPOnly: Bool? = nil
    ) async {
        let effectiveIncludeARPOnly = includeARPOnly ?? self.includeARPOnly
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let inspected = await inspector.currentDevices(
            records: connections,
            localIPs: localIPs,
            includeARPOnly: effectiveIncludeARPOnly
        )
        guard generation == refreshGeneration else { return }
        devices = inspected
        lanDeviceNamesByIP = Self.deviceNamesByIP(for: inspected)
    }

    func replaceDevices(_ newDevices: [GatewayClientDevice]) {
        devices = newDevices
        lanDeviceNamesByIP = Self.deviceNamesByIP(for: newDevices)
    }

    func clientDisplayLabel(for clientKey: String) -> String {
        Self.clientDisplayLabel(for: clientKey, namesByIP: lanDeviceNamesByIP)
    }

    func clientShortLabel(for clientKey: String) -> String {
        Self.clientShortLabel(for: clientKey, namesByIP: lanDeviceNamesByIP)
    }

    func connectionClientKey(for item: MonitoredConnection, localIPs: Set<String>) -> String {
        Self.connectionClientKey(for: item, localIPs: localIPs)
    }

    func connectionLANClientLabel(for item: MonitoredConnection, localIPs: Set<String>) -> String? {
        Self.connectionLANClientLabel(for: item, localIPs: localIPs, namesByIP: lanDeviceNamesByIP)
    }

    static func deviceNamesByIP(for devices: [GatewayClientDevice]) -> [String: String] {
        var result: [String: String] = [:]
        for device in devices {
            if let host = device.hostname?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
                result[device.ip] = host
            }
        }
        return result
    }

    static func clientDisplayLabel(for clientKey: String, namesByIP: [String: String]) -> String {
        if clientKey == TrafficAttribution.localDeviceLabel {
            return TrafficAttribution.localDeviceLabel
        }
        if let name = namesByIP[clientKey], !name.isEmpty, name != clientKey {
            return "\(name) (\(clientKey))"
        }
        return clientKey
    }

    static func clientShortLabel(for clientKey: String, namesByIP: [String: String]) -> String {
        if clientKey == TrafficAttribution.localDeviceLabel {
            return TrafficAttribution.localDeviceLabel
        }
        if let name = namesByIP[clientKey], !name.isEmpty {
            return name
        }
        return clientKey
    }

    static func connectionClientKey(for item: MonitoredConnection, localIPs: Set<String>) -> String {
        TrafficAttribution.extractClient(from: item.metadata, localIPs: localIPs)
    }

    /// Returns a display label only when the connection originates from another LAN device (nil for local machine).
    static func connectionLANClientLabel(
        for item: MonitoredConnection,
        localIPs: Set<String>,
        namesByIP: [String: String]
    ) -> String? {
        let key = connectionClientKey(for: item, localIPs: localIPs)
        guard key != TrafficAttribution.localDeviceLabel else { return nil }
        return clientShortLabel(for: key, namesByIP: namesByIP)
    }
}
