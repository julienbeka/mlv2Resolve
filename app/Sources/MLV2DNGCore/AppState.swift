// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation

/// UI-facing state: remembered folder, mounted shoots, dual ISO mode.
///
/// Shoots are identified by their standardized folder path. The saved list
/// (`mountedShoots`) holds what the user wants mounted: it survives quits,
/// engine crashes and disk unplugs, and is only shrunk by a deliberate unmount.
/// Methods never throw: failures become French `alert` strings.
@MainActor
public final class AppState: ObservableObject {
    enum Key {
        static let lastFolder = "lastFolder"
        static let mountedShoots = "mountedShoots"
        static let dualISOMode = "dualISOMode"
        static let fixBadPixels = "fixBadPixels"
        static let fixFocusPixels = "fixFocusPixels"
    }

    @Published public private(set) var folder: URL?
    @Published public private(set) var shoots: [Shoot] = []
    /// Folder paths of the shoots currently mounted.
    @Published public private(set) var mounted: Set<String> = [] {
        didSet { updateDesqueezeTargets() }
    }
    /// Mounted anamorphic shoots (mount path + squeeze factor), for « Desqueeze in Resolve ».
    @Published public private(set) var desqueezeTargets: [ResolveDesqueeze.Target] = []
    /// A « Desqueeze in Resolve » run is in flight.
    @Published public private(set) var desqueezing = false
    /// Whether the last « Desqueeze in Resolve » of this session reached Resolve Studio (nil: not tried yet).
    public private(set) var resolveReachable: Bool?
    @Published public private(set) var mode: DualISOMode
    @Published public private(set) var alert: String?
    /// FUSE-T is missing or outdated: the app is not started yet (menu shows the alert icon
    /// and « Installer FUSE-T… »). Set by the app shell.
    @Published public var needsFuseT = false
    /// Folder keys with a mount/unmount from `toggle` in flight.
    @Published public private(set) var busy: Set<String> = []
    /// Non-error hint (e.g. anamorphic pixel aspect), shown once per shoot per session.
    @Published public private(set) var info: String?
    /// Applied on the next mount.
    @Published public var fixBadPixels = true {
        didSet { defaults.set(fixBadPixels, forKey: Key.fixBadPixels) }
    }
    @Published public var fixFocusPixels = true {
        didSet { defaults.set(fixFocusPixels, forKey: Key.fixFocusPixels) }
    }

    private let manager: MountManager
    private let defaults: UserDefaults
    private let scan: (URL) throws -> [Shoot]
    private var eventTask: Task<Void, Never>?
    private var infoShown: Set<String> = []
    private var refreshHintShown = false
    /// Back-off before each automatic relaunch of a crashed engine.
    private let restartDelays: [Duration]
    /// A crash this long after the previous one starts a fresh retry budget.
    private let restartWindow: Duration
    /// Consecutive crashes per shoot key, with the time of the last one.
    private var crashes: [String: (count: Int, last: ContinuousClock.Instant)] = [:]
    private var restartTasks: [String: Task<Void, Never>] = [:]
    /// Per folder key: squeeze factor (nil = not anamorphic) and last mount point.
    private var squeezeFactors: [String: Int?] = [:]
    private var mountPoints: [String: URL] = [:]
    private let resolveRunner: ResolveDesqueeze.Runner?
    /// Where the Resolve menu script is written (nil: never written, e.g. in tests).
    private let resolveScriptsDir: URL?
    private let prepareResolvePresets: (([Int]) -> ResolvePresets.Preparation)?
    /// Background gyro sync, told about every mount and unmount (nil: no gyro sync, e.g. in tests).
    public let gyro: GyroSyncCoordinator?

    public init(manager: MountManager, defaults: UserDefaults, scan: @escaping (URL) throws -> [Shoot],
                restartDelays: [Duration] = [.seconds(1), .seconds(5)],
                restartWindow: Duration = .seconds(60),
                resolveRunner: ResolveDesqueeze.Runner? = nil, resolveScriptsDir: URL? = nil,
                prepareResolvePresets: (([Int]) -> ResolvePresets.Preparation)? = nil,
                gyro: GyroSyncCoordinator? = nil) {
        self.manager = manager
        self.gyro = gyro
        self.resolveRunner = resolveRunner
        self.resolveScriptsDir = resolveScriptsDir
        self.prepareResolvePresets = prepareResolvePresets
        self.defaults = defaults
        self.scan = scan
        self.restartDelays = restartDelays
        self.restartWindow = restartWindow
        mode = DualISOMode(rawValue: defaults.integer(forKey: Key.dualISOMode)) ?? .montageFluide
        if defaults.object(forKey: Key.fixBadPixels) != nil { fixBadPixels = defaults.bool(forKey: Key.fixBadPixels) }
        if defaults.object(forKey: Key.fixFocusPixels) != nil { fixFocusPixels = defaults.bool(forKey: Key.fixFocusPixels) }
        folder = resolveLastFolder()
        let stream = manager.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    deinit { eventTask?.cancel() }

    // MARK: Public API

    public func clearAlert() { alert = nil }
    public func clearInfo() { info = nil }

    public func choose(folder: URL) async {
        self.folder = folder
        if let data = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: Key.lastFolder)
        }
        rescan()
    }

    public func toggle(_ shoot: Shoot) async {
        let k = Self.key(shoot.folder)
        guard !busy.contains(k) else { return }
        busy.insert(k)
        defer { busy.remove(k) }
        cancelRestart(k)
        if mounted.contains(k) {
            do {
                try await manager.unmount(shoot)
                mounted.remove(k)
                saved.removeAll { $0 == k }
                gyro?.shootUnmounted(shoot)
            } catch {
                alert = Self.busyAlert([shoot.name])
            }
        } else {
            if await mount(shoot), !saved.contains(k) { saved.append(k) }
        }
    }

    /// Unmounts every mounted shoot, whatever folder it came from.
    public func unmountAll() async {
        // Pending relaunches of crashed engines are abandoned: the user wants everything off.
        for k in Array(restartTasks.keys) { cancelRestart(k); saved.removeAll { $0 == k } }
        var failed: [String] = []
        for shoot in await manager.mounted.keys {
            let k = Self.key(shoot.folder)
            do {
                try await manager.unmount(shoot)
                mounted.remove(k)
                saved.removeAll { $0 == k }
                gyro?.shootUnmounted(shoot)
            } catch { failed.append(shoot.name) }
        }
        // Anything not known to the manager anymore is no longer mounted.
        let live = Set(await manager.mounted.keys.map { Self.key($0.folder) })
        for k in mounted where !live.contains(k) { mounted.remove(k); saved.removeAll { $0 == k } }
        if !failed.isEmpty { alert = Self.busyAlert(failed) }
    }

    public func setMode(_ m: DualISOMode) async {
        mode = m
        defaults.set(m.rawValue, forKey: Key.dualISOMode)
        let failed = await manager.setMode(m)
        if m == .qualiteEtalonnage, !refreshHintShown {
            refreshHintShown = true
            info = String(localized: "In Resolve, select the clips, then right-click → Refresh.", bundle: L10n.bundle)
        }
        if !failed.isEmpty {
            let names = failed.map(\.name).sorted().joined(separator: ", ")
            alert = String(localized: "Dual ISO mode couldn't be applied to: \(names).", bundle: L10n.bundle)
        }
    }

    /// « Desqueeze in Resolve »: applies the « mlv2dng 1x<N> » Input Sizing preset to the clips of the mounted
    /// anamorphic shoots in Resolve's open project. Returns the alert text; nil if a run is already in flight.
    public func desqueezeInResolve() async -> (text: String, isError: Bool)? {
        guard !desqueezing else { return nil }
        desqueezing = true
        defer { desqueezing = false }
        let targets = desqueezeTargets
        let factors = Array(Set(targets.map(\.factor))).sorted()
        let preparation = prepareResolvePresets?(factors)
        if preparation == .created {
            return (ResolvePresets.createdMessage(), false)
        }
        if preparation == .manual && !ResolvePresets.isResolveRunning() && !factors.isEmpty {
            return (ResolvePresets.manualMessage() + "\n\n" + factors.map {
                ResolveDesqueeze.missingStepText(factor: "\($0)", preset: ResolveDesqueeze.presetName($0))
            }.joined(separator: "\n\n"), true)
        }
        let outcome: ResolveDesqueeze.Outcome
        if let resolveRunner {
            outcome = await ResolveDesqueeze.run(targets: targets, runner: resolveRunner)
        } else {
            outcome = .notInstalled
        }
        resolveReachable = outcome.reachedResolve
        let message = ResolveDesqueeze.message(for: outcome, targets: targets)
        if case .failed = outcome { return message }
        if case .report(let report) = outcome, !report.missingPreset.isEmpty {
            return (ResolvePresets.manualMessage() + "\n\n" + message.text, message.isError)
        }
        if preparation == .manual && message.isError && !factors.isEmpty {
            let steps = factors.map {
                ResolveDesqueeze.missingStepText(factor: "\($0)", preset: ResolveDesqueeze.presetName($0))
            }.joined(separator: "\n\n")
            return (message.text + "\n\n" + ResolvePresets.manualMessage() + "\n\n" + steps, true)
        }
        return message
    }

    /// Launch: clears stale mounts, rescans the last folder, then remounts
    /// saved shoots whose folder still exists (missing ones are skipped
    /// silently and kept for a later replug).
    public func restore() async {
        try? await manager.cleanStaleMounts()
        if folder == nil { folder = resolveLastFolder() }
        if folder != nil { rescan() }
        await remount(saved)
    }

    public func volumeDidMount(_ volume: URL) async {
        let prefix = Self.prefix(volume)
        if folder == nil { folder = resolveLastFolder() }
        if let folder, Self.key(folder).hasPrefix(prefix) { rescan() }
        await remount(saved.filter { $0.hasPrefix(prefix) })
        if alert == Self.unplugAlert(volume) { alert = nil }
    }

    public func volumeWillUnmount(_ volume: URL) async {
        let prefix = Self.prefix(volume)
        for k in Array(restartTasks.keys) where k.hasPrefix(prefix) { cancelRestart(k) }
        let affected = mounted.filter { $0.hasPrefix(prefix) }
        guard !affected.isEmpty else { return }
        // Drop them first so exit events during the unplug are not reported as crashes.
        mounted.subtract(affected)
        alert = Self.unplugAlert(volume)
        let live = await manager.mounted.keys
        for shoot in live where affected.contains(Self.key(shoot.folder)) {
            gyro?.shootUnmounted(shoot)
            try? await manager.unmount(shoot, force: true) // the disk is going away
        }
        // Anything that refused to unmount is still mounted.
        let still = await manager.mounted.keys.map { Self.key($0.folder) }
        mounted.formUnion(affected.intersection(still))
    }

    // MARK: Private

    private var saved: [String] {
        get { defaults.stringArray(forKey: Key.mountedShoots) ?? [] }
        set { defaults.set(newValue, forKey: Key.mountedShoots) }
    }

    /// `standardizedFileURL` drops a leading `/private` only while the path
    /// exists, so strip it explicitly: the key must not change when a folder
    /// disappears (unplugged disk, deleted folder).
    static func key(_ url: URL) -> String {
        var p = url.standardizedFileURL.path
        for d in ["/var/", "/tmp/", "/etc/"] where p.hasPrefix("/private" + d) { p.removeFirst("/private".count) }
        return p
    }
    static func prefix(_ volume: URL) -> String {
        let p = key(volume)
        return p.hasSuffix("/") ? p : p + "/"
    }
    /// User-initiated unmounts are never forced: a busy volume stays mounted.
    static func busyAlert(_ names: [String]) -> String {
        let list = names.sorted().map { String(localized: "“\($0)”", bundle: L10n.bundle) }.joined(separator: ", ")
        return String(localized: "Couldn't unmount \(list): files may be open in Resolve.", bundle: L10n.bundle)
    }

    static func unplugAlert(_ volume: URL) -> String {
        String(localized: "Disk “\(volume.standardizedFileURL.lastPathComponent)” was unplugged", bundle: L10n.bundle)
    }

    private func resolveLastFolder() -> URL? {
        guard let data = defaults.data(forKey: Key.lastFolder) else { return nil }
        var stale = false
        // Keep the bookmark when resolution fails: the disk may just be unplugged.
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Key.lastFolder)
        }
        return url
    }

    private func rescan() {
        guard let folder else { return }
        do {
            shoots = try scan(folder)
        } catch {
            shoots = []
            alert = String(localized: "Couldn't read folder: \(folder.path)", bundle: L10n.bundle)
        }
    }

    private func remount(_ paths: [String]) async {
        for path in paths where !mounted.contains(path) {
            guard FileManager.default.fileExists(atPath: path), let shoot = shoot(at: path) else { continue }
            await mount(shoot)
        }
    }

    /// The shoot for a saved folder path: from the current list, else by
    /// scanning the folder itself.
    private func shoot(at path: String) -> Shoot? {
        if let s = shoots.first(where: { Self.key($0.folder) == path }) { return s }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return (try? scan(url))?.first { Self.key($0.folder) == path }
    }

    @discardableResult
    private func mount(_ shoot: Shoot) async -> Bool {
        do {
            let url = try await manager.mount(shoot, mode: mode, fixBadPixels: fixBadPixels,
                                              fixFocusPixels: fixFocusPixels)
            noteMountPoint(shoot, url)
            mounted.insert(Self.key(shoot.folder))
            startGyro(shoot, mountPoint: url)
            noteSqueeze(shoot)
            noteCollision(shoot, mountedAt: url)
            return true
        } catch {
            alert = String(localized: "Couldn't mount “\(shoot.name)”: \(Self.reason(error)).", bundle: L10n.bundle)
            return false
        }
    }

    /// The mount point got the disk-name suffix because another mounted shoot
    /// already uses the plain name.
    private func noteCollision(_ shoot: Shoot, mountedAt url: URL) {
        let plain = MountPaths.sanitize(shoot.name)
        let actual = url.lastPathComponent
        guard actual.precomposedStringWithCanonicalMapping != plain else { return }
        let notice = String(localized: "Two shoots are named “\(shoot.name)”: the second is mounted as “\(actual)”.", bundle: L10n.bundle)
        info = info.map { $0 + "\n\n" + notice } ?? notice
    }

    private func noteSqueeze(_ shoot: Shoot) {
        let k = Self.key(shoot.folder)
        guard !infoShown.contains(k), let n = squeezeFactor(shoot) else { return }
        infoShown.insert(k)
        var hint = String(localized: "Anamorphic shoot 1x\(n): in Resolve, go to the Color page → Sizing → Input Sizing and set Width to \(n).", bundle: L10n.bundle)
        // The manual advice stays (free version); Studio users who already got through get the shortcut too.
        if resolveReachable == true { hint += " " + ResolveDesqueeze.hintSuffix() }
        info = hint
    }

    /// Squeeze factor of a shoot, read once from its first MLV header.
    private func squeezeFactor(_ shoot: Shoot) -> Int? {
        let k = Self.key(shoot.folder)
        if let cached = squeezeFactors[k] { return cached }
        let n = shoot.clips.first?.files.first.flatMap(MLVHeader.horizontalSqueeze(of:))
        squeezeFactors[k] = .some(n)
        return n
    }

    /// Starts the gyro sync of a freshly mounted shoot in the background. Logs are searched in the chosen
    /// folder when the shoot lies in it, else in the shoot's own folder.
    private func startGyro(_ shoot: Shoot, mountPoint: URL) {
        guard let gyro else { return }
        let chosen = folder.flatMap { f in
            Self.key(shoot.folder).hasPrefix(Self.prefix(f)) || Self.key(shoot.folder) == Self.key(f) ? f : nil
        } ?? shoot.folder
        let k = Self.key(shoot.folder)
        Task { [weak self] in
            guard self?.mounted.contains(k) == true else { return }  // unmounted before this task started
            await gyro.shootMounted(shoot, mountPoint: mountPoint, chosenFolder: chosen)
        }
    }

    private func noteMountPoint(_ shoot: Shoot, _ url: URL) {
        let k = Self.key(shoot.folder)
        _ = squeezeFactor(shoot)
        mountPoints[k] = url
    }

    private func updateDesqueezeTargets() {
        let targets = mounted.compactMap { k -> ResolveDesqueeze.Target? in
            guard let url = mountPoints[k], let f = squeezeFactors[k] ?? nil else { return nil }
            return ResolveDesqueeze.Target(prefix: url.standardizedFileURL.path, factor: f)
        }.sorted { ($0.prefix, $0.factor) < ($1.prefix, $1.factor) }
        guard targets != desqueezeTargets else { return }
        desqueezeTargets = targets
        if let dir = resolveScriptsDir {
            ResolveDesqueeze.installMenuScript(targets: targets, in: dir)
        }
    }

    private func handle(_ event: MountEvent) {
        switch event {
        case let .exited(shoot, status):
            // Only shoots we consider mounted (startup failures are alerted by `mount`,
            // unplugged disks are dropped from `mounted` before their engines stop).
            guard mounted.remove(Self.key(shoot.folder)) != nil else { return }
            gyro?.shootUnmounted(shoot)
            engineCrashed(shoot, status: status)
        }
    }

    /// Supervision: relaunch a crashed engine after 1 s, then 5 s; alert only
    /// when those relaunches fail too. A shoot whose folder is gone (disk
    /// unplugged) is left to the unplug flow.
    private func engineCrashed(_ shoot: Shoot, status: Int32) {
        let k = Self.key(shoot.folder)
        guard saved.contains(k), FileManager.default.fileExists(atPath: k) else {
            restartTasks[k] = nil
            crashes[k] = nil
            return
        }
        let now = ContinuousClock.now
        var n = crashes[k].map { now - $0.last < restartWindow ? $0.count : 0 } ?? 0
        guard n < restartDelays.count else {
            crashes[k] = nil
            restartTasks[k] = nil
            alert = String(localized: "Mounting of “\(shoot.name)” stopped and couldn't be restarted (code \(status)).", bundle: L10n.bundle)
            return
        }
        let delay = restartDelays[n]
        n += 1
        crashes[k] = (n, now)
        restartTasks[k] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.relaunch(shoot)
        }
    }

    private func relaunch(_ shoot: Shoot) async {
        let k = Self.key(shoot.folder)
        restartTasks[k] = nil
        guard saved.contains(k), !mounted.contains(k) else { return }
        guard FileManager.default.fileExists(atPath: k) else { crashes[k] = nil; return }
        do {
            let url = try await manager.mount(shoot, mode: mode, fixBadPixels: fixBadPixels, fixFocusPixels: fixFocusPixels)
            noteMountPoint(shoot, url)
            mounted.insert(k)
            startGyro(shoot, mountPoint: url)
        } catch {
            if case let .exitedDuringStartup(status)? = error as? MountError {
                engineCrashed(shoot, status: status)
            } else {
                engineCrashed(shoot, status: -1)
            }
        }
    }

    private func cancelRestart(_ k: String) {
        restartTasks.removeValue(forKey: k)?.cancel()
        crashes[k] = nil
    }

    static func reason(_ error: Error) -> String {
        switch error as? MountError {
        case .mountPointBusy(let url): return String(localized: "the location “\(url.path)” is already in use", bundle: L10n.bundle)
        case .unmountFailed: return String(localized: "the previous mount couldn't be removed", bundle: L10n.bundle)
        case .unmountInProgress: return String(localized: "an unmount is in progress, try again", bundle: L10n.bundle)
        case .exitedDuringStartup: return String(localized: "the engine stopped during startup", bundle: L10n.bundle)
        case .startupTimedOut: return String(localized: "the mount didn't appear in time", bundle: L10n.bundle)
        case .signalFailed: return String(localized: "the engine isn't responding", bundle: L10n.bundle)
        case nil: return error.localizedDescription
        }
    }
}
