import Combine
import Foundation

@MainActor
final class EngineLogStore: ObservableObject {
    @Published private(set) var text = ""

    private var readOffset: UInt64 = 0
    private var tailTask: Task<Void, Never>?

    private nonisolated static let writeQueue = DispatchQueue(label: "local.routeweaver.engine-log-writer", qos: .utility)

    var isEmpty: Bool { text.isEmpty }

    func clear() {
        text = ""
    }

    func replaceText(_ newText: String) {
        text = Self.truncate(Self.sanitize(newText))
    }

    func resetForNewRun(logURL: URL) {
        stopTailing()
        text = ""
        readOffset = 0
        Self.writeQueue.sync {
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    func append(_ raw: String, persistTo url: URL, stateDir: URL) {
        let safe = Self.sanitize(raw)
        text = Self.truncate(text + safe)
        Self.persistChunkAsync(safe, to: url, stateDir: stateDir)
    }

    func appendMemoryOnly(_ raw: String) {
        let safe = Self.sanitize(raw)
        text = Self.truncate(text + safe)
    }

    func prepareSharedLogFile(at url: URL, stateDir: URL) {
        readOffset = Self.writeQueue.sync {
            let fm = FileManager.default
            if !fm.fileExists(atPath: stateDir.path) {
                try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o644])
            } else {
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        }
    }

    func loadExistingTail(from url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            readOffset = 0
            return
        }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let maxInitialBytes: UInt64 = 120_000
        let startOffset = fileSize > maxInitialBytes ? fileSize - maxInitialBytes : 0
        try? handle.seek(toOffset: startOffset)
        if let data = try? handle.readToEnd(), !data.isEmpty {
            text = Self.sanitize(String(decoding: data, as: UTF8.self))
        }
        readOffset = fileSize
    }

    func startTailing(at url: URL, shouldContinue: @escaping @MainActor () -> Bool) {
        tailTask?.cancel()
        tailTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let self, shouldContinue() else { return }
                let offset = self.readOffset
                let result = await Task.detached(priority: .utility) {
                    Self.readIncrement(at: url, fromOffset: offset)
                }.value
                guard !Task.isCancelled, shouldContinue() else { return }
                if let (chunk, newOffset) = result {
                    self.readOffset = newOffset
                    if !chunk.isEmpty {
                        self.appendMemoryOnly(chunk)
                    }
                }
            }
        }
    }

    func stopTailing() {
        tailTask?.cancel()
        tailTask = nil
    }

    nonisolated static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)https?://[^\s"'\)\]]+"#, with: "[URL 已隐藏]", options: .regularExpression)
    }

    nonisolated static func truncate(_ text: String, maxUTF8Bytes: Int = 140_000, keepSuffixChars: Int = 45_000) -> String {
        if text.utf8.count > maxUTF8Bytes {
            return String(text.suffix(keepSuffixChars))
        }
        return text
    }

    nonisolated static func readIncrement(at url: URL, fromOffset offset: UInt64) -> (String, UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let start = fileSize < offset ? 0 : offset
        guard fileSize > start else { return nil }
        try? handle.seek(toOffset: start)
        let bytesToRead = min(Int(fileSize - start), 65_536)
        guard let data = try? handle.read(upToCount: bytesToRead), !data.isEmpty else { return nil }
        return (String(decoding: data, as: UTF8.self), start + UInt64(data.count))
    }

    private nonisolated static func persistChunkAsync(_ chunk: String, to url: URL, stateDir: URL) {
        let data = Data(chunk.utf8)
        writeQueue.async {
            let fm = FileManager.default
            if !fm.fileExists(atPath: stateDir.path) {
                try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o644])
                return
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}
