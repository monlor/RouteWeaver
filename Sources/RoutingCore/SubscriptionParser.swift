import Foundation

public struct SubscriptionNode: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let server: String?
    public let port: Int?

    public init(id: String? = nil, name: String, type: String, server: String? = nil, port: Int? = nil) {
        self.name = name
        self.type = type
        self.server = server
        self.port = port
        self.id = id ?? "\(name)|\(type)|\(server ?? "")|\(port.map(String.init) ?? "")"
    }
}

public enum SubscriptionParser {
    /// Parses Clash/Mihomo YAML subscriptions or Base64/plain URI lists (`ss://`, `vmess://`, `vless://`, `trojan://`, `hy2://`, `hysteria2://`, `tuic://`, etc.).
    public static func parse(_ data: Data) -> [SubscriptionNode] {
        guard let rawText = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // 1. Try Clash/Mihomo YAML (`proxies:` list)
        let yamlNodes = parseClashYAML(text)
        if !yamlNodes.isEmpty {
            return deduplicateIDs(yamlNodes)
        }

        // 2. Try plain URI list
        let directURINodes = parseURIList(text)
        if !directURINodes.isEmpty {
            return deduplicateIDs(directURINodes)
        }

        // 3. Try Base64-decoded URI list (or Base64-decoded YAML)
        if let decoded = decodeBase64Flexible(text) {
            let decodedYAML = parseClashYAML(decoded)
            if !decodedYAML.isEmpty {
                return deduplicateIDs(decodedYAML)
            }
            let decodedURIs = parseURIList(decoded)
            if !decodedURIs.isEmpty {
                return deduplicateIDs(decodedURIs)
            }
        }

        return []
    }

    /// Filters nodes by an include regular expression and an optional exclude regular expression matching `node.name`.
    /// Empty include pattern matches all nodes; empty exclude pattern excludes none.
    public static func matchingNodes(
        _ nodes: [SubscriptionNode],
        pattern: String,
        excludePattern: String = ""
    ) -> [SubscriptionNode] {
        let trimmedInclude = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExclude = excludePattern.trimmingCharacters(in: .whitespacesAndNewlines)

        let includeRegex: NSRegularExpression?
        if trimmedInclude.isEmpty {
            includeRegex = nil
        } else {
            guard let compiled = try? NSRegularExpression(pattern: trimmedInclude) else { return [] }
            includeRegex = compiled
        }

        let excludeRegex: NSRegularExpression?
        if trimmedExclude.isEmpty {
            excludeRegex = nil
        } else {
            guard let compiled = try? NSRegularExpression(pattern: trimmedExclude) else { return [] }
            excludeRegex = compiled
        }

        if includeRegex == nil && excludeRegex == nil {
            return nodes
        }

        return nodes.filter { node in
            let range = NSRange(node.name.startIndex..<node.name.endIndex, in: node.name)
            if let includeRegex, includeRegex.firstMatch(in: node.name, options: [], range: range) == nil {
                return false
            }
            if let excludeRegex, excludeRegex.firstMatch(in: node.name, options: [], range: range) != nil {
                return false
            }
            return true
        }
    }

    // MARK: - Clash / Mihomo YAML

    private static func parseClashYAML(_ text: String) -> [SubscriptionNode] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var inProxiesSection = false
        var proxiesIndent = 0
        var nodes: [SubscriptionNode] = []

        var currentName: String?
        var currentType: String?
        var currentServer: String?
        var currentPort: Int?

        func flushCurrent() {
            if let name = currentName, !name.isEmpty {
                nodes.append(SubscriptionNode(
                    name: name,
                    type: (currentType ?? "proxy").lowercased(),
                    server: currentServer,
                    port: currentPort
                ))
            }
            currentName = nil
            currentType = nil
            currentServer = nil
            currentPort = nil
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = leadingSpaces(rawLine)

            if !inProxiesSection {
                if trimmed == "proxies:" || trimmed.hasPrefix("proxies:") {
                    inProxiesSection = true
                    proxiesIndent = indent
                }
                continue
            }

            // Exit proxies section when a new top-level key appears at <= proxiesIndent
            if indent <= proxiesIndent && !trimmed.hasPrefix("-") {
                flushCurrent()
                break
            }

            if trimmed.hasPrefix("-") {
                flushCurrent()
                let afterDash = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if afterDash.hasPrefix("{") {
                    if let flowNode = parseFlowMap(afterDash) {
                        nodes.append(flowNode)
                    }
                    continue
                }
                if let (key, value) = splitYAMLKeyValue(afterDash) {
                    applyField(key: key, value: value, name: &currentName, type: &currentType, server: &currentServer, port: &currentPort)
                }
            } else if let (key, value) = splitYAMLKeyValue(trimmed) {
                applyField(key: key, value: value, name: &currentName, type: &currentType, server: &currentServer, port: &currentPort)
            }
        }

        flushCurrent()
        return nodes
    }

    private static func parseFlowMap(_ text: String) -> SubscriptionNode? {
        var inner = text.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("{") { inner.removeFirst() }
        if let closeIdx = inner.lastIndex(of: "}") {
            inner = String(inner[..<closeIdx])
        }

        let pairs = splitFlowEntries(inner)
        var name: String?
        var type: String?
        var server: String?
        var port: Int?

        for pair in pairs {
            guard let (key, value) = splitYAMLKeyValue(pair) else { continue }
            applyField(key: key, value: value, name: &name, type: &type, server: &server, port: &port)
        }

        guard let finalName = name, !finalName.isEmpty else { return nil }
        return SubscriptionNode(
            name: finalName,
            type: (type ?? "proxy").lowercased(),
            server: server,
            port: port
        )
    }

    private static func splitFlowEntries(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        var escaped = false

        for ch in text {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && quote == "\"" {
                current.append(ch)
                escaped = true
                continue
            }
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
                continue
            }
            if ch == "{" || ch == "[" {
                depth += 1
                current.append(ch)
                continue
            }
            if ch == "}" || ch == "]" {
                depth = max(0, depth - 1)
                current.append(ch)
                continue
            }
            if ch == "," && depth == 0 {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(current.trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    private static func splitYAMLKeyValue(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return (key, unquoteYAML(rawValue))
    }

    private static func unquoteYAML(_ raw: String) -> String {
        var value = raw
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applyField(
        key: String,
        value: String,
        name: inout String?,
        type: inout String?,
        server: inout String?,
        port: inout Int?
    ) {
        switch key {
        case "name":
            if !value.isEmpty { name = value }
        case "type":
            if !value.isEmpty { type = value }
        case "server":
            if !value.isEmpty { server = value }
        case "port":
            if let p = Int(value) { port = p }
        default:
            break
        }
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 2 }
            else { break }
        }
        return count
    }

    // MARK: - URI List (Base64 / Plain)

    private static let supportedSchemes: Set<String> = [
        "ss", "ssr", "vmess", "vless", "trojan", "hy2", "hysteria2", "hysteria", "tuic", "socks5", "socks", "http", "https", "anytls", "wireguard"
    ]

    private static func parseURIList(_ text: String) -> [SubscriptionNode] {
        var nodes: [SubscriptionNode] = []
        let lines = text.split(whereSeparator: \.isNewline)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let schemeEnd = line.range(of: "://") else { continue }
            let scheme = String(line[..<schemeEnd.lowerBound]).lowercased()
            guard supportedSchemes.contains(scheme) else { continue }

            if scheme == "vmess" {
                let payload = String(line[schemeEnd.upperBound...])
                if let decoded = decodeBase64Flexible(payload),
                   let jsonData = decoded.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    let ps = (obj["ps"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let add = obj["add"] as? String
                    let port: Int? = (obj["port"] as? Int) ?? (obj["port"] as? String).flatMap(Int.init)
                    let nodeName = (ps?.isEmpty == false ? ps! : (add ?? "VMess 节点"))
                    nodes.append(SubscriptionNode(name: nodeName, type: "vmess", server: add, port: port))
                    continue
                }
            }

            if scheme == "ssr" {
                let payload = String(line[schemeEnd.upperBound...])
                if let decoded = decodeBase64Flexible(payload) {
                    let parts = decoded.split(separator: ":")
                    let server = parts.first.map(String.init)
                    let port = parts.count > 1 ? Int(parts[1]) : nil
                    var remarks: String?
                    if let qIdx = decoded.firstIndex(of: "?") {
                        let query = decoded[decoded.index(after: qIdx)...]
                        for param in query.split(separator: "&") {
                            if param.hasPrefix("remarks=") {
                                let encoded = String(param.dropFirst("remarks=".count))
                                remarks = decodeBase64Flexible(encoded)?.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    }
                    nodes.append(SubscriptionNode(name: remarks ?? server ?? "SSR 节点", type: "ssr", server: server, port: port))
                    continue
                }
            }

            var name: String?
            if let hashIdx = line.lastIndex(of: "#") {
                let rawFragment = String(line[line.index(after: hashIdx)...])
                name = rawFragment.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? rawFragment.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let comps = URLComponents(string: line)
            let server = comps?.host
            let port = comps?.port
            let displayName = (name?.isEmpty == false ? name! : (server ?? "\(scheme.uppercased()) 节点"))
            let normalizedType = scheme == "hy2" ? "hysteria2" : scheme
            nodes.append(SubscriptionNode(name: displayName, type: normalizedType, server: server, port: port))
        }
        return nodes
    }

    private static func decodeBase64Flexible(_ raw: String) -> String? {
        var cleaned = raw
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = cleaned.count % 4
        if remainder != 0 {
            cleaned += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: cleaned),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func deduplicateIDs(_ nodes: [SubscriptionNode]) -> [SubscriptionNode] {
        var counts: [String: Int] = [:]
        return nodes.map { node in
            let seen = counts[node.id, default: 0]
            counts[node.id] = seen + 1
            if seen == 0 { return node }
            return SubscriptionNode(
                id: "\(node.id)#\(seen)",
                name: node.name,
                type: node.type,
                server: node.server,
                port: node.port
            )
        }
    }
}
