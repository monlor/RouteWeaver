import Foundation

public enum RoutingTemplate: String, CaseIterable, Identifiable, Sendable {
    case dualUplink
    case unifiedUplink
    case googleOnlyA

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dualUplink: return "双网卡 · Claude USB"
        case .unifiedUplink: return "单网卡 · Claude 与国内共用"
        case .googleOnlyA: return "Google 独享 A · 社交与默认走 B"
        }
    }
}

public struct RoutingProfile: Codable, Equatable, Sendable {
    public var name: String
    public var claudeInterface: String = ""
    public var domesticInterface: String = ""
    public var useDomesticInterfaceForClaude: Bool = false
    public var socialUsesGroupB: Bool = false
    public var entryProviderURL: String = ""
    public var exitProviderURL: String = ""
    public var entryPattern: String = ""
    public var groupAPattern: String = #"(?i)(🇺🇸|美国|美國|United States|\b(?:US|USA)\b|Los Angeles|San Jose|Seattle|New York)"#
    public var groupBPattern: String = #"(?i)(🇭🇰|香港|Hong[ -]?Kong|\bHK\b)"#
    public var entryAutoTest = false
    public var groupAAutoTest = true
    public var groupBAutoTest = true
    public var mixedPort: Int = 7890

    public var effectiveClaudeInterface: String {
        useDomesticInterfaceForClaude ? domesticInterface : claudeInterface
    }

    public var requiredInterfaces: Set<String> {
        Set([effectiveClaudeInterface, domesticInterface].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    }

    public init(name: String) {
        self.name = name
    }

    public static func template(_ template: RoutingTemplate) -> RoutingProfile {
        var profile = RoutingProfile(name: template.title)
        profile.useDomesticInterfaceForClaude = template == .unifiedUplink
        profile.socialUsesGroupB = template == .googleOnlyA
        return profile
    }
}
