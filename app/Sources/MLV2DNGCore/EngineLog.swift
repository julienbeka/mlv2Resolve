// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Per-shoot engine log files: `~/Library/Logs/mlv2dng/<mount name>.log`.
public enum EngineLog {
    /// Rotate to `<name>.log.1` when the log is larger than this at launch.
    public static let rotateBytes: Int64 = 5_000_000

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/mlv2dng", isDirectory: true)
    }

    /// Log file for a mount point folder name (already sanitized by MountPaths).
    public static func file(in directory: URL, name: String) -> URL {
        directory.appendingPathComponent(name + ".log")
    }

    /// Creates the directory, rotates an oversized log to `.1` (replacing an
    /// older `.1`), and opens the log for appending.
    public static func openForAppend(_ url: URL, rotateAbove limit: Int64 = rotateBytes) throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value, size > limit {
            let old = URL(fileURLWithPath: url.path + ".1")
            try? fm.removeItem(at: old)
            try fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}
