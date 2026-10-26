// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

// MARK: - Seams

public protocol ProcessLauncher: Sendable {
    /// `log`: file receiving the process's stdout and stderr (appended), or nil to discard them.
    func launch(_ executable: URL, _ args: [String], log: URL?) throws -> any RunningProcess
}

public protocol RunningProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
    /// Sends `sig` to the process. Throws when it cannot be delivered (the
    /// process is gone).
    func signal(_ sig: Int32) throws
    /// Called once, from an arbitrary thread, with the exit status.
    var onExit: (@Sendable (Int32) -> Void)? { get set }
}

public protocol Unmounter: Sendable {
    /// Unmounts `path`; a no-op when it is not a mount point. Without `force`
    /// only a polite unmount is tried and a busy volume throws (it stays
    /// mounted). `force` skips the polite attempt: quit, unplug, crash cleanup.
    /// May block: the manager calls it off its actor.
    func unmount(_ path: URL, force: Bool) throws
    /// False for symlinks, even if they point at a mount point.
    func isMountPoint(_ path: URL) -> Bool
}

public extension Unmounter {
    func unmount(_ path: URL) throws { try unmount(path, force: false) }
}

public enum MountError: Error, Equatable {
    case mountPointBusy(URL)
    case unmountFailed(URL)
    case unmountInProgress(URL)
    /// The engine exited before the mount was up.
    case exitedDuringStartup(status: Int32)
    /// The mount did not appear within the readiness timeout.
    case startupTimedOut(URL)
    /// The signal could not be delivered to the engine (it is no longer running).
    case signalFailed(errno: Int32)
}

public enum MountEvent: Sendable, Equatable {
    /// A supervised mlvfs exited on its own (crash or external kill); its
    /// mount has been cleaned up. Not sent for deliberate unmounts.
    case exited(Shoot, status: Int32)
}

// MARK: - Manager

/// Owns one supervised `mlvfs -f` process per mounted shoot.
///
/// State lives on the actor; blocking unmount tools run off it. An entry
/// being unmounted keeps its path reserved until the unmount ends. The dual
/// ISO mode is switched live by signals: SIGUSR1 = montage fluide (mode 1),
/// SIGUSR2 = qualité étalonnage (mode 2).
public actor MountManager {
    /// Actor-confined.
    private final class Entry {
        let id: UUID
        let shoot: Shoot
        let url: URL
        let process: any RunningProcess
        let exitStatus: ExitBox
        var unmountTask: Task<Void, Error>?
        /// The mount appeared: the engine has installed its signal handlers
        /// (before then SIGUSR1/SIGUSR2 would kill it).
        var isReady = false
        /// Mode the engine runs in: the launch flag, then each delivered signal.
        var mode: DualISOMode

        init(id: UUID, shoot: Shoot, url: URL, process: any RunningProcess, exitStatus: ExitBox,
             mode: DualISOMode) {
            self.id = id; self.shoot = shoot; self.url = url
            self.process = process; self.exitStatus = exitStatus; self.mode = mode
        }

        var isLive: Bool { process.isRunning }
    }

    private let mlvfs: URL
    private let fpmDir: URL
    private let indexDir: URL
    private let logDir: URL?
    private let paths: MountPaths
    private let launcher: any ProcessLauncher
    private let unmounter: any Unmounter
    private let readinessTimeout: Duration
    private let pollInterval: Duration
    private var entries: [UUID: Entry] = [:]
    /// Last mode passed to `setMode`; engines that become ready in another
    /// mode are switched to it.
    private var currentMode: DualISOMode?
    /// Post-crash cleanups in flight, by mount-point path.
    private var cleanups: [String: Task<Void, Never>] = [:]

    public nonisolated let events: AsyncStream<MountEvent>
    private let eventSink: AsyncStream<MountEvent>.Continuation

    public init(mlvfs: URL, fpmDir: URL, indexDir: URL, logDir: URL? = nil, paths: MountPaths,
                launcher: any ProcessLauncher, unmounter: any Unmounter,
                readinessTimeout: Duration = .seconds(5),
                pollInterval: Duration = .milliseconds(50)) {
        self.mlvfs = mlvfs
        self.fpmDir = fpmDir
        self.indexDir = indexDir
        self.logDir = logDir
        self.paths = paths
        self.launcher = launcher
        self.unmounter = unmounter
        self.readinessTimeout = readinessTimeout
        self.pollInterval = pollInterval
        (events, eventSink) = AsyncStream.makeStream(of: MountEvent.self)
    }

    deinit { eventSink.finish() }

    /// Shoots whose engine is running.
    public var mounted: [Shoot: URL] {
        Dictionary(entries.values.filter(\.isLive).map { ($0.shoot, $0.url) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// Launches mlvfs for `shoot` and returns once the mount is up (bounded
    /// by the readiness timeout). Mounting an already-mounted
    /// shoot (same folder) returns its existing mount point.
    @discardableResult
    /// - Parameter samplingFixes: clips whose header disagrees with the shoot majority (`SqueezeFix.analyze`,
    ///   computed by the caller); served with the corrected sampling.
    public func mount(_ shoot: Shoot, mode: DualISOMode,
                      fixBadPixels: Bool = true, fixFocusPixels: Bool = true,
                      samplingFixes: [SqueezeFix.Fix] = []) async throws -> URL {
        var url: URL
        while true {
            if let e = entry(for: shoot) {
                if e.unmountTask != nil { throw MountError.unmountInProgress(e.url) }
                if e.isLive {
                    try await awaitReady(e.id)
                    return e.url
                }
                await reap(e.id) // died, exit callback not handled yet
                continue
            }
            url = paths.mountPoint(for: shoot, alreadyMounted: allMounts)
            if let cleanup = cleanups[url.standardizedFileURL.path] {
                await cleanup.value
                continue // state may have changed while suspended
            }
            break
        }
        if unmounter.isMountPoint(url) { throw MountError.mountPointBusy(url) }

        var args = [url.path, "--mlv-dir=\(shoot.folder.path)", "--resolve-naming"]
        if fixBadPixels { args.append("--bad-pix") }
        if !fixFocusPixels { args.append("--no-focus-pixels") }
        // Clips whose header disagrees with the shoot majority (e.g. 1x3 recorded as 1x1): DefaultScale fixed.
        if let fix = SqueezeFix.engineArgument(samplingFixes) { args.append(fix) }
        args += [mode.engineFlag, "--fpm-dir=\(fpmDir.path)", "--index-dir=\(indexDir.path)",
                 "-o", "volname=\(Self.volumeName(url.lastPathComponent))",
                 "-f"] // foreground: otherwise mlvfs daemonizes and we lose the process

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let process: any RunningProcess
        do {
            process = try launcher.launch(mlvfs, args,
                                          log: logDir.map { EngineLog.file(in: $0, name: url.lastPathComponent) })
        } catch {
            removeIfEmpty(url)
            throw error
        }
        let id = UUID()
        let box = ExitBox()
        entries[id] = Entry(id: id, shoot: shoot, url: url, process: process, exitStatus: box,
                             mode: mode)
        process.onExit = { [weak self] status in
            box.set(status)
            guard let self else { return }
            Task { await self.processExited(id) }
        }
        try await awaitReady(id)
        return url
    }

    /// Unmounts the shoot's path, stops its process and removes the empty
    /// mount-point directory. Without `force` (user-initiated) a volume in use
    /// is left mounted and this throws; `force` is for quit and unplug.
    public func unmount(_ shoot: Shoot, force: Bool = false) async throws {
        guard let e = entry(for: shoot) else { return }
        if let running = e.unmountTask { return try await running.value }
        guard e.isLive else { return await reap(e.id) }
        let id = e.id
        let task = Task { try await self.performUnmount(id, force: force) }
        e.unmountTask = task
        try await task.value
    }

    public func unmountAll(force: Bool = false) async {
        for e in Array(entries.values) { try? await unmount(e.shoot, force: force) }
    }

    /// Switches the dual ISO mode of every ready mlvfs live by signalling
    /// it (SIGUSR1 = montage fluide, SIGUSR2 = qualité étalonnage). Returns
    /// the shoots whose engine could not be signalled (process gone).
    /// Engines still starting are not signalled (that would kill them): they
    /// receive the mode once their mount is up.
    @discardableResult
    public func setMode(_ mode: DualISOMode) async -> [Shoot] {
        currentMode = mode
        var failed: [Shoot] = []
        for e in entries.values where e.isReady && e.isLive && e.unmountTask == nil {
            do {
                try e.process.signal(mode.signal)
                e.mode = mode
            } catch { failed.append(e.shoot) }
        }
        return failed
    }

    /// Unmounts mount points under `paths.root` that no live process of this
    /// manager owns, then removes empty non-mounted child directories.
    /// Symlinks, files and non-empty directories are never touched.
    public func cleanStaleMounts() async throws {
        try await cleanStaleMounts(in: paths.root)
    }

    /// One-time cleanup of the previous app's mount root: unmounts stale mount
    /// points inside it, removes empty child directories, then the root itself
    /// if it ended up empty (`rmdir` only, never recursive).
    /// Does nothing unless `root` is a real directory (a symlink is never followed).
    public func cleanLegacyRoot(_ root: URL) async {
        var st = stat()
        guard lstat(root.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return }
        try? await cleanStaleMounts(in: root)
        rmdir(root.path)
    }

    private func cleanStaleMounts(in root: URL) async throws {
        for e in Array(entries.values) where !e.isLive && e.unmountTask == nil { await reap(e.id) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for child in children {
            var st = stat()
            guard lstat(child.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            let key = child.standardizedFileURL.path
            let owned = Set(entries.values.map { $0.url.standardizedFileURL.path })
            guard !owned.contains(key), cleanups[key] == nil else { continue }
            if unmounter.isMountPoint(child) {
                try? await unmountOffActor(child, force: true) // no engine of ours serves it
            }
            removeIfEmpty(child)
        }
    }

    /// Finder volume name for `-o volname=`: libfuse splits `-o` values on
    /// commas and treats `\\` as an escape, and `=` separates key and value,
    /// so those become spaces (runs of spaces collapsed, never empty).
    static func volumeName(_ name: String) -> String {
        let replaced = String(name.map { ",\\=".contains($0) ? " " : $0 })
        let collapsed = replaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return collapsed.isEmpty ? "mlv2Resolve" : collapsed
    }

    // MARK: Private

    private var allMounts: [Shoot: URL] {
        Dictionary(entries.values.map { ($0.shoot, $0.url) }, uniquingKeysWith: { a, _ in a })
    }

    private func entry(for shoot: Shoot) -> Entry? {
        let key = shoot.folder.standardizedFileURL
        return entries.values.first { $0.shoot.folder.standardizedFileURL == key }
    }

    /// Polls until the mount point is mounted.
    /// On failure the entry is torn down before throwing.
    private func awaitReady(_ id: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + readinessTimeout
        guard let initial = entries[id] else { throw MountError.exitedDuringStartup(status: -1) }
        let (url, process, box) = (initial.url, initial.process, initial.exitStatus)
        while true {
            let current = entries[id]
            if current == nil || !process.isRunning {
                if let current, current.unmountTask == nil { await reap(id) }
                throw MountError.exitedDuringStartup(status: box.get() ?? -1)
            }
            if unmounter.isMountPoint(url) {
                markReady(id)
                return
            }
            if clock.now >= deadline {
                if let current, current.unmountTask == nil {
                    let task = Task { try await self.performUnmount(id, force: true) } // our own failed start
                    current.unmountTask = task
                    try? await task.value
                }
                throw MountError.startupTimedOut(url)
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Marks the entry ready and, if `setMode` chose another mode while it was
    /// starting, switches it now. A failed signal means the engine died: its
    /// exit is handled by the exit callback.
    private func markReady(_ id: UUID) {
        guard let e = entries[id], e.unmountTask == nil else { return }
        e.isReady = true
        if let mode = currentMode, mode != e.mode, (try? e.process.signal(mode.signal)) != nil {
            e.mode = mode
        }
    }

    /// Deliberate unmount. Ordering: unmount the path (off-actor), then drop
    /// the entry, then stop the process, then remove the empty directory.
    private func performUnmount(_ id: UUID, force: Bool) async throws {
        guard let e = entries[id] else { return }
        do {
            try await unmountOffActor(e.url, force: force)
        } catch {
            e.unmountTask = nil
            if !e.isLive { await reap(id) } // engine died meanwhile
            throw error
        }
        entries[id] = nil
        e.process.onExit = nil
        if e.process.isRunning { e.process.terminate() }
        removeIfEmpty(e.url)
    }

    private func processExited(_ id: UUID) async {
        guard let e = entries[id], e.unmountTask == nil else { return } // deliberate unmount owns it
        await reap(id)
    }

    /// Unexpected exit: drop the entry, report it, force-unmount the path.
    private func reap(_ id: UUID) async {
        guard let e = entries.removeValue(forKey: id) else { return }
        e.process.onExit = nil
        eventSink.yield(.exited(e.shoot, status: e.exitStatus.get() ?? -1))
        let url = e.url
        let key = url.standardizedFileURL.path
        let cleanup = Task { _ = try? await self.unmountOffActor(url, force: true) }
        cleanups[key] = cleanup
        await cleanup.value
        cleanups[key] = nil
        removeIfEmpty(url)
    }

    private nonisolated func unmountOffActor(_ url: URL, force: Bool) async throws {
        let unmounter = self.unmounter
        try await Task.detached { try unmounter.unmount(url, force: force) }.value
    }

    /// Removes `url` only if it is a real empty directory and not a mount point.
    private func removeIfEmpty(_ url: URL) {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              !unmounter.isMountPoint(url),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
              contents.isEmpty
        else { return }
        rmdir(url.path)
    }
}

/// Exit status recorded synchronously by the process callback.
final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    func set(_ s: Int32) { lock.withLock { status = s } }
    func get() -> Int32? { lock.withLock { status } }
}

// MARK: - Real implementations

public struct FoundationLauncher: ProcessLauncher {
    public init() {}

    public func launch(_ executable: URL, _ args: [String], log: URL?) throws -> any RunningProcess {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        // A log that cannot be opened must not prevent the mount.
        let handle = log.flatMap { try? EngineLog.openForAppend($0) }
        if let handle {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "=== \(stamp) \(executable.lastPathComponent) \(args.joined(separator: " "))\n"
            try? handle.write(contentsOf: Data(line.utf8))
        }
        p.standardOutput = handle ?? FileHandle.nullDevice
        p.standardError = handle ?? FileHandle.nullDevice
        let running = FoundationProcess(p)
        p.terminationHandler = { [running] proc in running.exited(proc.terminationStatus) }
        defer { try? handle?.close() } // the child keeps its own descriptors
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

    func signal(_ sig: Int32) throws {
        guard isRunning else { throw MountError.signalFailed(errno: ESRCH) }
        if kill(process.processIdentifier, sig) != 0 { throw MountError.signalFailed(errno: errno) }
    }

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

/// `/sbin/umount` (polite), or `/sbin/umount -f` when forced. diskutil is
/// deliberately not used: it goes through DiskArbitration, which asks running
/// apps (including this one) to approve the unmount, and deadlocks if the
/// caller's main thread is busy. Each tool is bounded by a timeout so a dead localhost NFS server cannot
/// hang the caller indefinitely.
public struct UmountUnmounter: Unmounter {
    let umountTimeout: TimeInterval
    let forceTimeout: TimeInterval
    /// Test seam: when set, replaces the real process runner and mount-point check.
    let runner: (@Sendable (String, [String], TimeInterval) -> Int32?)?
    let mountCheck: (@Sendable (URL) -> Bool)?

    public init(umountTimeout: TimeInterval = 5, forceTimeout: TimeInterval = 10) {
        self.init(umountTimeout: umountTimeout, forceTimeout: forceTimeout, runner: nil, mountCheck: nil)
    }

    init(umountTimeout: TimeInterval = 5, forceTimeout: TimeInterval = 10,
         runner: (@Sendable (String, [String], TimeInterval) -> Int32?)?,
         mountCheck: (@Sendable (URL) -> Bool)?) {
        self.umountTimeout = umountTimeout
        self.forceTimeout = forceTimeout
        self.runner = runner
        self.mountCheck = mountCheck
    }

    public func unmount(_ path: URL, force: Bool) throws {
        guard isMountPoint(path) else { return }
        if !force {
            // Polite only: a volume with open files (Resolve) stays mounted.
            _ = run("/sbin/umount", [path.path], timeout: umountTimeout)
            if isMountPoint(path) { throw MountError.unmountFailed(path) }
            return
        }
        _ = run("/sbin/umount", ["-f", path.path], timeout: forceTimeout)
        if isMountPoint(path) { throw MountError.unmountFailed(path) }
    }

    /// True when `path` is the root of a mounted file system (`statfs`
    /// f_mntonname). Symlinks are never mount points here.
    public func isMountPoint(_ path: URL) -> Bool {
        if let mountCheck { return mountCheck(path) }
        var st = stat()
        guard lstat(path.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return false }
        guard let real = realpath(path.path, nil) else { return false }
        defer { free(real) }
        var fs = statfs()
        guard statfs(real, &fs) == 0 else { return false }
        let mountedOn = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mountedOn == String(cString: real)
    }

    /// Exit status, or nil if the tool could not start or timed out (it is
    /// then terminated, and killed if it ignores SIGTERM).
    private func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> Int32? {
        if let runner { return runner(tool, args, timeout) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            return nil
        }
        return p.terminationStatus
    }
}
