import Foundation

public struct MihomoReleaseAsset: Equatable, Sendable {
    public let name: String
    public let downloadURL: URL
    public let size: Int64
    public let sha256: String?

    public init(name: String, downloadURL: URL, size: Int64, sha256: String? = nil) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
        self.sha256 = Self.normalizeSHA256(sha256)
    }

    /// Parses GitHub release asset `digest` (e.g. `"sha256:0123abcd..."`) or raw 64-char hex string.
    public static func parseGitHubDigest(_ digest: String?) -> String? {
        guard let raw = digest?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        let hex = lower.hasPrefix("sha256:") ? String(lower.dropFirst("sha256:".count)) : lower
        return normalizeSHA256(hex)
    }

    private static func normalizeSHA256(_ candidate: String?) -> String? {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              candidate.count == 64,
              candidate.unicodeScalars.allSatisfy({
                  ("0"..."9").contains($0) || ("a"..."f").contains($0)
              }) else {
            return nil
        }
        return candidate
    }
}

public struct MihomoRelease: Equatable, Sendable {
    public let tagName: String
    public let htmlURL: URL?
    public let publishedAt: String?
    public let assets: [MihomoReleaseAsset]

    public init(tagName: String, htmlURL: URL?, publishedAt: String?, assets: [MihomoReleaseAsset]) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.assets = assets
    }
}

public enum MihomoReleaseSelector {
    /// Picks the best macOS `.gz` asset for the given architecture (`arm64` or `amd64`/`x86_64`).
    public static func selectMacOSAsset(from assets: [MihomoReleaseAsset], arch: String) -> MihomoReleaseAsset? {
        let normalizedArch: String
        switch arch.lowercased() {
        case "arm64", "aarch64":
            normalizedArch = "arm64"
        case "x86_64", "amd64":
            normalizedArch = "amd64"
        default:
            return nil
        }

        let prefix = "mihomo-darwin-\(normalizedArch)-"
        let candidates = assets.filter { asset in
            let lower = asset.name.lowercased()
            return lower.hasPrefix(prefix) && lower.hasSuffix(".gz")
        }
        guard !candidates.isEmpty else { return nil }

        // Prefer the standard release binary (e.g. `mihomo-darwin-arm64-v1.19.27.gz`)
        // over `-compatible`, `-go120`, `-v1`/`-v2`/`-v3` variants.
        let standard = candidates.first { asset in
            let lower = asset.name.lowercased()
            let suffix = lower.dropFirst(prefix.count)
            return suffix.hasPrefix("v")
                && !lower.contains("compatible")
                && !lower.contains("-go")
        }
        if let standard {
            return standard
        }

        // Next fallback: avoid `-go` older toolchain builds if possible.
        if let nonGo = candidates.first(where: { !$0.name.lowercased().contains("-go") }) {
            return nonGo
        }

        return candidates.first
    }
}
