import Foundation

// MARK: - Outbound Dial & Relay Failure Log Parsing

public enum MihomoLogStreamEvent: Equatable, Sendable {
    case dns(DNSLogRecord)
    case outboundError(OutboundErrorRecord)
}

public enum OutboundFailureCategory: String, Codable, Equatable, Sendable {
    case timeout
    case connectionRefused
    case tlsOrProtocol
    case interfaceOrRoute
    case dnsFailure
    case rejected
    case other

    public var shortTitle: String {
        switch self {
        case .timeout: return "连接超时"
        case .connectionRefused: return "连接被拒/重置"
        case .tlsOrProtocol: return "协议/TLS 握手失败"
        case .interfaceOrRoute: return "网卡/路由不可达"
        case .dnsFailure: return "DNS 解析失败"
        case .rejected: return "策略拦截"
        case .other: return "代理拨号异常"
        }
    }
}

public enum TopologyHopKind: String, Codable, Equatable, Sendable {
    case interface
    case relay
    case exit
}

public struct OutboundErrorRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let network: String
    /// Primary network target outbound name (e.g. `"美国"`), stripped of `·链式` suffix when possible.
    public let primaryTarget: String
    /// Exact group or proxy mentioned in the error (e.g. `"美国·链式"` or `"美国"`).
    public let outboundGroup: String
    public let nodeName: String?
    public let destination: String
    public let matchedRuleType: String?
    public let matchedRulePayload: String?
    public let suspectedHop: TopologyHopKind?
    public let category: OutboundFailureCategory
    public let reason: String
    public let rawPayload: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        network: String,
        primaryTarget: String,
        outboundGroup: String,
        nodeName: String? = nil,
        destination: String = "",
        matchedRuleType: String? = nil,
        matchedRulePayload: String? = nil,
        suspectedHop: TopologyHopKind? = nil,
        category: OutboundFailureCategory,
        reason: String,
        rawPayload: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.network = network
        self.primaryTarget = primaryTarget
        self.outboundGroup = outboundGroup
        self.nodeName = nodeName
        self.destination = destination
        self.matchedRuleType = matchedRuleType
        self.matchedRulePayload = matchedRulePayload
        self.suspectedHop = suspectedHop
        self.category = category
        self.reason = reason
        self.rawPayload = rawPayload
    }

    public var conciseReason: String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return category.shortTitle }
        if trimmed.count <= 64 {
            return "\(category.shortTitle) (\(trimmed))"
        }
        return "\(category.shortTitle) (\(trimmed.prefix(60))…)"
    }
}

public enum OutboundErrorParser {
    private static let relaySuffix = "·链式"

    /// Parses a Mihomo `/logs` payload (or `msg="..."` content) into an `OutboundErrorRecord` when it represents
    /// a proxy/direct dial or tunnel failure. Ignores routine info logs and `[DNS]` lines (handled by `DNSLogParser`).
    public static func parse(
        payload: String,
        level: String? = nil,
        at timestamp: Date = Date()
    ) -> OutboundErrorRecord? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("[DNS]"),
              !trimmed.hasPrefix("[DNS Server]") else {
            return nil
        }
        if let level, level.lowercased() == "debug" || level.lowercased() == "info" {
            let lower = trimmed.lowercased()
            if !lower.contains("error:") && !lower.contains("failed:") && !lower.contains("fail:") {
                return nil
            }
        }

        // Pattern 1: `[TCP] dial <Outbound> ... error: <Reason>` or `[UDP] dial <Outbound> ... error: <Reason>`
        if (trimmed.hasPrefix("[TCP] ") || trimmed.hasPrefix("[UDP] ")),
           let dialRange = trimmed.range(of: " dial ") {
            let net = String(trimmed.dropFirst().prefix(3)).uppercased()
            let afterDial = String(trimmed[dialRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard let errorSplit = splitErrorSuffix(in: afterDial) else { return nil }

            let header = errorSplit.prefix
            let rawReason = errorSplit.reason
            let parsedHeader = parseDialHeader(header, rawReason: rawReason)
            guard !parsedHeader.primaryTarget.isEmpty else { return nil }

            let category = classifyFailure(reason: rawReason, primaryTarget: parsedHeader.primaryTarget)
            let suspectedHop = inferSuspectedHop(
                primaryTarget: parsedHeader.primaryTarget,
                outboundGroup: parsedHeader.outboundGroup,
                reason: rawReason,
                category: category
            )
            return OutboundErrorRecord(
                timestamp: timestamp,
                network: net,
                primaryTarget: parsedHeader.primaryTarget,
                outboundGroup: parsedHeader.outboundGroup,
                nodeName: parsedHeader.nodeName,
                destination: parsedHeader.destination,
                matchedRuleType: parsedHeader.ruleType,
                matchedRulePayload: parsedHeader.rulePayload,
                suspectedHop: suspectedHop,
                category: category,
                reason: simplifyReason(rawReason),
                rawPayload: trimmed
            )
        }

        // Pattern 2: Direct `dialer-proxy [<Group>] ... error/failed: <Reason>`
        if let dpRange = trimmed.range(of: "dialer-proxy", options: .caseInsensitive),
           let errorSplit = splitErrorSuffix(in: String(trimmed[dpRange.lowerBound...])) {
            let segment = errorSplit.prefix
            if let openBracket = segment.firstIndex(of: "["),
               let closeBracket = segment[openBracket...].firstIndex(of: "]") {
                let group = String(segment[segment.index(after: openBracket)..<closeBracket])
                    .trimmingCharacters(in: .whitespaces)
                if !group.isEmpty {
                    let primary = stripRelaySuffix(group)
                    let reason = simplifyReason(errorSplit.reason)
                    let category = classifyFailure(reason: errorSplit.reason, primaryTarget: primary)
                    return OutboundErrorRecord(
                        timestamp: timestamp,
                        network: "TCP",
                        primaryTarget: primary,
                        outboundGroup: group,
                        nodeName: nil,
                        destination: "",
                        suspectedHop: .relay,
                        category: category,
                        reason: reason,
                        rawPayload: trimmed
                    )
                }
            }
        }

        return nil
    }

    /// Parses recent lines from a Mihomo log text buffer (`time="..." level=... msg="..."` or plain payloads).
    public static func parseLogBuffer(_ text: String, maxRecords: Int = 200) -> [OutboundErrorRecord] {
        guard !text.isEmpty else { return [] }
        var results: [OutboundErrorRecord] = []
        let lines = text.split(whereSeparator: \.isNewline)
        for rawLine in lines.suffix(800) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let extracted = extractStructuredLogLine(line) {
                if let record = parse(payload: extracted.msg, level: extracted.level, at: extracted.timestamp ?? Date()) {
                    results.append(record)
                }
            } else if let record = parse(payload: line) {
                results.append(record)
            }
        }
        if results.count > maxRecords {
            results = Array(results.suffix(maxRecords))
        }
        return results.reversed()
    }

    // MARK: - Internal Helpers

    private struct DialHeaderParts {
        var primaryTarget: String
        var outboundGroup: String
        var nodeName: String?
        var destination: String
        var ruleType: String?
        var rulePayload: String?
    }

    private static func parseDialHeader(_ header: String, rawReason: String) -> DialHeaderParts {
        var working = header.trimmingCharacters(in: .whitespaces)
        var ruleType: String?
        var rulePayload: String?
        var destination = ""

        // Extract `(match RuleType/Payload)` if present
        if let matchRange = working.range(of: "(match ") {
            let afterMatch = working[matchRange.upperBound...]
            if let closeParen = afterMatch.firstIndex(of: ")") {
                let matchContent = String(afterMatch[..<closeParen]).trimmingCharacters(in: .whitespaces)
                if let slash = matchContent.firstIndex(of: "/") {
                    ruleType = String(matchContent[..<slash]).trimmingCharacters(in: .whitespaces)
                    rulePayload = String(matchContent[matchContent.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
                } else if !matchContent.isEmpty {
                    ruleType = matchContent
                }
                let before = String(working[..<matchRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let after = String(afterMatch[afterMatch.index(after: closeParen)...]).trimmingCharacters(in: .whitespaces)
                working = [before, after].filter { !$0.isEmpty }.joined(separator: " ")
            }
        }

        // Extract `src --> dst` at the end if present
        var targetSegment = working
        if let arrowRange = working.range(of: " --> ", options: .backwards) {
            destination = String(working[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            let leftSide = String(working[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            // `leftSide` is typically `<Outbound> <srcIP:port>` or `<Outbound>`
            if let lastSpace = leftSide.lastIndex(of: " ") {
                let tailToken = String(leftSide[leftSide.index(after: lastSpace)...])
                if looksLikeEndpoint(tailToken) {
                    targetSegment = String(leftSide[..<lastSpace]).trimmingCharacters(in: .whitespaces)
                } else {
                    targetSegment = leftSide
                }
            } else {
                targetSegment = leftSide
            }
        }

        // `targetSegment` might be:
        // - `美国`
        // - `美国·链式`
        // - `[美国] US-01`
        // - `美国 --> [美国] US-01`
        var rawOutbound = targetSegment
        var extractedNode: String? = nil

        if let chainArrow = targetSegment.range(of: " --> ") {
            rawOutbound = String(targetSegment[..<chainArrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rightNode = String(targetSegment[chainArrow.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !rightNode.isEmpty {
                extractedNode = stripTargetPrefix(rightNode, target: rawOutbound)
            }
        }

        if rawOutbound.hasPrefix("["), let closeIdx = rawOutbound.firstIndex(of: "]") {
            let prefixTarget = String(rawOutbound[rawOutbound.index(after: rawOutbound.startIndex)..<closeIdx])
                .trimmingCharacters(in: .whitespaces)
            let restNode = String(rawOutbound[rawOutbound.index(after: closeIdx)...])
                .trimmingCharacters(in: .whitespaces)
            if !prefixTarget.isEmpty {
                rawOutbound = prefixTarget
                if !restNode.isEmpty {
                    extractedNode = restNode
                }
            }
        }

        var outboundGroup = rawOutbound
        let primaryTarget = stripRelaySuffix(rawOutbound)

        // Check if `rawReason` explicitly names `目标·链式` or `[目标] 节点`
        let relayGroupCandidate = MihomoConfig.relayGroupName(for: primaryTarget)
        if rawReason.contains(relayGroupCandidate) {
            outboundGroup = relayGroupCandidate
        } else if extractedNode == nil {
            let exitPrefix = "[\(primaryTarget)] "
            if let prefixRange = rawReason.range(of: exitPrefix) {
                let after = rawReason[prefixRange.upperBound...]
                let endIdx = after.firstIndex(where: { $0 == ":" || $0 == "]" || $0 == "\n" }) ?? after.endIndex
                let candidate = String(after[..<endIdx]).trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty {
                    extractedNode = candidate
                }
            }
        }

        return DialHeaderParts(
            primaryTarget: primaryTarget,
            outboundGroup: outboundGroup,
            nodeName: extractedNode,
            destination: destination,
            ruleType: ruleType,
            rulePayload: rulePayload
        )
    }

    private static func splitErrorSuffix(in text: String) -> (prefix: String, reason: String)? {
        for marker in [" error: ", " failed: ", " err: "] {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                let prefix = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let reason = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !reason.isEmpty {
                    return (prefix, reason)
                }
            }
        }
        return nil
    }

    private static func stripRelaySuffix(_ name: String) -> String {
        if name.hasSuffix(relaySuffix) {
            let base = String(name.dropLast(relaySuffix.count))
            if !base.isEmpty { return base }
        }
        return name
    }

    private static func stripTargetPrefix(_ node: String, target: String) -> String {
        let prefix = "[\(target)] "
        if node.hasPrefix(prefix) {
            let stripped = String(node.dropFirst(prefix.count))
            if !stripped.isEmpty { return stripped }
        }
        return node
    }

    private static func looksLikeEndpoint(_ token: String) -> Bool {
        guard token.contains(":") else { return false }
        if token.hasPrefix("[") { return true }
        let parts = token.split(separator: ":")
        guard let last = parts.last, Int(last) != nil else { return false }
        return true
    }

    private static func classifyFailure(reason: String, primaryTarget: String) -> OutboundFailureCategory {
        let upperTarget = primaryTarget.uppercased()
        if upperTarget == "REJECT" || upperTarget == "REJECT-DROP" {
            return .rejected
        }
        let lower = reason.lowercased()
        if lower.contains("can't assign requested address")
            || lower.contains("no route to host")
            || lower.contains("network is unreachable")
            || lower.contains("host is down")
            || lower.contains("bind:") {
            return .interfaceOrRoute
        }
        if lower.contains("timeout")
            || lower.contains("deadline exceeded")
            || lower.contains("timed out") {
            return .timeout
        }
        if lower.contains("connection refused")
            || lower.contains("connection reset")
            || lower.contains("broken pipe") {
            return .connectionRefused
        }
        if lower.contains("tls")
            || lower.contains("eof")
            || lower.contains("handshake")
            || lower.contains("certificate")
            || lower.contains("bad record mac")
            || lower.contains("trojan")
            || lower.contains("vmess")
            || lower.contains("vless")
            || lower.contains("shadowsocks")
            || lower.contains("hysteria") {
            return .tlsOrProtocol
        }
        if lower.contains("no such host")
            || lower.contains("lookup ")
            || lower.contains("dns") {
            return .dnsFailure
        }
        if lower.contains("reject") {
            return .rejected
        }
        return .other
    }

    private static func inferSuspectedHop(
        primaryTarget: String,
        outboundGroup: String,
        reason: String,
        category: OutboundFailureCategory
    ) -> TopologyHopKind? {
        if category == .interfaceOrRoute {
            return .interface
        }
        if outboundGroup.hasSuffix(relaySuffix) || reason.lowercased().contains("dialer-proxy") {
            return .relay
        }
        return nil
    }

    private static func simplifyReason(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lastColon = text.range(of: ": ", options: .backwards) {
            let suffix = String(text[lastColon.upperBound...]).trimmingCharacters(in: .whitespaces)
            // Keep meaningful tail while preserving context if suffix is too terse like "EOF"
            if suffix.count >= 10 && text.count > 56 {
                text = suffix
            }
        }
        return text
    }

    private static func extractStructuredLogLine(_ line: String) -> (timestamp: Date?, level: String?, msg: String)? {
        guard let msgRange = line.range(of: "msg=\"") else { return nil }
        let afterMsg = line[msgRange.upperBound...]
        guard let endQuote = afterMsg.lastIndex(of: "\"") else { return nil }
        let rawMsg = String(afterMsg[..<endQuote])
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: " ")

        var parsedTime: Date? = nil
        if let timeRange = line.range(of: "time=\"") {
            let afterTime = line[timeRange.upperBound...]
            if let timeEnd = afterTime.firstIndex(of: "\"") {
                parsedTime = ConnectionTracker.parseISO8601(String(afterTime[..<timeEnd]))
            }
        }

        var parsedLevel: String? = nil
        if let levelRange = line.range(of: "level=") {
            let afterLevel = line[levelRange.upperBound...]
            let endIdx = afterLevel.firstIndex(where: \.isWhitespace) ?? afterLevel.endIndex
            parsedLevel = String(afterLevel[..<endIdx]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        return (parsedTime, parsedLevel, rawMsg)
    }
}

// MARK: - Outbound Error Tracker

public struct OutboundErrorTracker: Equatable, Sendable {
    public private(set) var records: [OutboundErrorRecord] = []
    public let maxRecords: Int

    public init(maxRecords: Int = 300) {
        self.maxRecords = max(20, maxRecords)
    }

    public mutating func appendBatch(_ batch: [OutboundErrorRecord]) {
        guard !batch.isEmpty else { return }
        records.insert(contentsOf: batch.reversed(), at: 0)
        if records.count > maxRecords {
            records.removeLast(records.count - maxRecords)
        }
    }

    public mutating func replaceAll(_ newRecords: [OutboundErrorRecord]) {
        if newRecords.count > maxRecords {
            records = Array(newRecords.prefix(maxRecords))
        } else {
            records = newRecords
        }
    }

    public mutating func clear() {
        records.removeAll()
    }

    public mutating func clearTarget(_ targetName: String) {
        let relayName = MihomoConfig.relayGroupName(for: targetName)
        records.removeAll { $0.primaryTarget == targetName || $0.outboundGroup == relayName }
    }

    public func recentErrors(
        forTarget targetName: String,
        within windowSeconds: TimeInterval = 180,
        after cutoffDate: Date? = nil,
        now: Date = Date()
    ) -> [OutboundErrorRecord] {
        let relayName = MihomoConfig.relayGroupName(for: targetName)
        let earliest = now.addingTimeInterval(-windowSeconds)
        return records.filter { item in
            guard item.primaryTarget == targetName || item.outboundGroup == relayName else { return false }
            guard item.timestamp >= earliest else { return false }
            if let cutoffDate, item.timestamp <= cutoffDate { return false }
            return true
        }
    }
}

// MARK: - Topology & Per-Hop Health Models

public enum TopologyHealthState: String, Equatable, Comparable, Sendable {
    case idle
    case healthy
    case warning
    case error

    private var severityOrder: Int {
        switch self {
        case .idle: return 0
        case .healthy: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: TopologyHealthState, rhs: TopologyHealthState) -> Bool {
        lhs.severityOrder < rhs.severityOrder
    }
}

public struct ProxyGroupHealthSnapshot: Equatable, Sendable {
    public let name: String
    public let type: String
    public let now: String
    public let all: [String]
    public let delays: [String: Int]
    public let timedOutNodes: Set<String>
    public let isTesting: Bool
    public let lastVerifiedHealthyAt: Date?

    public init(
        name: String,
        type: String,
        now: String,
        all: [String],
        delays: [String: Int],
        timedOutNodes: Set<String> = [],
        isTesting: Bool = false,
        lastVerifiedHealthyAt: Date? = nil
    ) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
        self.delays = delays
        self.timedOutNodes = timedOutNodes
        self.isTesting = isTesting
        self.lastVerifiedHealthyAt = lastVerifiedHealthyAt
    }

    public var isAutoTest: Bool {
        let lower = type.lowercased()
        return lower == "urltest" || lower == "fallback" || lower == "load-balance"
    }

    public var isRejectFallbackOnly: Bool {
        all == ["REJECT"]
    }

    public var currentDelay: Int? {
        guard !now.isEmpty else { return nil }
        return delays[now]
    }

    public var isCurrentTimedOut: Bool {
        guard !now.isEmpty else { return false }
        return timedOutNodes.contains(now)
    }
}

public enum BrokenHopFailureKind: Equatable, Sendable {
    case interfaceOffline(bsdName: String, displayLabel: String)
    case emptyNodeGroup(hop: TopologyHopKind, groupName: String)
    case relayHopFailed(groupName: String, nodeName: String, reason: String)
    case exitHopFailed(groupName: String, nodeName: String, relayHealthyLatencyMs: Int?, reason: String)
    case proxyDoHFailed(upstream: String, failedCount: Int, reason: String)
    case silentZeroByteDrops(count: Int)
}

public struct BrokenHopDiagnosis: Equatable, Sendable {
    public let severity: TopologyHealthState
    public let brokenHop: TopologyHopKind?
    public let kind: BrokenHopFailureKind
    public let headline: String
    public let detail: String
    public let failureCount: Int

    public init(
        severity: TopologyHealthState,
        brokenHop: TopologyHopKind?,
        kind: BrokenHopFailureKind,
        headline: String,
        detail: String,
        failureCount: Int = 0
    ) {
        self.severity = severity
        self.brokenHop = brokenHop
        self.kind = kind
        self.headline = headline
        self.detail = detail
        self.failureCount = failureCount
    }
}

public struct TopologyRuleBranch: Identifiable, Equatable, Sendable {
    public let id: String
    public let rank: Int
    public let name: String
    public let icon: String
    public let isFallbackMatch: Bool
    public let aliasChain: [String]
    public let targetKey: String
    public let enabledRuleCount: Int
    public let activeConnectionCount: Int
    public let uploadSpeed: Int64
    public let downloadSpeed: Int64
    public let sessionBytes: Int64
    public let recentErrorCount: Int

    public var totalSpeed: Int64 { uploadSpeed + downloadSpeed }
    public var hasTraffic: Bool { activeConnectionCount > 0 || totalSpeed > 0 || sessionBytes > 0 }
}

public struct TopologyHopNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: TopologyHopKind
    public let roleLabel: String
    public let title: String
    public let groupName: String?
    public let candidateNodes: [String]
    public let nodeDelays: [String: Int]
    public let timedOutNodes: Set<String>
    public let selectedRawNode: String?
    public let latencyMs: Int?
    public let isTimedOut: Bool
    public let isAutoTest: Bool
    public let isTesting: Bool
    public let health: TopologyHealthState
    public let statusText: String
}

public struct TopologyTargetLane: Identifiable, Equatable, Sendable {
    public let id: String
    public let targetID: UUID?
    public let name: String
    public let mode: NetworkTargetMode?
    public let isRejectBuiltin: Bool
    public let hasRelayHop: Bool
    public let relayGroupName: String?
    public let aliasReferrers: [String]
    public let branches: [TopologyRuleBranch]
    public let hops: [TopologyHopNode]
    public let activeConnectionCount: Int
    public let uploadSpeed: Int64
    public let downloadSpeed: Int64
    public let sessionUpload: Int64
    public let sessionDownload: Int64
    public let zeroByteClosedCount: Int
    public let health: TopologyHealthState
    public let diagnosis: BrokenHopDiagnosis?
    public let recentErrors: [OutboundErrorRecord]
    public let recentDNSFailures: [DNSLogRecord]

    public var totalSpeed: Int64 { uploadSpeed + downloadSpeed }
    public var sessionTotal: Int64 { sessionUpload + sessionDownload }
    public var affectedBranchNames: [String] { branches.map(\.name) }
}

public struct TopologySnapshot: Equatable, Sendable {
    public let isCoreRunning: Bool
    public let totalUploadSpeed: Int64
    public let totalDownloadSpeed: Int64
    public let totalActiveConnections: Int
    public let lanes: [TopologyTargetLane]

    public var issueLanes: [TopologyTargetLane] {
        lanes.filter { $0.health == .error || $0.health == .warning }
            .sorted { lhs, rhs in
                if lhs.health != rhs.health { return lhs.health > rhs.health }
                return lhs.totalSpeed > rhs.totalSpeed
            }
    }

    public var errorCount: Int {
        lanes.filter { $0.health == .error }.count
    }

    public var warningCount: Int {
        lanes.filter { $0.health == .warning }.count
    }
}

// MARK: - Topology Snapshot Builder

public enum TopologySnapshotBuilder {
    public static let fallbackBranchID = "__match__"
    public static let rejectLaneID = "__reject__"

    public static func build(
        profile: RoutingProfile,
        isCoreRunning: Bool,
        activeInterfaceNames: Set<String>,
        interfaceLabels: [String: String],
        groupStatuses: [String: ProxyGroupHealthSnapshot],
        tracker: ConnectionTracker,
        dnsRecords: [DNSLogRecord],
        outboundErrorTracker: OutboundErrorTracker,
        ruleIndex: RuleMatchDisplayIndex? = nil,
        now: Date = Date()
    ) -> TopologySnapshot {
        let resolvedRuleIndex = ruleIndex ?? RuleMatchDisplayIndex(profile: profile)

        // 1. Attribute live connections & recent errors to rule groups (`branchID`) and concrete target names (`targetKey`)
        var branchActiveCount: [String: Int] = [:]
        var branchUpSpeed: [String: Int64] = [:]
        var branchDownSpeed: [String: Int64] = [:]
        var branchSessionBytes: [String: Int64] = [:]
        var targetActiveCount: [String: Int] = [:]
        var targetZeroResponseCount: [String: Int] = [:]

        var groupIDByName: [String: String] = [:]
        for group in profile.ruleGroups where group.isEnabled {
            groupIDByName[group.name] = group.id.uuidString
        }

        let useSessionRuleTotals = !tracker.sessionRuleTotals.isEmpty
        if useSessionRuleTotals {
            for (compositeKey, bytes) in tracker.sessionRuleTotals where bytes.total > 0 {
                let parts = ConnectionTracker.splitRuleSessionKey(compositeKey)
                let branchID: String = {
                    if parts.rule.lowercased() == "match" {
                        return fallbackBranchID
                    }
                    if let gName = resolvedRuleIndex.resolve(rule: parts.rule, payload: parts.payload)?.groupName,
                       let gid = groupIDByName[gName] {
                        return gid
                    }
                    return fallbackBranchID
                }()
                branchSessionBytes[branchID, default: 0] += bytes.total
            }
        }

        let recentWindowCutoff = now.addingTimeInterval(-60)
        for conn in tracker.allRecords where !conn.isInner {
            let targetKey = conn.isRejected ? rejectLaneID : conn.primaryTarget
            let matchedInfo = resolvedRuleIndex.resolve(rule: conn.rule, payload: conn.rulePayload)
            let branchID: String = {
                if conn.rule.lowercased() == "match" {
                    return fallbackBranchID
                }
                if let gName = matchedInfo?.groupName, let gid = groupIDByName[gName] {
                    return gid
                }
                return fallbackBranchID
            }()

            if !useSessionRuleTotals {
                branchSessionBytes[branchID, default: 0] += conn.totalBytes
            }
            if conn.isActive {
                targetActiveCount[targetKey, default: 0] += 1
                branchActiveCount[branchID, default: 0] += 1
                branchUpSpeed[branchID, default: 0] += conn.uploadSpeed
                branchDownSpeed[branchID, default: 0] += conn.downloadSpeed
            } else if !conn.isDirect && !conn.isRejected,
                      let closedAt = conn.closedAt,
                      closedAt >= recentWindowCutoff,
                      conn.upload > 0 && conn.download == 0 {
                targetZeroResponseCount[targetKey, default: 0] += 1
            }
        }

        // Count recent outbound errors per branch
        var branchErrorCount: [String: Int] = [:]
        let recentCutoff = now.addingTimeInterval(-180)
        for err in outboundErrorTracker.records where err.timestamp >= recentCutoff {
            if let rType = err.matchedRuleType {
                if rType.lowercased() == "match" {
                    branchErrorCount[fallbackBranchID, default: 0] += 1
                } else if let info = resolvedRuleIndex.resolve(rule: rType, payload: err.matchedRulePayload ?? ""),
                          let gid = groupIDByName[info.groupName] {
                    branchErrorCount[gid, default: 0] += 1
                }
            }
        }

        // 2. Build Rule Branches and resolve each to its concrete target lane key
        var orderedTargetKeys: [String] = []
        var targetByKey: [String: NetworkTarget] = [:]
        var branchesByTargetKey: [String: [TopologyRuleBranch]] = [:]

        func registerConcreteTarget(_ target: NetworkTarget) -> String {
            let key = target.name
            if targetByKey[key] == nil {
                targetByKey[key] = target
                orderedTargetKeys.append(key)
            }
            return key
        }

        func resolveReference(_ ref: TargetReference) -> (targetKey: String, aliasNames: [String]) {
            switch ref {
            case .reject:
                if !orderedTargetKeys.contains(rejectLaneID) {
                    orderedTargetKeys.append(rejectLaneID)
                }
                return (rejectLaneID, [])
            case .target(let id):
                switch profile.resolveTarget(id: id) {
                case .resolved(let leaf, let path):
                    let aliases = path.dropLast().map(\.name)
                    let key = registerConcreteTarget(leaf)
                    return (key, aliases)
                case .missingTarget(let src, let path):
                    let key = registerConcreteTarget(src)
                    return (key, path.dropLast().map(\.name))
                case .cycle(let path):
                    if let first = path.first {
                        let key = registerConcreteTarget(first)
                        return (key, [])
                    }
                    return (rejectLaneID, [])
                case .notFound:
                    if !orderedTargetKeys.contains(rejectLaneID) {
                        orderedTargetKeys.append(rejectLaneID)
                    }
                    return (rejectLaneID, [])
                }
            }
        }

        var rank = 1
        for group in profile.ruleGroups where group.isEffectivelyActive {
            let resolved = resolveReference(group.target)
            let gid = group.id.uuidString
            let branch = TopologyRuleBranch(
                id: gid,
                rank: rank,
                name: group.name,
                icon: group.icon,
                isFallbackMatch: false,
                aliasChain: resolved.aliasNames,
                targetKey: resolved.targetKey,
                enabledRuleCount: group.rules.filter(\.isEnabled).count,
                activeConnectionCount: branchActiveCount[gid] ?? 0,
                uploadSpeed: branchUpSpeed[gid] ?? 0,
                downloadSpeed: branchDownSpeed[gid] ?? 0,
                sessionBytes: branchSessionBytes[gid] ?? 0,
                recentErrorCount: branchErrorCount[gid] ?? 0
            )
            branchesByTargetKey[resolved.targetKey, default: []].append(branch)
            rank += 1
        }

        let resolvedFallback = resolveReference(profile.fallbackTarget)
        let fallbackBranch = TopologyRuleBranch(
            id: fallbackBranchID,
            rank: rank,
            name: "默认兜底 (MATCH)",
            icon: "tray.full",
            isFallbackMatch: true,
            aliasChain: resolvedFallback.aliasNames,
            targetKey: resolvedFallback.targetKey,
            enabledRuleCount: 1,
            activeConnectionCount: branchActiveCount[fallbackBranchID] ?? 0,
            uploadSpeed: branchUpSpeed[fallbackBranchID] ?? 0,
            downloadSpeed: branchDownSpeed[fallbackBranchID] ?? 0,
            sessionBytes: branchSessionBytes[fallbackBranchID] ?? 0,
            recentErrorCount: branchErrorCount[fallbackBranchID] ?? 0
        )
        branchesByTargetKey[resolvedFallback.targetKey, default: []].append(fallbackBranch)

        // Include any additional active concrete targets referenced by custom DNS or rule-provider downloads
        for activeID in profile.activeTargetIDs {
            if let t = profile.target(id: activeID), t.mode != .alias {
                _ = registerConcreteTarget(t)
            }
        }

        // 3. Build each Target Lane with Hop-by-Hop Health & Diagnosis
        var lanes: [TopologyTargetLane] = []
        for key in orderedTargetKeys {
            let branches = branchesByTargetKey[key] ?? []
            if key == rejectLaneID {
                let speed = tracker.liveSpeed(for: "REJECT")
                let session = tracker.sessionTraffic(for: "REJECT")
                let activeConns = targetActiveCount[rejectLaneID] ?? 0
                lanes.append(
                    TopologyTargetLane(
                        id: rejectLaneID,
                        targetID: nil,
                        name: "拦截 (REJECT)",
                        mode: nil,
                        isRejectBuiltin: true,
                        hasRelayHop: false,
                        relayGroupName: nil,
                        aliasReferrers: [],
                        branches: branches,
                        hops: [
                            TopologyHopNode(
                                id: "\(rejectLaneID)-exit",
                                kind: .exit,
                                roleLabel: "动作",
                                title: "阻断连接 (REJECT)",
                                groupName: nil,
                                candidateNodes: [],
                                nodeDelays: [:],
                                timedOutNodes: [],
                                selectedRawNode: nil,
                                latencyMs: nil,
                                isTimedOut: false,
                                isAutoTest: false,
                                isTesting: false,
                                health: .idle,
                                statusText: activeConns > 0 ? "已拦截" : "就绪"
                            )
                        ],
                        activeConnectionCount: activeConns,
                        uploadSpeed: speed.upload,
                        downloadSpeed: speed.download,
                        sessionUpload: session.upload,
                        sessionDownload: session.download,
                        zeroByteClosedCount: 0,
                        health: .idle,
                        diagnosis: nil,
                        recentErrors: [],
                        recentDNSFailures: []
                    )
                )
                continue
            }

            guard let target = targetByKey[key] else { continue }
            let lane = buildConcreteTargetLane(
                target: target,
                profile: profile,
                branches: branches,
                isCoreRunning: isCoreRunning,
                activeInterfaceNames: activeInterfaceNames,
                interfaceLabels: interfaceLabels,
                groupStatuses: groupStatuses,
                tracker: tracker,
                activeConnCount: targetActiveCount[target.name] ?? 0,
                zeroByteCount: targetZeroResponseCount[target.name] ?? 0,
                dnsRecords: dnsRecords,
                outboundErrorTracker: outboundErrorTracker,
                now: now
            )
            lanes.append(lane)
        }

        return TopologySnapshot(
            isCoreRunning: isCoreRunning,
            totalUploadSpeed: tracker.uploadSpeed,
            totalDownloadSpeed: tracker.downloadSpeed,
            totalActiveConnections: tracker.businessActiveCount,
            lanes: lanes
        )
    }

    private static func buildConcreteTargetLane(
        target: NetworkTarget,
        profile: RoutingProfile,
        branches: [TopologyRuleBranch],
        isCoreRunning: Bool,
        activeInterfaceNames: Set<String>,
        interfaceLabels: [String: String],
        groupStatuses: [String: ProxyGroupHealthSnapshot],
        tracker: ConnectionTracker,
        activeConnCount: Int,
        zeroByteCount: Int,
        dnsRecords: [DNSLogRecord],
        outboundErrorTracker: OutboundErrorTracker,
        now: Date
    ) -> TopologyTargetLane {
        let targetName = target.name
        let speed = tracker.liveSpeed(for: targetName)
        let session = tracker.sessionTraffic(for: targetName)
        let aliasReferrers = profile.aliasReferrers(of: target.id).map(\.name)

        // Bound physical interface check
        let boundBSD = target.normalizedInterface
        let ifaceDisplay: String = {
            guard let bsd = boundBSD else { return "系统默认网卡" }
            return interfaceLabels[bsd] ?? bsd
        }()
        let isInterfaceOffline: Bool = {
            guard let bsd = boundBSD else { return false }
            // Only flag offline when interface list has been populated
            guard !activeInterfaceNames.isEmpty else { return false }
            return !activeInterfaceNames.contains(bsd)
        }()

        // Recent outbound errors (filtered after any verified-healthy timestamp)
        let relayGroupName = target.mode == .proxy && target.relayGroupID != nil
            ? MihomoConfig.relayGroupName(for: targetName)
            : nil
        let exitSnapshot = groupStatuses[targetName]
        let relaySnapshot = relayGroupName.flatMap { groupStatuses[$0] }

        let verifiedCutoff: Date? = {
            switch (relaySnapshot?.lastVerifiedHealthyAt, exitSnapshot?.lastVerifiedHealthyAt) {
            case let (.some(r), .some(e)):
                return min(r, e)
            case let (nil, .some(e)) where relayGroupName == nil:
                return e
            default:
                return nil
            }
        }()

        let recentErrors = isCoreRunning
            ? outboundErrorTracker.recentErrors(forTarget: targetName, within: 180, after: verifiedCutoff, now: now)
            : []

        // Recent DNS failures explicitly routed through `#<targetName>`
        let dnsSuffix = "#\(targetName)".lowercased()
        let dnsCutoff = now.addingTimeInterval(-180)
        let recentDNSFailures = isCoreRunning
            ? dnsRecords.filter { rec in
                rec.status == .failed
                    && rec.timestamp >= dnsCutoff
                    && (rec.upstream.lowercased().hasSuffix(dnsSuffix) || rec.rawPayload.lowercased().contains(dnsSuffix))
            }
            : []

        // Build Direct Target Lane
        if target.mode == .direct {
            let routeErrors = recentErrors.filter { $0.category == .interfaceOrRoute }
            let ifaceHealth: TopologyHealthState = isInterfaceOffline
                ? .error
                : (!routeErrors.isEmpty ? .error : (isCoreRunning ? .healthy : .idle))

            var diagnosis: BrokenHopDiagnosis? = nil
            if isInterfaceOffline, let bsd = boundBSD {
                diagnosis = BrokenHopDiagnosis(
                    severity: .error,
                    brokenHop: .interface,
                    kind: .interfaceOffline(bsdName: bsd, displayLabel: ifaceDisplay),
                    headline: "绑定网卡「\(ifaceDisplay)」未就绪",
                    detail: "网卡 \(bsd) 当前未连接或未分配有效 IPv4 地址，直连请求无法从该接口发出。"
                )
            } else if let firstErr = routeErrors.first {
                diagnosis = BrokenHopDiagnosis(
                    severity: .error,
                    brokenHop: .interface,
                    kind: .interfaceOffline(bsdName: boundBSD ?? "default", displayLabel: ifaceDisplay),
                    headline: "直连网卡路由异常",
                    detail: firstErr.conciseReason,
                    failureCount: routeErrors.count
                )
            }

            let directHop = TopologyHopNode(
                id: "\(target.id.uuidString)-exit",
                kind: .exit,
                roleLabel: "直连",
                title: "本地直连出站",
                groupName: nil,
                candidateNodes: [],
                nodeDelays: [:],
                timedOutNodes: [],
                selectedRawNode: nil,
                latencyMs: nil,
                isTimedOut: false,
                isAutoTest: false,
                isTesting: false,
                health: isCoreRunning ? (diagnosis == nil ? .healthy : .warning) : .idle,
                statusText: speed.total > 0 ? "传输中" : (isCoreRunning ? "正常" : "未运行")
            )
            let ifaceHop = TopologyHopNode(
                id: "\(target.id.uuidString)-iface",
                kind: .interface,
                roleLabel: "网卡",
                title: ifaceDisplay,
                groupName: nil,
                candidateNodes: [],
                nodeDelays: [:],
                timedOutNodes: [],
                selectedRawNode: nil,
                latencyMs: nil,
                isTimedOut: isInterfaceOffline,
                isAutoTest: false,
                isTesting: false,
                health: ifaceHealth,
                statusText: isInterfaceOffline ? "未连接" : (boundBSD ?? "默认路由")
            )

            return TopologyTargetLane(
                id: targetName,
                targetID: target.id,
                name: targetName,
                mode: .direct,
                isRejectBuiltin: false,
                hasRelayHop: false,
                relayGroupName: nil,
                aliasReferrers: aliasReferrers,
                branches: branches,
                hops: [directHop, ifaceHop],
                activeConnectionCount: activeConnCount,
                uploadSpeed: speed.upload,
                downloadSpeed: speed.download,
                sessionUpload: session.upload,
                sessionDownload: session.download,
                zeroByteClosedCount: 0,
                health: diagnosis?.severity ?? (isCoreRunning ? .healthy : .idle),
                diagnosis: diagnosis,
                recentErrors: recentErrors,
                recentDNSFailures: recentDNSFailures
            )
        }

        // Build Proxy Target Lane (Single-Hop or Chained Relay -> Exit -> Interface)
        let configuredRelayGroup = profile.nodeGroup(id: target.relayGroupID)
        let configuredExitGroup = profile.nodeGroup(id: target.exitGroupID)

        // Evaluate Relay Hop (Hop 1 when chained)
        var relayHopNode: TopologyHopNode? = nil
        var relayFailedReason: String? = nil
        var relayIsRejectEmpty = false
        let relayLatency = relaySnapshot?.currentDelay

        if let rGroupName = relayGroupName {
            let rNow = relaySnapshot?.now ?? ""
            let rTimedOut = relaySnapshot?.isCurrentTimedOut ?? false
            relayIsRejectEmpty = relaySnapshot?.isRejectFallbackOnly ?? false
            let relaySpecificErrors = recentErrors.filter {
                if let verifiedAt = relaySnapshot?.lastVerifiedHealthyAt, $0.timestamp <= verifiedAt {
                    return false
                }
                return $0.suspectedHop == .relay || $0.outboundGroup == rGroupName
            }

            let rHealth: TopologyHealthState
            let rStatusText: String
            if !isCoreRunning {
                rHealth = .idle
                rStatusText = configuredRelayGroup?.name ?? "链式待启动"
            } else if isInterfaceOffline {
                rHealth = .warning
                rStatusText = "受制于网卡离线"
            } else if relayIsRejectEmpty {
                rHealth = .error
                rStatusText = "无匹配节点 (REJECT)"
                relayFailedReason = "未匹配到可用链式节点"
            } else if rTimedOut {
                rHealth = .error
                let errDetail = relaySpecificErrors.first?.conciseReason ?? "测速连接超时"
                rStatusText = "✕ 超时不可达"
                relayFailedReason = errDetail
            } else if let firstRelayErr = relaySpecificErrors.first {
                rHealth = .error
                rStatusText = "✕ 拨号失败"
                relayFailedReason = firstRelayErr.conciseReason
            } else if let ms = relayLatency {
                rHealth = ms >= 600 ? .warning : .healthy
                rStatusText = "\(ms) ms"
            } else {
                rHealth = .healthy
                rStatusText = rNow.isEmpty ? "待选路" : "就绪"
            }

            let displayRelayTitle: String = {
                if !isCoreRunning {
                    return configuredRelayGroup?.name ?? rGroupName
                }
                if relayIsRejectEmpty { return "无可用链式节点" }
                if !rNow.isEmpty { return rNow }
                return configuredRelayGroup?.name ?? rGroupName
            }()

            relayHopNode = TopologyHopNode(
                id: "\(target.id.uuidString)-relay",
                kind: .relay,
                roleLabel: "第一跳 · 链式",
                title: displayRelayTitle,
                groupName: rGroupName,
                candidateNodes: relaySnapshot?.all ?? [],
                nodeDelays: relaySnapshot?.delays ?? [:],
                timedOutNodes: relaySnapshot?.timedOutNodes ?? [],
                selectedRawNode: rNow.isEmpty ? nil : rNow,
                latencyMs: relayLatency,
                isTimedOut: rTimedOut,
                isAutoTest: relaySnapshot?.isAutoTest ?? (configuredRelayGroup?.autoTest ?? false),
                isTesting: relaySnapshot?.isTesting ?? false,
                health: rHealth,
                statusText: rStatusText
            )
        }

        // Evaluate Exit Hop (Hop 2 when chained, Hop 1 when single-hop)
        let eNow = exitSnapshot?.now ?? ""
        let compactExitNow = stripTargetNodePrefix(eNow, targetName: targetName)
        let eTimedOut = exitSnapshot?.isCurrentTimedOut ?? false
        let exitIsRejectEmpty = exitSnapshot?.isRejectFallbackOnly ?? false
        let exitLatency = exitSnapshot?.currentDelay
        let exitSpecificErrors = recentErrors.filter {
            if let verifiedAt = exitSnapshot?.lastVerifiedHealthyAt, $0.timestamp <= verifiedAt {
                return false
            }
            return $0.suspectedHop != .relay && $0.suspectedHop != .interface
        }

        var exitFailedReason: String? = nil
        let exitHealth: TopologyHealthState
        let exitStatusText: String

        if !isCoreRunning {
            exitHealth = .idle
            exitStatusText = configuredExitGroup?.name ?? "出口待启动"
        } else if isInterfaceOffline {
            exitHealth = .warning
            exitStatusText = "等待网卡恢复"
        } else if exitIsRejectEmpty {
            exitHealth = .error
            exitStatusText = "无匹配节点 (REJECT)"
            exitFailedReason = "未匹配到可用出口节点"
        } else if relayFailedReason != nil {
            // Upstream relay hop is already confirmed dead; exit cannot reach network through a broken tunnel!
            exitHealth = .warning
            exitStatusText = "受阻于第一跳中断"
        } else if eTimedOut {
            exitHealth = .error
            let errDetail = exitSpecificErrors.first?.conciseReason ?? "隧道握手/测速超时"
            exitStatusText = "✕ 超时不可达"
            exitFailedReason = errDetail
        } else if let firstExitErr = exitSpecificErrors.first {
            exitHealth = .error
            exitStatusText = "✕ 拨号失败"
            exitFailedReason = firstExitErr.conciseReason
        } else if let ms = exitLatency {
            exitHealth = ms >= 800 ? .warning : .healthy
            exitStatusText = "\(ms) ms"
        } else {
            exitHealth = .healthy
            exitStatusText = compactExitNow.isEmpty ? "待选路" : "就绪"
        }

        let displayExitTitle: String = {
            if !isCoreRunning {
                return configuredExitGroup?.name ?? targetName
            }
            if exitIsRejectEmpty { return "无可用出口节点" }
            if !compactExitNow.isEmpty { return compactExitNow }
            return configuredExitGroup?.name ?? targetName
        }()

        let exitHopNode = TopologyHopNode(
            id: "\(target.id.uuidString)-exit",
            kind: .exit,
            roleLabel: relayGroupName != nil ? "第二跳 · 出口" : "代理出口",
            title: displayExitTitle,
            groupName: targetName,
            candidateNodes: exitSnapshot?.all ?? [],
            nodeDelays: exitSnapshot?.delays ?? [:],
            timedOutNodes: exitSnapshot?.timedOutNodes ?? [],
            selectedRawNode: eNow.isEmpty ? nil : eNow,
            latencyMs: exitLatency,
            isTimedOut: eTimedOut,
            isAutoTest: exitSnapshot?.isAutoTest ?? (configuredExitGroup?.autoTest ?? true),
            isTesting: exitSnapshot?.isTesting ?? false,
            health: exitHealth,
            statusText: exitStatusText
        )

        let ifaceRouteErrors = recentErrors.filter { $0.category == .interfaceOrRoute }
        let ifaceHealth: TopologyHealthState = isInterfaceOffline || !ifaceRouteErrors.isEmpty
            ? .error
            : (isCoreRunning ? .healthy : .idle)
        let ifaceHopNode = TopologyHopNode(
            id: "\(target.id.uuidString)-iface",
            kind: .interface,
            roleLabel: "物理网卡",
            title: ifaceDisplay,
            groupName: nil,
            candidateNodes: [],
            nodeDelays: [:],
            timedOutNodes: [],
            selectedRawNode: nil,
            latencyMs: nil,
            isTimedOut: isInterfaceOffline,
            isAutoTest: false,
            isTesting: false,
            health: ifaceHealth,
            statusText: isInterfaceOffline ? "✕ 网卡离线" : (boundBSD ?? "默认路由")
        )

        // Assemble Hops in actual network traversal order from RouteWeaver out to the Internet:
        // Wait: in RouteWeaver's ChainFlowBadge (`AppState.targetChainPreview`), let's be super clear!
        // For network packets leaving Mihomo:
        // Traffic enters Target -> if chained, dials Relay Hop (via NIC) -> tunnels to Exit Hop -> Target Website!
        // Displaying `[物理网卡] -> [第一跳 · 链式] -> [第二跳 · 出口]` OR `[第一跳 · 链式] -> [第二跳 · 出口] -> [出口网卡]`?
        // Look at our approved HTML preview in Panel C (`美国 -> 美国·链式 -> 美国出口`, `香港 -> 香港出口 -> 默认网卡`):
        // Putting `链式 (Hop 1) -> 出口 (Hop 2) -> 物理网卡` (or when interface is offline marking interface) matches BOTH our HTML preview AND `ChainFlowBadge` familiarity while keeping Hop 1 -> Hop 2 in strict traversal order!
        var hops: [TopologyHopNode] = []
        if let relayHopNode {
            hops.append(relayHopNode)
        }
        hops.append(exitHopNode)
        hops.append(ifaceHopNode)

        // Synthesize primary root-cause BrokenHopDiagnosis
        let diagnosis: BrokenHopDiagnosis? = {
            guard isCoreRunning else { return nil }

            if isInterfaceOffline, let bsd = boundBSD {
                return BrokenHopDiagnosis(
                    severity: .error,
                    brokenHop: .interface,
                    kind: .interfaceOffline(bsdName: bsd, displayLabel: ifaceDisplay),
                    headline: "物理网卡「\(ifaceDisplay)」未连接",
                    detail: "目标「\(targetName)」绑定的网卡 \(bsd) 离线或无 IPv4 地址，整条代理链路无法出站。"
                )
            }
            if let firstRouteErr = ifaceRouteErrors.first {
                return BrokenHopDiagnosis(
                    severity: .error,
                    brokenHop: .interface,
                    kind: .interfaceOffline(bsdName: boundBSD ?? "default", displayLabel: ifaceDisplay),
                    headline: "本机出站路由不可达",
                    detail: firstRouteErr.conciseReason,
                    failureCount: ifaceRouteErrors.count
                )
            }
            if relayIsRejectEmpty, let rGroupName = relayGroupName {
                return BrokenHopDiagnosis(
                    severity: .error,
                    brokenHop: .relay,
                    kind: .emptyNodeGroup(hop: .relay, groupName: rGroupName),
                    headline: "第一跳链式组无可用节点",
                    detail: "「\(rGroupName)」未匹配到任何节点（当前回退 REJECT），请检查链式订阅拉取或正则过滤。"
                )
            }
            if exitIsRejectEmpty {
                return BrokenHopDiagnosis(
                    severity: .error,
                    brokenHop: .exit,
                    kind: .emptyNodeGroup(hop: .exit, groupName: targetName),
                    headline: "出口节点组无可用节点",
                    detail: "「\(targetName)」未匹配到任何节点（当前回退 REJECT），请检查出口订阅拉取或正则过滤。"
                )
            }
            if let rReason = relayFailedReason, let rGroupName = relayGroupName {
                let nodeLabel = relayHopNode?.title ?? rGroupName
                let dnsNote = recentDNSFailures.isEmpty ? "" : "（同时导致 \(recentDNSFailures.count) 次防泄漏 DoH 解析连带失败）"
                return BrokenHopDiagnosis(
                    severity: .error,
                    brokenHop: .relay,
                    kind: .relayHopFailed(groupName: rGroupName, nodeName: nodeLabel, reason: rReason),
                    headline: "第一跳「链式节点」连接中断",
                    detail: "链式入口「\(nodeLabel)」无法连通：\(rReason)\(dnsNote)。",
                    failureCount: recentErrors.count
                )
            }
            if let eReason = exitFailedReason {
                let nodeLabel = exitHopNode.title
                let dnsNote = recentDNSFailures.isEmpty ? "" : "（并引发 \(recentDNSFailures.count) 次代理 DoH 解析失败）"
                if relayGroupName != nil {
                    let relayBadge = relayLatency.map { "（\(relayHopNode?.title ?? "链式") \($0) ms 正常）" }
                        ?? "（链式第一跳未报错）"
                    return BrokenHopDiagnosis(
                        severity: .error,
                        brokenHop: .exit,
                        kind: .exitHopFailed(
                            groupName: targetName,
                            nodeName: nodeLabel,
                            relayHealthyLatencyMs: relayLatency,
                            reason: eReason
                        ),
                        headline: "第二跳「链式 → 出口」连接中断",
                        detail: "第一跳链式入口连通\(relayBadge)，但落地出口「\(nodeLabel)」失败：\(eReason)\(dnsNote)。",
                        failureCount: recentErrors.count
                    )
                } else {
                    return BrokenHopDiagnosis(
                        severity: .error,
                        brokenHop: .exit,
                        kind: .exitHopFailed(
                            groupName: targetName,
                            nodeName: nodeLabel,
                            relayHealthyLatencyMs: nil,
                            reason: eReason
                        ),
                        headline: "代理出口节点连接中断",
                        detail: "出口节点「\(nodeLabel)」异常：\(eReason)\(dnsNote)。",
                        failureCount: recentErrors.count
                    )
                }
            }
            if recentDNSFailures.count >= 2, let latestDNS = recentDNSFailures.first {
                return BrokenHopDiagnosis(
                    severity: .warning,
                    brokenHop: .exit,
                    kind: .proxyDoHFailed(
                        upstream: latestDNS.upstream,
                        failedCount: recentDNSFailures.count,
                        reason: latestDNS.answerSummary
                    ),
                    headline: "经由「\(targetName)」的代理 DoH 解析异常",
                    detail: "近 3 分钟有 \(recentDNSFailures.count) 次海外 DNS 查询失败（\(latestDNS.answerSummary)），建议点击双跳测速确认代理连通性。",
                    failureCount: recentDNSFailures.count
                )
            }
            if zeroByteCount >= 2 && speed.download == 0 {
                return BrokenHopDiagnosis(
                    severity: .warning,
                    brokenHop: .exit,
                    kind: .silentZeroByteDrops(count: zeroByteCount),
                    headline: "疑似隧道静默黑洞（请求发出无回包）",
                    detail: "近 1 分钟有 \(zeroByteCount) 条连接发送请求后收到 0 字节响应即关闭，常见于链式隧道协议不兼容或出口节点假死。",
                    failureCount: zeroByteCount
                )
            }
            return nil
        }()

        let laneHealth: TopologyHealthState = {
            if let diagnosis { return diagnosis.severity }
            if !isCoreRunning { return .idle }
            if hops.contains(where: { $0.health == .warning }) { return .warning }
            return .healthy
        }()

        return TopologyTargetLane(
            id: targetName,
            targetID: target.id,
            name: targetName,
            mode: .proxy,
            isRejectBuiltin: false,
            hasRelayHop: relayGroupName != nil,
            relayGroupName: relayGroupName,
            aliasReferrers: aliasReferrers,
            branches: branches,
            hops: hops,
            activeConnectionCount: activeConnCount,
            uploadSpeed: speed.upload,
            downloadSpeed: speed.download,
            sessionUpload: session.upload,
            sessionDownload: session.download,
            zeroByteClosedCount: zeroByteCount,
            health: laneHealth,
            diagnosis: diagnosis,
            recentErrors: recentErrors,
            recentDNSFailures: recentDNSFailures
        )
    }

    public static func stripTargetNodePrefix(_ nodeName: String, targetName: String) -> String {
        let prefix = "[\(targetName)] "
        if nodeName.hasPrefix(prefix) {
            let trimmed = String(nodeName.dropFirst(prefix.count))
            if !trimmed.isEmpty { return trimmed }
        }
        return nodeName
    }
}
