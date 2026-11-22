import Foundation

/// Parsed subscription traffic quota and expiration metadata from standard
/// `Subscription-Userinfo` HTTP response headers (`upload=...; download=...; total=...; expire=...`).
public struct SubscriptionUsage: Codable, Equatable, Sendable {
    public let upload: Int64
    public let download: Int64
    public let total: Int64
    /// Unix timestamp in seconds; `nil` means no expiration (permanent / unspecified).
    public let expireTimestamp: TimeInterval?
    /// Optional provider portal URL from `profile-web-page-url` header.
    public let webPageURL: String?
    /// Optional suggested update interval in hours from `profile-update-interval` header.
    public let updateIntervalHours: Int?

    public init(
        upload: Int64,
        download: Int64,
        total: Int64,
        expireTimestamp: TimeInterval? = nil,
        webPageURL: String? = nil,
        updateIntervalHours: Int? = nil
    ) {
        self.upload = max(0, upload)
        self.download = max(0, download)
        self.total = max(0, total)
        if let ts = expireTimestamp, ts > 0 {
            self.expireTimestamp = ts
        } else {
            self.expireTimestamp = nil
        }
        self.webPageURL = webPageURL
        self.updateIntervalHours = updateIntervalHours
    }

    public var used: Int64 {
        upload + download
    }

    public var remaining: Int64 {
        max(0, total - used)
    }

    /// Fraction in `[0.0, 1.0]` representing `used / total`. Returns `0` when `total == 0`.
    public var usageFraction: Double {
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(used) / Double(total)))
    }

    public var usagePercentage: Double {
        usageFraction * 100.0
    }

    public var isOverLimit: Bool {
        total > 0 && used >= total
    }

    public var expireDate: Date? {
        guard let ts = expireTimestamp, ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    public func isExpired(referenceNow: Date = Date()) -> Bool {
        guard let expireDate else { return false }
        return expireDate <= referenceNow
    }

    /// Whole days remaining until expiration (negative if expired, `nil` if no expiration date).
    public func daysUntilExpire(referenceNow: Date = Date()) -> Int? {
        guard let expireDate else { return nil }
        let seconds = expireDate.timeIntervalSince(referenceNow)
        if seconds <= 0 {
            return Int(floor(seconds / 86_400))
        }
        return Int(ceil(seconds / 86_400))
    }

    /// Parses a standard `subscription-userinfo` HTTP header value, e.g.:
    /// `upload=123456; download=789012; total=107374182400; expire=1767225600`
    public static func parse(
        headerValue: String?,
        webPageURL: String? = nil,
        updateInterval: String? = nil
    ) -> SubscriptionUsage? {
        guard let raw = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        var upload: Int64?
        var download: Int64?
        var total: Int64?
        var expire: TimeInterval?

        let separators = CharacterSet(charactersIn: ";,")
        for part in raw.components(separatedBy: separators) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !val.isEmpty else { continue }

            switch key {
            case "upload":
                upload = parseByteInt64(val)
            case "download":
                download = parseByteInt64(val)
            case "total":
                total = parseByteInt64(val)
            case "expire":
                if let parsed = Double(val), parsed.isFinite, parsed > 0 {
                    expire = parsed
                }
            default:
                break
            }
        }

        // Require at least one valid traffic or expiration field.
        guard upload != nil || download != nil || total != nil || expire != nil else {
            return nil
        }

        let normalizedWebURL: String? = {
            guard let rawURL = webPageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawURL.isEmpty,
                  let parsed = URL(string: rawURL),
                  let scheme = parsed.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                return nil
            }
            return rawURL
        }()

        let parsedInterval: Int? = {
            guard let rawInterval = updateInterval?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let hours = Int(rawInterval),
                  hours > 0 else {
                return nil
            }
            return hours
        }()

        return SubscriptionUsage(
            upload: upload ?? 0,
            download: download ?? 0,
            total: total ?? 0,
            expireTimestamp: expire,
            webPageURL: normalizedWebURL,
            updateIntervalHours: parsedInterval
        )
    }

    private static func parseByteInt64(_ raw: String) -> Int64? {
        if let intVal = Int64(raw) {
            return max(0, intVal)
        }
        // Some providers emit float or scientific notation (e.g. "1.073741824e+11").
        if let doubleVal = Double(raw), doubleVal.isFinite, doubleVal >= 0 {
            if doubleVal >= Double(Int64.max) {
                return Int64.max
            }
            return Int64(doubleVal.rounded())
        }
        return nil
    }
}
