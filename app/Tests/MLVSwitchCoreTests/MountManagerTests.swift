// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLVSwitchCore

final class MountManagerTests: XCTestCase {
    var root: URL!
    let mlvfs = URL(fileURLWithPath: "/opt/engine/mlvfs")
    let fpmDir = URL(fileURLWithPath: "/opt/engine/fpm", isDirectory: true)
    let indexDir = URL(fileURLWithPath: "/tmp/index dir", isDirectory: true)
    var launcher: FakeLauncher!
    var unmounter: FakeUnmounter!
    var http: RecordingHTTP!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MountManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        launcher = FakeLauncher()
        unmounter = FakeUnmounter()
        http = RecordingHTTP()
    }

    override func tearDownWithError() throws {
        // Never recursively delete through a live mount (integration test failure).
        let real = UmountUnmounter()
        let sub = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])
        var hasMount = false
        while let u = sub?.nextObject() as? URL, !hasMount {
            if real.isMountPoint(u) { hasMount = true; sub?.skipDescendants() }
            if sub?.level ?? 0 >= 2 { sub?.skipDescendants() }
        }
        if !hasMount { try? FileManager.default.removeItem(at: root) }
    }

    func makeManager(isPortFree: @escaping @Sendable (Int) -> Bool = { _ in true }) -> MountManager {
        let http = self.http!
        return MountManager(mlvfs: mlvfs, fpmDir: fpmDir, indexDir: indexDir,
                            paths: MountPaths(root: root), launcher: launcher, unmounter: unmounter,
                            http: { try await http.get($0) }, isPortFree: isPortFree)
    }

    func shoot(_ name: String, folder: String) -> Shoot {
        Shoot(name: name, folder: URL(fileURLWithPath: folder, isDirectory: true),
              volumeName: "SSD", clips: [])
    }

    func testMountPassesArgsAsArray() async throws {
        let m = makeManager()
        let s = shoot("Tournage été 2026 🎬", folder: "/Volumes/SSD/Tournage été 2026 🎬")
        let url = try await m.mount(s, mode: .montageFluide)
        let args = try XCTUnwrap(launcher.processes.first).args
        XCTAssertEqual(args[0], root.appendingPathComponent("Tournage été 2026 🎬").path)
        XCTAssertEqual(url.path, args[0])
        XCTAssertTrue(args.contains("--mlv-dir=/Volumes/SSD/Tournage été 2026 🎬"))
        XCTAssertTrue(args.contains("--dual-iso-preview"))
        XCTAssertFalse(args.contains("--dual-iso"))
        XCTAssertTrue(args.contains("-o"))
        XCTAssertTrue(args.contains("ro"))
        XCTAssertEqual(args, [
            url.path, "--mlv-dir=/Volumes/SSD/Tournage été 2026 🎬", "--resolve-naming", "--bad-pix",
            "--dual-iso-preview", "--fpm-dir=/opt/engine/fpm", "--index-dir=/tmp/index dir",
            "--port=8100", "-o", "ro", "-o", "volname=Tournage été 2026 🎬", "-f",
        ])
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue,
                      "mount point directory must exist before launch")
        let mounted = await m.mounted
        XCTAssertEqual(mounted, [s: url])
    }

    func testQualityModeUsesFullDualISO() async throws {
        let m = makeManager()
        _ = try await m.mount(shoot("A", folder: "/Volumes/SSD/A"), mode: .qualiteEtalonnage)
        let args = try XCTUnwrap(launcher.processes.first).args
        XCTAssertTrue(args.contains("--dual-iso"))
        XCTAssertFalse(args.contains("--dual-iso-preview"))
    }

    func testAdvancedTogglesChangeArgs() async throws {
        let m = makeManager()
        _ = try await m.mount(shoot("A", folder: "/Volumes/SSD/A"), mode: .montageFluide,
                              fixBadPixels: false, fixFocusPixels: false)
        let args = try XCTUnwrap(launcher.processes.first).args
        XCTAssertFalse(args.contains("--bad-pix"))
        XCTAssertTrue(args.contains("--no-focus-pixels"))
    }

    func testPortSkipsBusyPorts() async throws {
        let m = makeManager(isPortFree: { $0 != 8100 })
        _ = try await m.mount(shoot("A", folder: "/Volumes/SSD/A"), mode: .montageFluide)
        XCTAssertEqual(launcher.processes.first?.value("--port"), "8101")
    }

    func testPortSkipsOwnLiveProcesses() async throws {
        let m = makeManager()
        _ = try await m.mount(shoot("A", folder: "/Volumes/SSD/A"), mode: .montageFluide)
        _ = try await m.mount(shoot("B", folder: "/Volumes/SSD/B"), mode: .montageFluide)
        XCTAssertEqual(launcher.processes.map { $0.value("--port") }, ["8100", "8101"])
    }

    func testMountingSameShootTwiceIsNoOp() async throws {
        let m = makeManager()
        let s = shoot("A", folder: "/Volumes/SSD/A")
        let a = try await m.mount(s, mode: .montageFluide)
        let b = try await m.mount(s, mode: .montageFluide)
        XCTAssertEqual(a, b)
        XCTAssertEqual(launcher.processes.count, 1)
    }

    func testNoFreePortThrows() async throws {
        let m = makeManager(isPortFree: { _ in false })
        do {
            _ = try await m.mount(shoot("A", folder: "/Volumes/SSD/A"), mode: .montageFluide)
            XCTFail("expected error")
        } catch MountError.noFreePort {}
        XCTAssertTrue(launcher.processes.isEmpty)
    }

    func testSetModeHitsEveryProcess() async throws {
        let m = makeManager()
        _ = try await m.mount(shoot("A", folder: "/Volumes/SSD/A"), mode: .montageFluide)
        _ = try await m.mount(shoot("B", folder: "/Volumes/SSD/B"), mode: .montageFluide)
        await m.setMode(.qualiteEtalonnage)
        XCTAssertEqual(Set(http.requested.map(\.absoluteString)), [
            "http://127.0.0.1:8100/set_value?dual_iso=2",
            "http://127.0.0.1:8101/set_value?dual_iso=2",
        ])
    }

    func testCrashCleansMount() async throws {
        let m = makeManager()
        let url = try await m.mount(shoot("A", folder: "/Volumes/SSD/A"), mode: .montageFluide)
        unmounter.markMounted(url)
        try XCTUnwrap(launcher.processes.first).exit(11)
        for _ in 0..<200 where await !m.mounted.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let mounted = await m.mounted
        XCTAssertTrue(mounted.isEmpty)
        XCTAssertEqual(unmounter.unmounted, [url.standardizedFileURL.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "empty mount point removed")
    }

    func testCleanStaleMounts() async throws {
        let stale = root.appendingPathComponent("Ancien tournage", isDirectory: true)
        let emptyDir = root.appendingPathComponent("Vide", isDirectory: true)
        let userDir = root.appendingPathComponent("Mes fichiers", isDirectory: true)
        for d in [stale, emptyDir, userDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: userDir.appendingPathComponent("note.txt").path,
                                       contents: Data("x".utf8))
        unmounter.markMounted(stale)

        let m = makeManager()
        let live = try await m.mount(shoot("En cours", folder: "/Volumes/SSD/En cours"), mode: .montageFluide)
        unmounter.markMounted(live)

        try await m.cleanStaleMounts()

        XCTAssertEqual(unmounter.unmounted, [stale.standardizedFileURL.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userDir.appendingPathComponent("note.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertTrue(unmounter.isMountPoint(live))
        let mounted = await m.mounted
        XCTAssertEqual(mounted.count, 1)
    }

    func testUnmountTerminatesAndRemovesDir() async throws {
        let m = makeManager()
        let s = shoot("A", folder: "/Volumes/SSD/A")
        let url = try await m.mount(s, mode: .montageFluide)
        unmounter.markMounted(url)
        try await m.unmount(s)
        XCTAssertEqual(unmounter.unmounted, [url.standardizedFileURL.path])
        XCTAssertTrue(try XCTUnwrap(launcher.processes.first).wasTerminated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let mounted = await m.mounted
        XCTAssertTrue(mounted.isEmpty)
    }

    func testUnmountAll() async throws {
        let m = makeManager()
        var urls: [URL] = []
        for name in ["A", "B", "C"] {
            let url = try await m.mount(shoot(name, folder: "/Volumes/SSD/\(name)"), mode: .montageFluide)
            unmounter.markMounted(url)
            urls.append(url)
        }
        await m.unmountAll()
        XCTAssertTrue(launcher.processes.allSatisfy { $0.wasTerminated && !$0.isRunning })
        XCTAssertEqual(Set(unmounter.unmounted), Set(urls.map(\.standardizedFileURL.path)))
        let mounted = await m.mounted
        XCTAssertTrue(mounted.isEmpty)
        // Terminating fires onExit; it must not trigger a second unmount.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(unmounter.unmounted.count, 3)
    }

    // MARK: - Integration

    func testRealMountOfTestClip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLVSWITCH_INTEGRATION"] == "1",
                          "set MLVSWITCH_INTEGRATION=1 to run")
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let engine = repo.appendingPathComponent("build/engine/mlvfs")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: engine.path), "build the engine first")
        let index = root.appendingPathComponent(".index", isDirectory: true)
        let mountRoot = root.appendingPathComponent("mounts", isDirectory: true)
        let m = MountManager(mlvfs: engine, fpmDir: repo.appendingPathComponent("engine/mlvfs/fpm"),
                             indexDir: index, paths: MountPaths(root: mountRoot),
                             launcher: FoundationLauncher(), unmounter: UmountUnmounter(),
                             http: MountManager.httpGet, isPortFree: MountManager.isLocalPortFree)
        let s = Shoot(name: "Integration \(UUID().uuidString.prefix(6))", folder: repo,
                      volumeName: "Macintosh HD", clips: [])
        let url = try await m.mount(s, mode: .montageFluide)
        do {
            let unmounter = UmountUnmounter()
            for _ in 0..<100 where !unmounter.isMountPoint(url) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertTrue(unmounter.isMountPoint(url), "mount did not appear")
            let clipDir = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: url.path)
                .first { $0.hasPrefix("M29-0615") })
            let dngs = try FileManager.default.contentsOfDirectory(
                atPath: url.appendingPathComponent(clipDir).path).filter { $0.lowercased().hasSuffix(".dng") }
            XCTAssertEqual(dngs.count, 320)
            let maybePort = await m.port(for: s)
            let port = try XCTUnwrap(maybePort)
            // The live switch endpoint must answer 2xx on the real engine.
            try await MountManager.httpGet(URL(string: "http://127.0.0.1:\(port)/set_value?dual_iso=2")!)
            await m.setMode(.montageFluide)
        } catch {
            await m.unmountAll()
            throw error
        }
        try await m.unmount(s)
        XCTAssertFalse(UmountUnmounter().isMountPoint(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let mounted = await m.mounted
        XCTAssertTrue(mounted.isEmpty)
    }
}
