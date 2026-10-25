// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2DNGCore

final class GyroSyncTests: XCTestCase {
    struct RNG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func gauss(_ r: inout RNG) -> Double {
        let u1 = Double.random(in: 1e-12..<1, using: &r), u2 = Double.random(in: 0..<1, using: &r)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    /// Smooth random angular velocity (rad/s), 1 kHz.
    private func makeGyro(seconds: Int, seed: UInt64) -> [SIMD3<Float>] {
        var r = RNG(s: seed)
        var w = SIMD3<Double>.zero
        var out: [SIMD3<Float>] = []
        for _ in 0..<(seconds * 1000) {
            let n = SIMD3(gauss(&r), gauss(&r), gauss(&r))
            w = w * 0.995 + n * 0.02
            out.append(SIMD3<Float>(w))
        }
        return out
    }

    private let map: [[Double]] = [[900, 50], [-30, 1100], [200, -150]]

    /// Motion for a 25 fps clip whose first frame sits at `lagMs` in the log.
    private func makeMotion(gyro: [SIMD3<Float>], lagMs: Int, seconds: Int, noise: Double,
                            seed: UInt64) -> [MotionSample] {
        var cum = [SIMD3<Double>](repeating: .zero, count: gyro.count + 1)
        for i in 0..<gyro.count { cum[i + 1] = cum[i] + SIMD3<Double>(gyro[i]) / 1000 }
        var r = RNG(s: seed)
        var out: [MotionSample] = []
        for f in 1...(seconds * 25) {
            let a = lagMs + (f - 1) * 40, b = lagMs + f * 40
            var g = SIMD3<Double>.zero
            if a >= 0 && b <= gyro.count { g = cum[b] - cum[a] }
            let dx = g.x * map[0][0] + g.y * map[1][0] + g.z * map[2][0] + noise * gauss(&r)
            let dy = g.x * map[0][1] + g.y * map[1][1] + g.z * map[2][1] + noise * gauss(&r)
            out.append(MotionSample(frame: f, dx: dx, dy: dy, peak: 1 + Double.random(in: 0..<1, using: &r)))
        }
        return out
    }

    func testRecoversSyntheticLag() throws {
        let gyro = makeGyro(seconds: 40, seed: 1)
        let motion = makeMotion(gyro: gyro, lagMs: 4192, seconds: 12, noise: 0.5, seed: 2)
        let res = try GyroSync.solve(motion: motion, fps: 25, gyro: gyro, rateHz: 1000, searchMs: 0...25000)
        XCTAssertEqual(res.lagMs, 4192, accuracy: 1)
        XCTAssertGreaterThan(res.r2, 0.9)
        XCTAssertEqual(res.map[0][0], 900, accuracy: 60)
        XCTAssertEqual(res.map[1][1], 1100, accuracy: 60)
    }

    func testNoMotionRefused() {
        let gyro = makeGyro(seconds: 20, seed: 3)
        let motion = (1...200).map { MotionSample(frame: $0, dx: 3, dy: -2, peak: 1) }
        XCTAssertThrowsError(try GyroSync.solve(motion: motion, fps: 25, gyro: gyro, rateHz: 1000,
                                                searchMs: 0...10000)) {
            XCTAssertEqual($0 as? SyncRefusal, .notEnoughMotion)
        }
    }

    func testNoiseIsAmbiguous() {
        let gyro = makeGyro(seconds: 30, seed: 4)
        var r = RNG(s: 5)
        let motion = (1...300).map {
            MotionSample(frame: $0, dx: 3 * gauss(&r), dy: 3 * gauss(&r), peak: 1 + Double.random(in: 0..<1, using: &r))
        }
        XCTAssertThrowsError(try GyroSync.solve(motion: motion, fps: 25, gyro: gyro, rateHz: 1000,
                                                searchMs: 0...18000)) {
            guard case .ambiguous? = $0 as? SyncRefusal else { return XCTFail("got \($0)") }
        }
    }

    func testPartialOverlap() throws {
        // Log is 9 s long and covers the last 9 s of a 12 s clip (first frame 3 s before the log).
        let gyro = makeGyro(seconds: 9, seed: 6)
        let motion = makeMotion(gyro: gyro, lagMs: -3000, seconds: 12, noise: 0.5, seed: 7)
        let res = try GyroSync.solve(motion: motion, fps: 25, gyro: gyro, rateHz: 1000, searchMs: -6000...3000)
        XCTAssertEqual(res.lagMs, -3000, accuracy: 2)

        // Only 5 s of log for a 12 s clip: refused.
        let short = makeGyro(seconds: 5, seed: 8)
        let motion2 = makeMotion(gyro: short, lagMs: -7000, seconds: 12, noise: 0.5, seed: 9)
        XCTAssertThrowsError(try GyroSync.solve(motion: motion2, fps: 25, gyro: short, rateHz: 1000,
                                                searchMs: -9000...3000)) {
            XCTAssertEqual($0 as? SyncRefusal, .noOverlap)
        }
    }

    func testShortClipMostlyCoveredAndLongClipBarelyCovered() throws {
        // 6 s clip, 5 s covered (83 %): accepted.
        let gyro = makeGyro(seconds: 5, seed: 10)
        let motion = makeMotion(gyro: gyro, lagMs: -1000, seconds: 6, noise: 0.5, seed: 11)
        let res = try GyroSync.solve(motion: motion, fps: 25, gyro: gyro, rateHz: 1000, searchMs: -2000...0)
        XCTAssertEqual(res.lagMs, -1000, accuracy: 2)

        // 30 s clip, 7 s covered (< 8 s and < 80 %): no log covers it.
        let short = makeGyro(seconds: 7, seed: 12)
        let motion2 = makeMotion(gyro: short, lagMs: -23000, seconds: 30, noise: 0.5, seed: 13)
        XCTAssertThrowsError(try GyroSync.solve(motion: motion2, fps: 25, gyro: short, rateHz: 1000,
                                                searchMs: -25000...0)) {
            XCTAssertEqual($0 as? SyncRefusal, .noOverlap)
        }
    }

    func testNoiseNeverAccepted() {
        // Pure-noise motion vs random-walk gyro: short and normal clips, narrow and wide searches.
        var accepted = 0
        for seed in UInt64(0)..<48 {
            let gyro = makeGyro(seconds: 12, seed: 100 + seed)
            var r = RNG(s: 500 + seed)
            let seconds = seed % 2 == 0 ? 4 : 10
            let motion = (1...(seconds * 25)).map {
                MotionSample(frame: $0, dx: 3 * gauss(&r), dy: 3 * gauss(&r), peak: 1 + Double.random(in: 0..<1, using: &r))
            }
            let range = seed % 4 < 2 ? 0...800 : 0...2000
            if (try? GyroSync.solve(motion: motion, fps: 25, gyro: gyro, rateHz: 1000, searchMs: range)) != nil {
                accepted += 1
            }
        }
        XCTAssertEqual(accepted, 0)
    }

    func testTooLittleCoverageFloor() {
        // 2.5 s clip fully covered: below the 3 s floor.
        let gyro = makeGyro(seconds: 10, seed: 20)
        let motion = makeMotion(gyro: gyro, lagMs: 2000, seconds: 2, noise: 0.5, seed: 21)
        let short = Array(motion.prefix(62))
        XCTAssertThrowsError(try GyroSync.solve(motion: short, fps: 25, gyro: gyro, rateHz: 1000,
                                                searchMs: 0...6000)) {
            XCTAssertEqual($0 as? SyncRefusal, .noOverlap)
        }
    }

    func testStaticGyroRefused() {
        let gyro = [SIMD3<Float>](repeating: .zero, count: 20000)
        let motion = makeMotion(gyro: makeGyro(seconds: 20, seed: 30), lagMs: 1000, seconds: 8, noise: 0.5, seed: 31)
        XCTAssertThrowsError(try GyroSync.solve(motion: motion, fps: 25, gyro: gyro, rateHz: 1000,
                                                searchMs: 0...8000)) {
            XCTAssertEqual($0 as? SyncRefusal, .notEnoughMotion)
        }
    }

    func testNonFiniteInputs() throws {
        let gyro = makeGyro(seconds: 40, seed: 1)
        let motion = makeMotion(gyro: gyro, lagMs: 4192, seconds: 12, noise: 0.5, seed: 2)
        // NaN motion rows are dropped; NaN gyro samples count as no rotation: still solvable.
        var bad = motion
        bad[10] = MotionSample(frame: 11, dx: .nan, dy: 1, peak: 1)
        var badGyro = gyro
        badGyro[100] = SIMD3<Float>(.nan, 0, 0)
        let res = try GyroSync.solve(motion: bad, fps: 25, gyro: badGyro, rateHz: 1000, searchMs: 0...25000)
        XCTAssertEqual(res.lagMs, 4192, accuracy: 2)
        for (fps, rate) in [(Double.nan, 1000.0), (25, .infinity), (0, 1000), (25, -1)] {
            XCTAssertThrowsError(try GyroSync.solve(motion: motion, fps: fps, gyro: gyro, rateHz: rate,
                                                    searchMs: 0...25000)) {
                XCTAssertEqual($0 as? SyncRefusal, .noOverlap)
            }
        }
    }

    func testRealM24_1845() throws {
        guard let dir = ProcessInfo.processInfo.environment["MLV2DNG_GYRO_DIR"] else {
            throw XCTSkip("MLV2DNG_GYRO_DIR not set")
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tool = repo.appendingPathComponent("build/engine/mlvmotion")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw XCTSkip("mlvmotion not built") }
        let base = URL(fileURLWithPath: dir)
        let p = Process()
        p.executableURL = tool
        p.arguments = [base.appendingPathComponent("M24-1845.MLV").path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let motion: [MotionSample] = String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst().compactMap {
            let c = $0.split(separator: ",").compactMap { Double($0) }
            return c.count == 4 ? MotionSample(frame: Int(c[0]), dx: c[1], dy: c[2], peak: c[3]) : nil
        }
        let log = try A1Log.read(base.appendingPathComponent("2026-10-24_18-44-36_mix.bin"))
        let t0 = Date()
        let res = try GyroSync.solve(motion: motion, fps: 25, gyro: log.gyro, rateHz: log.rateHz, searchMs: 0...25000)
        let dt = Date().timeIntervalSince(t0)
        print("REAL lag=\(res.lagMs) r2=\(res.r2) second=\(res.secondPeak) solve=\(dt)s frames=\(motion.count)")
        XCTAssertEqual(res.lagMs, 4192, accuracy: 10)
        XCTAssertEqual(res.r2, 0.78, accuracy: 0.05)
        XCTAssertLessThan(dt, 3)  // debug build; release is ~10x faster
    }
}
