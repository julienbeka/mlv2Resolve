// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2ResolveCore

final class LogMatcherTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LogMatcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 18, minute: 0, second: 0))!

    /// Log starting `offset` s after 18:00:00 with `seconds` of samples.
    private func log(_ name: String, offset: Int, seconds: Int) throws -> A1Log {
        var h = Data(count: 0x200)
        h.replaceSubrange(0..<9, with: Array("SenseFlow".utf8))
        let s = offset
        h.replaceSubrange(0x40..<0x46, with: [26, 10, 24, 18, UInt8(s / 60), UInt8(s % 60)])
        var body = Data()
        var r = Data([0xAA, 0x55, 0x03]); r.append(Data(count: 13))
        for _ in 0..<(seconds * 1000) { body.append(r) }
        let u = root.appendingPathComponent(name)
        try (h + body).write(to: u)
        return try A1Log.read(u)
    }

    private func clip(offset: TimeInterval, frames: Int = 250) -> ClipTiming {
        ClipTiming(start: t0.addingTimeInterval(offset), frames: frames, fps: 25, width: 1600, height: 2008, squeeze: 3)
    }

    func testCandidatesWithSkew() throws {
        let a = try log("a_mix.bin", offset: 0, seconds: 60)        // 18:00:00-18:01:00
        let b = try log("b_mix.bin", offset: 300, seconds: 60)      // far away
        let c = try log("c_mix.bin", offset: 20, seconds: 60)       // 18:00:20-18:01:20
        // clip at 18:00:30 camera, skew +2 -> A1 time 18:00:32, 10 s long
        let r = LogMatcher.candidates(for: clip(offset: 30), logs: [b, a, c], skew: 2)
        XCTAssertEqual(r.map { $0.log.url.lastPathComponent }, ["a_mix.bin", "c_mix.bin"])  // both inside; a: 32 s (centre 30), c: 12 s
        XCTAssertEqual(r[0].searchMs, (32000 - 30000)...(32000 + 30000))
        XCTAssertEqual(r[1].searchMs, (12000 - 30000)...(12000 + 30000))
    }

    func testCandidatesWithSkewWindowEdges() throws {
        let a = try log("a_mix.bin", offset: 0, seconds: 10)
        // clip starts 40 s after log end -> expected 40 s, window lo = 10 s -> touches end
        XCTAssertEqual(LogMatcher.candidates(for: clip(offset: 40), logs: [a], skew: 0).count, 1)
        XCTAssertEqual(LogMatcher.candidates(for: clip(offset: 41), logs: [a], skew: 0).count, 0)
    }

    func testClipBeforeLogStartEdgeAndOrdering() throws {
        let a = try log("a_mix.bin", offset: 100, seconds: 60)
        // clip 10 s long ending 31 s before the log start: hi = -31+10+30 < 0 -> excluded
        XCTAssertEqual(LogMatcher.candidates(for: clip(offset: 59), logs: [a], skew: 0).count, 0)
        // clip ends 29 s before log start -> included
        let r = LogMatcher.candidates(for: clip(offset: 61), logs: [a], skew: 0)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].searchMs, (-39000 - 30000)...(-39000 + 30000))
        // inside a log (dist 0) outranks one the clip is before
        let b = try log("b_mix.bin", offset: 0, seconds: 200)
        let r2 = LogMatcher.candidates(for: clip(offset: 61), logs: [a, b], skew: 0)
        XCTAssertEqual(r2.map { $0.log.url.lastPathComponent }, ["b_mix.bin", "a_mix.bin"])
    }

    func testHugeClockSkewStillMatchesOrRefuses() throws {
        let a = try log("a_mix.bin", offset: 0, seconds: 60)
        let b = try log("b_mix.bin", offset: 120, seconds: 30)
        let far = clip(offset: 55 * 86400)
        let r = LogMatcher.candidates(for: far, logs: [a, b], skew: nil)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].log.url.lastPathComponent, "b_mix.bin")   // closest start first
        XCTAssertEqual(r[0].searchMs, -10000...30000)
        XCTAssertEqual(r[1].searchMs, -10000...60000)
    }

    func testEstimateSkewMedian() throws {
        let a = try log("a_mix.bin", offset: 0, seconds: 60)
        // skew = log.start + lag - clip.start
        func entry(skew: Double) -> (clip: ClipTiming, log: A1Log, lagMs: Int) {
            let c = clip(offset: 30)
            return (c, a, Int(((c.start.timeIntervalSince(a.start)) + skew) * 1000))
        }
        let s = LogMatcher.estimateSkew([entry(skew: 1), entry(skew: 3), entry(skew: 100)])
        XCTAssertEqual(s!, 3, accuracy: 1e-6)
        XCTAssertNil(LogMatcher.estimateSkew([]))
    }
}
