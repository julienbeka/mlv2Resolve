// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import MLVSwitchCore

/// The real MountManager, the shared AppState and the disk-event wiring.
@MainActor
final class AppCore {
    static let shared = AppCore()

    let manager: MountManager
    let state: AppState
    private var started = false
    private var observers: [NSObjectProtocol] = []

    /// `-MLVSwitchRoot <path>` overrides the mount root (testing only).
    static var mountRoot: URL {
        if let p = UserDefaults.standard.string(forKey: "MLVSwitchRoot") {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return MountPaths.defaultRoot
    }

    private init() {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let mlvfs = Bundle.main.url(forResource: "mlvfs", withExtension: nil)
            ?? resources.appendingPathComponent("mlvfs")
        let indexDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MLV Switch", isDirectory: true)
            .appendingPathComponent("index", isDirectory: true)
        try? FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
        manager = MountManager(mlvfs: mlvfs,
                               fpmDir: resources.appendingPathComponent("fpm", isDirectory: true),
                               indexDir: indexDir,
                               paths: MountPaths(root: Self.mountRoot),
                               launcher: FoundationLauncher(), unmounter: UmountUnmounter(),
                               http: MountManager.httpGet,
                               isPortFree: MountManager.isLocalPortFree)
        state = AppState(manager: manager, defaults: .standard, scan: ShootScanner.scan)
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
        Task { await state.restore() }
    }

    /// Quit: unmount everything (bounded to 10 s), keeping the saved list so
    /// the next launch remounts the same shoots.
    func shutdown() {
        guard started else { return }
        let manager = self.manager
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await manager.unmountAll(force: true) // quitting: Resolve may still hold files
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
    }
}
