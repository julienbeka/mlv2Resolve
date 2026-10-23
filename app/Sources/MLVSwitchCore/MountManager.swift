// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

// MARK: - Seams

public protocol ProcessLauncher: Sendable {
    func launch(_ executable: URL, _ args: [String]) throws -> any RunningProcess
}

public protocol RunningProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
    /// Called once, from an arbitrary thread, with the exit status.
    var onExit: (@Sendable (Int32) -> Void)? { get set }
}

public protocol Unmounter: Sendable {
    /// Unmounts `path`; a no-op when it is not a mount point.
    func unmount(_ path: URL) throws
    func isMountPoint(_ path: URL) -> Bool
}

public enum MountError: Error, Equatable {
    case noFreePort
    case mountPointBusy(URL)
    case unmountFailed(URL)
}

// MARK: - Manager

/// Owns one supervised `mlvfs -f` process per mounted shoot.
public actor MountManager {
    private struct Entry {
        let id: UUID
        let shoot: Shoot
        let url: URL
        let port: Int
        let process: any RunningProcess
    }

    private let mlvfs: URL
    private let fpmDir: URL
    private let indexDir: URL
    private let paths: MountPaths
    private let launcher: any ProcessLauncher
    private let unmounter: any Unmounter
    private let http: @Sendable (URL) async throws -> Void
    private let portRange: ClosedRange<Int>
    private let isPortFree: @Sendable (Int) -> Bool
    private var entries: [UUID: Entry] = [:]

    public init(mlvfs: URL, fpmDir: URL, indexDir: URL, paths: MountPaths,
                launcher: any ProcessLauncher, unmounter: any Unmounter,
                http: @escaping @Sendable (URL) async throws -> Void,
                portRange: ClosedRange<Int> = 8100...8199,
                isPortFree: @escaping @Sendable (Int) -> Bool) {
        self.mlvfs = mlvfs
        self.fpmDir = fpmDir
        self.indexDir = indexDir
        self.paths = paths
        self.launcher = launcher
        self.unmounter = unmounter
        self.http = http
        self.portRange = portRange
        self.isPortFree = isPortFree
    }

    public var mounted: [Shoot: URL] {
        Dictionary(entries.values.map { ($0.shoot, $0.url) }, uniquingKeysWith: { a, _ in a })
    }

    /// Web-GUI port of a mounted shoot (internal, for tests).
    func port(for shoot: Shoot) -> Int? { entry(for: shoot)?.port }

    /// Launches mlvfs for `shoot` and returns its mount point. The mount itself
    /// appears shortly after this returns. Mounting an already-mounted shoot
    /// (same folder) returns its existing mount point.
    @discardableResult
    public func mount(_ shoot: Shoot, mode: DualISOMode,
                      fixBadPixels: Bool = true, fixFocusPixels: Bool = true) throws -> URL {
        if let existing = entry(for: shoot) { return existing.url }

        let url = paths.mountPoint(for: shoot, alreadyMounted: mounted)
        if unmounter.isMountPoint(url) { throw MountError.mountPointBusy(url) }
        let port = try freePort()

        var args = [url.path, "--mlv-dir=\(shoot.folder.path)", "--resolve-naming"]
        if fixBadPixels { args.append("--bad-pix") }
        if !fixFocusPixels { args.append("--no-focus-pixels") }
        args += [mode.engineFlag, "--fpm-dir=\(fpmDir.path)", "--index-dir=\(indexDir.path)",
                 "--port=\(port)", "-o", "ro", "-o", "volname=\(shoot.name)",
                 "-f"] // foreground: otherwise mlvfs daemonizes and we lose the process

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let process: any RunningProcess
        do {
            process = try launcher.launch(mlvfs, args)
        } catch {
            removeIfEmpty(url)
            throw error
        }
        let id = UUID()
        entries[id] = Entry(id: id, shoot: shoot, url: url, port: port, process: process)
        process.onExit = { [weak self] status in
            guard let self else { return }
            Task { await self.processExited(id, status: status) }
        }
        // The process may have died between launch and installing the handler.
        if !process.isRunning { processExited(id, status: -1) }
        return url
    }

    /// Unmounts the shoot's path, stops its process and removes the empty
    /// mount-point directory. Throws (and keeps the shoot mounted) when the
    /// volume cannot be unmounted, e.g. because files are in use.
    public func unmount(_ shoot: Shoot) throws {
        guard let e = entry(for: shoot) else { return }
        try unmounter.unmount(e.url)
        entries[e.id] = nil
        e.process.onExit = nil
        if e.process.isRunning { e.process.terminate() }
        removeIfEmpty(e.url)
    }

    public func unmountAll() {
        for e in entries.values { try? unmount(e.shoot) }
    }

    /// Switches the dual ISO mode of every running mlvfs live. Unreachable
    /// processes are ignored.
    public func setMode(_ mode: DualISOMode) async {
        let urls = entries.values.compactMap {
            URL(string: "http://127.0.0.1:\($0.port)/set_value?dual_iso=\(mode.rawValue)")
        }
        let http = self.http
        await withTaskGroup(of: Void.self) { group in
            for url in urls { group.addTask { try? await http(url) } }
        }
    }

    /// Unmounts mount points under `paths.root` that no live process of this
    /// manager owns, then removes empty non-mounted child directories.
    /// Non-empty regular directories are never touched.
    public func cleanStaleMounts() throws {
        let owned = Set(entries.values.filter { $0.process.isRunning }
            .map { $0.url.standardizedFileURL.path })
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.root.path) else { return }
        let children = try fm.contentsOfDirectory(at: paths.root, includingPropertiesForKeys: nil)
        for child in children where !owned.contains(child.standardizedFileURL.path) {
            if unmounter.isMountPoint(child) {
                try? unmounter.unmount(child)
            }
            removeIfEmpty(child)
        }
    }

    // MARK: Private

    private func entry(for shoot: Shoot) -> Entry? {
        let key = shoot.folder.standardizedFileURL
        return entries.values.first { $0.shoot.folder.standardizedFileURL == key }
    }

    private func freePort() throws -> Int {
        let used = Set(entries.values.map(\.port))
        guard let port = portRange.first(where: { !used.contains($0) && isPortFree($0) }) else {
            throw MountError.noFreePort
        }
        return port
    }

    private func processExited(_ id: UUID, status: Int32) {
        guard let e = entries.removeValue(forKey: id) else { return } // already unmounted by us
        try? unmounter.unmount(e.url)
        removeIfEmpty(e.url)
    }

    /// Removes `url` only if it is an empty directory and not a mount point.
    private func removeIfEmpty(_ url: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
              !unmounter.isMountPoint(url),
              let contents = try? fm.contentsOfDirectory(atPath: url.path), contents.isEmpty
        else { return }
        rmdir(url.path)
    }
}

// MARK: - Real implementations

public extension MountManager {
    /// True when nothing listens on 127.0.0.1:`port` (probed with `bind()`).
    @Sendable static func isLocalPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    /// Plain GET; throws on transport errors and non-2xx responses.
    @Sendable static func httpGet(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }
}

public struct FoundationLauncher: ProcessLauncher {
    public init() {}

    public func launch(_ executable: URL, _ args: [String]) throws -> any RunningProcess {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let running = FoundationProcess(p)
        p.terminationHandler = { [running] proc in running.exited(proc.terminationStatus) }
        try p.run()
        return running
    }
}

/// `Process` wrapper; an exit that happens before `onExit` is set is replayed
/// when the handler is installed.
final class FoundationProcess: RunningProcess, @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var handler: (@Sendable (Int32) -> Void)?
    private var exitStatus: Int32?

    init(_ process: Process) { self.process = process }

    var isRunning: Bool { lock.withLock { exitStatus == nil } && process.isRunning }

    func terminate() { if process.isRunning { process.terminate() } }

    var onExit: (@Sendable (Int32) -> Void)? {
        get { lock.withLock { handler } }
        set {
            let replay: Int32? = lock.withLock {
                handler = newValue
                return newValue == nil ? nil : exitStatus
            }
            if let replay { newValue?(replay) }
        }
    }

    fileprivate func exited(_ status: Int32) {
        let h: (@Sendable (Int32) -> Void)? = lock.withLock {
            exitStatus = status
            return handler
        }
        h?(status)
    }
}

/// `/sbin/umount`, falling back to `/usr/sbin/diskutil unmount force`.
public struct UmountUnmounter: Unmounter {
    public init() {}

    public func unmount(_ path: URL) throws {
        guard isMountPoint(path) else { return }
        if run("/sbin/umount", [path.path]) == 0, !isMountPoint(path) { return }
        _ = run("/usr/sbin/diskutil", ["unmount", "force", path.path])
        if isMountPoint(path) { throw MountError.unmountFailed(path) }
    }

    /// True when `path` is the root of a mounted file system (`statfs` f_mntonname).
    public func isMountPoint(_ path: URL) -> Bool {
        guard let real = realpath(path.path, nil) else { return false }
        defer { free(real) }
        var fs = statfs()
        guard statfs(real, &fs) == 0 else { return false }
        let mountedOn = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mountedOn == String(cString: real)
    }

    private func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
