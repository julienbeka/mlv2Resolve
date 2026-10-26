// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2ResolveCore

final class GyroflowProjectTests: XCTestCase {
    let timing = ClipTiming(start: Date(timeIntervalSince1970: 0), frames: 529, fps: 25, width: 1600, height: 2008, squeeze: 3)
    let clipDir = URL(fileURLWithPath: "/x/mount dir/clip_1")
    let log = URL(fileURLWithPath: "/x/logs/full log.bin")

    func make(offset: Double = -4192, position: MountingPosition = .top, cal: [String: Any] = ["focal_length": 25]) throws -> [String: Any] {
        let d = try GyroflowProject.make(clipDir: clipDir, timing: timing, log: log, offsetMs: offset, calibration: cal, position: position)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
    }


    // Regression: a correct lens profile must also reach the plugin's stabilization settings.
    func testSlimReadoutReachesBothProjectFields() throws {
        let modes: [(Int, Int, Int, Double, Double)] = [
            (2520, 1080, 1, 25, 24.165),
            (2880, 1226, 1, 25, 30.879875),
            (3072, 1308, 1, 23.976, 35.1525),
            (2560, 1440, 1, 25, 32.94),
            (1920, 1280, 1, 25, 22.64),
            (2160, 1620, 1, 23.943, 32.09625),
            (1504, 2538, 3, 22.25, 40.608),
            (1376, 2322, 3, 23.976, 37.152),
            (1280, 2160, 3, 25, 34.56),
            (1600, 2400, 3, 23.3, 38.4),
            (1472, 2208, 3, 25, 35.328),
            (1360, 2040, 3, 25, 32.64),
            (1664, 2268, 3, 23.976, 36.288),
            (1552, 2216, 3, 25, 35.456),
            (1424, 1942, 3, 25, 31.072),
            (1736, 2214, 3, 23.976, 35.9775),
            (1600, 2040, 3, 25, 32.64),
            (1472, 1878, 3, 25, 30.048),
            (1736, 2178, 3, 23.976, 35.3925),
            (1600, 2008, 3, 25, 32.128),
            (1472, 1846, 3, 25, 29.536),
            (1736, 976, 1, 46.8, 16.104),
            (1736, 868, 1, 50, 14.105),
            (1736, 790, 1, 54, 12.8375),
            (1736, 738, 1, 57, 11.9925),
            (1736, 1160, 1, 23.976, 19.14),
            (1736, 1160, 1, 25, 23.2),
            (1736, 1160, 1, 29.97, 19.14),
            (5208, 3478, 1, 3, 150.85825),
            (1552, 2118, 3, 25, 33.888), // Actual height wins over the inconsistent firmware label.
            (1736, 1152, 1, 25, 23.04),
            (1736, 1152, 1, 29.97, 19.008),
        ]
        for (w, h, squeeze, fps, expected) in modes {
            let t = ClipTiming(start: Date(), frames: 100, fps: fps, width: w, height: h, squeeze: squeeze)
            let c = try LensProfile.computed(focalMM: 25, timing: t)
            let data = try GyroflowProject.make(clipDir: clipDir, timing: t, log: log, offsetMs: -4192,
                                               calibration: c, position: .top)
            let p = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for section in ["calibration_data", "stabilization"] {
                let value = try XCTUnwrap((p[section] as? [String: Any])?["frame_readout_time"] as? Double)
                XCTAssertEqual(value, expected, accuracy: 0.000001, "\(w)x\(h) @\(fps): \(section)")
            }
        }
    }

    func testKnownSensorTimingReplacesGenericImportedLensTiming() throws {
        let p = try make(cal: ["frame_readout_time": 15.8, "focal_length": 25])
        for section in ["calibration_data", "stabilization"] {
            XCTAssertEqual((p[section] as? [String: Any])?["frame_readout_time"] as? Double, 32.128)
        }
        XCTAssertEqual((p["calibration_data"] as? [String: Any])?["focal_length"] as? Int, 25)
    }

    func testUnknownFormatPreservesImportedReadoutOrDisablesCorrection() throws {
        let t = ClipTiming(start: Date(), frames: 100, fps: 25, width: 1234, height: 567, squeeze: 1)
        let cases: [(Any, Double)] = [(22.7, 22.7), (-22.7, -22.7), (0.0, 0.0),
                                     (true, 0.0), (Double.nan, 0.0), ("bad", 0.0), (NSNull(), 0.0)]
        for (value, expected) in cases {
            let data = try GyroflowProject.make(clipDir: clipDir, timing: t, log: log, offsetMs: 0,
                                               calibration: ["frame_readout_time": value], position: .top)
            let p = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((p["stabilization"] as? [String: Any])?["frame_readout_time"] as? Double, expected)
        }
        let c = try LensProfile.computed(focalMM: 25, timing: t)
        XCTAssertEqual(c["frame_readout_time"] as? Double, 0)
    }

    func testUnrecognizedSamplingCadenceAndDesqueezedSizeDoNotGuessReadout() throws {
        let unsupported = [
            // Native 3x3 footage must not inherit the 1x1 1080p crop's timing.
            ClipTiming(start: Date(), frames: 10, fps: 25, width: 1920, height: 1080, squeeze: 1,
                       samplingX: 3, samplingY: 3),
            ClipTiming(start: Date(), frames: 10, fps: 25, width: 1600, height: 2008, squeeze: 3,
                       samplingX: 2, samplingY: 1),
            ClipTiming(start: Date(), frames: 10, fps: 60, width: 1600, height: 2008, squeeze: 3),
            ClipTiming(start: Date(), frames: 10, fps: 25, width: 4800, height: 2008, squeeze: 3),
            ClipTiming(start: Date(), frames: 10, fps: 60, width: 1736, height: 1160, squeeze: 1),
        ]
        for timing in unsupported {
            let c = try LensProfile.computed(focalMM: 25, timing: timing)
            XCTAssertEqual(c["frame_readout_time"] as? Double, 0)
        }
    }

    func testRealSlimShootReadouts() throws {
        guard let path = ProcessInfo.processInfo.environment["MLV2Resolve_SLIM_SHOOT"] else {
            throw XCTSkip("MLV2Resolve_SLIM_SHOOT not set")
        }
        let source = URL(fileURLWithPath: path)
        let clips = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.uppercased() == "MLV" }
        XCTAssertEqual(clips.count, 8)
        let fixes = SqueezeFix.corrections(for: clips.compactMap { clip in
            MLVHeader.sampling(of: clip).map { (name: clip.lastPathComponent, sampling: $0) }
        })
        for clip in clips {
            let header = try XCTUnwrap(MLVHeader.timing(of: clip))
            let t = fixes[clip.lastPathComponent].map {
                header.withSqueeze(SqueezeFix.horizontalSqueeze(x: $0.x, y: $0.y) ?? 1)
            } ?? header
            XCTAssertEqual(t.samplingX, 3)
            XCTAssertEqual(t.samplingY, 1)
            let expected = t.width == 1600 ? 32.128 : 35.3925
            let c = try LensProfile.computed(focalMM: 25, timing: t)
            let data = try GyroflowProject.make(clipDir: clipDir, timing: t, log: log, offsetMs: -4192,
                                               calibration: c, position: .top)
            let p = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for section in ["calibration_data", "stabilization"] {
                let value = try XCTUnwrap((p[section] as? [String: Any])?["frame_readout_time"] as? Double)
                XCTAssertEqual(value, expected, accuracy: 0.000001, clip.lastPathComponent)
            }
        }
    }

    func testOffsetsFormula() {
        let o = GyroflowProject.offsets(durationMs: 21159, offsetMs: -4192)
        XCTAssertEqual(Set(o.keys), ["7365850", "14771500", "22177150"])
        for v in o.values { XCTAssertEqual(v as? Double, -4192.0) }
    }

    func testVideofileEncoding() throws {
        let p = try make()
        XCTAssertEqual(p["videofile"] as? String, "file:////x/mount%20dir/clip_1/clip_1_%2506d.dng")
        XCTAssertEqual((p["gyro_source"] as? [String: Any])?["filepath"] as? String, "file:////x/logs/full%20log.bin")
        XCTAssertEqual((p["offsets"] as? [String: Any])?.count, 3)
    }

    func testAutosyncOff() throws {
        let p = try make(cal: ["focal_length": 25, "sync_settings": ["do_autosync": true]])
        let s = try XCTUnwrap(p["synchronization"] as? [String: Any])
        XCTAssertEqual(s["do_autosync"] as? Bool, false)
        XCTAssertEqual(s["auto_sync_points"] as? Bool, false)
        let c = try XCTUnwrap(p["calibration_data"] as? [String: Any])
        XCTAssertEqual(c["sync_settings"] as? [String: Bool], ["do_autosync": false])
        let p2 = try make()
        XCTAssertEqual((p2["calibration_data"] as? [String: Any])?["sync_settings"] as? [String: Bool], ["do_autosync": false])
    }

    func testKeepsTemplateKeys() throws {
        let expected = ["app_version", "background_color", "background_margin", "background_margin_feather", "background_mode",
                        "calibration_data", "date", "gyro_source", "image_sequence_fps", "image_sequence_start", "keyframes",
                        "light_refraction_coefficient", "muted", "offsets", "output", "playback_speed", "stabilization",
                        "synchronization", "title", "version", "video_info", "videofile"]
        XCTAssertEqual(Set(try GyroflowProject.template().keys), Set(expected))
        let p = try make()
        for k in expected { XCTAssertNotNil(p[k], k) }
    }

    func testInvalidTimingThrows() {
        for (fps, frames) in [(0.0, 10), (.nan, 10), (.infinity, 10), (-1.0, 10), (25.0, 0)] {
            let t = ClipTiming(start: Date(), frames: frames, fps: fps, width: 1600, height: 2008, squeeze: 3)
            XCTAssertThrowsError(try GyroflowProject.make(clipDir: clipDir, timing: t, log: log, offsetMs: 0, calibration: [:], position: .top)) {
                XCTAssertEqual($0 as? GyroflowProjectError, .invalidTiming)
            }
        }
    }

    func testPathEncodingRoundTrip() {
        let nfc = "caf\u{E9}", nfd = "cafe\u{301}"
        let path = "/x/a b/\(nfc)/\(nfd)/#1?q/50%/f.bin"
        let url = GyroflowProject.fileURL(path)
        XCTAssertTrue(url.hasPrefix("file:////x/"))
        for c in ["#", "?", " "] { XCTAssertFalse(url.contains(c), c) }
        XCTAssertEqual(String(url.dropFirst("file:///".count)).removingPercentEncoding, path)
        XCTAssertTrue(url.contains("%25"))
    }

    func testFieldsAndIntegers() throws {
        let p = try make()
        let o = try XCTUnwrap(p["output"] as? [String: Any])
        XCTAssertEqual(o["output_width"] as? Int, 4800)
        XCTAssertEqual(o["output_height"] as? Int, 2008)
        XCTAssertEqual(o["output_filename"] as? String, "clip_1_000000_stabilized.gyroflow")
        XCTAssertEqual(o["output_folder"] as? String, "file:////x/mount%20dir/clip_1")
        let v = try XCTUnwrap(p["video_info"] as? [String: Any])
        XCTAssertEqual(v["duration_ms"] as? Int, 21160)
        XCTAssertEqual(v["width"] as? Int, 1600)
        let raw = String(decoding: try GyroflowProject.make(clipDir: clipDir, timing: timing, log: log, offsetMs: -4192, calibration: [:], position: .top), as: UTF8.self)
        // key order is not stable: integer check without relying on what follows
        XCTAssertNotNil(raw.range(of: #""output_width" : 4800\s*[,\n}]"#, options: .regularExpression))
        XCTAssertEqual(GyroflowProject.fileName(clipDir: "clip_1"), "clip_1_000000.gyroflow")
    }

    func testMountingPositionsDistinct() {
        XCTAssertEqual(MountingPosition.top.imuOrientation, "XYZ")
        XCTAssertEqual(MountingPosition.top.rotation, [0, 0, 0])
        XCTAssertEqual(Set(MountingPosition.allCases.map(\.imuOrientation)).count, MountingPosition.allCases.count)
    }

    func testAtomicWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.gyroflow")
        try GyroflowProject.write(Data("one".utf8), to: f)
        try GyroflowProject.write(Data("two".utf8), to: f)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "two")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.gyroflow"])
        XCTAssertThrowsError(try GyroflowProject.write(Data("x".utf8), to: dir.appendingPathComponent("nope/b.gyroflow")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.gyroflow"])
    }
}
