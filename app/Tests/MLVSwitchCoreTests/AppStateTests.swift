// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLVSwitchCore

@MainActor
final class AppStateTests: XCTestCase {
    var tmp: URL!
    var volume: URL!          // stands in for /Volumes/SSD
    var mountRoot: URL!
    var suite: String!
    var defaults: UserDefaults!
    var launcher: FakeLauncher!
    var unmounter: FakeUnmounter!
    var http: RecordingHTTP!

    override func setUp() async throws {
        let fm = FileManager.default
        tmp = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AppStateTests-\(UUID().uuidString)", isDirectory: true)
        volume = tmp.appendingPathComponent("SSD", isDirectory: true)
        mountRoot = tmp.appendingPathComponent("mounts", isDirectory: true)
        try fm.createDirectory(at: volume, withIntermediateDirectories: true)
        try fm.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        unmounter = FakeUnmounter()
        launcher = FakeLauncher(unmounter: unmounter)
        http = RecordingHTTP()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Helpers

    func makeManager(isPortFree: @escaping @Sendable (Int) -> Bool = { _ in true }) -> MountManager {
        let http = self.http!
        let busy = launcher.busyPorts
        return MountManager(mlvfs: URL(fileURLWithPath: "/opt/engine/mlvfs"),
                            fpmDir: URL(fileURLWithPath: "/opt/engine/fpm", isDirectory: true),
                            indexDir: tmp.appendingPathComponent("index", isDirectory: true),
                            paths: MountPaths(root: mountRoot), launcher: launcher, unmounter: unmounter,
                            http: { try await http.get($0) },
                            isPortFree: { !busy.get().contains($0) && isPortFree($0) },
                            readinessTimeout: .seconds(2), pollInterval: .milliseconds(5))
    }

    func makeState(_ manager: MountManager? = nil,
                   restartDelays: [Duration] = [.milliseconds(10), .milliseconds(30)]) -> AppState {
        AppState(manager: manager ?? makeManager(), defaults: defaults, scan: ShootScanner.scan,
                 restartDelays: restartDelays)
    }

    /// Creates `<volume>/<name>/A001.MLV` and returns the shoot folder.
    @discardableResult
    func makeShootFolder(_ name: String, in parent: URL? = nil) throws -> URL {
        let dir = (parent ?? volume).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("A001.MLV").path, contents: Data())
        return dir
    }

    func key(_ url: URL) -> String { AppState.key(url) }

    var savedMounts: [String] { defaults.stringArray(forKey: "mountedShoots") ?? [] }

    func shoot(_ state: AppState, _ name: String) throws -> Shoot {
        try XCTUnwrap(state.shoots.first { $0.name == name })
    }

    func waitUntil(_ timeout: Double = 2, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Brief tests

    func testLastFolderRemembered() async throws {
        try makeShootFolder("Tournage 1")
        let first = makeState()
        await first.choose(folder: volume)
        XCTAssertEqual(first.folder.map(key), key(volume))
        XCTAssertEqual(first.shoots.map(\.name), ["Tournage 1"])
        XCTAssertNotNil(defaults.data(forKey: "lastFolder"))

        let second = makeState()
        XCTAssertEqual(second.folder.map(key), key(volume))
        await second.restore()
        XCTAssertEqual(second.shoots.map(\.name), ["Tournage 1"])
    }

    func testRestoreRemountsExistingOnly() async throws {
        let a = try makeShootFolder("A")
        let missing = volume.appendingPathComponent("Disparu", isDirectory: true).path
        defaults.set([key(a), missing], forKey: "mountedShoots")
        let manager = makeManager()
        let state = makeState(manager)
        await state.restore()
        XCTAssertEqual(state.mounted, [key(a)])
        let mounted = await manager.mounted
        XCTAssertEqual(mounted.keys.map { key($0.folder) }, [key(a)])
        XCTAssertNil(state.alert)
        XCTAssertEqual(launcher.processes.count, 1)
    }

    func testConcurrentTogglesMountOnce() async throws {
        try makeShootFolder("A")
        let manager = makeManager()
        let state = makeState(manager)
        await state.choose(folder: volume)
        let a = try shoot(state, "A")
        async let t1: Void = state.toggle(a)
        async let t2: Void = state.toggle(a)
        _ = await (t1, t2)
        XCTAssertEqual(launcher.processes.count, 1)
        XCTAssertEqual(state.mounted.count, 1)
        XCTAssertTrue(state.busy.isEmpty)
    }

    func testUnplugUnmountsAndAlerts() async throws {
        try makeShootFolder("A")
        let manager = makeManager()
        let state = makeState(manager)
        await state.choose(folder: volume)
        await state.toggle(try shoot(state, "A"))
        XCTAssertEqual(state.mounted.count, 1)

        await state.volumeWillUnmount(volume)
        XCTAssertTrue(state.mounted.isEmpty)
        let mounted = await manager.mounted
        XCTAssertTrue(mounted.isEmpty)
        XCTAssertEqual(state.alert, "Disque « SSD » débranché")
        XCTAssertEqual(savedMounts, [key(volume.appendingPathComponent("A"))])
    }

    func testReplugRemounts() async throws {
        try makeShootFolder("A")
        let manager = makeManager()
        let state = makeState(manager)
        await state.choose(folder: volume)
        await state.toggle(try shoot(state, "A"))
        let before = await manager.mounted.values.first
        await state.volumeWillUnmount(volume)

        await state.volumeDidMount(volume)
        XCTAssertEqual(state.mounted, [key(volume.appendingPathComponent("A"))])
        let after = await manager.mounted.values.first
        XCTAssertNotNil(after)
        XCTAssertEqual(after.map(key), before.map(key))
        XCTAssertNil(state.alert)
    }

    func testModePersistsAndApplies() async throws {
        try makeShootFolder("A")
        let state = makeState()
        XCTAssertEqual(state.mode, .montageFluide)
        await state.choose(folder: volume)
        await state.toggle(try shoot(state, "A"))
        await state.setMode(.qualiteEtalonnage)
        XCTAssertEqual(state.mode, .qualiteEtalonnage)
        XCTAssertEqual(defaults.integer(forKey: "dualISOMode"), 2)
        XCTAssertTrue(http.requested.contains { $0.absoluteString.hasSuffix("/set_value?dual_iso=2") })
        XCTAssertNil(state.alert)

        let reloaded = makeState()
        XCTAssertEqual(reloaded.mode, .qualiteEtalonnage)
    }

    // MARK: Extra

    func testEngineCrashIsRelaunched() async throws {
        try makeShootFolder("A")
        let manager = makeManager()
        let state = makeState(manager)
        await state.choose(folder: volume)
        await state.toggle(try shoot(state, "A"))
        XCTAssertEqual(state.mounted.count, 1)

        try XCTUnwrap(launcher.processes.last).exit(9)
        await waitUntil { self.launcher.processes.count == 2 && state.mounted.count == 1 }
        XCTAssertEqual(launcher.processes.count, 2, "engine relaunched")
        XCTAssertTrue(try XCTUnwrap(launcher.processes.last).isRunning)
        XCTAssertEqual(state.mounted, [key(volume.appendingPathComponent("A"))])
        let mounted = await manager.mounted
        XCTAssertEqual(mounted.count, 1)
        XCTAssertNil(state.alert, "a successful relaunch is silent")
        XCTAssertEqual(savedMounts, [key(volume.appendingPathComponent("A"))])
    }

    func testEngineCrashingThreeTimesAlertsAndStaysUnmounted() async throws {
        try makeShootFolder("A")
        let state = makeState()
        await state.choose(folder: volume)
        await state.toggle(try shoot(state, "A"))
        for attempt in 1...3 {
            try XCTUnwrap(launcher.processes.last).exit(9)
            if attempt < 3 {
                await waitUntil { self.launcher.processes.count == attempt + 1 && state.mounted.count == 1 }
                XCTAssertEqual(launcher.processes.count, attempt + 1, "relaunch \(attempt)")
                XCTAssertNil(state.alert)
            }
        }
        await waitUntil { state.alert != nil }
        XCTAssertEqual(state.alert, "Le montage de « A » s'est arrêté et n'a pas pu être relancé (code 9).")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(launcher.processes.count, 3, "no relaunch after two retries")
        XCTAssertTrue(state.mounted.isEmpty)
        XCTAssertEqual(savedMounts, [key(volume.appendingPathComponent("A"))], "kept for the next launch")
    }

    func testRelaunchThatFailsAtStartupCountsAsRetry() async throws {
        try makeShootFolder("A")
        let state = makeState()
        await state.choose(folder: volume)
        await state.toggle(try shoot(state, "A"))
        launcher.mountsAppear.set(false) // relaunches never come up
        try XCTUnwrap(launcher.processes.last).exit(4)
        await waitUntil(8) { state.alert != nil }
        XCTAssertTrue(state.alert?.hasPrefix("Le montage de « A » s'est arrêté et n'a pas pu être relancé") ?? false,
                      state.alert ?? "nil")
        XCTAssertEqual(launcher.processes.count, 3)
        XCTAssertTrue(state.mounted.isEmpty)
    }

    func testCrashWithFolderGoneIsNotRetried() async throws {
        let a = try makeShootFolder("A")
        let state = makeState()
        await state.choose(folder: volume)
        await state.toggle(try shoot(state, "A"))
        try FileManager.default.removeItem(at: a) // the disk went away under the engine
        try XCTUnwrap(launcher.processes.last).exit(6)
        await waitUntil { state.mounted.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.mounted.isEmpty)
        XCTAssertEqual(launcher.processes.count, 1, "no relaunch when the folder is gone")
        XCTAssertNil(state.alert, "left to the unplug flow")
        XCTAssertEqual(savedMounts, [key(a)], "kept for a replug")
    }

    func testUnmountAllCancelsPendingRelaunch() async throws {
        try makeShootFolder("A")
        let state = makeState(restartDelays: [.milliseconds(200), .milliseconds(200)])
        await state.choose(folder: volume)
        await state.toggle(try shoot(state, "A"))
        try XCTUnwrap(launcher.processes.last).exit(9)
        await waitUntil { state.mounted.isEmpty }
        await state.unmountAll()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(launcher.processes.count, 1)
        XCTAssertTrue(state.mounted.isEmpty)
        XCTAssertTrue(savedMounts.isEmpty)
    }

    func testMountFailureAlertsAndDoesNotSave() async throws {
        try makeShootFolder("A")
        let state = makeState(makeManager(isPortFree: { _ in false }))
        await state.choose(folder: volume)
        await state.toggle(try shoot(state, "A"))
        XCTAssertTrue(state.mounted.isEmpty)
        XCTAssertEqual(state.alert, "Impossible de monter « A » : aucun port libre.")
        XCTAssertTrue(savedMounts.isEmpty)
    }

    func testDeliberateUnmountForgetsShoot() async throws {
        try makeShootFolder("A")
        let state = makeState()
        await state.choose(folder: volume)
        let a = try shoot(state, "A")
        await state.toggle(a)
        await state.toggle(a)
        XCTAssertTrue(state.mounted.isEmpty)
        XCTAssertTrue(savedMounts.isEmpty)
    }
}

// MARK: Task 11: pixel fixes, info, alert clearing
extension AppStateTests {
    func testPixelTogglesReachNextMount() async throws {
        try makeShootFolder("A")
        let state = makeState()
        XCTAssertTrue(state.fixBadPixels && state.fixFocusPixels)
        await state.choose(folder: volume)
        let a = try shoot(state, "A")
        await state.toggle(a)
        var args = try XCTUnwrap(launcher.processes.last).args
        XCTAssertTrue(args.contains("--bad-pix"))
        XCTAssertFalse(args.contains("--no-focus-pixels"))
        await state.toggle(a) // unmount
        state.fixBadPixels = false
        state.fixFocusPixels = false
        await state.toggle(a)
        args = try XCTUnwrap(launcher.processes.last).args
        XCTAssertFalse(args.contains("--bad-pix"))
        XCTAssertTrue(args.contains("--no-focus-pixels"))
        // persisted
        let other = makeState()
        XCTAssertFalse(other.fixBadPixels)
        XCTAssertFalse(other.fixFocusPixels)
    }

    func testSqueezeInfoOncePerShoot() async throws {
        let dir = try makeShootFolder("Ana")
        try SyntheticMLV.data(sampling: (1, 2, 1, 0)).write(to: dir.appendingPathComponent("A001.MLV"))
        let state = makeState()
        await state.choose(folder: volume)
        let s = try shoot(state, "Ana")
        await state.toggle(s)
        XCTAssertEqual(state.info, "Tournage anamorphosé 1x3 : dans Resolve, réglez le rapport de pixel à 3:1 (Attributs du clip).")
        state.clearInfo()
        XCTAssertNil(state.info)
        await state.toggle(s)
        await state.toggle(s)
        XCTAssertNil(state.info)
    }

    func testNoInfoForPlainShootAndClearAlert() async throws {
        try makeShootFolder("A")
        let state = makeState()
        await state.choose(folder: volume)
        await state.toggle(try shoot(state, "A"))
        XCTAssertNil(state.info)
        await state.volumeWillUnmount(volume)
        XCTAssertNotNil(state.alert)
        state.clearAlert()
        XCTAssertNil(state.alert)
    }
}

extension AppStateTests {
    func testQualityModeHintOnce() async {
        let state = makeState()
        await state.setMode(.montageFluide)
        XCTAssertNil(state.info)
        await state.setMode(.qualiteEtalonnage)
        XCTAssertEqual(state.info, "Dans Resolve, sélectionnez les plans puis clic droit → Rafraîchir.")
        state.clearInfo()
        await state.setMode(.montageFluide)
        await state.setMode(.qualiteEtalonnage)
        XCTAssertNil(state.info)
    }
}

extension AppStateTests {
    func testUnmountAllCoversOtherFolders() async throws {
        let a = try makeShootFolder("A")
        let other = tmp.appendingPathComponent("Other", isDirectory: true)
        let b = try makeShootFolder("B", in: other)
        defaults.set([key(a), key(b)], forKey: "mountedShoots")
        let state = makeState()
        await state.choose(folder: volume)
        await state.restore()
        XCTAssertEqual(state.mounted, [key(a), key(b)])
        await state.unmountAll()
        XCTAssertTrue(state.mounted.isEmpty)
        XCTAssertTrue(savedMounts.isEmpty)
        XCTAssertNil(state.alert)
        XCTAssertEqual(unmounter.unmounted.count, 2)
    }
}

extension AppStateTests {
    func testSameNameOnTwoDisksGetsCollisionNotice() async throws {
        try makeShootFolder("Jour 1")
        let other = tmp.appendingPathComponent("Other", isDirectory: true)
        try makeShootFolder("Jour 1", in: other)
        let manager = makeManager()
        let state = makeState(manager)
        await state.choose(folder: volume)
        await state.toggle(try shoot(state, "Jour 1"))
        XCTAssertNil(state.info, "first one gets the plain name")
        await state.choose(folder: other)
        let second = try shoot(state, "Jour 1")
        await state.toggle(second)
        let all = await manager.mounted
        let url = try XCTUnwrap(all[second])
        XCTAssertEqual(url.lastPathComponent, "Jour 1 (\(second.volumeName))")
        XCTAssertEqual(state.info,
                       "Deux tournages s'appellent « Jour 1 » : le second est monté sous « Jour 1 (\(second.volumeName)) ».")
    }
}

extension AppStateTests {
    func testToggleOffBusyShootAlertsAndStaysMounted() async throws {
        let a = try makeShootFolder("A")
        let manager = makeManager()
        let state = makeState(manager)
        await state.choose(folder: volume)
        let s = try shoot(state, "A")
        await state.toggle(s)
        let first = await manager.mounted.values.first
        let url = try XCTUnwrap(first)
        unmounter.makeBusy(url)

        await state.toggle(s)
        XCTAssertEqual(state.alert, "Impossible de démonter « A » : des fichiers sont peut-être ouverts dans Resolve.")
        XCTAssertEqual(state.mounted, [key(a)])
        XCTAssertEqual(savedMounts, [key(a)])
        XCTAssertEqual(unmounter.forced, [false])
        let mounted = await manager.mounted
        XCTAssertEqual(mounted.count, 1)

        await state.unmountAll()
        XCTAssertEqual(state.alert, "Impossible de démonter « A » : des fichiers sont peut-être ouverts dans Resolve.")
        XCTAssertEqual(state.mounted, [key(a)])
        XCTAssertEqual(unmounter.forced, [false, false], "« Tout démonter » never forces")
    }

    func testUnplugForcesBusyShoot() async throws {
        try makeShootFolder("A")
        let manager = makeManager()
        let state = makeState(manager)
        await state.choose(folder: volume)
        await state.toggle(try shoot(state, "A"))
        let first = await manager.mounted.values.first
        let url = try XCTUnwrap(first)
        unmounter.makeBusy(url)
        await state.volumeWillUnmount(volume)
        XCTAssertTrue(state.mounted.isEmpty)
        XCTAssertEqual(unmounter.forced, [true])
        let mounted = await manager.mounted
        XCTAssertTrue(mounted.isEmpty)
    }
}
