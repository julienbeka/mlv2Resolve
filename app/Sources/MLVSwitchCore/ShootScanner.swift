// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum ShootScanner {
    /// Scans `folder`: if it directly contains clips it is a single shoot,
    /// otherwise each direct subfolder containing clips is a shoot.
    /// Throws only if `folder` itself cannot be read.
    public static func scan(_ folder: URL) throws -> [Shoot] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .volumeNameKey, .isDirectoryKey]
        let entries = try fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])

        let rootClips = clips(in: entries)
        if !rootClips.isEmpty {
            return [makeShoot(folder, rootClips)]
        }

        var shoots: [Shoot] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let sub = try? fm.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            let c = clips(in: sub)
            if !c.isEmpty { shoots.append(makeShoot(entry, c)) }
        }
        return shoots.sorted { $0.name > $1.name }
    }

    private static func makeShoot(_ folder: URL, _ clips: [Clip]) -> Shoot {
        let volume = (try? folder.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? ""
        return Shoot(name: folder.lastPathComponent, folder: folder,
                     volumeName: volume ?? "", clips: clips)
    }

    /// Chunk index: 0 for MLV, n+1 for Mnn; nil if not a clip file.
    private static func chunkIndex(_ ext: String) -> Int? {
        let e = ext.lowercased()
        if e == "mlv" { return 0 }
        if e.count == 3, e.hasPrefix("m"), let n = Int(e.dropFirst()), n >= 0 {
            return n + 1
        }
        return nil
    }

    private static func clips(in entries: [URL]) -> [Clip] {
        var groups: [String: [(Int, URL)]] = [:]
        for url in entries {
            let file = url.lastPathComponent
            if file.hasPrefix(".") { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            guard let idx = chunkIndex(url.pathExtension) else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            groups[base, default: []].append((idx, url))
        }
        var result: [Clip] = []
        for (base, items) in groups {
            guard items.contains(where: { $0.0 == 0 }) else { continue }
            let sorted = items.sorted { $0.0 < $1.0 }
            let bytes = sorted.reduce(Int64(0)) { acc, item in
                let size = (try? item.1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return acc + Int64(size)
            }
            result.append(Clip(name: base, files: sorted.map(\.1), bytes: bytes))
        }
        return result.sorted { $0.name < $1.name }
    }
}
