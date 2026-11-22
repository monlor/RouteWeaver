import AppKit
import Foundation

struct InstalledAppInfo: Identifiable, Hashable {
    var id: String { bundlePath }
    let name: String
    let executableName: String
    let bundlePath: String

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: bundlePath)
    }
}

struct RunningProcessInfo: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isGUIApp: Bool
}

enum SystemInspector {
    static func discoverInstalledApps() -> [InstalledAppInfo] {
        let fm = FileManager.default
        let searchRoots: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]

        var seenPaths = Set<String>()
        var results: [InstalledAppInfo] = []

        func appendApp(at url: URL) {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { return }
            guard let bundle = Bundle(url: url) else { return }
            let execName = (bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String)
                ?? bundle.executableURL?.lastPathComponent
                ?? url.deletingPathExtension().lastPathComponent
            let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let cleanExec = execName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanExec.isEmpty else { return }
            results.append(InstalledAppInfo(name: displayName, executableName: cleanExec, bundlePath: path))
        }

        // Include running regular apps first
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let url = app.bundleURL {
                appendApp(at: url)
            }
        }

        // Scan Applications directories (1 level + immediate subfolders like Utilities)
        for root in searchRoots {
            guard let items = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in items {
                if item.pathExtension.lowercased() == "app" {
                    appendApp(at: item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if let subitems = try? fm.contentsOfDirectory(
                        at: item,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) {
                        for sub in subitems where sub.pathExtension.lowercased() == "app" {
                            appendApp(at: sub)
                        }
                    }
                }
            }
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func discoverRunningProcesses() -> [RunningProcessInfo] {
        var guiNames = Set<String>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let exec = app.executableURL?.lastPathComponent, !exec.isEmpty {
                guiNames.insert(exec)
            }
        }

        var allNames = guiNames
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "comm="]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            for line in output.split(whereSeparator: \.isNewline) {
                let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                let basename = URL(fileURLWithPath: raw).lastPathComponent
                if !basename.isEmpty && !basename.hasPrefix("(") {
                    allNames.insert(basename)
                }
            }
        }

        return allNames
            .map { RunningProcessInfo(name: $0, isGUIApp: guiNames.contains($0)) }
            .sorted { lhs, rhs in
                if lhs.isGUIApp != rhs.isGUIApp { return lhs.isGUIApp }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func executableName(forAppBundle url: URL) -> String? {
        if let bundle = Bundle(url: url),
           let exec = (bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String)
            ?? bundle.executableURL?.lastPathComponent {
            let trimmed = exec.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
