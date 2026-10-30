// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation

/// Gyro sync state of one clip, keyed by its standardized MLV path.
public enum ClipGyroState: Equatable, Sendable {
    case pending, running
    case synced(r2: Double, log: String, offsetMs: Double)
    /// A `.gyroflow` is there that mlv2Resolve did not write (e.g. made with Gyroflow / NiYien): left alone.
    case existing
    case noLog, notEnoughMotion, ambiguous
    case failed(String)
}

/// Terminal states include clips needing attention: the counter measures finished work, not sync success.
public struct GyroProgress: Equatable, Sendable {
    public let total: Int
    public let completed: Int
    public var isActive: Bool { completed < total }
    public init(states: [ClipGyroState]) {
        total = states.count
        completed = states.filter { $0 != .pending && $0 != .running }.count
    }
}

/// Which lens profile went into a clip's `.gyroflow`.
public enum LensProfileKind: String, Sendable {
    /// Distortion-free profile computed from the focal length.
    case computed
    /// A calibrated profile imported for the lens.
    case calibrated
}

/// Background gyro sync: for every mounted shoot, finds the SenseFlow A1 logs of the chosen folder, syncs each
/// MLV clip and writes its `.gyroflow` next to the MLV (the running MLVFS mount then lists it in the clip folder).
///
/// Never changes MLV files or original gyro logs. Writes clip-sized log excerpts next to the MLV.
/// Owned legacy `.gyroflow` files are optimized on mount; other replacements require regeneration,
/// a lens or position change. The replaced file is first copied to
/// `<backupsRoot>/<shoot name>/<name>-<yyyyMMdd-HHmmss>.gyroflow`.
///
/// Persisted in `defaults` (paths are standardized, see `AppState.key`):
/// - `gyroLenses`: JSON `[Lens]`.
/// - `gyroShootLens` / `gyroClipLens`: `[path: lens UUID string]` (shoot folder / MLV path).
/// - `gyroShootPosition` / `gyroClipPosition`: `[path: MountingPosition.rawValue]`.
/// - `gyroDefaultPosition`: `MountingPosition.rawValue`, for shoots without their own position (default `.top`).
/// - `gyroWritten`: `[String]`, MLV paths whose `.gyroflow` mlv2Resolve wrote.
/// - `gyroWrittenMeta`: `[MLV path: ["r2": Double, "log": String, "offsetMs": Double, "profile": String]]`, to
///   restore `.synced` and tell which lens profile was used (`profile`: `LensProfileKind.rawValue`).
///
/// One job at a time per shoot (serial chain); different shoots run concurrently. Heavy work (log reading,
/// motion, solving, writing) runs off the main actor.
@MainActor
public final class GyroSyncCoordinator: ObservableObject {
    public typealias MotionRunner = @Sendable (URL) async throws -> [MotionSample]
    /// (motion, fps, log, searchMs) -> result; production calls `GyroSync.solve`.
    typealias Solver = @Sendable ([MotionSample], Double, A1Log, ClosedRange<Int>) throws -> SyncResult
    /// (mount point, MLV file) -> clip folder inside the mount.
    typealias ClipDirResolver = @Sendable (URL, URL) -> URL?

    enum Key {
        static let lenses = "gyroLenses"
        static let shootLens = "gyroShootLens"
        static let clipLens = "gyroClipLens"
        static let shootPosition = "gyroShootPosition"
        static let clipPosition = "gyroClipPosition"
        static let defaultPosition = "gyroDefaultPosition"
        static let written = "gyroWritten"
        static let meta = "gyroWrittenMeta"
    }

    @Published public private(set) var states: [String: ClipGyroState] = [:]

    public var progress: GyroProgress { GyroProgress(states: Array(states.values)) }

    public var lenses: [Lens] {
        get {
            guard let d = defaults.data(forKey: Key.lenses) else { return [] }
            return (try? JSONDecoder().decode([Lens].self, from: d)) ?? []
        }
        set {
            objectWillChange.send()
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.lenses)
        }
    }

    private let motionRunner: MotionRunner
    private let fullMotionRunner: MotionRunner?
    private let solver: Solver
    private let clipDirResolver: ClipDirResolver
    private let defaults: UserDefaults
    private let backupsRoot: URL

    private struct Context {
        let shoot: Shoot; let mountPoint: URL; let chosenFolder: URL
        /// Relative MLV path -> squeeze corrected from the shoot majority (`SqueezeFix`), as the engine serves it.
        let squeezeFixes: [String: Int]
    }
    /// Per shoot folder key.
    private var contexts: [String: Context] = [:]
    private var tails: [String: Task<Void, Never>] = [:]
    private var tasks: [String: [UUID: Task<Void, Never>]] = [:]
    /// Per chosen folder key: clips synced this session (log gyro dropped), for the clock skew.
    private var syncedByFolder: [String: [(clip: ClipTiming, log: A1Log, lagMs: Int)]] = [:]
    /// Per chosen folder key (internal for tests).
    var skews: [String: TimeInterval] = [:]
    /// Per chosen folder key: header-only logs by path, with the file size and date they were read at.
    private var logIndex: [String: [String: LogIndexEntry]] = [:]
    private let decodedLogs: DecodedLogCache

    /// Test hook: every (log, searchMs) handed to the solver.
    var onSolve: (@MainActor (URL, ClosedRange<Int>) -> Void)?

    public convenience init(motionRunner: @escaping MotionRunner, defaults: UserDefaults, backupsRoot: URL,
                            fullMotionRunner: MotionRunner? = nil) {
        self.init(motionRunner: motionRunner, defaults: defaults, backupsRoot: backupsRoot,
                  solver: { try GyroSync.solve(motion: $0, fps: $1, gyro: $2.gyro, rateHz: $2.rateHz, searchMs: $3) },
                  clipDirResolver: GyroSyncCoordinator.clipDir(mountPoint:mlv:), fullMotionRunner: fullMotionRunner)
    }

    /// - Parameter logReader: decodes a full log (production: `A1Log.read`); only candidate logs are decoded,
    ///   the last two are kept.
    init(motionRunner: @escaping MotionRunner, defaults: UserDefaults, backupsRoot: URL,
         solver: @escaping Solver, clipDirResolver: @escaping ClipDirResolver,
         logReader: @escaping @Sendable (URL) throws -> A1Log = A1Log.read,
         fullMotionRunner: MotionRunner? = nil) {
        decodedLogs = DecodedLogCache(capacity: 2, reader: logReader)
        self.motionRunner = motionRunner
        self.fullMotionRunner = fullMotionRunner
        self.defaults = defaults
        self.backupsRoot = backupsRoot
        self.solver = solver
        self.clipDirResolver = clipDirResolver
    }

    // MARK: Settings

    /// Key of a shoot in the settings and `states` APIs (standardized folder path).
    public static func key(of shoot: Shoot) -> String { AppState.key(shoot.folder) }
    /// Key of a clip in the settings and `states` APIs (standardized path of its first MLV file).
    public static func key(of clip: Clip) -> String? { clip.files.first.map(AppState.key) }

    /// Position of the shoots that have none of their own. Changing it only affects clips synced afterwards
    /// (files already written are kept).
    public var defaultPosition: MountingPosition {
        get { defaults.string(forKey: Key.defaultPosition).flatMap(MountingPosition.init(rawValue:)) ?? .top }
        set {
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Key.defaultPosition)
        }
    }

    public func defaultLens(forShoot shoot: String) -> Lens? { lens(id: dict(Key.shootLens)[shoot]) }

    /// Regenerates the shoot's clips that use the default lens and whose file mlv2Resolve wrote; `.existing` stay.
    public func setDefaultLens(_ lens: Lens?, forShoot shoot: String) {
        setEntry(Key.shootLens, shoot, lens?.id.uuidString)
        shootDefaultsChanged(shoot, overridden: { self.dict(Key.clipLens)[$0] != nil })
    }

    /// The clip's own lens (nil: it uses the shoot's default).
    public func ownLens(forClip clip: String) -> Lens? { lens(id: dict(Key.clipLens)[clip]) }

    public func lens(forClip clip: String) -> Lens? {
        if let own = lens(id: dict(Key.clipLens)[clip]) { return own }
        return shootKey(ofClip: clip).flatMap(defaultLens(forShoot:))
    }

    /// Explicit regeneration of that clip (backup first if a file is there).
    public func setLens(_ lens: Lens?, forClip clip: String) {
        setEntry(Key.clipLens, clip, lens?.id.uuidString)
        clipSettingChanged(clip)
    }

    public func position(forShoot shoot: String) -> MountingPosition {
        dict(Key.shootPosition)[shoot].flatMap(MountingPosition.init(rawValue:)) ?? defaultPosition
    }

    public func setPosition(_ p: MountingPosition, forShoot shoot: String) {
        setEntry(Key.shootPosition, shoot, p.rawValue)
        shootDefaultsChanged(shoot, overridden: { self.dict(Key.clipPosition)[$0] != nil })
    }

    /// The clip's own position (nil: it uses the shoot's).
    public func ownPosition(forClip clip: String) -> MountingPosition? {
        dict(Key.clipPosition)[clip].flatMap(MountingPosition.init(rawValue:))
    }

    public func position(forClip clip: String) -> MountingPosition {
        if let p = ownPosition(forClip: clip) { return p }
        return shootKey(ofClip: clip).map(position(forShoot:)) ?? defaultPosition
    }

    /// nil: back to the shoot's position. Regenerates that clip.
    public func setPosition(_ p: MountingPosition?, forClip clip: String) {
        setEntry(Key.clipPosition, clip, p?.rawValue)
        clipSettingChanged(clip)
    }

    /// Removes a lens and the shoot/clip choices pointing to it, then re-evaluates the mounted clips that used
    /// it: files mlv2Resolve wrote are rewritten with the lens that now applies (backup first), or the clip reports
    /// that a lens is needed. Files mlv2Resolve did not write are left alone.
    public func removeLens(id: UUID) {
        var affected: [String: [String]] = [:]
        for (k, ctx) in contexts {
            let clips = ctx.shoot.clips.compactMap { $0.files.first.map(AppState.key) }
                .filter { lens(forClip: $0)?.id == id }
            if !clips.isEmpty { affected[k] = clips }
        }
        lenses.removeAll { $0.id == id }
        for key in [Key.shootLens, Key.clipLens] {
            objectWillChange.send()
            defaults.set(dict(key).filter { $0.value != id.uuidString }, forKey: key)
        }
        let w = written
        for (k, clips) in affected {
            for c in clips { states[c] = .pending }
            schedule(k, clips: clips, force: Set(clips.filter(w.contains)))
        }
    }

    /// The lens profile used for the clip's last `.gyroflow` written by mlv2Resolve (nil: none written).
    public func profileKind(forClip clip: String) -> LensProfileKind? {
        guard written.contains(clip), let m = defaults.dictionary(forKey: Key.meta)?[clip] as? [String: Any] else {
            return nil
        }
        return (m["profile"] as? String).flatMap(LensProfileKind.init(rawValue:))
    }

    /// A `.gyroflow` mlv2Resolve did not write sits next to the clip's MLV: replacing it needs the user's consent.
    public func hasForeignGyroflow(clip: String) -> Bool {
        guard !written.contains(clip) else { return false }
        return Self.gyroflowExists(mlv: URL(fileURLWithPath: clip))
    }

    /// Whether the MLV's folder holds a `<clip folder>_000000.gyroflow` for it (clip folder named
    /// `<MLV basename><MLV extension>_1_…`, see `clipDir(mountPoint:mlv:)`).
    nonisolated static func gyroflowExists(mlv: URL) -> Bool {
        let prefix = mlv.deletingPathExtension().lastPathComponent + mlv.pathExtension + "_1_"
        let suffix = GyroflowProject.fileName(clipDir: "")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: mlv.deletingLastPathComponent().path)) ?? []
        return names.contains { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
    }

    // MARK: Mount events

    /// Syncs every clip of the shoot; returns when that job is done (or cancelled).
    /// - Parameter squeezeFixes: the mount's header corrections (`SqueezeFix.Analysis.squeezeByName`).
    public func shootMounted(_ shoot: Shoot, mountPoint: URL, chosenFolder: URL,
                             squeezeFixes: [String: Int] = [:]) async {
        let k = AppState.key(shoot.folder)
        contexts[k] = Context(shoot: shoot, mountPoint: mountPoint, chosenFolder: chosenFolder,
                              squeezeFixes: squeezeFixes)
        let clips = shoot.clips.compactMap { $0.files.first.map(AppState.key) }
        for c in clips where !isActive(states[c]) { states[c] = .pending }
        await enqueue(k, clips: clips, force: [])
    }

    /// Cancels the shoot's jobs: a clip in flight writes nothing unless its atomic write had already started
    /// (that complete file is then recorded as mlv2Resolve's). Its clips leave `states`.
    public func shootUnmounted(_ shoot: Shoot) {
        shootUnmounted(folder: AppState.key(shoot.folder), clips: shoot.clips)
    }

    /// Same, by standardized shoot folder path (for shoots whose `Shoot` value is no longer at hand).
    public func shootUnmounted(folder k: String) {
        shootUnmounted(folder: k, clips: contexts[k]?.shoot.clips ?? [])
    }

    private func shootUnmounted(folder k: String, clips: [Clip]) {
        contexts[k] = nil
        tails[k] = nil
        for t in (tasks.removeValue(forKey: k) ?? [:]).values { t.cancel() }
        for c in clips.compactMap({ $0.files.first.map(AppState.key) }) { states[c] = nil }
    }

    /// Rewrites the clip's `.gyroflow` (old one backed up). No-op if its shoot is not mounted.
    public func regenerate(clip: String) async {
        guard let k = shootKey(ofClip: clip) else { return }
        states[clip] = .pending
        await enqueue(k, clips: [clip], force: [clip])
    }

    /// Waits until no job is queued, including jobs scheduled while waiting.
    public func idle() async {
        while let t = tasks.values.lazy.flatMap(\.values).first { await t.value }
    }

    // MARK: Jobs

    private func clipSettingChanged(_ clip: String) {
        guard let k = shootKey(ofClip: clip) else { return }
        states[clip] = .pending
        schedule(k, clips: [clip], force: [clip])
    }

    private func shootDefaultsChanged(_ shoot: String, overridden: @escaping (String) -> Bool) {
        guard let ctx = contexts[shoot] else { return }
        let written = Set(defaults.stringArray(forKey: Key.written) ?? [])
        let clips = ctx.shoot.clips.compactMap { $0.files.first.map(AppState.key) }
        let force = Set(clips.filter { written.contains($0) && !overridden($0) })
        for c in clips where force.contains(c) || !isSettled(states[c]) { states[c] = .pending }
        schedule(shoot, clips: clips, force: force)
    }

    private func isActive(_ s: ClipGyroState?) -> Bool { s == .running || s == .pending }
    /// Already handled and not to redo without force (`.failed` etc. are retried).
    private func isSettled(_ s: ClipGyroState?) -> Bool {
        switch s { case .synced?, .existing?: return true; default: return false }
    }

    private func enqueue(_ shoot: String, clips: [String], force: Set<String>) async {
        await schedule(shoot, clips: clips, force: force).value
    }

    @discardableResult
    private func schedule(_ shoot: String, clips: [String], force: Set<String>) -> Task<Void, Never> {
        let prev = tails[shoot]
        let id = UUID()
        let task = Task { [weak self] in
            await prev?.value
            guard let self else { return }
            defer {
                self.tasks[shoot]?[id] = nil
                if self.tasks[shoot]?.isEmpty == true { self.tasks[shoot] = nil }
            }
            guard !Task.isCancelled else { return }
            await self.run(shoot, clips: clips, force: force)
        }
        tails[shoot] = task
        tasks[shoot, default: [:]][id] = task
        return task
    }

    private func run(_ shootKey: String, clips: [String], force: Set<String>) async {
        if let ctx = contexts[shootKey] { await refreshLogIndex(ctx.chosenFolder) }
        for clip in clips {
            guard !Task.isCancelled, let ctx = contexts[shootKey] else { return }
            guard let mlv = ctx.shoot.clips.first(where: { $0.files.first.map(AppState.key) == clip })?.files.first
            else { continue }
            await process(clip: clip, mlv: mlv, ctx: ctx, force: force.contains(clip),
                          squeezeFix: ctx.squeezeFixes[SqueezeFix.relativeName(of: mlv, in: ctx.shoot.folder)])
        }
    }

    private func process(clip: String, mlv: URL, ctx: Context, force: Bool, squeezeFix: Int?) async {
        let resolver = clipDirResolver, mountPoint = ctx.mountPoint
        guard let clipDir = await Self.offMain({ resolver(mountPoint, mlv) }) else {
            states[clip] = .failed(String(localized: "Clip folder not found in the mount", bundle: L10n.bundle))
            return
        }
        if Task.isCancelled { return }
        let dest = mlv.deletingLastPathComponent()
            .appendingPathComponent(GyroflowProject.fileName(clipDir: clipDir.lastPathComponent))
        let exists = FileManager.default.fileExists(atPath: dest.path)
        if !exists && written.contains(clip) { unrecordWritten(clip) }  // our file is gone: forget it
        if exists && !force {
            guard written.contains(clip) else { states[clip] = .existing; return }
            states[clip] = .running
            let backup = backupsRoot.appendingPathComponent(MountPaths.sanitize(ctx.shoot.name), isDirectory: true)
            let migration = Task.detached { try GyroLogExcerpt.migrate(at: dest, backupDirectory: backup) }
            let result = await withTaskCancellationHandler(operation: { await migration.result },
                                                          onCancel: { migration.cancel() })
            guard !Task.isCancelled, contexts[AppState.key(ctx.shoot.folder)] != nil else { return }
            switch result {
            case .success: states[clip] = meta(clip) ?? .existing
            case .failure(let error):
                states[clip] = .failed(String(localized: "Couldn't optimize the gyro log: \(error.localizedDescription)", bundle: L10n.bundle))
            }
            return
        }
        guard let lens = lens(forClip: clip) else {
            states[clip] = .failed(String(localized: "Choose a lens for this shoot", bundle: L10n.bundle))
            return
        }
        states[clip] = .running
        let folderKey = AppState.key(ctx.chosenFolder)
        let position = position(forClip: clip)
        let logs = (logIndex[folderKey] ?? [:]).values.map(\.log).sorted { $0.url.path < $1.url.path }
        let job = Job(mlv: mlv, squeezeFix: squeezeFix, clipDir: clipDir, dest: dest, force: force, lens: lens, position: position,
                      logs: logs, decodedLogs: decodedLogs, skew: skews[folderKey],
                      backupDir: backupsRoot.appendingPathComponent(MountPaths.sanitize(ctx.shoot.name), isDirectory: true),
                      motionRunner: motionRunner, fullMotionRunner: fullMotionRunner, solver: solver)
        let hook = onSolve
        var observer: (@Sendable (URL, ClosedRange<Int>) async -> Void)?
        if let hook { observer = { url, r in await hook(url, r) } }
        let outcome = await job.run(onSolve: observer)
        // Unmounted meanwhile (the file, if any, was written before the cancel was seen: atomic, complete).
        if Task.isCancelled || contexts[AppState.key(ctx.shoot.folder)] == nil {
            if case .synced = outcome.state { recordWritten(clip, outcome.state, profile: outcome.profile) }
            return
        }
        // Recorded first, so views refreshed by `states` read the new profile kind.
        if case .synced = outcome.state { recordWritten(clip, outcome.state, profile: outcome.profile) }
        states[clip] = outcome.state
        if let entry = outcome.skewEntry {
            syncedByFolder[folderKey, default: []].append(entry)
            skews[folderKey] = LogMatcher.estimateSkew(syncedByFolder[folderKey] ?? [])
        }
        // Settings changed while this clip was computed: redo it with the new ones.
        if case .synced = outcome.state, self.lens(forClip: clip) != lens || self.position(forClip: clip) != position,
           let k = shootKey(ofClip: clip) {
            states[clip] = .pending
            schedule(k, clips: [clip], force: [clip])
        }
    }

    /// Rescans the chosen folder's logs; only new or changed files get their header read.
    private func refreshLogIndex(_ folder: URL) async {
        let k = AppState.key(folder)
        let old = logIndex[k] ?? [:]
        logIndex[k] = await Self.offMain { Self.scanLogs(folder, old: old) }
    }

    nonisolated static func scanLogs(_ folder: URL, old: [String: LogIndexEntry]) -> [String: LogIndexEntry] {
        var out: [String: LogIndexEntry] = [:]
        for url in A1Log.find(in: folder) {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = v?.fileSize ?? -1, date = v?.contentModificationDate
            if let e = old[url.path], e.size == size, e.modified == date { out[url.path] = e; continue }
            guard let log = try? A1Log.headerOnly(url) else { continue }
            out[url.path] = LogIndexEntry(log: log, size: size, modified: date)
        }
        return out
    }

    // MARK: Persistence

    private var written: Set<String> { Set(defaults.stringArray(forKey: Key.written) ?? []) }

    private func recordWritten(_ clip: String, _ s: ClipGyroState, profile: LensProfileKind) {
        guard case let .synced(r2, log, offsetMs) = s else { return }
        var w = written; w.insert(clip)
        defaults.set(w.sorted(), forKey: Key.written)
        var m = defaults.dictionary(forKey: Key.meta) ?? [:]
        m[clip] = ["r2": r2, "log": log, "offsetMs": offsetMs, "profile": profile.rawValue]
        defaults.set(m, forKey: Key.meta)
    }

    private func unrecordWritten(_ clip: String) {
        var w = written; w.remove(clip)
        defaults.set(w.sorted(), forKey: Key.written)
        var m = defaults.dictionary(forKey: Key.meta) ?? [:]
        m[clip] = nil
        defaults.set(m, forKey: Key.meta)
    }

    private func meta(_ clip: String) -> ClipGyroState? {
        guard let m = defaults.dictionary(forKey: Key.meta)?[clip] as? [String: Any],
              let r2 = m["r2"] as? Double, let log = m["log"] as? String, let off = m["offsetMs"] as? Double
        else { return nil }
        return .synced(r2: r2, log: log, offsetMs: off)
    }

    private func dict(_ key: String) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private func setEntry(_ key: String, _ path: String, _ value: String?) {
        objectWillChange.send()
        var d = dict(key); d[path] = value
        defaults.set(d, forKey: key)
    }

    private func lens(id: String?) -> Lens? {
        guard let id else { return nil }
        return lenses.first { $0.id.uuidString == id }
    }

    /// The mounted shoot holding that MLV path.
    private func shootKey(ofClip clip: String) -> String? {
        contexts.first { $0.value.shoot.clips.contains { $0.files.first.map(AppState.key) == clip } }?.key
    }

    nonisolated private static func offMain<T: Sendable>(_ f: @escaping @Sendable () -> T) async -> T {
        await Task.detached { f() }.value
    }

    // MARK: Clip folder

    /// The clip folder MLVFS shows for `mlv`: the directory of the mount whose name starts with
    /// `<MLV basename><MLV extension>_1_`, as the engine names it with `--resolve-naming`
    /// (`%s%s_1_<date>_0001_C0000`, e.g. `M29-0615MLV_1_2026-08-29_0001_C0000`).
    nonisolated static func clipDir(mountPoint: URL, mlv: URL) -> URL? {
        let prefix = mlv.deletingPathExtension().lastPathComponent + mlv.pathExtension + "_1_"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint.path)) ?? []
        return names.sorted().first { $0.hasPrefix(prefix) }
            .map { mountPoint.appendingPathComponent($0, isDirectory: true) }
    }

    // MARK: Production motion runner

    /// Runs `binary <clip.MLV>` and parses its `frame,dx,dy,peak` CSV. Throws on a non-zero exit (message = last
    /// stderr line); terminates the process when the task is cancelled.
    public nonisolated static func mlvmotionRunner(binary: URL, sampled: Bool = false) -> MotionRunner {
        { mlv in try await runMotion(binary: binary, mlv: mlv, sampled: sampled) }
    }

    struct MotionError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The process plus a cancelled flag, so a cancel that lands before `run()` still stops it.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var cancelled = false
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if process.isRunning { process.terminate() }
        }
        /// Called right after `run()`: terminates the process if a cancel came first.
        func checkAfterLaunch() {
            lock.lock(); defer { lock.unlock() }
            if cancelled, process.isRunning { process.terminate() }
        }
    }

    nonisolated static func runMotion(binary: URL, mlv: URL, sampled: Bool = false) async throws -> [MotionSample] {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binary.path) else {
            throw MotionError(message: String(localized: "The motion analyzer (mlvmotion) is missing from the app. Reinstall mlv2Resolve.", bundle: L10n.bundle))
        }
        let tmp = fm.temporaryDirectory
        let outURL = tmp.appendingPathComponent("mlvmotion-\(UUID().uuidString).csv")
        let errURL = tmp.appendingPathComponent("mlvmotion-\(UUID().uuidString).err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer { try? fm.removeItem(at: outURL); try? fm.removeItem(at: errURL) }
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }

        let box = ProcessBox()
        let p = box.process
        p.executableURL = binary
        p.arguments = [mlv.path] + (sampled ? ["--sampled"] : [])
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try p.run(); box.checkAfterLaunch() } catch { p.terminationHandler = nil; c.resume(throwing: error) }
            }
        } onCancel: {
            box.cancel()
        }
        try Task.checkCancellation()
        guard status == 0 else {
            let text = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            let line = text.split(separator: "\n").last.map(String.init) ?? "mlvmotion exited with status \(status)"
            throw MotionError(message: line)
        }
        return parseCSV((try? String(contentsOf: outURL, encoding: .utf8)) ?? "")
    }

    nonisolated static func parseCSV(_ text: String) -> [MotionSample] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: ",")
            guard f.count == 4, let frame = Int(f[0]), let dx = Double(f[1]), let dy = Double(f[2]),
                  let peak = Double(f[3]) else { return nil }  // header and junk skipped
            return MotionSample(frame: frame, dx: dx, dy: dy, peak: peak)
        }
    }
}

/// The off-main work for one clip.
private struct Job: Sendable {
    let mlv: URL
    /// Corrected horizontal squeeze when the clip's header is known wrong (`SqueezeFix`), else nil.
    let squeezeFix: Int?
    let clipDir: URL, dest: URL
    /// Explicit regeneration: an existing file is replaced (after a backup).
    let force: Bool
    let lens: Lens
    let position: MountingPosition
    /// Header-only logs of the chosen folder; candidates are decoded through `decodedLogs`.
    let logs: [A1Log]
    let decodedLogs: DecodedLogCache
    let skew: TimeInterval?
    let backupDir: URL
    let motionRunner: GyroSyncCoordinator.MotionRunner
    let fullMotionRunner: GyroSyncCoordinator.MotionRunner?
    let solver: GyroSyncCoordinator.Solver

    struct Outcome: Sendable {
        var state: ClipGyroState
        var skewEntry: (clip: ClipTiming, log: A1Log, lagMs: Int)?
        var profile: LensProfileKind = .computed
    }

    nonisolated func run(onSolve: (@Sendable (URL, ClosedRange<Int>) async -> Void)?) async -> Outcome {
        func fail(_ s: String) -> Outcome { Outcome(state: .failed(s)) }
        guard let header = MLVHeader.timing(of: mlv) else {
            return fail(String(localized: "Couldn't read the clip's timing", bundle: L10n.bundle))
        }
        let timing = squeezeFix.map(header.withSqueeze) ?? header
        let full = LogMatcher.candidates(for: timing, logs: logs, skew: nil)
        guard !full.isEmpty else { return Outcome(state: .noLog) }
        // With a learned skew, search near the expected position first; the full search is the fallback.
        let narrowed = skew.map { LogMatcher.candidates(for: timing, logs: logs, skew: $0) }
        if Task.isCancelled { return Outcome(state: .pending) }

        var best: (log: A1Log, result: SyncResult)?
        var sawAmbiguous = false, sawMotion = false
        // Fast windows first. An uncertain result is never written: retry every candidate
        // with the full clip, using the same confidence and ambiguity thresholds.
        for runner in [motionRunner, fullMotionRunner].compactMap({ $0 }) {
            if Task.isCancelled { return Outcome(state: .pending) }
            let motion: [MotionSample]
            do { motion = try await runner(mlv) } catch {
                if Task.isCancelled || error is CancellationError { return Outcome(state: .pending) }
                return fail(String(localized: "Motion analysis failed: \(error.localizedDescription)", bundle: L10n.bundle))
            }
            sawAmbiguous = false; sawMotion = false
            for pass in [narrowed, full].compactMap({ $0 }) where best == nil {
                for c in pass {
                    if Task.isCancelled { return Outcome(state: .pending) }
                    guard let log = try? await decodedLogs.log(c.log.url) else { continue }
                    await onSolve?(c.log.url, c.searchMs)
                    do {
                        let r = try solver(motion, timing.fps, log, c.searchMs)
                        if best.map({ r.r2 > $0.result.r2 }) ?? true { best = (log, r) }
                    } catch SyncRefusal.ambiguous {
                        sawAmbiguous = true
                    } catch SyncRefusal.noOverlap {
                    } catch {
                        sawMotion = true
                    }
                }
            }
            // The sampled engine already analyses short/high-fps clips in full.
            // Retrying identical complete evidence cannot improve a refused result.
            if best != nil || motion.count >= timing.frames - 1 { break }
        }
        guard let best else {
            return Outcome(state: sawAmbiguous ? .ambiguous : sawMotion ? .notEnoughMotion : .noLog)
        }

        let calibration: [String: Any]
        var profile = LensProfileKind.computed
        if let c = lens.calibratedProfiles.lazy.compactMap({ try? LensProfile.calibrated($0, for: timing) }).first {
            calibration = c
            profile = .calibrated
        } else {
            do { calibration = try LensProfile.computed(focalMM: lens.focalMM, lensName: lens.name, timing: timing) }
            catch { return fail(String(localized: "Couldn't build the lens profile: \(String(describing: error))", bundle: L10n.bundle)) }
        }
        let offsetMs = Double(-best.result.lagMs)
        let prepared: GyroLogExcerpt.Prepared
        do {
            let data = try GyroflowProject.make(clipDir: clipDir, timing: timing, log: best.log.url, offsetMs: offsetMs,
                                              calibration: calibration, position: position)
            prepared = try GyroLogExcerpt.prepare(data, destination: dest)
        } catch {
            if Task.isCancelled || error is CancellationError { return Outcome(state: .pending) }
            return fail(String(localized: "Couldn't write the Gyroflow project: \(String(describing: error))", bundle: L10n.bundle))
        }
        if Task.isCancelled { return Outcome(state: .pending) }
        // A file saved meanwhile (e.g. by Gyroflow) is only replaced on an explicit regeneration.
        if !force, FileManager.default.fileExists(atPath: dest.path) { return Outcome(state: .existing) }
        do { try backupIfNeeded() } catch {
            return fail(String(localized: "Couldn't back up the existing Gyroflow project: \(error.localizedDescription)", bundle: L10n.bundle))
        }
        if Task.isCancelled { return Outcome(state: .pending) }
        do {
            try prepared.persistLog()
            try Task.checkCancellation()
            try GyroflowProject.write(prepared.projectData, to: dest)
        } catch {
            if Task.isCancelled || error is CancellationError { return Outcome(state: .pending) }
            return fail(String(localized: "Couldn't write the Gyroflow project: \(error.localizedDescription)", bundle: L10n.bundle))
        }
        let light = A1Log(url: best.log.url, start: best.log.start, rateHz: best.log.rateHz, gyro: [])
        return Outcome(state: .synced(r2: best.result.r2, log: best.log.url.lastPathComponent, offsetMs: offsetMs),
                       skewEntry: (timing, light, best.result.lagMs), profile: profile)
    }

    /// Copies the file about to be replaced to `<backupDir>/<name>-<yyyyMMdd-HHmmss>.gyroflow`.
    private func backupIfNeeded() throws {
        try GyroflowProject.backup(dest, to: backupDir)
    }
}

/// A log found in a chosen folder: header-only `A1Log`, plus the file size and date it was read at.
struct LogIndexEntry: Sendable {
    let log: A1Log
    let size: Int
    let modified: Date?
}

/// Decoded logs, least recently used dropped beyond `capacity`.
actor DecodedLogCache {
    private let capacity: Int
    private let reader: @Sendable (URL) throws -> A1Log
    private var entries: [(path: String, log: A1Log)] = []

    init(capacity: Int, reader: @escaping @Sendable (URL) throws -> A1Log) {
        self.capacity = capacity; self.reader = reader
    }

    func log(_ url: URL) throws -> A1Log {
        if let i = entries.firstIndex(where: { $0.path == url.path }) {
            let e = entries.remove(at: i)
            entries.append(e)
            return e.log
        }
        let log = try reader(url)
        entries.append((url.path, log))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        return log
    }
}
