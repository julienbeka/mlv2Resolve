// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum AppDataPaths {
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mlv2Resolve", isDirectory: true)
    }
    /// Copy rather than move: old absolute profile URLs and a previous app installation remain valid.
    public static func copyMissing(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for url in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            let target = destination.appendingPathComponent(url.lastPathComponent)
            if values.isDirectory == true { try copyMissing(from: url, to: target) }
            else if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: url, to: target) }
        }
    }
    public static func migrateSupport() {
        guard !UserDefaults.standard.bool(forKey: "migratedMLV2ResolveSupport") else { return }
        let old = support.deletingLastPathComponent().appendingPathComponent("mlv2dng", isDirectory: true)
        do {
            try copyMissing(from: old, to: support)
            UserDefaults.standard.set(true, forKey: "migratedMLV2ResolveSupport")
        }
        catch { NSLog("mlv2Resolve data migration: %@", error.localizedDescription) }
    }
}
