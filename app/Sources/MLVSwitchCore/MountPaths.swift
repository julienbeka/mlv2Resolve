// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct MountPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MLV Switch", isDirectory: true)
    }

    /// Pure: no filesystem access.
    public func mountPoint(for shoot: Shoot, alreadyMounted: [Shoot: URL]) -> URL {
        let key = shoot.folder.standardizedFileURL
        if let existing = alreadyMounted.first(where: { $0.key.folder.standardizedFileURL == key })?.value {
            return existing
        }
        let taken = Set(alreadyMounted.filter { $0.key.folder.standardizedFileURL != key }
            .map { $0.value.standardizedFileURL.path })
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        func isFree(_ name: String) -> Bool { !taken.contains(url(name).standardizedFileURL.path) }

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
        if s.isEmpty { s = fallback }
        if s.hasPrefix(".") { s = "_" + s.dropFirst() }
        return s
    }
}
