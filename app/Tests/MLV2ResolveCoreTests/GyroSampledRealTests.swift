// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2ResolveCore

final class GyroSampledRealTests: XCTestCase {
    /// Opt-in, read-only comparison against the complete analysis and existing projects.
    /// Set MLV2Resolve_GYRO_BENCH_DIR and comma-separated MLV2Resolve_GYRO_BENCH_CLIPS.
    func testAcceptedSampledOffsetsMatchFullAnalysisOnRealClips() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["MLV2Resolve_GYRO_BENCH_DIR"],
              let names = env["MLV2Resolve_GYRO_BENCH_CLIPS"] else {
            throw XCTSkip("Real gyro benchmark not configured")
        }
        let base = URL(fileURLWithPath: dir)
        let files = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        for name in names.split(separator: ",").map(String.init) {
            let project = try XCTUnwrap(files.first {
                $0.lastPathComponent.hasPrefix(name + "MLV_") && $0.pathExtension == "gyroflow"
            })
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any])
            let source = try XCTUnwrap(json["gyro_source"] as? [String: Any])
            let sourceURL = try XCTUnwrap(URL(string: try XCTUnwrap(source["filepath"] as? String)))
            let log = try A1Log.read(base.appendingPathComponent(".mlv2resolve-gyro")
                .appendingPathComponent(sourceURL.lastPathComponent))
            let timing = try XCTUnwrap(MLVHeader.timing(of: base.appendingPathComponent(name + ".MLV")))
            // Warm the footage cache before timing either path; cold-vs-warm I/O
            // would exaggerate the gain of whichever analysis runs second.
            _ = try RealGyroFixture.motion(base: base, clip: name + ".MLV")
            let start = Date()
            let full = try RealGyroFixture.motion(base: base, clip: name + ".MLV")
            let fullMotionSeconds = Date().timeIntervalSince(start)
            let fastStart = Date()
            let sampled = try RealGyroFixture.motion(base: base, clip: name + ".MLV", sampled: true)
            let sampledMotionSeconds = Date().timeIntervalSince(fastStart)
            let fullByFrame = Dictionary(uniqueKeysWithValues: full.map { ($0.frame, $0) })
            XCTAssertLessThanOrEqual(sampled.count, max(194, 3 * Int(ceil(timing.fps * 2)) + 2))
            for row in sampled {
                let original = try XCTUnwrap(fullByFrame[row.frame])
                XCTAssertEqual(row.dx, original.dx)
                XCTAssertEqual(row.dy, original.dy)
                XCTAssertEqual(row.peak, original.peak)
            }
            let range = 0...Int(Double(log.gyro.count) / log.rateHz * 1000)
            let fullStart = Date()
            let reference = try GyroSync.solve(motion: full, fps: timing.fps, gyro: log.gyro,
                                               rateHz: log.rateHz, searchMs: range)
            let fullSolveSeconds = Date().timeIntervalSince(fullStart)
            let sampledStart = Date()
            let result: SyncResult
            var fallback = false
            do {
                result = try GyroSync.solve(motion: sampled, fps: timing.fps, gyro: log.gyro,
                                           rateHz: log.rateHz, searchMs: range)
            } catch is SyncRefusal {
                // A refusal is the intended trigger for the complete analysis, not
                // permission to lower confidence thresholds. Coordinator tests cover
                // this fallback and ensure that no sampled result is written.
                fallback = true
                result = reference
            }
            let sampledSolveSeconds = Date().timeIntervalSince(sampledStart)
            XCTAssertEqual(result.lagMs, reference.lagMs, accuracy: 10, name)
            print("GYRO_BENCH \(name) rows=\(full.count)->\(sampled.count) " +
                  "motion=\(fullMotionSeconds)->\(sampledMotionSeconds)s " +
                  "solve=\(fullSolveSeconds)->\(sampledSolveSeconds)s " +
                  "lag=\(reference.lagMs)->\(result.lagMs) R2=\(reference.r2)->\(result.r2) fallback=\(fallback)")
        }
    }
}
