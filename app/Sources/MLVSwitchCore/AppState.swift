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
    @Published public private(set) var mounted: Set<String> = []
    @Published public private(set) var mode: DualISOMode
    @Published public private(set) var alert: String?
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

    public init(manager: MountManager, defaults: UserDefaults, scan: @escaping (URL) throws -> [Shoot]) {
        self.manager = manager
        self.defaults = defaults
        self.scan = scan
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
        if mounted.contains(k) {
            do {
                try await manager.unmount(shoot)
                mounted.remove(k)
                saved.removeAll { $0 == k }
            } catch {
                alert = "Impossible de démonter « \(shoot.name) » : des fichiers sont peut-être ouverts (DaVinci Resolve ?)."
            }
        } else {
            if await mount(shoot), !saved.contains(k) { saved.append(k) }
        }
    }

    /// Unmounts every mounted shoot, whatever folder it came from.
    public func unmountAll() async {
        var failed: [String] = []
        for shoot in await manager.mounted.keys {
            let k = Self.key(shoot.folder)
            do {
                try await manager.unmount(shoot)
                mounted.remove(k)
                saved.removeAll { $0 == k }
            } catch { failed.append(shoot.name) }
        }
        // Anything not known to the manager anymore is no longer mounted.
        let live = Set(await manager.mounted.keys.map { Self.key($0.folder) })
        for k in mounted where !live.contains(k) { mounted.remove(k); saved.removeAll { $0 == k } }
        if !failed.isEmpty {
            alert = "Impossible de démonter : \(failed.sorted().joined(separator: ", ")) (des fichiers sont peut-être ouverts dans DaVinci Resolve ?)."
        }
    }

    public func setMode(_ m: DualISOMode) async {
        mode = m
        defaults.set(m.rawValue, forKey: Key.dualISOMode)
        let failed = await manager.setMode(m)
        if m == .qualiteEtalonnage, !refreshHintShown {
            refreshHintShown = true
            info = "Dans Resolve, sélectionnez les plans puis clic droit → Rafraîchir."
        }
        if !failed.isEmpty {
            alert = "Le mode dual ISO n'a pas pu être appliqué à : \(failed.map(\.name).sorted().joined(separator: ", "))."
        }
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
        let affected = mounted.filter { $0.hasPrefix(prefix) }
        guard !affected.isEmpty else { return }
        // Drop them first so exit events during the unplug are not reported as crashes.
        mounted.subtract(affected)
        alert = Self.unplugAlert(volume)
        let live = await manager.mounted.keys
        for shoot in live where affected.contains(Self.key(shoot.folder)) {
            try? await manager.unmount(shoot)
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

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }
    static func prefix(_ volume: URL) -> String {
        let p = key(volume)
        return p.hasSuffix("/") ? p : p + "/"
    }
    static func unplugAlert(_ volume: URL) -> String {
        "Disque « \(volume.standardizedFileURL.lastPathComponent) » débranché"
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
            alert = "Dossier illisible : \(folder.path)"
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
            try await manager.mount(shoot, mode: mode, fixBadPixels: fixBadPixels, fixFocusPixels: fixFocusPixels)
            mounted.insert(Self.key(shoot.folder))
            noteSqueeze(shoot)
            return true
        } catch {
            alert = "Impossible de monter « \(shoot.name) » : \(Self.reason(error))."
            return false
        }
    }

    private func noteSqueeze(_ shoot: Shoot) {
        let k = Self.key(shoot.folder)
        guard !infoShown.contains(k), let file = shoot.clips.first?.files.first,
              let n = MLVHeader.horizontalSqueeze(of: file) else { return }
        infoShown.insert(k)
        info = "Tournage anamorphosé 1x\(n) : dans Resolve, réglez le rapport de pixel à \(n):1 (Attributs du clip)."
    }

    private func handle(_ event: MountEvent) {
        switch event {
        case let .exited(shoot, status):
            // Only report shoots we consider mounted (startup failures are alerted by `mount`).
            guard mounted.remove(Self.key(shoot.folder)) != nil else { return }
            alert = "Le montage de « \(shoot.name) » s'est arrêté (code \(status))."
        }
    }

    static func reason(_ error: Error) -> String {
        switch error as? MountError {
        case .noFreePort: return "aucun port libre"
        case .mountPointBusy(let url): return "l'emplacement « \(url.path) » est déjà utilisé"
        case .unmountFailed: return "l'ancien montage n'a pas pu être retiré"
        case .unmountInProgress: return "un démontage est en cours, réessayez"
        case .exitedDuringStartup: return "le moteur s'est arrêté au démarrage"
        case .startupTimedOut: return "le montage n'est pas apparu à temps"
        case .webGUIUnavailable: return "le moteur ne répond pas"
        case nil: return error.localizedDescription
        }
    }
}
