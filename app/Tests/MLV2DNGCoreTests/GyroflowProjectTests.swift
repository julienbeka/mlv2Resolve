// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2DNGCore

final class GyroflowProjectTests: XCTestCase {
    let timing = ClipTiming(start: Date(timeIntervalSince1970: 0), frames: 529, fps: 25, width: 1600, height: 2008, squeeze: 3)
    let clipDir = URL(fileURLWithPath: "/x/mount dir/clip_1")
    let log = URL(fileURLWithPath: "/x/logs/full log.bin")

    func make(offset: Double = -4192, position: MountingPosition = .top, cal: [String: Any] = ["focal_length": 25]) throws -> [String: Any] {
        let d = GyroflowProject.make(clipDir: clipDir, timing: timing, log: log, offsetMs: offset, calibration: cal, position: position)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
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
        let url = try XCTUnwrap(Bundle.module.url(forResource: "niyien-template", withExtension: "gyroflow", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let p = try make()
        for k in fixture.keys { XCTAssertNotNil(p[k], k) }
        // the embedded runtime template must not drift from the fixture
        XCTAssertEqual(try Data(contentsOf: url),
                       try Data(contentsOf: XCTUnwrap(L10n.moduleBundle.url(forResource: "gyroflow-template", withExtension: "json"))))
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
        let raw = String(decoding: GyroflowProject.make(clipDir: clipDir, timing: timing, log: log, offsetMs: -4192, calibration: [:], position: .top), as: UTF8.self)
        XCTAssertTrue(raw.contains("\"output_width\" : 4800,"))
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
