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

    func makeState(_ manager: MountManager? = nil) -> AppState {
        AppState(manager: manager ?? makeManager(), defaults: defaults, scan: ShootScanner.scan)
    }

    /// Creates `<volume>/<name>/A001.MLV` and returns the shoot folder.
    @discardableResult
    func makeShootFolder(_ name: String, in parent: URL? = nil) throws -> URL {
        let dir = (parent ?? volume).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("A001.MLV").path, contents: Data())
        return dir
    }

    func key(_ url: URL) -> String { url.standardizedFileURL.path }

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

    func testEngineCrashRemovesMountKeepsSavedAndAlerts() async throws {
        try makeShootFolder("A")
        let state = makeState()
        await state.choose(folder: volume)
        await state.toggle(try shoot(state, "A"))
        XCTAssertEqual(state.mounted.count, 1)

        try XCTUnwrap(launcher.processes.last).exit(9)
        await waitUntil { state.mounted.isEmpty }
        XCTAssertTrue(state.mounted.isEmpty)
        XCTAssertEqual(state.alert, "Le montage de « A » s'est arrêté (code 9).")
        XCTAssertEqual(savedMounts, [key(volume.appendingPathComponent("A"))])
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
