// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import MLV2DNGCore

/// The real MountManager, the shared AppState and the disk-event wiring.
@MainActor
final class AppCore {
    static let shared = AppCore()

    let manager: MountManager
    let state: AppState
    private var started = false
    private var observers: [NSObjectProtocol] = []

    /// `-MLV2DNGRoot <path>` overrides the mount root (testing only).
    static var mountRoot: URL {
        if let p = UserDefaults.standard.string(forKey: "MLV2DNGRoot") {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return MountPaths.defaultRoot
    }

    private init() {
        LegacyMigration.migrateDefaults(into: .standard)
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let mlvfs = Bundle.main.url(forResource: "mlvfs", withExtension: nil)
            ?? resources.appendingPathComponent("mlvfs")
        let indexDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mlv2dng", isDirectory: true)
            .appendingPathComponent("index", isDirectory: true)
        try? FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
        manager = MountManager(mlvfs: mlvfs,
                               fpmDir: resources.appendingPathComponent("fpm", isDirectory: true),
                               indexDir: indexDir,
                               logDir: EngineLog.defaultDirectory,
                               paths: MountPaths(root: Self.mountRoot),
                               launcher: FoundationLauncher(), unmounter: UmountUnmounter())
        // Built-in SenseFlow A1 gyro sync: the bundled mlvmotion analyses each clip's motion.
        let mlvmotion = Bundle.main.url(forResource: "mlvmotion", withExtension: nil)
            ?? resources.appendingPathComponent("mlvmotion")
        let backups = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mlv2dng", isDirectory: true)
            .appendingPathComponent("gyroflow-backups", isDirectory: true)
        let gyro = GyroSyncCoordinator(motionRunner: GyroSyncCoordinator.mlvmotionRunner(binary: mlvmotion),
                                       defaults: .standard, backupsRoot: backups)
        state = AppState(manager: manager, defaults: .standard, scan: ShootScanner.scan,
                         resolveRunner: ResolveDesqueeze.fuscriptRunner(),
                         resolveScriptsDir: ResolveDesqueeze.menuScriptsDirectory,
                         prepareResolvePresets: { ResolvePresets.prepare(factors: $0) },
                         gyro: gyro)
    }

    /// Once FUSE-T is ready: observe disks, then restore the previous session.
    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        let state = self.state
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor (AppState, URL) async -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                Task { @MainActor in await action(state, url) }
            })
        }
        observe(NSWorkspace.didMountNotification) { await $0.volumeDidMount($1) }
        observe(NSWorkspace.willUnmountNotification) { await $0.volumeWillUnmount($1) }
        // A yanked disk may only send didUnmount; the call is a no-op when nothing is affected.
        observe(NSWorkspace.didUnmountNotification) { await $0.volumeWillUnmount($1) }
        let manager = self.manager
        Task {
            // One-time cleanup of the old "~/MLV Switch" mount root.
            await manager.cleanLegacyRoot(MountPaths.legacyRoot)
            await state.restore()
        }
    }

    /// Quit: force-unmount everything this process mounted, keeping the saved
    /// list so the next launch remounts the same shoots. Async so the main
    /// thread stays free (nothing here may block it); callers bound it.
    func shutdown() async {
        await manager.unmountAll(force: true) // quitting: Resolve may still hold files
    }
}
