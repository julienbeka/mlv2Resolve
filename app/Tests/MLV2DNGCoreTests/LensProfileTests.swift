// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2DNGCore

final class LensProfileTests: XCTestCase {
    private let timing = ClipTiming(start: Date(timeIntervalSince1970: 0), frames: 100, fps: 25,
                                    width: 1600, height: 2008, squeeze: 3)

    private func writeJSON(_ obj: Any) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lens-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testComputed25mm1x3() throws {
        let p = LensProfile.computed(focalMM: 25, lensName: "25mm", timing: timing)
        let dim = try XCTUnwrap(p["calib_dimension"] as? [String: Any])
        XCTAssertEqual(dim["w"] as? Int, 4800)
        XCTAssertEqual(dim["h"] as? Int, 2008)
        XCTAssertEqual((p["output_dimension"] as? [String: Any])?["w"] as? Int, 4800)
        XCTAssertEqual((p["orig_dimension"] as? [String: Any])?["h"] as? Int, 2008)
        XCTAssertEqual(p["input_horizontal_stretch"] as? Int, 3)
        XCTAssertEqual(p["input_vertical_stretch"] as? Int, 1)
        let fish = try XCTUnwrap(p["fisheye_params"] as? [String: Any])
        let m = try XCTUnwrap(fish["camera_matrix"] as? [[Double]])
        XCTAssertEqual(m[0][0], 5811.7, accuracy: 0.5)
        XCTAssertEqual(m[1][1], m[0][0])
        XCTAssertEqual(m[0][2], 2400)
        XCTAssertEqual(m[1][2], 1004)
        XCTAssertEqual(fish["distortion_coeffs"] as? [Double], [0, 0, 0, 0])
        XCTAssertEqual((p["sync_settings"] as? [String: Any])?["do_autosync"] as? Bool, false)
        XCTAssertEqual(p["name"] as? String, "mlv2dng 25mm 4800x2008 1x3")
        XCTAssertEqual(p["camera_brand"] as? String, "Canon")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: p))
    }

    func testCalibratedAccepted() throws {
        let url = try writeJSON(["calib_dimension": ["w": 5760, "h": 2409], "input_horizontal_stretch": 3,
                                 "sync_settings": NSNull(), "focal_length": 25])
        let p = try LensProfile.calibrated(url, for: timing)
        XCTAssertEqual((p["sync_settings"] as? [String: Any])?["do_autosync"] as? Bool, false)
        XCTAssertEqual(p["focal_length"] as? Int, 25)
    }

    func testCalibratedDimensionMismatch() throws {
        let wrongAspect = try writeJSON(["calib_dimension": ["w": 5760, "h": 1080], "input_horizontal_stretch": 3])
        XCTAssertThrowsError(try LensProfile.calibrated(wrongAspect, for: timing)) {
            guard case .dimensionMismatch? = $0 as? LensProfileError else { return XCTFail("got \($0)") }
        }
        let wrongStretch = try writeJSON(["calib_dimension": ["w": 4800, "h": 2008], "input_horizontal_stretch": 1])
        XCTAssertThrowsError(try LensProfile.calibrated(wrongStretch, for: timing))
    }

    func testCalibratedInvalid() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).json")
        try Data("not json".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try LensProfile.calibrated(url, for: timing)) {
            XCTAssertEqual($0 as? LensProfileError, .invalid)
        }
        XCTAssertThrowsError(try LensProfile.calibrated(url.deletingLastPathComponent().appendingPathComponent("nope.json"), for: timing))
    }

    func testLensCodable() throws {
        let l = Lens(name: "Samyang", focalMM: 12, calibratedProfiles: [URL(fileURLWithPath: "/x/y.json")])
        let back = try JSONDecoder().decode(Lens.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(l, back)
    }

    func testFocalMatchesMeasuredScale() throws {
        guard let dir = ProcessInfo.processInfo.environment["MLV2DNG_GYRO_DIR"] else {
            throw XCTSkip("MLV2DNG_GYRO_DIR not set")
        }
        let base = URL(fileURLWithPath: dir)
        let motion = try RealGyroFixture.motion(base: base)
        let log = try A1Log.read(base.appendingPathComponent("2026-10-24_18-44-36_mix.bin"))
        let res = try GyroSync.solve(motion: motion, fps: 25, gyro: log.gyro, rateHz: log.rateHz, searchMs: 0...25000)
        // Yaw produces horizontal motion: the gyro axis with the largest |dx| term.
        let yaw = res.map.map { abs($0[0]) }.enumerated().max { $0.element < $1.element }!.offset
        // mlvmotion units: 2x2 Bayer bin then 2x decimation = 4 raw px per unit in both axes; dx is
        // already multiplied by the squeeze, so dx units are desqueezed full-res px / 4 as well.
        let measured = abs(res.map[yaw][0]) * 4
        let f = LensProfile.computed(focalMM: 25, timing: timing)
        let fish = try XCTUnwrap(f["fisheye_params"] as? [String: Any])
        let expected = try XCTUnwrap((fish["camera_matrix"] as? [[Double]])?[0][0])
        print("FOCAL axis=\(yaw) measured=\(measured) expected=\(expected) ratio=\(measured / expected)")
        XCTAssertEqual(measured, expected, accuracy: expected * 0.05)
    }
}
