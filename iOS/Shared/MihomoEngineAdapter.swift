import Foundation

#if canImport(MihomoKit)
import MihomoKit
#endif

public protocol MobileTunnelCoreEngine: AnyObject, Sendable {
    var isRunning: Bool { get }
    var engineVersion: String { get }
    func start(homeDirectory: URL, configData: Data, tunFileDescriptor: Int32) throws
    func reload(configData: Data) throws
    func stop()
}

public enum MihomoEngineAdapterError: LocalizedError {
    case invalidConfigEncoding
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .invalidConfigEncoding:
            return "Mihomo configuration data is not valid UTF-8."
        case .notRunning:
            return "Mihomo engine is not running."
        }
    }
}

public final class MihomoKitEngineAdapter: MobileTunnelCoreEngine, @unchecked Sendable {
    private let lock = NSLock()

    #if !canImport(MihomoKit)
    private var stubRunning = false
    private var stubHomeDirectory: URL?
    #endif

    public init() {}

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        #if canImport(MihomoKit)
        return MihomoKitIsRunning()
        #else
        return stubRunning
        #endif
    }

    public var engineVersion: String {
        #if canImport(MihomoKit)
        return MihomoKitVersion()
        #else
        return "stub (run iOS/Scripts/build-mihomo-ios.sh)"
        #endif
    }

    public func start(homeDirectory: URL, configData: Data, tunFileDescriptor: Int32) throws {
        guard let configJSON = String(data: configData, encoding: .utf8) else {
            throw MihomoEngineAdapterError.invalidConfigEncoding
        }

        lock.lock()
        defer { lock.unlock() }

        #if canImport(MihomoKit)
        MihomoKitSetMemoryLimitMB(32)
        try MihomoKitStart(homeDirectory.path, configJSON, tunFileDescriptor)
        #else
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        let configURL = homeDirectory.appendingPathComponent("config.json")
        try configData.write(to: configURL, options: .atomic)
        stubHomeDirectory = homeDirectory
        stubRunning = true
        #endif
    }

    public func reload(configData: Data) throws {
        guard let configJSON = String(data: configData, encoding: .utf8) else {
            throw MihomoEngineAdapterError.invalidConfigEncoding
        }

        lock.lock()
        defer { lock.unlock() }

        #if canImport(MihomoKit)
        try MihomoKitReload(configJSON)
        #else
        guard stubRunning else {
            throw MihomoEngineAdapterError.notRunning
        }
        if let homeDir = stubHomeDirectory {
            let configURL = homeDir.appendingPathComponent("config.json")
            try configData.write(to: configURL, options: .atomic)
        }
        #endif
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        #if canImport(MihomoKit)
        try? MihomoKitStop()
        #else
        stubRunning = false
        stubHomeDirectory = nil
        #endif
    }
}
