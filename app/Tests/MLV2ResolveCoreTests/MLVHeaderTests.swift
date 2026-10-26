// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2ResolveCore

/// Builds header-only MLV bytes (MLVI + RAWC [+ VIDF]).
enum SyntheticMLV {
    static func block(_ type: String, payload: [UInt8]) -> Data {
        var d = Data(type.utf8)
        var size = UInt32(16 + payload.count).littleEndian
        withUnsafeBytes(of: &size) { d.append(contentsOf: $0) }
        d.append(contentsOf: [UInt8](repeating: 0, count: 8))
        d.append(contentsOf: payload)
        return d
    }
    /// `size`: adds a RAWI block (xRes, yRes) before RAWC.
    static func data(sampling: (UInt8, UInt8, UInt8, UInt8)?, withRAWC: Bool = true, size: (Int, Int)? = nil) -> Data {
        var d = block("MLVI", payload: [UInt8](repeating: 0, count: 36))
        if let (w, h) = size {
            d.append(block("RAWI", payload: [UInt8(w & 0xFF), UInt8(w >> 8), UInt8(h & 0xFF), UInt8(h >> 8)]
                           + [UInt8](repeating: 0, count: 44)))
        }
        if withRAWC, let s = sampling {
            d.append(block("RAWC", payload: [UInt8](repeating: 0, count: 8) + [s.0, s.1, s.2, s.3] + [0, 0, 0, 0]))
        }
        d.append(block("VIDF", payload: [UInt8](repeating: 0, count: 8)))
        return d
    }
    static func write(_ d: Data, to url: URL) throws { try d.write(to: url) }
}

final class MLVHeaderTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("MLVHeader-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func squeeze(_ d: Data) throws -> Int? {
        let u = tmp.appendingPathComponent("a.MLV")
        try d.write(to: u)
        return MLVHeader.horizontalSqueeze(of: u)
    }

    func testHorizontalSqueeze3() throws {
        XCTAssertEqual(try squeeze(SyntheticMLV.data(sampling: (1, 2, 1, 0))), 3)   // 3x1
    }
    func testNoSqueeze() throws {
        XCTAssertNil(try squeeze(SyntheticMLV.data(sampling: (1, 0, 1, 0))))        // 1x1
        XCTAssertNil(try squeeze(SyntheticMLV.data(sampling: (1, 2, 1, 4))))        // 3x5: vertical
        XCTAssertNil(try squeeze(SyntheticMLV.data(sampling: (0, 0, 0, 0))))
    }
    func testNoRAWCBeforeVIDF() throws {
        XCTAssertNil(try squeeze(SyntheticMLV.data(sampling: nil)))
        XCTAssertNil(MLVHeader.horizontalSqueeze(of: tmp.appendingPathComponent("missing.MLV")))
    }
    func testTruncatedFile() throws {
        XCTAssertNil(try squeeze(Data([0x4D, 0x4C, 0x56])))
    }

    func testBlockSizeBelowMinimum() throws {
        var d = Data("MLVI".utf8)
        d.append(contentsOf: [8, 0, 0, 0] + [UInt8](repeating: 0, count: 8))
        XCTAssertNil(try squeeze(d))
    }

    func testRealClipIfPresent() throws {
        var dir = URL(fileURLWithPath: #filePath)
        var found: URL?
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let c = dir.appendingPathComponent("M29-0615.MLV")
            if FileManager.default.fileExists(atPath: c.path) { found = c; break }
        }
        guard let url = found else { throw XCTSkip("M29-0615.MLV absent") }
        XCTAssertEqual(MLVHeader.horizontalSqueeze(of: url), 3)
    }

    // MARK: timing

    private func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
    private func hdr(_ type: String, size: Int, ts: UInt64) -> Data {
        Data(type.utf8) + Data(le(UInt64(size), 4)) + Data(le(ts, 8))
    }
    private func timingClip(chunkFrames: Int) throws -> URL {
        var mlvi = hdr("MLVI", size: 52, ts: 0)   // ts bytes are version string here; harmless
        mlvi.replaceSubrange(8..<16, with: Data(count: 8))
        mlvi += Data(count: 36); mlvi.replaceSubrange(44..<48, with: le(25000, 4)); mlvi.replaceSubrange(48..<52, with: le(1000, 4))
        var rawi = hdr("RAWI", size: 64, ts: 0); rawi += Data(le(1600, 2) + le(2008, 2)) + Data(count: 44)
        var rtci = hdr("RTCI", size: 44, ts: 1_000_000)
        rtci += Data(le(32, 2) + le(44, 2) + le(18, 2) + le(24, 2) + le(9, 2) + le(126, 2)) + Data(count: 16)
        var d = mlvi + rawi + rtci
        d += hdr("VIDF", size: 32, ts: 1_216_000) + Data(count: 16)
        d += hdr("VIDF", size: 32, ts: 1_256_000) + Data(count: 16)
        let u = tmp.appendingPathComponent("T.MLV")
        try d.write(to: u)
        if chunkFrames > 0 {
            var c = Data()
            for _ in 0..<chunkFrames { c += hdr("VIDF", size: 32, ts: 2_000_000) + Data(count: 16) }
            try c.write(to: tmp.appendingPathComponent("T.M00"))
        }
        return u
    }

    func testTimingSynthetic() throws {
        let t = try XCTUnwrap(MLVHeader.timing(of: try timingClip(chunkFrames: 3)))
        XCTAssertEqual(t.frames, 5)
        XCTAssertEqual(t.fps, 25)
        XCTAssertEqual(t.width, 1600); XCTAssertEqual(t.height, 2008)
        XCTAssertEqual(t.squeeze, 1)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: t.start)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 10, 24, 18, 44, 32])
        XCTAssertEqual(Double(c.nanosecond ?? 0) / 1e9, 0.216, accuracy: 0.001)
    }

    func testSensorSamplingSurvivesTimingAndSqueezeCorrection() throws {
        let url = try timingClip(chunkFrames: 0)
        var bytes = try Data(contentsOf: url)
        let rawc = hdr("RAWC", size: 32, ts: 0) + Data(count: 8) + Data([1, 0, 1, 0]) + Data(count: 4)
        bytes.insert(contentsOf: rawc, at: 52) // Before RAWI/RTCI and the first video frame.
        try bytes.write(to: url)
        let original = try XCTUnwrap(MLVHeader.timing(of: url))
        XCTAssertEqual(original.samplingX, 1)
        let timing = original.withSqueeze(3)
        XCTAssertEqual(timing.samplingX, 3)
        XCTAssertEqual(timing.samplingY, 1)
        let profile = try LensProfile.computed(focalMM: 25, timing: timing)
        XCTAssertEqual(profile["frame_readout_time"] as? Double, 32.128)
    }

    func testTimingTruncatedAndInvalid() throws {
        let full = try Data(contentsOf: try timingClip(chunkFrames: 0))
        let u = tmp.appendingPathComponent("cut.MLV")
        // cut mid second VIDF payload: only the first frame counts
        try full.prefix(full.count - 20).write(to: u)
        XCTAssertEqual(MLVHeader.timing(of: u)?.frames, 1)
        // cut every possible length: never crashes
        for n in stride(from: 0, to: full.count, by: 7) {
            try full.prefix(n).write(to: u)
            _ = MLVHeader.timing(of: u)
        }
        // all-zero RTCI date (year 1900) is rejected
        var bad = full
        let r = bad.range(of: Data("RTCI".utf8))!.lowerBound
        bad.replaceSubrange((r + 16)..<(r + 28), with: Data(count: 12))
        try bad.write(to: u)
        XCTAssertNil(MLVHeader.timing(of: u))
    }

    func testTimingNilWithoutRTCI() throws {
        let d = SyntheticMLV.data(sampling: (1, 2, 1, 0))
        let u = tmp.appendingPathComponent("n.MLV"); try d.write(to: u)
        XCTAssertNil(MLVHeader.timing(of: u))
        XCTAssertNil(MLVHeader.timing(of: tmp.appendingPathComponent("missing.MLV")))
    }

    func testTimingM24_1845() throws {
        guard let dir = ProcessInfo.processInfo.environment["MLV2Resolve_GYRO_DIR"] else {
            throw XCTSkip("MLV2Resolve_GYRO_DIR not set")
        }
        let t = try XCTUnwrap(MLVHeader.timing(of: URL(fileURLWithPath: dir).appendingPathComponent("M24-1845.MLV")))
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: t.start)
        XCTAssertEqual([c.hour, c.minute, c.second], [18, 44, 32])
        XCTAssertEqual(Double(c.nanosecond ?? 0) / 1e9, 0.216, accuracy: 0.002)
        XCTAssertEqual(t.frames, 529)
        XCTAssertEqual(t.fps, 25)
        XCTAssertEqual(t.width, 1600); XCTAssertEqual(t.height, 2008)
        XCTAssertEqual(t.squeeze, 3)
    }
}
