// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation

/// Gyro sync state of one clip, keyed by its standardized MLV path.
public enum ClipGyroState: Equatable, Sendable {
    case pending, running
    case synced(r2: Double, log: String, offsetMs: Double)
    /// A `.gyroflow` is there that mlv2dng did not write (e.g. made with Gyroflow / NiYien): left alone.
    case existing
    case noLog, notEnoughMotion, ambiguous
    case failed(String)
}

/// Background gyro sync: for every mounted shoot, finds the SenseFlow A1 logs of the chosen folder, syncs each
/// MLV clip and writes its `.gyroflow` next to the MLV (the running MLVFS mount then lists it in the clip folder).
///
/// Never writes, renames or deletes MLV files or logs. Never overwrites a `.gyroflow` unless asked (regenerate,
/// lens or position change on that clip); the replaced file is first copied to
/// `<backupsRoot>/<shoot name>/<name>-<yyyyMMdd-HHmmss>.gyroflow`.
///
/// Persisted in `defaults` (paths are standardized, see `AppState.key`):
/// - `gyroLenses`: JSON `[Lens]`.
/// - `gyroShootLens` / `gyroClipLens`: `[path: lens UUID string]` (shoot folder / MLV path).
/// - `gyroShootPosition` / `gyroClipPosition`: `[path: MountingPosition.rawValue]`.
/// - `gyroWritten`: `[String]`, MLV paths whose `.gyroflow` mlv2dng wrote.
/// - `gyroWrittenMeta`: `[MLV path: ["r2": Double, "log": String, "offsetMs": Double]]`, to restore `.synced`.
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
        static let written = "gyroWritten"
        static let meta = "gyroWrittenMeta"
    }

    @Published public private(set) var states: [String: ClipGyroState] = [:]

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
    private let solver: Solver
    private let clipDirResolver: ClipDirResolver
    private let defaults: UserDefaults
    private let backupsRoot: URL

    private struct Context { let shoot: Shoot; let mountPoint: URL; let chosenFolder: URL }
    /// Per shoot folder key.
    private var contexts: [String: Context] = [:]
    private var tails: [String: Task<Void, Never>] = [:]
    private var tasks: [String: [UUID: Task<Void, Never>]] = [:]
    /// Per chosen folder key: clips synced this session (log gyro dropped), for the clock skew.
    private var syncedByFolder: [String: [(clip: ClipTiming, log: A1Log, lagMs: Int)]] = [:]
    private var skews: [String: TimeInterval] = [:]

    /// Test hook: every (log, searchMs) handed to the solver.
    var onSolve: (@MainActor (URL, ClosedRange<Int>) -> Void)?

    public convenience init(motionRunner: @escaping MotionRunner, defaults: UserDefaults, backupsRoot: URL) {
        self.init(motionRunner: motionRunner, defaults: defaults, backupsRoot: backupsRoot,
                  solver: { try GyroSync.solve(motion: $0, fps: $1, gyro: $2.gyro, rateHz: $2.rateHz, searchMs: $3) },
                  clipDirResolver: GyroSyncCoordinator.clipDir(mountPoint:mlv:))
    }

    init(motionRunner: @escaping MotionRunner, defaults: UserDefaults, backupsRoot: URL,
         solver: @escaping Solver, clipDirResolver: @escaping ClipDirResolver) {
        self.motionRunner = motionRunner
        self.defaults = defaults
        self.backupsRoot = backupsRoot
        self.solver = solver
        self.clipDirResolver = clipDirResolver
    }

    // MARK: Settings

    public func defaultLens(forShoot shoot: String) -> Lens? { lens(id: dict(Key.shootLens)[shoot]) }

    /// Regenerates the shoot's clips that use the default lens and whose file mlv2dng wrote; `.existing` stay.
    public func setDefaultLens(_ lens: Lens?, forShoot shoot: String) {
        setEntry(Key.shootLens, shoot, lens?.id.uuidString)
        shootDefaultsChanged(shoot, overridden: { self.dict(Key.clipLens)[$0] != nil })
    }

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
        dict(Key.shootPosition)[shoot].flatMap(MountingPosition.init(rawValue:)) ?? .top
    }

    public func setPosition(_ p: MountingPosition, forShoot shoot: String) {
        setEntry(Key.shootPosition, shoot, p.rawValue)
        shootDefaultsChanged(shoot, overridden: { self.dict(Key.clipPosition)[$0] != nil })
    }

    public func position(forClip clip: String) -> MountingPosition {
        if let p = dict(Key.clipPosition)[clip].flatMap(MountingPosition.init(rawValue:)) { return p }
        return shootKey(ofClip: clip).map(position(forShoot:)) ?? .top
    }

    /// nil: back to the shoot's position. Regenerates that clip.
    public func setPosition(_ p: MountingPosition?, forClip clip: String) {
        setEntry(Key.clipPosition, clip, p?.rawValue)
        clipSettingChanged(clip)
    }

    // MARK: Mount events

    /// Syncs every clip of the shoot; returns when that job is done (or cancelled).
    public func shootMounted(_ shoot: Shoot, mountPoint: URL, chosenFolder: URL) async {
        let k = AppState.key(shoot.folder)
        contexts[k] = Context(shoot: shoot, mountPoint: mountPoint, chosenFolder: chosenFolder)
        let clips = shoot.clips.compactMap { $0.files.first.map(AppState.key) }
        for c in clips where !isActive(states[c]) { states[c] = .pending }
        await enqueue(k, clips: clips, force: [])
    }

    /// Cancels the shoot's jobs; an in-flight clip writes nothing. Its clips leave `states`.
    public func shootUnmounted(_ shoot: Shoot) {
        let k = AppState.key(shoot.folder)
        contexts[k] = nil
        tails[k] = nil
        for t in (tasks.removeValue(forKey: k) ?? [:]).values { t.cancel() }
        for c in shoot.clips.compactMap({ $0.files.first.map(AppState.key) }) { states[c] = nil }
    }

    /// Rewrites the clip's `.gyroflow` (old one backed up). No-op if its shoot is not mounted.
    public func regenerate(clip: String) async {
        guard let k = shootKey(ofClip: clip) else { return }
        states[clip] = .pending
        await enqueue(k, clips: [clip], force: [clip])
    }

    /// Waits for every queued job.
    public func idle() async {
        for t in tasks.values.flatMap(\.values) { await t.value }
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
            guard !Task.isCancelled, let self else { return }
            await self.run(shoot, clips: clips, force: force)
            self.tasks[shoot]?[id] = nil
        }
        tails[shoot] = task
        tasks[shoot, default: [:]][id] = task
        return task
    }

    private func run(_ shootKey: String, clips: [String], force: Set<String>) async {
        for clip in clips {
            guard !Task.isCancelled, let ctx = contexts[shootKey] else { return }
            guard let mlv = ctx.shoot.clips.first(where: { $0.files.first.map(AppState.key) == clip })?.files.first
            else { continue }
            await process(clip: clip, mlv: mlv, ctx: ctx, force: force.contains(clip))
        }
    }

    private func process(clip: String, mlv: URL, ctx: Context, force: Bool) async {
        let resolver = clipDirResolver, mountPoint = ctx.mountPoint
        guard let clipDir = await Self.offMain({ resolver(mountPoint, mlv) }) else {
            states[clip] = .failed(String(localized: "Clip folder not found in the mount", bundle: L10n.bundle))
            return
        }
        if Task.isCancelled { return }
        let dest = mlv.deletingLastPathComponent()
            .appendingPathComponent(GyroflowProject.fileName(clipDir: clipDir.lastPathComponent))
        let exists = FileManager.default.fileExists(atPath: dest.path)
        if exists && !force {
            if written.contains(clip), let m = meta(clip) { states[clip] = m } else { states[clip] = .existing }
            return
        }
        guard let lens = lens(forClip: clip) else {
            states[clip] = .failed(String(localized: "Choose a lens for this shoot", bundle: L10n.bundle))
            return
        }
        states[clip] = .running
        let folderKey = AppState.key(ctx.chosenFolder)
        let job = Job(mlv: mlv, clipDir: clipDir, dest: dest, lens: lens, position: position(forClip: clip),
                      chosenFolder: ctx.chosenFolder, skew: skews[folderKey],
                      backupDir: backupsRoot.appendingPathComponent(MountPaths.sanitize(ctx.shoot.name), isDirectory: true),
                      motionRunner: motionRunner, solver: solver)
        let hook = onSolve
        var observer: (@Sendable (URL, ClosedRange<Int>) async -> Void)?
        if let hook { observer = { url, r in await hook(url, r) } }
        let outcome = await job.run(onSolve: observer)
        // Unmounted meanwhile (the file, if any, was written before the cancel was seen: atomic, complete).
        if Task.isCancelled || contexts[AppState.key(ctx.shoot.folder)] == nil {
            if case .synced = outcome.state { recordWritten(clip, outcome.state) }
            return
        }
        states[clip] = outcome.state
        if case .synced = outcome.state { recordWritten(clip, outcome.state) }
        if let entry = outcome.skewEntry {
            syncedByFolder[folderKey, default: []].append(entry)
            skews[folderKey] = LogMatcher.estimateSkew(syncedByFolder[folderKey] ?? [])
        }
    }

    // MARK: Persistence

    private var written: Set<String> { Set(defaults.stringArray(forKey: Key.written) ?? []) }

    private func recordWritten(_ clip: String, _ s: ClipGyroState) {
        guard case let .synced(r2, log, offsetMs) = s else { return }
        var w = written; w.insert(clip)
        defaults.set(w.sorted(), forKey: Key.written)
        var m = defaults.dictionary(forKey: Key.meta) ?? [:]
        m[clip] = ["r2": r2, "log": log, "offsetMs": offsetMs]
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
    /// `<MLV basename><MLV extension>_` (Resolve naming: `M29-0615MLV_1_2026-08-29_0001_C0000`).
    nonisolated static func clipDir(mountPoint: URL, mlv: URL) -> URL? {
        let prefix = mlv.deletingPathExtension().lastPathComponent + mlv.pathExtension + "_"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint.path)) ?? []
        return names.sorted().first { $0.hasPrefix(prefix) }
            .map { mountPoint.appendingPathComponent($0, isDirectory: true) }
    }

    // MARK: Production motion runner

    /// Runs `binary <clip.MLV>` and parses its `frame,dx,dy,peak` CSV. Throws on a non-zero exit (message = last
    /// stderr line); terminates the process when the task is cancelled.
    public nonisolated static func mlvmotionRunner(binary: URL) -> MotionRunner {
        { mlv in try await runMotion(binary: binary, mlv: mlv) }
    }

    struct MotionError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    nonisolated static func runMotion(binary: URL, mlv: URL) async throws -> [MotionSample] {
        let fm = FileManager.default
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
        p.arguments = [mlv.path]
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error) }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
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
    let mlv: URL, clipDir: URL, dest: URL
    let lens: Lens
    let position: MountingPosition
    let chosenFolder: URL
    let skew: TimeInterval?
    let backupDir: URL
    let motionRunner: GyroSyncCoordinator.MotionRunner
    let solver: GyroSyncCoordinator.Solver

    struct Outcome: Sendable {
        var state: ClipGyroState
        var skewEntry: (clip: ClipTiming, log: A1Log, lagMs: Int)?
    }

    nonisolated func run(onSolve: (@Sendable (URL, ClosedRange<Int>) async -> Void)?) async -> Outcome {
        func fail(_ s: String) -> Outcome { Outcome(state: .failed(s)) }
        guard let timing = MLVHeader.timing(of: mlv) else {
            return fail(String(localized: "Couldn't read the clip's timing", bundle: L10n.bundle))
        }
        let logs = A1Log.find(in: chosenFolder).compactMap { try? A1Log.read($0) }
        let candidates = LogMatcher.candidates(for: timing, logs: logs, skew: skew)
        guard !candidates.isEmpty else { return Outcome(state: .noLog) }
        if Task.isCancelled { return Outcome(state: .pending) }

        let motion: [MotionSample]
        do { motion = try await motionRunner(mlv) } catch {
            if Task.isCancelled || error is CancellationError { return Outcome(state: .pending) }
            return fail(String(localized: "Motion analysis failed: \(error.localizedDescription)", bundle: L10n.bundle))
        }

        var best: (log: A1Log, result: SyncResult)?
        var sawAmbiguous = false, sawMotion = false
        for c in candidates {
            if Task.isCancelled { return Outcome(state: .pending) }
            await onSolve?(c.log.url, c.searchMs)
            do {
                let r = try solver(motion, timing.fps, c.log, c.searchMs)
                if best.map({ r.r2 > $0.result.r2 }) ?? true { best = (c.log, r) }
            } catch SyncRefusal.ambiguous {
                sawAmbiguous = true
            } catch SyncRefusal.noOverlap {
            } catch {
                sawMotion = true
            }
        }
        guard let best else {
            return Outcome(state: sawAmbiguous ? .ambiguous : sawMotion ? .notEnoughMotion : .noLog)
        }

        let calibration: [String: Any]
        if let c = lens.calibratedProfiles.lazy.compactMap({ try? LensProfile.calibrated($0, for: timing) }).first {
            calibration = c
        } else {
            do { calibration = try LensProfile.computed(focalMM: lens.focalMM, lensName: lens.name, timing: timing) }
            catch { return fail(String(localized: "Couldn't build the lens profile: \(String(describing: error))", bundle: L10n.bundle)) }
        }
        let offsetMs = Double(-best.result.lagMs)
        let data: Data
        do {
            data = try GyroflowProject.make(clipDir: clipDir, timing: timing, log: best.log.url, offsetMs: offsetMs,
                                            calibration: calibration, position: position)
        } catch {
            return fail(String(localized: "Couldn't write the Gyroflow project: \(String(describing: error))", bundle: L10n.bundle))
        }
        if Task.isCancelled { return Outcome(state: .pending) }
        do { try backupIfNeeded() } catch {
            return fail(String(localized: "Couldn't back up the existing Gyroflow project: \(error.localizedDescription)", bundle: L10n.bundle))
        }
        if Task.isCancelled { return Outcome(state: .pending) }
        do { try GyroflowProject.write(data, to: dest) } catch {
            return fail(String(localized: "Couldn't write the Gyroflow project: \(error.localizedDescription)", bundle: L10n.bundle))
        }
        let light = A1Log(url: best.log.url, start: best.log.start, rateHz: best.log.rateHz, gyro: [])
        return Outcome(state: .synced(r2: best.result.r2, log: best.log.url.lastPathComponent, offsetMs: offsetMs),
                       skewEntry: (timing, light, best.result.lagMs))
    }

    /// Copies the file about to be replaced to `<backupDir>/<name>-<yyyyMMdd-HHmmss>.gyroflow`.
    private func backupIfNeeded() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dest.path) else { return }
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(dest.deletingPathExtension().lastPathComponent)-\(f.string(from: Date()))"
        var target = backupDir.appendingPathComponent(base + ".gyroflow")
        var n = 1
        while fm.fileExists(atPath: target.path) {
            target = backupDir.appendingPathComponent("\(base)-\(n).gyroflow"); n += 1
        }
        try fm.copyItem(at: dest, to: target)
    }
}
