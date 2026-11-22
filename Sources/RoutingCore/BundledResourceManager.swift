import CryptoKit
import Foundation

public enum BundledResourceKind: String, Codable, Equatable, Sendable {
    case mmdb
    case dat
    case textRuleSet
    case yamlRuleSet
    case mrsRuleSet
}

public struct BundledResourceEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let relativePath: String
    public let kind: BundledResourceKind
    public let version: String
    public let sha256: String
    public let sizeBytes: Int64
    public let sourceURL: String
    public let mirrorURLs: [String]
    public let license: String
    public let attribution: String

    public init(
        id: String,
        relativePath: String,
        kind: BundledResourceKind,
        version: String,
        sha256: String,
        sizeBytes: Int64,
        sourceURL: String,
        mirrorURLs: [String] = [],
        license: String,
        attribution: String
    ) {
        self.id = id
        self.relativePath = relativePath
        self.kind = kind
        self.version = version
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.sourceURL = sourceURL
        self.mirrorURLs = mirrorURLs
        self.license = license
        self.attribution = attribution
    }

    public var candidateURLs: [String] {
        var urls: [String] = []
        for url in mirrorURLs + [sourceURL] {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !urls.contains(trimmed) {
                urls.append(trimmed)
            }
        }
        return urls
    }
}

public struct BundledResourceManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let entries: [BundledResourceEntry]

    public init(schemaVersion: Int = 1, generatedAt: String, entries: [BundledResourceEntry]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.entries = entries
    }

    public static func load(from url: URL) throws -> BundledResourceManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BundledResourceManifest.self, from: data)
    }
}

public enum ResourceIntegrityError: LocalizedError, Equatable {
    case fileMissing
    case emptyFile
    case fileTooLarge(Int64)
    case invalidFormat(String)
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "资源文件不存在。"
        case .emptyFile:
            return "资源文件为空。"
        case .fileTooLarge(let size):
            return "资源文件过大（\(size) 字节）。"
        case .invalidFormat(let detail):
            return "资源格式校验失败：\(detail)"
        case .checksumMismatch(let expected, let actual):
            return "资源 SHA-256 校验失败（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）。"
        }
    }
}

public enum ResourceIntegrityValidator {
    private static let maxGeoBytes: Int64 = 64 * 1024 * 1024
    private static let maxRuleSetBytes: Int64 = 10 * 1024 * 1024
    private static let mmdbMarker = Data([0xAB, 0xCD, 0xEF]) + Data("MaxMind.com".utf8)
    private static let zstdMagic = Data([0x28, 0xB5, 0x2F, 0xFD])
    private static let rawMRSMagic = Data([0x4D, 0x52, 0x53, 0x01]) // "MRS\x01"

    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func validateFile(
        at url: URL,
        kind: BundledResourceKind,
        expectedSHA256: String? = nil
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw ResourceIntegrityError.fileMissing
        }
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw ResourceIntegrityError.emptyFile
        }
        let maxAllowed: Int64 = (kind == .mmdb || kind == .dat) ? maxGeoBytes : maxRuleSetBytes
        guard size <= maxAllowed else {
            throw ResourceIntegrityError.fileTooLarge(size)
        }

        switch kind {
        case .mmdb:
            guard size >= 1_024 else {
                throw ResourceIntegrityError.invalidFormat("MMDB 文件过小。")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let tailSize = min(size, 131_072)
            try handle.seek(toOffset: UInt64(size - tailSize))
            let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
            guard tail.range(of: mmdbMarker) != nil else {
                throw ResourceIntegrityError.invalidFormat("缺少 MaxMind MMDB 元数据标记。")
            }

        case .dat:
            guard size >= 1_024 else {
                throw ResourceIntegrityError.invalidFormat("GeoSite/GeoIP .dat 文件过小。")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let head = try handle.read(upToCount: 64) ?? Data()
            guard let first = head.first, first == 0x0A else {
                throw ResourceIntegrityError.invalidFormat("Geo .dat Protobuf 文件头无效。")
            }
            if looksLikeHTMLOrErrorText(head) {
                throw ResourceIntegrityError.invalidFormat("下载内容为 HTML/错误页而非 .dat 文件。")
            }

        case .mrsRuleSet:
            guard size >= 16 else {
                throw ResourceIntegrityError.invalidFormat("MRS 文件过小。")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let head = try handle.read(upToCount: 16) ?? Data()
            let hasZstd = head.prefix(4) == zstdMagic
            let hasRawMRS = head.prefix(4) == rawMRSMagic
            guard hasZstd || hasRawMRS else {
                throw ResourceIntegrityError.invalidFormat("缺少 MRS / Zstd 文件头魔数。")
            }

        case .textRuleSet, .yamlRuleSet:
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ResourceIntegrityError.invalidFormat("规则文件不是有效的 UTF-8 文本。")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ResourceIntegrityError.emptyFile
            }
            let lowerPrefix = String(trimmed.prefix(256)).lowercased()
            if lowerPrefix.contains("<!doctype html") || lowerPrefix.contains("<html") || lowerPrefix.contains("<?xml") {
                throw ResourceIntegrityError.invalidFormat("下载内容为 HTML/XML 错误页。")
            }
            let hasRuleLine = trimmed.split(whereSeparator: \.isNewline).contains { raw in
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("//") && !line.hasPrefix(";")
            }
            guard hasRuleLine else {
                throw ResourceIntegrityError.invalidFormat("规则文件不包含有效规则条目。")
            }
        }

        if let expected = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !expected.isEmpty {
            let actual = try sha256Hex(ofFileAt: url)
            guard actual == expected else {
                throw ResourceIntegrityError.checksumMismatch(expected: expected, actual: actual)
            }
        }
    }

    private static func looksLikeHTMLOrErrorText(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(64), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return prefix.hasPrefix("<!doctype") || prefix.hasPrefix("<html") || prefix.hasPrefix("{\"")
    }
}

public struct ResourceSeedReport: Equatable, Sendable {
    public var seeded: [String] = []
    public var keptExisting: [String] = []
    public var repairedCorrupted: [String] = []
    public var missingInBundle: [String] = []

    public init() {}
}

public enum ResourceUpdateOutcome: Equatable, Sendable {
    case updated
    case keptExistingAfterFailure(String)
    case restoredBundledAfterFailure(String)
    case failedWithoutFallback(String)
}

public enum BundledResourceManager {
    public static let manifestFileName = "manifest.json"

    /// Default GeoX mirror URLs used in rendered Mihomo config and background updater.
    public static let defaultGeoURLs: [String: String] = [
        "mmdb": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb",
        "geoip": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat",
        "geosite": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
    ]

    /// Seeds bundled resources into `workDir` ONLY when the destination file is missing, empty, or corrupted.
    /// Existing valid cached files (including newer user-updated files) are never overwritten and keep their `mtime`.
    @discardableResult
    public static func seedMissingResources(
        from bundleDir: URL,
        to workDir: URL,
        manifest: BundledResourceManifest
    ) throws -> ResourceSeedReport {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        var report = ResourceSeedReport()

        for entry in manifest.entries {
            let sourceURL = bundleDir.appendingPathComponent(entry.relativePath)
            let destURL = workDir.appendingPathComponent(entry.relativePath)

            let destExists = fm.fileExists(atPath: destURL.path)
            if destExists {
                if (try? ResourceIntegrityValidator.validateFile(at: destURL, kind: entry.kind)) != nil {
                    report.keptExisting.append(entry.relativePath)
                    continue
                }
            }

            guard fm.fileExists(atPath: sourceURL.path) else {
                report.missingInBundle.append(entry.relativePath)
                continue
            }

            // Validate bundled file before copying
            try ResourceIntegrityValidator.validateFile(
                at: sourceURL,
                kind: entry.kind,
                expectedSHA256: entry.sha256.isEmpty ? nil : entry.sha256
            )

            try atomicCopy(from: sourceURL, to: destURL)
            if destExists {
                report.repairedCorrupted.append(entry.relativePath)
            } else {
                report.seeded.append(entry.relativePath)
            }
        }
        return report
    }

    /// Validates a newly downloaded temporary file and atomically replaces `destination`.
    /// On validation failure:
    /// - Discards `tempFile`.
    /// - Preserves `destination` untouched if it is already valid.
    /// - Only falls back to `bundledFallback` if `destination` is missing or itself invalid.
    public static func installValidatedUpdate(
        tempFile: URL,
        kind: BundledResourceKind,
        destination: URL,
        bundledFallback: URL? = nil,
        bundledExpectedSHA256: String? = nil
    ) -> ResourceUpdateOutcome {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: tempFile) }

        do {
            try ResourceIntegrityValidator.validateFile(at: tempFile, kind: kind)
            try atomicReplace(source: tempFile, destination: destination)
            return .updated
        } catch {
            let reason = error.localizedDescription
            if (try? ResourceIntegrityValidator.validateFile(at: destination, kind: kind)) != nil {
                return .keptExistingAfterFailure(reason)
            }
            if let bundledFallback,
               fm.fileExists(atPath: bundledFallback.path),
               (try? ResourceIntegrityValidator.validateFile(
                   at: bundledFallback,
                   kind: kind,
                   expectedSHA256: bundledExpectedSHA256
               )) != nil {
                do {
                    try atomicCopy(from: bundledFallback, to: destination)
                    return .restoredBundledAfterFailure(reason)
                } catch {
                    return .failedWithoutFallback(error.localizedDescription)
                }
            }
            return .failedWithoutFallback(reason)
        }
    }

    private static func atomicCopy(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).stage-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        try atomicReplace(source: staging, destination: destination)
    }

    private static func atomicReplace(source: URL, destination: URL) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
    }
}
