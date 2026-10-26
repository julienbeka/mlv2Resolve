// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct MountPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Name of the mount root folder in the user's home. Deliberately
    /// product-neutral: DaVinci Resolve stores these paths in its projects, so
    /// this name must NEVER change again, even if the app is renamed.
    public static let rootFolderName = "MLV Mounts"

    /// Mount root of the pre-mlv2Resolve app ("MLV Switch"), cleaned up once at launch.
    public static var legacyRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MLV Switch", isDirectory: true)
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(rootFolderName, isDirectory: true)
    }

    /// Pure: no filesystem access.
    /// Folder identity is by standardized file URL; callers must pass URLs as
    /// produced by ShootScanner (symlinks are not resolved).
    public func mountPoint(for shoot: Shoot, alreadyMounted: [Shoot: URL]) -> URL {
        let key = shoot.folder.standardizedFileURL
        if let existing = alreadyMounted.first(where: { $0.key.folder.standardizedFileURL == key })?.value {
            return existing
        }
        let taken = Set(alreadyMounted.filter { $0.key.folder.standardizedFileURL != key }
            .map { $0.value.standardizedFileURL.path })
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        // Case-insensitive (default APFS) and normalization-insensitive keys.
        func fold(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        let takenKeys = Set(taken.map(fold))
        func isFree(_ name: String) -> Bool { !takenKeys.contains(fold(url(name).standardizedFileURL.path)) }

        let base = Self.sanitize(shoot.name)
        if isFree(base) { return url(base) }
        let volume = Self.sanitize(shoot.volumeName.isEmpty ? "disque" : shoot.volumeName,
                                   fallback: "disque")
        let withVolume = "\(base) (\(volume))"
        if isFree(withVolume) { return url(withVolume) }
        var n = 2
        while !isFree("\(withVolume) \(n)") { n += 1 }
        return url("\(withVolume) \(n)")
    }

    static func sanitize(_ name: String, fallback: String = "Tournage") -> String {
        var s = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        if s.isEmpty { s = fallback }
        if s.hasPrefix(".") { s = "_" + s.dropFirst() }
        return s
    }
}
