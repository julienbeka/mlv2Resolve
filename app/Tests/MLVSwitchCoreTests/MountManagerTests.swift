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
        unmounter = FakeUnmounter()
        launcher = FakeLauncher(unmounter: unmounter)
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

    func makeManager(isPortFree: @escaping @Sendable (Int) -> Bool = { _ in true },
                     readinessTimeout: Duration = .seconds(2)) -> MountManager {
        let http = self.http!
        let busy = launcher.busyPorts
        return MountManager(mlvfs: mlvfs, fpmDir: fpmDir, indexDir: indexDir,
                            paths: MountPaths(root: root), launcher: launcher, unmounter: unmounter,
                            http: { try await http.get($0) },
                            isPortFree: { !busy.get().contains($0) && isPortFree($0) },
                            readinessTimeout: readinessTimeout, pollInterval: .milliseconds(5))
    }

    func shoot(_ name: String, folder: String? = nil) -> Shoot {
        Shoot(name: name, folder: URL(fileURLWithPath: folder ?? "/Volumes/SSD/\(name)", isDirectory: true),
              volumeName: "SSD", clips: [])
    }

    /// First event within `seconds`, or nil. Consumes the stream: call once per test.
    func firstEvent(_ m: MountManager, within seconds: Double) async -> MountEvent? {
        let stream = m.events
        return await withTaskGroup(of: MountEvent?.self) { group in
            group.addTask { for await e in stream { return e }; return nil }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Arguments

    func testMountPassesArgsAsArray() async throws {
        let m = makeManager()
        let s = shoot("Tournage été 2026 🎬")
        let url = try await m.mount(s, mode: .montageFluide)
        let args = try XCTUnwrap(launcher.processes.first).args
        XCTAssertEqual(args[0], root.appendingPathComponent("Tournage été 2026 🎬").path)
        XCTAssertEqual(url.path, args[0])
        XCTAssertTrue(args.contains("--mlv-dir=/Volumes/SSD/Tournage été 2026 🎬"))
        XCTAssertTrue(args.contains("--dual-iso-preview"))
        XCTAssertFalse(args.contains("--dual-iso"))
        XCTAssertEqual(args, [
            url.path, "--mlv-dir=/Volumes/SSD/Tournage été 2026 🎬", "--resolve-naming", "--bad-pix",
            "--dual-iso-preview", "--fpm-dir=/opt/engine/fpm", "--index-dir=/tmp/index dir",
            "--port=127.0.0.1:8100", "-o", "ro", "-o", "volname=Tournage été 2026 🎬", "-f",
        ])
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue,
                      "mount point directory must exist before launch")
        let mounted = await m.mounted
        XCTAssertEqual(mounted, [s: url])
    }

    func testVolumeNameIsSafeForFuseOptions() async throws {
        let m = makeManager()
        let url = try await m.mount(shoot("Paris, jour 1"), mode: .montageFluide)
        let args = try XCTUnwrap(launcher.processes.first).args
        XCTAssertEqual(url.lastPathComponent, "Paris, jour 1", "the folder keeps the real name")
        XCTAssertTrue(args.contains("volname=Paris jour 1"), "\(args)")
        XCTAssertFalse(args.contains { $0.hasPrefix("volname=") && $0.contains(",") })
        XCTAssertEqual(MountManager.volumeName("a=b\\c,,d"), "a b c d")
        XCTAssertEqual(MountManager.volumeName(" , "), "MLV Switch")
        XCTAssertEqual(MountManager.volumeName("Tournage été 2026 🎬"), "Tournage été 2026 🎬")
    }

    func testEngineLogNamedAfterMountPoint() async throws {
        let logDir = root.appendingPathComponent("Logs", isDirectory: true)
        let http = self.http!
        let busy = launcher.busyPorts
        let m = MountManager(mlvfs: mlvfs, fpmDir: fpmDir, indexDir: indexDir, logDir: logDir,
                             paths: MountPaths(root: root), launcher: launcher, unmounter: unmounter,
                             http: { try await http.get($0) }, isPortFree: { !busy.get().contains($0) },
                             readinessTimeout: .seconds(2), pollInterval: .milliseconds(5))
        try await m.mount(shoot("Jour 1"), mode: .montageFluide)
        try await m.mount(shoot("Jour 1", folder: "/Volumes/Autre/Jour 1"), mode: .montageFluide)
        XCTAssertEqual(launcher.logs.get().map { $0?.lastPathComponent }, ["Jour 1.log", "Jour 1 (SSD).log"])
        XCTAssertEqual(launcher.logs.get().first??.deletingLastPathComponent().standardizedFileURL,
                       logDir.standardizedFileURL)
    }

    func testQualityModeUsesFullDualISO() async throws {
        let m = makeManager()
        try await m.mount(shoot("A"), mode: .qualiteEtalonnage)
        let args = try XCTUnwrap(launcher.processes.first).args
        XCTAssertTrue(args.contains("--dual-iso"))
        XCTAssertFalse(args.contains("--dual-iso-preview"))
    }

    func testAdvancedTogglesChangeArgs() async throws {
        let m = makeManager()
        try await m.mount(shoot("A"), mode: .montageFluide, fixBadPixels: false, fixFocusPixels: false)
        let args = try XCTUnwrap(launcher.processes.first).args
        XCTAssertFalse(args.contains("--bad-pix"))
        XCTAssertTrue(args.contains("--no-focus-pixels"))
    }

    // MARK: Ports

    func testPortSkipsBusyPorts() async throws {
        let m = makeManager(isPortFree: { $0 != 8100 })
        try await m.mount(shoot("A"), mode: .montageFluide)
        XCTAssertEqual(launcher.processes.first?.value("--port"), "127.0.0.1:8101")
    }

    func testPortSkipsOwnLiveProcesses() async throws {
        let m = makeManager()
        try await m.mount(shoot("A"), mode: .montageFluide)
        try await m.mount(shoot("B"), mode: .montageFluide)
        XCTAssertEqual(launcher.processes.map { $0.value("--port") }, ["127.0.0.1:8100", "127.0.0.1:8101"])
    }

    func testNoFreePortThrows() async throws {
        let m = makeManager(isPortFree: { _ in false })
        do {
            try await m.mount(shoot("A"), mode: .montageFluide)
            XCTFail("expected error")
        } catch MountError.noFreePort {}
        XCTAssertTrue(launcher.processes.isEmpty)
    }

    // MARK: Readiness

    func testMountingSameShootTwiceIsNoOp() async throws {
        let m = makeManager()
        let s = shoot("A")
        let a = try await m.mount(s, mode: .montageFluide)
        let b = try await m.mount(s, mode: .montageFluide)
        XCTAssertEqual(a, b)
        XCTAssertEqual(launcher.processes.count, 1)
    }

    func testWebGUINotBoundFailsMountAndCleansUp() async throws {
        launcher.bindsPort.set(false)
        let m = makeManager(readinessTimeout: .milliseconds(100))
        do {
            try await m.mount(shoot("A"), mode: .montageFluide)
            XCTFail("expected error")
        } catch MountError.webGUIUnavailable(let port) {
            XCTAssertEqual(port, 8100)
        }
        let p = try XCTUnwrap(launcher.processes.first)
        XCTAssertTrue(p.wasTerminated)
        XCTAssertEqual(unmounter.unmounted, [root.appendingPathComponent("A").path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("A").path))
        let mounted = await m.mounted
        XCTAssertTrue(mounted.isEmpty)
    }

    func testMountThatNeverAppearsTimesOut() async throws {
        launcher.mountsAppear.set(false)
        let m = makeManager(readinessTimeout: .milliseconds(100))
        do {
            try await m.mount(shoot("A"), mode: .montageFluide)
            XCTFail("expected error")
        } catch MountError.startupTimedOut {}
        XCTAssertTrue(try XCTUnwrap(launcher.processes.first).wasTerminated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("A").path))
    }

    func testProcessDyingDuringStartupThrows() async throws {
        launcher.mountsAppear.set(false)
        let m = makeManager()
        let launcher = self.launcher!
        Task {
            while launcher.processes.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
            launcher.processes[0].exit(1)
        }
        do {
            try await m.mount(shoot("A"), mode: .montageFluide)
            XCTFail("expected error")
        } catch MountError.exitedDuringStartup(let status) {
            XCTAssertEqual(status, 1)
        }
    }

    // MARK: Dual ISO

    func testSetModeHitsEveryProcess() async throws {
        let m = makeManager()
        try await m.mount(shoot("A"), mode: .montageFluide)
        try await m.mount(shoot("B"), mode: .montageFluide)
        let failed = await m.setMode(.qualiteEtalonnage)
        XCTAssertEqual(failed, [])
        XCTAssertEqual(Set(http.requested.map(\.absoluteString)), [
            "http://127.0.0.1:8100/set_value?dual_iso=2",
            "http://127.0.0.1:8101/set_value?dual_iso=2",
        ])
    }

    func testSetModeReportsFailingShoots() async throws {
        let m = makeManager()
        let a = shoot("A"), b = shoot("B")
        try await m.mount(a, mode: .montageFluide)
        try await m.mount(b, mode: .montageFluide)
        http.failingPorts.set([8101])
        let failed = await m.setMode(.qualiteEtalonnage)
        XCTAssertEqual(failed, [b])
    }

    // MARK: Exits

    func testCrashCleansMount() async throws {
        let m = makeManager()
        let s = shoot("A")
        let url = try await m.mount(s, mode: .montageFluide)
        try XCTUnwrap(launcher.processes.first).exit(11)
        let event = await firstEvent(m, within: 2)
        XCTAssertEqual(event, .exited(s, status: 11))
        // The event is sent before the force unmount runs: wait for the cleanup.
        let deadline = Date().addingTimeInterval(2)
        while unmounter.unmounted.isEmpty || FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let mounted = await m.mounted
        XCTAssertTrue(mounted.isEmpty)
        XCTAssertEqual(unmounter.unmounted, [url.standardizedFileURL.path])
        XCTAssertEqual(unmounter.forced, [true], "crash path goes straight to force unmount")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "empty mount point removed")
    }

    func testDeliberateUnmountEmitsNoEvent() async throws {
        let m = makeManager()
        let s = shoot("A")
        try await m.mount(s, mode: .montageFluide)
        try await m.unmount(s)
        let event = await firstEvent(m, within: 0.2)
        XCTAssertNil(event)
    }

    func testDeadEntryIsHiddenAndMountRelaunches() async throws {
        let m = makeManager()
        let s = shoot("A")
        let url = try await m.mount(s, mode: .montageFluide)
        let first = try XCTUnwrap(launcher.processes.first)
        first.dieSilently()
        let mounted = await m.mounted
        XCTAssertTrue(mounted.isEmpty, "dead process must not count as mounted")
        let again = try await m.mount(s, mode: .montageFluide)
        XCTAssertEqual(again, url)
        XCTAssertEqual(launcher.processes.count, 2)
        let mountedAfter = await m.mounted
        XCTAssertEqual(mountedAfter, [s: url])
        // The late exit callback of the first process must not tear down the new mount.
        first.onExit?(9)
        try await Task.sleep(for: .milliseconds(50))
        let stillMounted = await m.mounted
        XCTAssertEqual(stillMounted, [s: url])
    }

    // MARK: Unmount

    func testUnmountTerminatesAndRemovesDir() async throws {
        let m = makeManager()
        let s = shoot("A")
        let url = try await m.mount(s, mode: .montageFluide)
        try await m.unmount(s)
        XCTAssertEqual(unmounter.unmounted, [url.standardizedFileURL.path])
        XCTAssertEqual(unmounter.forced, [false])
        XCTAssertTrue(try XCTUnwrap(launcher.processes.first).wasTerminated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let mounted = await m.mounted
        XCTAssertTrue(mounted.isEmpty)
    }

    func testFailedUnmountKeepsShootMounted() async throws {
        let m = makeManager()
        let s = shoot("A")
        let url = try await m.mount(s, mode: .montageFluide)
        unmounter.failUnmount(url)
        do {
            try await m.unmount(s)
            XCTFail("expected error")
        } catch MountError.unmountFailed {}
        XCTAssertFalse(try XCTUnwrap(launcher.processes.first).wasTerminated)
        let mounted = await m.mounted
        XCTAssertEqual(mounted, [s: url])
    }

    func testBusyVolumeIsNotForcedByDefault() async throws {
        let m = makeManager()
        let s = shoot("A")
        let url = try await m.mount(s, mode: .montageFluide)
        unmounter.makeBusy(url)
        do {
            try await m.unmount(s)
            XCTFail("expected error")
        } catch MountError.unmountFailed {}
        XCTAssertEqual(unmounter.forced, [false], "user-initiated unmount never forces")
        XCTAssertFalse(try XCTUnwrap(launcher.processes.first).wasTerminated)
        let still = await m.mounted
        XCTAssertEqual(still, [s: url])

        try await m.unmount(s, force: true) // quit / unplug
        XCTAssertEqual(unmounter.forced, [false, true])
        let after = await m.mounted
        XCTAssertTrue(after.isEmpty)
    }

    func testUnmountAll() async throws {
        let m = makeManager()
        var urls: [URL] = []
        for name in ["A", "B", "C"] {
            urls.append(try await m.mount(shoot(name), mode: .montageFluide))
        }
        await m.unmountAll()
        XCTAssertTrue(launcher.processes.allSatisfy { $0.wasTerminated && !$0.isRunning })
        XCTAssertEqual(Set(unmounter.unmounted), Set(urls.map(\.standardizedFileURL.path)))
        let mounted = await m.mounted
        XCTAssertTrue(mounted.isEmpty)
        // Terminating fires onExit; it must not trigger a second unmount.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(unmounter.unmounted.count, 3)
    }

    // MARK: Stale mounts

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
        let live = try await m.mount(shoot("En cours"), mode: .montageFluide)

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

    func testCleanStaleMountsIgnoresSymlinkedChildren() async throws {
        let volume = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeVolume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: volume) }
        let link = root.appendingPathComponent("SSD")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: volume)
        // Simulate an unmounter that follows the link to a real mount point.
        unmounter.markMounted(volume)
        unmounter.markMounted(link)

        try await makeManager().cleanStaleMounts()

        XCTAssertEqual(unmounter.unmounted, [])
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: volume.path))
    }

    func testForceUnmountUsesUmountDashF() throws {
        final class Calls: @unchecked Sendable { var list: [(String, [String])] = [] }
        let calls = Calls()
        let mounted = NSLock()
        nonisolated(unsafe) var isMounted = true
        let u = UmountUnmounter(runner: { tool, args, _ in
            mounted.lock(); defer { mounted.unlock() }
            calls.list.append((tool, args)); isMounted = false; return 0
        }, mountCheck: { _ in mounted.lock(); defer { mounted.unlock() }; return isMounted })
        let p = URL(fileURLWithPath: "/tmp/x-mount")
        try u.unmount(p, force: true)
        XCTAssertEqual(calls.list.count, 1)
        XCTAssertEqual(calls.list[0].0, "/sbin/umount")
        XCTAssertEqual(calls.list[0].1, ["-f", "/tmp/x-mount"])
    }

    func testRealIsMountPointIgnoresSymlinks() throws {
        let u = UmountUnmounter()
        XCTAssertTrue(u.isMountPoint(URL(fileURLWithPath: "/")))
        let link = root.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/"))
        XCTAssertFalse(u.isMountPoint(link))
        XCTAssertFalse(u.isMountPoint(root))
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
        let logDir = root.appendingPathComponent("Logs", isDirectory: true)
        let m = MountManager(mlvfs: engine, fpmDir: repo.appendingPathComponent("engine/mlvfs/fpm"),
                             indexDir: index, logDir: logDir, paths: MountPaths(root: mountRoot),
                             launcher: FoundationLauncher(), unmounter: UmountUnmounter(),
                             http: MountManager.httpGet, isPortFree: MountManager.isLocalPortFree)
        let s = Shoot(name: "Intégration été, n° \(UUID().uuidString.prefix(6))", folder: repo,
                      volumeName: "Macintosh HD", clips: [])
        let url = try await m.mount(s, mode: .montageFluide)
        do {
            XCTAssertTrue(UmountUnmounter().isMountPoint(url), "mount must be up when mount() returns")
            // FUSE-T accepted the sanitized volname (spaces, accents; the comma became a space).
            var fs = statfs()
            XCTAssertEqual(statfs(url.path, &fs), 0)
            let from = withUnsafePointer(to: &fs.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            print("mount source for \(url.lastPathComponent): \(from)")
            let expected = MountManager.volumeName(s.name)
            XCTAssertFalse(expected.contains(","))
            XCTAssertEqual(from.precomposedStringWithCanonicalMapping,
                           "fuse-t:/\(expected)".precomposedStringWithCanonicalMapping)
            let clipDir = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: url.path)
                .first { $0.hasPrefix("M29-0615") })
            let dngs = try FileManager.default.contentsOfDirectory(
                atPath: url.appendingPathComponent(clipDir).path).filter { $0.lowercased().hasSuffix(".dng") }
            XCTAssertEqual(dngs.count, 320)
            // The engine's stdout+stderr land in the per-shoot log (frame 0 read -> focus pixel line).
            let first = try XCTUnwrap(dngs.sorted().first)
            let reader = try FileHandle(forReadingFrom: url.appendingPathComponent(clipDir).appendingPathComponent(first))
            _ = try reader.read(upToCount: 1 << 20)
            try reader.close()
            let logURL = EngineLog.file(in: logDir, name: url.lastPathComponent)
            var log = ""
            for _ in 0..<100 where !log.contains("focus pixels:") {
                log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                try await Task.sleep(for: .milliseconds(20))
            }
            print("engine log \(logURL.lastPathComponent):\n" + log.split(separator: "\n").prefix(4).joined(separator: "\n"))
            XCTAssertTrue(log.hasPrefix("=== "), log)
            XCTAssertTrue(log.contains("focus pixels:"), log)

            // A DNG held open (as Resolve does): the user-initiated unmount must not force it.
            let held = try FileHandle(forReadingFrom: url.appendingPathComponent(clipDir)
                .appendingPathComponent(try XCTUnwrap(dngs.sorted().first)))
            _ = try held.read(upToCount: 4096)
            var busyError: Error?
            do { try await m.unmount(s) } catch { busyError = error }
            print("unmount with an open DNG -> \(busyError.map { "\($0)" } ?? "succeeded")")
            try held.close()
            XCTAssertEqual(busyError as? MountError, .unmountFailed(url))
            XCTAssertTrue(UmountUnmounter().isMountPoint(url), "a refused unmount keeps the volume mounted")
            let still = await m.mounted
            XCTAssertEqual(still.count, 1)

            let maybePort = await m.port(for: s)
            let port = try XCTUnwrap(maybePort)
            let listen = try lsofListen(port)
            print("lsof LISTEN :\(port) -> \(listen)")
            XCTAssertTrue(listen.contains("127.0.0.1:\(port)"), listen)
            XCTAssertFalse(listen.contains("*:\(port)"), listen)

            // The live switch endpoint must answer 2xx on the real engine.
            try await MountManager.httpGet(URL(string: "http://127.0.0.1:\(port)/set_value?dual_iso=2")!)
            let failed = await m.setMode(.montageFluide)
            XCTAssertEqual(failed, [])
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

    private func lsofListen(_ port: Int) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
