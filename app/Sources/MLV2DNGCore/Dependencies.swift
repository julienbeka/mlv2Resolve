// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum DependencyState: Equatable {
    case ready
    case fuseTMissing
    case fuseTOutdated(found: String, minimum: String)
}

public struct Dependencies {
    public static let minimumFuseT = "1.2.6"
    public static let fuseTInstaller = URL(string: "https://github.com/macos-fuse-t/fuse-t/releases/download/1.2.9/fuse-t-macos-installer-1.2.9.pkg")!
    static let dylibPath = "/usr/local/lib/libfuse-t.dylib"

    private let fileExists: (String) -> Bool
    private let fuseTVersion: () -> String?

    public init(fileExists: @escaping (String) -> Bool, fuseTVersion: @escaping () -> String?) {
        self.fileExists = fileExists
        self.fuseTVersion = fuseTVersion
    }

    public static var live: Dependencies {
        Dependencies(fileExists: { FileManager.default.fileExists(atPath: $0) },
                     fuseTVersion: { readInstalledFuseTVersion() })
    }

    public func check() -> DependencyState {
        guard fileExists(Self.dylibPath), let found = fuseTVersion() else { return .fuseTMissing }
        if Self.compare(found, Self.minimumFuseT) == .orderedAscending {
            return .fuseTOutdated(found: found, minimum: Self.minimumFuseT)
        }
        return .ready
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Highest version among receipt ids like `org.fuse-t.core.1.2.9`.
    static func highestCoreVersion(in ids: [String]) -> String? {
        let prefix = "org.fuse-t.core."
        let versions = ids.compactMap { id -> String? in
            guard id.hasPrefix(prefix) else { return nil }
            let v = String(id.dropFirst(prefix.count))
            let ok = !v.isEmpty && v.split(separator: ".", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            return ok ? v : nil
        }
        return versions.max { compare($0, $1) == .orderedAscending }
    }
}

/// Reads the installed FUSE-T version from pkg receipts (nil if none).
public func readInstalledFuseTVersion() -> String? {
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: "/var/db/receipts")) ?? []
    let receiptIDs = ids.filter { $0.hasSuffix(".plist") }.map { String($0.dropLast(6)) }
    if let v = Dependencies.highestCoreVersion(in: receiptIDs) { return v }
    // Fallback: unsuffixed receipt.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
    p.arguments = ["--pkg-info", "org.fuse-t.core"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0, let out = String(data: data, encoding: .utf8) else { return nil }
    for line in out.split(separator: "\n") where line.hasPrefix("version:") {
        return line.dropFirst(8).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

public func resolveAppURL(fileExists: (String) -> Bool) -> URL? {
    let candidates = [
        "/Applications/DaVinci Resolve/DaVinci Resolve.app",
        "/Applications/DaVinci Resolve Studio/DaVinci Resolve Studio.app",
    ]
    return candidates.first(where: fileExists).map { URL(fileURLWithPath: $0) }
}
