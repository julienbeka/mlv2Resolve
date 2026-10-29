// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2ResolveCore

final class GyroLogExcerptTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GyroLogExcerptTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    static func log(samples: Int = 60_000, rate: Int = 1000) -> Data {
        var data = Data(count: 512)
        data.replaceSubrange(0..<9, with: "SenseFlow".utf8)
        data.replaceSubrange(64..<70, with: [26, 10, 28, 23, 59, 50])
        data.replaceSubrange(92..<96, with: (0..<4).map { UInt8((rate >> ($0 * 8)) & 255) })
        for i in 0..<samples {
            var payload = [UInt8](repeating: 0, count: 12)
            payload[0] = UInt8(i & 255); payload[1] = UInt8((i >> 8) & 255)
            payload[6] = 10
            data.append(contentsOf: [0xAA, 0x55, 3] + payload + [payload.reduce(0, &+)])
            if (i + 1) % rate == 0 { data.append(contentsOf: [0x55, 0xAA, 0x40] + [UInt8](repeating: 0, count: 13)) }
        }
        return data
    }
    func fixture(offset: Double = -30_500.25, frames: Int = 250, fourSlashes: Bool = true) throws -> (URL, Data) {
        let log = root.appendingPathComponent("session_mix.bin")
        try Self.log().write(to: log)
        let project: [String: Any] = [
            "gyro_source": ["filepath": fourSlashes ? "file:///" + log.path : log.absoluteString, "imu_orientation": "Xzy"],
            "offsets": ["32000250": offset, "35500250": offset, "39000250": offset],
            "video_info": ["num_frames": frames, "fps": 25],
            "stabilization": ["fov": 0.9, "smoothing_params": [["name": "time_constant", "value": 2.0]]],
        ]
        return (root.appendingPathComponent("clip_000000.gyroflow"), try JSONSerialization.data(withJSONObject: project))
    }
    func json(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    func logURL(_ data: Data) throws -> URL {
        let source = try XCTUnwrap(try json(data)["gyro_source"] as? [String: Any])
        return try XCTUnwrap(URL(string: try XCTUnwrap(source["filepath"] as? String)))
    }

    func testExactSamplesSyncAndDateRollover() throws {
        let (dest, data) = try fixture()
        let originalLog = try A1Log.read(logURL(data))
        let result = try GyroLogExcerpt.prepare(data, destination: dest)
        try result.persistLog()
        let shortened = try A1Log.read(logURL(result.projectData))
        XCTAssertEqual(shortened.gyro.count, 30_501)
        XCTAssertEqual(shortened.start.timeIntervalSince(originalLog.start), 20)
        XCTAssertEqual(shortened.gyro, Array(originalLog.gyro[20_000..<50_501]))
        let offsets = try XCTUnwrap(try json(result.projectData)["offsets"] as? [String: Double])
        XCTAssertEqual(offsets, ["12000250": -10_500.25, "15500250": -10_500.25, "19000250": -10_500.25])
        XCTAssertEqual(try json(result.projectData)["stabilization"] as? NSDictionary, try json(data)["stabilization"] as? NSDictionary)
        XCTAssertEqual(try Data(contentsOf: logURL(data)), Self.log())
        XCTAssertEqual(try logURL(result.projectData).deletingLastPathComponent().lastPathComponent, ".mlv2resolve-gyro")
    }

    func testStandardFileURLAndPaddingAtBothBoundaries() throws {
        let (dest, data) = try fixture(offset: -100, frames: 1495, fourSlashes: false)
        let result = try GyroLogExcerpt.prepare(data, destination: dest)
        try result.persistLog()
        XCTAssertEqual(try A1Log.read(logURL(result.projectData)).gyro.count, 60_000)
    }

    func testMigrateBacksUpOnceAndIsIdempotent() throws {
        let (dest, data) = try fixture()
        try data.write(to: dest)
        let backups = root.appendingPathComponent("backups")
        XCTAssertTrue(try GyroLogExcerpt.migrate(at: dest, backupDirectory: backups))
        let after = try Data(contentsOf: dest)
        XCTAssertFalse(try GyroLogExcerpt.migrate(at: dest, backupDirectory: backups))
        XCTAssertEqual(try Data(contentsOf: dest), after)
        let copies = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), data)
    }

    func testInvalidChecksumAndUnsupportedRecordsRefuseMigrationWithoutWriting() throws {
        for corrupt in [true, false] {
            let (dest, data) = try fixture()
            let source = try logURL(data)
            var binary = try Data(contentsOf: source)
            if corrupt { binary[527] ^= 1 } else { binary[514] = 7 }
            try binary.write(to: source)
            try data.write(to: dest)
            XCTAssertThrowsError(try GyroLogExcerpt.migrate(at: dest, backupDirectory: root.appendingPathComponent("backups")))
            XCTAssertEqual(try Data(contentsOf: dest), data)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".mlv2resolve-gyro").path))
    }

    func testOutOfRangeAndVariableOffsetsRefused() throws {
        let (dest, data) = try fixture(offset: -59_000)
        XCTAssertThrowsError(try GyroLogExcerpt.prepare(data, destination: dest))
        var p = try json(data)
        p["offsets"] = ["1000000": -2000.0, "5000000": -2001.0]
        XCTAssertThrowsError(try GyroLogExcerpt.prepare(JSONSerialization.data(withJSONObject: p), destination: dest))
    }

    func testOldExcerptRemainsValidAfterRegeneration() throws {
        let (dest, first) = try fixture()
        let a = try GyroLogExcerpt.prepare(first, destination: dest); try a.persistLog()
        let old = try Data(contentsOf: logURL(a.projectData))
        let (_, second) = try fixture(offset: -20_000)
        let b = try GyroLogExcerpt.prepare(second, destination: dest); try b.persistLog()
        XCTAssertNotEqual(try logURL(a.projectData), try logURL(b.projectData))
        XCTAssertEqual(try Data(contentsOf: logURL(a.projectData)), old)
    }

    @MainActor
    func testCancellationDoesNotReplaceProject() async throws {
        let (dest, data) = try fixture()
        try data.write(to: dest)
        let backup = root.appendingPathComponent("backups")
        let task = Task { try GyroLogExcerpt.migrate(at: dest, backupDirectory: backup) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled migration succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: dest), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testBackupFailureDoesNotReplaceProject() throws {
        let (dest, data) = try fixture()
        try data.write(to: dest)
        let backup = root.appendingPathComponent("blocked-backups")
        try Data("file".utf8).write(to: backup)
        XCTAssertThrowsError(try GyroLogExcerpt.migrate(at: dest, backupDirectory: backup))
        XCTAssertEqual(try Data(contentsOf: dest), data)
    }

    func testRealExcerptMatchesResolveValidatedBytes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let original = env["MLV2RESOLVE_EXCERPT_ORIGINAL"], let expected = env["MLV2RESOLVE_EXCERPT_EXPECTED"] else {
            throw XCTSkip("set MLV2RESOLVE_EXCERPT_ORIGINAL and MLV2RESOLVE_EXCERPT_EXPECTED")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: original))
        let result = try GyroLogExcerpt.prepare(data, destination: root.appendingPathComponent("real.gyroflow"))
        let tested = try Data(contentsOf: URL(fileURLWithPath: expected))
        XCTAssertEqual(result.logData, try Data(contentsOf: logURL(tested)))
        XCTAssertEqual(try json(result.projectData)["offsets"] as? NSDictionary, try json(tested)["offsets"] as? NSDictionary)
    }
}
