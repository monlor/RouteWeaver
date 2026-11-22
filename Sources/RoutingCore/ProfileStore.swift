import Foundation

public enum ProfileStoreError: LocalizedError {
    case fileTooLarge
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "配置文件超过 2 MB，无法读取。"
        case .writeFailed:
            return "无法写入配置文件。"
        }
    }
}

/// Manages where RouteWeaver persists `profile.json`, supporting both the
/// default Application Support directory and a user-chosen sync folder (e.g. iCloud Drive).
public struct ProfileStore: Sendable {
    public static let fileName = "profile.json"
    public static let maxProfileBytes = 2 << 20

    public let defaultDirectory: URL
    public var customDirectory: URL?

    public init(
        defaultDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RouteWeaver", isDirectory: true),
        customDirectory: URL? = nil
    ) {
        self.defaultDirectory = defaultDirectory.standardizedFileURL
        self.customDirectory = customDirectory?.standardizedFileURL
    }

    public var isUsingCustomDirectory: Bool {
        guard let customDirectory else { return false }
        return customDirectory.standardizedFileURL != defaultDirectory.standardizedFileURL
    }

    public var activeDirectory: URL {
        isUsingCustomDirectory ? (customDirectory ?? defaultDirectory) : defaultDirectory
    }

    public var activeProfileURL: URL {
        Self.profileFileURL(in: activeDirectory)
    }

    public static func profileFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func profileExists(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: profileFileURL(in: directory).path)
    }

    public static func readProfile(from directory: URL) throws -> RoutingProfile {
        let url = profileFileURL(in: directory)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxProfileBytes + 1) ?? Data()
        guard data.count <= maxProfileBytes else {
            throw ProfileStoreError.fileTooLarge
        }
        return try RoutingProfile.decodeOrMigrate(from: data)
    }

    public static func writeProfile(_ profile: RoutingProfile, to directory: URL, enforcePrivateDirectoryPermissions: Bool) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            let attributes: [FileAttributeKey: Any]? = enforcePrivateDirectoryPermissions
                ? [.posixPermissions: 0o700]
                : nil
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        }
        if enforcePrivateDirectoryPermissions {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try writePrivateFile(data, to: profileFileURL(in: directory), tempName: fileName)
    }

    public static func writePrivateFile(_ data: Data, to url: URL, tempName: String) throws {
        let manager = FileManager.default
        let temp = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: url, create: true
        )
        defer { try? manager.removeItem(at: temp) }
        let privateFile = temp.appendingPathComponent(tempName)
        guard manager.createFile(atPath: privateFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ProfileStoreError.writeFailed
        }
        try data.write(to: privateFile)
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: privateFile, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try manager.moveItem(at: privateFile, to: url)
        }
    }
}
