// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2DNGCore

/// Counts motion runs and can hold them until released.
private actor MotionGate {
    private(set) var calls = 0
    private(set) var entered = false
    private var holding: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(holding: Bool = false) { self.holding = holding }
    func pass() async {
        calls += 1
        entered = true
        if holding { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { holding = false; waiters.forEach { $0.resume() }; waiters = [] }
}

@MainActor
final class GyroSyncCoordinatorTests: XCTestCase {
    var tmp: URL!
    var shootDir: URL!
    var mountPoint: URL!
    var backups: URL!
    var suite: String!
    var defaults: UserDefaults!

    /// Day of every synthetic clip/log (local time, like the camera and the A1).
    let day = DateComponents(year: 2026, month: 10, day: 24, hour: 10, minute: 0, second: 0)

    override func setUp() async throws {
        L10n.bundle = L10nTests.bundle("en")
        let fm = FileManager.default
        tmp = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("GyroSyncCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        shootDir = tmp.appendingPathComponent("rushes/Day1", isDirectory: true)
        mountPoint = tmp.appendingPathComponent("mounts/Day1", isDirectory: true)
        backups = tmp.appendingPathComponent("backups", isDirectory: true)
        for d in [shootDir!, mountPoint!] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Builders

    private func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
    private func hdr(_ type: String, size: Int, ts: UInt64) -> Data {
        Data(type.utf8) + Data(le(UInt64(size), 4)) + Data(le(ts, 8))
    }

    /// A header-only MLV at 25 fps, 1600x900, starting at `day` + `atSecond`, with its mount clip folder.
    @discardableResult
    private func makeClip(_ name: String, atSecond s: Int, frames: Int = 250,
                          sampling: (UInt8, UInt8, UInt8, UInt8)? = nil) throws -> (clip: Clip, key: String, dir: String) {
        var mlvi = hdr("MLVI", size: 52, ts: 0)
        mlvi += Data(count: 36); mlvi.replaceSubrange(44..<48, with: le(25, 4)); mlvi.replaceSubrange(48..<52, with: le(1, 4))
        let rawi = hdr("RAWI", size: 64, ts: 0) + Data(le(1600, 2) + le(900, 2)) + Data(count: 44)
        let t = day.hour! * 3600 + s
        let rtci = hdr("RTCI", size: 44, ts: 1_000_000)
            + Data(le(UInt64(t % 60), 2) + le(UInt64(t / 60 % 60), 2) + le(UInt64(t / 3600), 2)
                   + le(UInt64(day.day!), 2) + le(UInt64(day.month! - 1), 2) + le(UInt64(day.year! - 1900), 2))
            + Data(count: 16)
        var d = mlvi + rawi + rtci
        if let p = sampling {  // RAWC: binning_x, skipping_x, binning_y, skipping_y after res_x/res_y/crop/reserved
            d += hdr("RAWC", size: 32, ts: 0) + Data(count: 8) + Data([p.0, p.1, p.2, p.3]) + Data(count: 4)
        }
        for _ in 0..<frames { d += hdr("VIDF", size: 32, ts: 1_000_000) + Data(count: 16) }
        let url = shootDir.appendingPathComponent("\(name).MLV")
        try d.write(to: url)
        let dir = "\(name)MLV_1_2026-10-24_0001_C0000"
        try FileManager.default.createDirectory(at: mountPoint.appendingPathComponent(dir), withIntermediateDirectories: true)
        return (Clip(name: name, files: [url], bytes: Int64(d.count)), AppState.key(url), dir)
    }

    /// A SenseFlow log starting at `day` + `atSecond`, `seconds` long at 1 kHz.
    @discardableResult
    private func makeLog(_ name: String, atSecond s: Int, seconds: Int = 60) throws -> URL {
        var h = Data(count: 0x200)
        h.replaceSubrange(0..<9, with: Array("SenseFlow".utf8))
        let t = day.hour! * 3600 + s
        h.replaceSubrange(0x40..<0x46, with: [UInt8(day.year! - 2000), UInt8(day.month!), UInt8(day.day!),
                                              UInt8(t / 3600), UInt8(t / 60 % 60), UInt8(t % 60)])
        var rec = Data([0xAA, 0x55, 0x03]) + Data(count: 13)
        rec[9] = 10
        var body = Data(); body.reserveCapacity(seconds * 1000 * 16)
        for _ in 0..<(seconds * 1000) { body += rec }
        let url = tmp.appendingPathComponent("rushes/A1/\(name)_mix.bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (h + body).write(to: url)
        return url
    }

    private func shoot(_ clips: [Clip]) -> Shoot {
        Shoot(name: "Day1", folder: shootDir, volumeName: "", clips: clips)
    }

    private var chosen: URL { tmp.appendingPathComponent("rushes", isDirectory: true) }

    private func gyroflow(_ dir: String) -> URL { shootDir.appendingPathComponent("\(dir)_000000.gyroflow") }

    private func coordinator(gate: MotionGate = MotionGate(),
                             solver: @escaping GyroSyncCoordinator.Solver = { _, _, _, _ in
                                 SyncResult(lagMs: 10_000, r2: 0.9, secondPeak: 0.1, map: [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
                             },
                             logReader: @escaping @Sendable (URL) throws -> A1Log = A1Log.read) -> GyroSyncCoordinator {
        GyroSyncCoordinator(
            motionRunner: { _ in
                await gate.pass()
                return [MotionSample(frame: 1, dx: 1, dy: 0, peak: 1)]
            },
            defaults: defaults, backupsRoot: backups, solver: solver,
            clipDirResolver: GyroSyncCoordinator.clipDir(mountPoint:mlv:), logReader: logReader)
    }

    private func withLens(_ c: GyroSyncCoordinator, _ name: String = "Helios", focal: Double = 25) -> Lens {
        let lens = Lens(name: name, focalMM: focal)
        c.lenses.append(lens)
        c.setDefaultLens(lens, forShoot: AppState.key(shootDir))
        return lens
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: Tests

    func testWritesGyroflowNextToMLV() async throws {
        let (clip, key, dir) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        let c = coordinator()
        _ = withLens(c)
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)

        XCTAssertEqual(c.states[key], .synced(r2: 0.9, log: "t1_mix.bin", offsetMs: -10_000))
        let p = try json(gyroflow(dir))
        let src = try XCTUnwrap(p["gyro_source"] as? [String: Any])
        XCTAssertTrue((src["filepath"] as? String ?? "").hasSuffix("t1_mix.bin"))
        XCTAssertTrue((p["videofile"] as? String ?? "").contains("mounts/Day1/\(dir)/"))
        XCTAssertEqual(defaults.stringArray(forKey: "gyroWritten"), [key])

        // Remount: restored from the stored metadata, nothing recomputed.
        let gate = MotionGate()
        let c2 = coordinator(gate: gate)
        c2.shootUnmounted(shoot([clip]))
        await c2.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
        XCTAssertEqual(c2.states[key], .synced(r2: 0.9, log: "t1_mix.bin", offsetMs: -10_000))
        let calls = await gate.calls
        XCTAssertEqual(calls, 0)
    }

    /// A clip whose header says 1x1 among 1x3 clips of the same size gets the 1x3 Gyroflow project.
    func testCorrectedSqueezeReachesGyroflow() async throws {
        let a = try makeClip("A001", atSecond: 10, frames: 50, sampling: (1, 2, 1, 0))
        let b = try makeClip("A002", atSecond: 15, frames: 50, sampling: (1, 0, 1, 0))  // wrong header
        let d = try makeClip("A003", atSecond: 20, frames: 50, sampling: (1, 2, 1, 0))
        try makeLog("t1", atSecond: 0)
        let c = coordinator()
        _ = withLens(c)
        let sh = shoot([a.clip, b.clip, d.clip])
        let analysis = SqueezeFix.analyze(sh)
        XCTAssertEqual(analysis.squeezeByName, ["A002.MLV": 3])
        await c.shootMounted(sh, mountPoint: mountPoint, chosenFolder: chosen, squeezeFixes: analysis.squeezeByName)
        for clip in [a, b, d] {
            let p = try json(gyroflow(clip.dir))
            let out = try XCTUnwrap(p["output"] as? [String: Any])
            XCTAssertEqual(out["output_width"] as? Int, 4800, clip.dir)
            let cal = try XCTUnwrap(p["calibration_data"] as? [String: Any])
            XCTAssertEqual(cal["input_horizontal_stretch"] as? Double, 3, clip.dir)
        }
        // The coordinator uses the mount's result and never re-reads the headers: without it, the header wins.
        c.shootUnmounted(sh)
        let c2 = coordinator()
        _ = withLens(c2)
        try FileManager.default.removeItem(at: gyroflow(b.dir))
        await c2.shootMounted(sh, mountPoint: mountPoint, chosenFolder: chosen)
        let out = try XCTUnwrap(try json(gyroflow(b.dir))["output"] as? [String: Any])
        XCTAssertEqual(out["output_width"] as? Int, 1600)
    }

    func testSkipsExisting() async throws {
        let (clip, key, dir) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        try Data("niyien".utf8).write(to: gyroflow(dir))
        let gate = MotionGate()
        let c = coordinator(gate: gate)
        _ = withLens(c)
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)

        XCTAssertEqual(c.states[key], .existing)
        XCTAssertEqual(try String(contentsOf: gyroflow(dir), encoding: .utf8), "niyien")
        let calls = await gate.calls
        XCTAssertEqual(calls, 0)

        // A shoot default lens change does not touch a file mlv2dng did not write.
        c.setDefaultLens(withLens(c, "Other", focal: 50), forShoot: AppState.key(shootDir))
        await c.idle()
        XCTAssertEqual(try String(contentsOf: gyroflow(dir), encoding: .utf8), "niyien")
        XCTAssertEqual(c.states[key], .existing)
    }

    func testRegenerateBacksUpOld() async throws {
        let (clip, key, dir) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        try Data("niyien".utf8).write(to: gyroflow(dir))
        let c = coordinator()
        _ = withLens(c)
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
        await c.regenerate(clip: key)

        XCTAssertEqual(c.states[key], .synced(r2: 0.9, log: "t1_mix.bin", offsetMs: -10_000))
        XCTAssertNotNil(try? json(gyroflow(dir)))
        let saved = try FileManager.default.contentsOfDirectory(at: backups.appendingPathComponent("Day1"),
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(saved.count, 1)
        let name = try XCTUnwrap(saved.first?.lastPathComponent)
        XCTAssertTrue(name.hasPrefix("\(dir)_000000-") && name.hasSuffix(".gyroflow"), name)
        XCTAssertEqual(name.count, "\(dir)_000000-yyyyMMdd-HHmmss.gyroflow".count)
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(saved.first), encoding: .utf8), "niyien")
    }

    func testLensChangeRegenerates() async throws {
        let (clip, key, dir) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        let c = coordinator()
        _ = withLens(c, "Helios", focal: 25)
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
        func calName() throws -> String {
            try XCTUnwrap((json(gyroflow(dir))["calibration_data"] as? [String: Any])?["name"] as? String)
        }
        XCTAssertTrue(try calName().contains("Helios"))

        let other = Lens(name: "Jupiter", focalMM: 85)
        c.lenses.append(other)
        c.setLens(other, forClip: key)
        XCTAssertEqual(c.lens(forClip: key), other)
        await c.idle()
        XCTAssertTrue(try calName().contains("Jupiter"))
        XCTAssertEqual(c.states[key], .synced(r2: 0.9, log: "t1_mix.bin", offsetMs: -10_000))
        let saved = try FileManager.default.contentsOfDirectory(atPath: backups.appendingPathComponent("Day1").path)
        XCTAssertEqual(saved.count, 1)

        // Position change on the clip regenerates too; the shoot keeps Top by default.
        XCTAssertEqual(c.position(forShoot: AppState.key(shootDir)), .top)
        let pos = try XCTUnwrap(MountingPosition.allCases.first { $0 != .top })
        c.setPosition(pos, forClip: key)
        await c.idle()
        XCTAssertEqual(c.position(forClip: key), pos)
        let src = try XCTUnwrap(json(gyroflow(dir))["gyro_source"] as? [String: Any])
        XCTAssertEqual(src["imu_orientation"] as? String, pos.imuOrientation)
    }

    func testDefaultPositionAndOwnSettings() async throws {
        let (clip, key, _) = try makeClip("A001", atSecond: 10)
        let c = coordinator()
        let shootKey = AppState.key(shootDir)
        XCTAssertEqual(GyroSyncCoordinator.key(of: shoot([clip])), shootKey)
        XCTAssertEqual(GyroSyncCoordinator.key(of: clip), key)
        XCTAssertEqual(c.defaultPosition, .top)
        c.defaultPosition = .left
        XCTAssertEqual(c.position(forShoot: shootKey), .left)
        XCTAssertEqual(c.position(forClip: key), .left)
        XCTAssertNil(c.ownPosition(forClip: key))
        c.setPosition(.back, forShoot: shootKey)
        XCTAssertEqual(c.position(forShoot: shootKey), .back)

        let lens = withLens(c)
        XCTAssertNil(c.ownLens(forClip: key))
        XCTAssertEqual(c.defaultLens(forShoot: shootKey), lens)  // lens(forClip:) needs the shoot mounted
        let other = Lens(name: "Jupiter", focalMM: 85)
        c.lenses.append(other)
        c.setLens(other, forClip: key)
        c.setPosition(.front, forClip: key)
        XCTAssertEqual(c.ownLens(forClip: key), other)
        XCTAssertEqual(c.ownPosition(forClip: key), .front)
        c.setLens(nil, forClip: key)
        c.setPosition(nil, forClip: key)
        XCTAssertNil(c.ownLens(forClip: key))
        XCTAssertNil(c.ownPosition(forClip: key))

        // Persisted.
        let again = coordinator()
        XCTAssertEqual(again.defaultPosition, .left)
    }

    func testProfileKindIsRecorded() async throws {
        let (a, ka, _) = try makeClip("A001", atSecond: 10)
        let (b, kb, _) = try makeClip("A002", atSecond: 20)
        try makeLog("t1", atSecond: 0)
        let good = tmp.appendingPathComponent("good.json"), bad = tmp.appendingPathComponent("bad.json")
        try JSONSerialization.data(withJSONObject: ["calib_dimension": ["w": 1600, "h": 900], "name": "cal"]).write(to: good)
        try JSONSerialization.data(withJSONObject: ["calib_dimension": ["w": 1920, "h": 800]]).write(to: bad)
        let c = coordinator()
        let calibrated = Lens(name: "Cal", focalMM: 12, calibratedProfiles: [good])
        let mismatched = Lens(name: "Mis", focalMM: 12, calibratedProfiles: [bad])
        c.lenses = [calibrated, mismatched]
        c.setDefaultLens(calibrated, forShoot: AppState.key(shootDir))
        c.setLens(mismatched, forClip: kb)
        XCTAssertNil(c.profileKind(forClip: ka))
        await c.shootMounted(shoot([a, b]), mountPoint: mountPoint, chosenFolder: chosen)
        XCTAssertEqual(c.profileKind(forClip: ka), .calibrated)
        XCTAssertEqual(c.profileKind(forClip: kb), .computed)
    }

    func testRemoveLensReevaluatesItsClips() async throws {
        let (clip, key, dir) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        let c = coordinator()
        let lens = withLens(c)
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
        guard case .synced? = c.states[key] else { return XCTFail("got \(String(describing: c.states[key]))") }

        c.removeLens(id: lens.id)
        XCTAssertTrue(c.lenses.isEmpty)
        XCTAssertNil(c.defaultLens(forShoot: AppState.key(shootDir)))
        await c.idle()
        XCTAssertEqual(c.states[key], .failed("Choose a lens for this shoot"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gyroflow(dir).path))  // never deleted
    }

    func testHasForeignGyroflow() async throws {
        let (clip, key, dir) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        let c = coordinator()
        XCTAssertFalse(c.hasForeignGyroflow(clip: key))
        try Data("{}".utf8).write(to: gyroflow(dir))
        XCTAssertTrue(c.hasForeignGyroflow(clip: key))
        try FileManager.default.removeItem(at: gyroflow(dir))
        _ = withLens(c)
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gyroflow(dir).path))
        XCTAssertFalse(c.hasForeignGyroflow(clip: key))  // mlv2dng's own file
    }

    func testMLVMotionRunnerMissingBinary() async throws {
        let run = GyroSyncCoordinator.mlvmotionRunner(binary: tmp.appendingPathComponent("no-mlvmotion"))
        do {
            _ = try await run(URL(fileURLWithPath: "/x.MLV"))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "The motion analyzer (mlvmotion) is missing from the app. Reinstall mlv2dng.")
        }
    }

    func testNoLensChosenNoFile() async throws {
        let (clip, key, dir) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        let gate = MotionGate()
        let c = coordinator(gate: gate)
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)

        XCTAssertEqual(c.states[key], .failed("Choose a lens for this shoot"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gyroflow(dir).path))
        let calls = await gate.calls
        XCTAssertEqual(calls, 0)
    }

    func testNoCoveringLogIsReported() async throws {
        let (clip, key, dir) = try makeClip("A001", atSecond: 10)
        let c = coordinator()
        _ = withLens(c)
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
        XCTAssertEqual(c.states[key], .noLog)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gyroflow(dir).path))
    }

    func testCancelOnUnmountLeavesNoFile() async throws {
        let (clip, key, dir) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        let gate = MotionGate(holding: true)
        let c = coordinator(gate: gate)
        _ = withLens(c)
        let s = shoot([clip])
        let job = Task { await c.shootMounted(s, mountPoint: mountPoint, chosenFolder: chosen) }
        for _ in 0..<500 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(10)) }
        let entered = await gate.entered
        XCTAssertTrue(entered)
        XCTAssertEqual(c.states[key], .running)

        c.shootUnmounted(s)
        await gate.release()
        await job.value
        await c.idle()

        XCTAssertNil(c.states[key])
        let left = try FileManager.default.contentsOfDirectory(atPath: shootDir.path)
        XCTAssertEqual(left, ["A001.MLV"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: gyroflow(dir).path))
        XCTAssertNil(defaults.stringArray(forKey: "gyroWritten"))
    }

    func testOverlappingLogsPickBest() async throws {
        let (clip, key, _) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        try makeLog("t2", atSecond: 5)
        try makeLog("t3", atSecond: 2)
        let c = coordinator(solver: { _, _, log, _ in
            switch log.url.lastPathComponent {
            case "t1_mix.bin": return SyncResult(lagMs: 10_000, r2: 0.5, secondPeak: 0.1, map: [])
            case "t2_mix.bin": return SyncResult(lagMs: 5_000, r2: 0.8, secondPeak: 0.1, map: [])
            default: throw SyncRefusal.ambiguous(r2: 0.6, second: 0.55)
            }
        })
        _ = withLens(c)
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
        XCTAssertEqual(c.states[key], .synced(r2: 0.8, log: "t2_mix.bin", offsetMs: -5_000))
    }

    func testRefusalsMapToStates() async throws {
        let (clip, key, _) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        try makeLog("t2", atSecond: 5)
        for (refusal, expected) in [(SyncRefusal.noOverlap, ClipGyroState.noLog),
                                    (.notEnoughMotion, .notEnoughMotion),
                                    (.ambiguous(r2: 0.5, second: 0.45), .ambiguous)] {
            let c = coordinator(solver: { _, _, _, _ in throw refusal })
            _ = withLens(c)
            await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
            XCTAssertEqual(c.states[key], expected, "\(refusal)")
            c.shootUnmounted(shoot([clip]))
        }
    }

    func testSkewReusedNarrowsSearch() async throws {
        let (a, _, _) = try makeClip("A001", atSecond: 10)
        let (b, keyB, _) = try makeClip("A002", atSecond: 40)
        try makeLog("t1", atSecond: 0, seconds: 120)
        // A1 clock 0.5 s ahead of the camera: lag = clip offset in the log + 0.5 s.
        let c = coordinator(solver: { _, _, _, range in
            let mid = (range.lowerBound + range.upperBound) / 2
            let lag = range.count > 60_001 ? 10_500 : mid  // B: 40 s + 0.5 s, its window centre
            return SyncResult(lagMs: lag, r2: 0.9, secondPeak: 0.1, map: [])
        })
        var widths: [Int] = []
        c.onSolve = { _, r in widths.append(r.upperBound - r.lowerBound) }
        _ = withLens(c)
        await c.shootMounted(shoot([a, b]), mountPoint: mountPoint, chosenFolder: chosen)

        XCTAssertEqual(widths.count, 2)
        XCTAssertGreaterThan(widths[0], 60_000)
        XCTAssertLessThanOrEqual(widths[1], 60_000)
        XCTAssertEqual(c.states[keyB], .synced(r2: 0.9, log: "t1_mix.bin", offsetMs: -40_500))
    }

    func testMotionCSVParsing() {
        let s = GyroSyncCoordinator.parseCSV("frame,dx,dy,peak\n1,2.500,-1.000,0.9000\n2,0.000,0.250,0.1000\n")
        XCTAssertEqual(s.map(\.frame), [1, 2])
        XCTAssertEqual(s[0].dx, 2.5); XCTAssertEqual(s[0].dy, -1); XCTAssertEqual(s[1].peak, 0.1)
    }

    func testMLVMotionRunnerReportsStderrOnFailure() async throws {
        let script = tmp.appendingPathComponent("fake-mlvmotion")
        try "#!/bin/sh\necho 'mlvmotion: bad clip' >&2\nexit 2\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let run = GyroSyncCoordinator.mlvmotionRunner(binary: script)
        do {
            _ = try await run(URL(fileURLWithPath: "/nonexistent.MLV"))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "mlvmotion: bad clip")
        }

        let ok = tmp.appendingPathComponent("ok-mlvmotion")
        try "#!/bin/sh\nprintf 'frame,dx,dy,peak\\n1,1.000,2.000,0.5000\\n'\n".write(to: ok, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ok.path)
        let samples = try await GyroSyncCoordinator.mlvmotionRunner(binary: ok)(URL(fileURLWithPath: "/x.MLV"))
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.dy, 2)
    }

    func testMLVMotionRunnerCancels() async throws {
        let script = tmp.appendingPathComponent("slow-mlvmotion")
        try "#!/bin/sh\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let run = GyroSyncCoordinator.mlvmotionRunner(binary: script)
        let t = Task { try await run(URL(fileURLWithPath: "/x.MLV")) }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        t.cancel()
        do { _ = try await t.value; XCTFail("expected cancellation") } catch {}
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    // MARK: Fix round 1

    private func calName(_ dir: String) throws -> String {
        try XCTUnwrap((json(gyroflow(dir))["calibration_data"] as? [String: Any])?["name"] as? String)
    }

    private func waitRunning(_ gate: MotionGate) async throws {
        for _ in 0..<500 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(10)) }
        let entered = await gate.entered
        XCTAssertTrue(entered)
    }

    func testSkewFallbackToFullSearch() async throws {
        let (clip, key, _) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0, seconds: 120)
        // Narrowed searches are refused; only the full one finds the clip.
        let c = coordinator(solver: { _, _, _, range in
            guard range.count > 60_001 else { throw SyncRefusal.noOverlap }
            return SyncResult(lagMs: 10_000, r2: 0.9, secondPeak: 0.1, map: [])
        })
        var widths: [Int] = []
        c.onSolve = { _, r in widths.append(r.upperBound - r.lowerBound) }
        c.skews[AppState.key(chosen)] = 50  // wrong: expects the clip at 60 s in the log
        _ = withLens(c)
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
        XCTAssertEqual(c.states[key], .synced(r2: 0.9, log: "t1_mix.bin", offsetMs: -10_000))
        XCTAssertEqual(widths.count, 2)
        XCTAssertLessThanOrEqual(widths[0], 60_000)
        XCTAssertGreaterThan(widths[1], 60_000)

        // A skew pointing outside every log falls back too.
        let (b, keyB, _) = try makeClip("A002", atSecond: 20)
        c.skews[AppState.key(chosen)] = 5_000
        await c.shootMounted(shoot([clip, b]), mountPoint: mountPoint, chosenFolder: chosen)
        XCTAssertEqual(c.states[keyB], .synced(r2: 0.9, log: "t1_mix.bin", offsetMs: -10_000))
    }

    func testOnlyCandidateLogsAreDecoded() async throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var names: [String] = []
            func add(_ u: URL) { lock.lock(); names.append(u.lastPathComponent); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
        }
        let rec = Recorder()
        let (clip, key, _) = try makeClip("A001", atSecond: 40)
        try makeLog("t1", atSecond: 0, seconds: 120)
        try makeLog("far", atSecond: 7_200, seconds: 30)
        let header = try A1Log.header(tmp.appendingPathComponent("rushes/A1/t1_mix.bin"))
        XCTAssertEqual(header.duration, 120, accuracy: 0.2)
        let c = coordinator(solver: { _, _, _, range in
            SyncResult(lagMs: (range.lowerBound + range.upperBound) / 2, r2: 0.9, secondPeak: 0.1, map: [])
        }, logReader: { rec.add($0); return try A1Log.read($0) })
        c.skews[AppState.key(chosen)] = 0.5
        _ = withLens(c)
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
        XCTAssertEqual(c.states[key], .synced(r2: 0.9, log: "t1_mix.bin", offsetMs: -40_500))
        XCTAssertEqual(rec.all, ["t1_mix.bin"])
        // Decoded logs are cached: regenerating does not decode again.
        await c.regenerate(clip: key)
        XCTAssertEqual(rec.all, ["t1_mix.bin"])
    }

    func testShootDefaultLensChangeRegeneratesDefaultUsersOnly() async throws {
        let (a, keyA, dirA) = try makeClip("A001", atSecond: 10)
        let (b, keyB, dirB) = try makeClip("A002", atSecond: 30)
        try makeLog("t1", atSecond: 0, seconds: 120)
        let c = coordinator()
        _ = withLens(c, "Helios")
        let own = Lens(name: "Zenitar", focalMM: 16)
        c.lenses.append(own)
        await c.shootMounted(shoot([a, b]), mountPoint: mountPoint, chosenFolder: chosen)
        c.setLens(own, forClip: keyB)
        await c.idle()
        XCTAssertTrue(try calName(dirA).contains("Helios"))
        XCTAssertTrue(try calName(dirB).contains("Zenitar"))

        let jupiter = Lens(name: "Jupiter", focalMM: 85)
        c.lenses.append(jupiter)
        c.setDefaultLens(jupiter, forShoot: AppState.key(shootDir))
        await c.idle()
        XCTAssertTrue(try calName(dirA).contains("Jupiter"))
        XCTAssertTrue(try calName(dirB).contains("Zenitar"))
        XCTAssertEqual(c.states[keyA], .synced(r2: 0.9, log: "t1_mix.bin", offsetMs: -10_000))
        let saved = try FileManager.default.contentsOfDirectory(atPath: backups.appendingPathComponent("Day1").path)
        XCTAssertEqual(saved.filter { $0.hasPrefix(dirA) }.count, 1)
        XCTAssertEqual(saved.filter { $0.hasPrefix(dirB) }.count, 1)  // from its own lens change only
    }

    func testCalibratedProfileSelection() async throws {
        let (clip, _, dir) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        func profile(_ name: String, w: Int, h: Int) throws -> URL {
            let u = tmp.appendingPathComponent("\(name).json")
            let obj: [String: Any] = ["name": name, "calib_dimension": ["w": w, "h": h], "input_horizontal_stretch": 1]
            try JSONSerialization.data(withJSONObject: obj).write(to: u)
            return u
        }
        let wrong = try profile("Wrong geometry", w: 1000, h: 1000)
        let right = try profile("Calibrated Helios", w: 3200, h: 1800)
        let c = coordinator()
        let lens = Lens(name: "Helios", focalMM: 25, calibratedProfiles: [wrong, right])
        c.lenses.append(lens)
        c.setDefaultLens(lens, forShoot: AppState.key(shootDir))
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
        XCTAssertEqual(try calName(dir), "Calibrated Helios")

        // No matching calibrated profile: computed one.
        let other = Lens(name: "Helios only wrong", focalMM: 25, calibratedProfiles: [wrong])
        c.lenses.append(other)
        c.setDefaultLens(other, forShoot: AppState.key(shootDir))
        await c.idle()
        XCTAssertTrue(try calName(dir).hasPrefix("mlv2dng Helios only wrong"))
    }

    func testFileSavedDuringSyncIsNotOverwritten() async throws {
        let (clip, key, dir) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        let gate = MotionGate(holding: true)
        let c = coordinator(gate: gate)
        _ = withLens(c)
        let job = Task { await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen) }
        try await waitRunning(gate)
        try Data("niyien".utf8).write(to: gyroflow(dir))
        await gate.release()
        await job.value
        XCTAssertEqual(c.states[key], .existing)
        XCTAssertEqual(try String(contentsOf: gyroflow(dir), encoding: .utf8), "niyien")
        XCTAssertNil(defaults.stringArray(forKey: "gyroWritten"))
    }

    func testLensChangeDuringSyncRedoesClip() async throws {
        let (clip, key, dir) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        let gate = MotionGate(holding: true)
        let c = coordinator(gate: gate)
        _ = withLens(c, "Helios")
        let job = Task { await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen) }
        try await waitRunning(gate)
        let jupiter = Lens(name: "Jupiter", focalMM: 85)
        c.lenses.append(jupiter)
        c.setDefaultLens(jupiter, forShoot: AppState.key(shootDir))
        await gate.release()
        await job.value
        await c.idle()
        XCTAssertTrue(try calName(dir).contains("Jupiter"))
        XCTAssertEqual(c.states[key], .synced(r2: 0.9, log: "t1_mix.bin", offsetMs: -10_000))
    }

    func testStaleWrittenEntryIsPruned() async throws {
        let (clip, key, dir) = try makeClip("A001", atSecond: 10)
        try makeLog("t1", atSecond: 0)
        let c = coordinator()
        _ = withLens(c)
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
        XCTAssertEqual(defaults.stringArray(forKey: "gyroWritten"), [key])
        c.shootUnmounted(shoot([clip]))
        try FileManager.default.removeItem(at: gyroflow(dir))
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)  // rewritten, ours again
        XCTAssertEqual(defaults.stringArray(forKey: "gyroWritten"), [key])

        // Ours removed, then a foreign file put there: it is not ours anymore.
        c.shootUnmounted(shoot([clip]))
        try FileManager.default.removeItem(at: gyroflow(dir))
        c.lenses = []  // no lens: nothing rewritten, but the entry is pruned
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
        XCTAssertEqual(defaults.stringArray(forKey: "gyroWritten"), [])
        try Data("niyien".utf8).write(to: gyroflow(dir))
        c.shootUnmounted(shoot([clip]))
        await c.shootMounted(shoot([clip]), mountPoint: mountPoint, chosenFolder: chosen)
        XCTAssertEqual(c.states[key], .existing)
    }

    func testClipDirNeedsEngineNamingPrefix() throws {
        let mlv = shootDir.appendingPathComponent("A001.MLV")
        try FileManager.default.createDirectory(at: mountPoint.appendingPathComponent("A001MLV_x"), withIntermediateDirectories: true)
        XCTAssertNil(GyroSyncCoordinator.clipDir(mountPoint: mountPoint, mlv: mlv))
        try FileManager.default.createDirectory(at: mountPoint.appendingPathComponent("A001MLV_1_2026-10-24_0001_C0000"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(GyroSyncCoordinator.clipDir(mountPoint: mountPoint, mlv: mlv)?.lastPathComponent,
                       "A001MLV_1_2026-10-24_0001_C0000")
    }
}
