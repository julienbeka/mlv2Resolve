// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2DNGCore

final class A1LogTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("A1LogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func header(magic: String = "SenseFlow") -> Data {
        var h = Data(count: 0x200)
        h.replaceSubrange(0..<magic.utf8.count, with: Array(magic.utf8))
        h.replaceSubrange(0x40..<0x46, with: [26, 10, 24, 18, 44, 36])
        return h
    }

    private func record(gx: Int16 = 0, gy: Int16 = 0, gz: Int16 = 0) -> Data {
        var r = Data([0xAA, 0x55, 0x03])
        for v in [Int16(1), 2, 3, gx, gy, gz] {
            let u = UInt16(bitPattern: v)
            r.append(UInt8(u & 0xFF)); r.append(UInt8(u >> 8))
        }
        r.append(0)
        return r
    }

    private let marker = Data([0x55, 0xAA, 0x40] + [UInt8](repeating: 0, count: 13))

    private func write(_ data: Data, _ name: String = "t_mix.bin") throws -> URL {
        let u = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        return u
    }

    private func syntheticBody(count: Int) -> Data {
        var d = Data()
        for i in 0..<count {
            d.append(record(gx: 328, gy: -328, gz: 0))
            if (i + 1) % 1000 == 0 { d.append(marker) }
        }
        return d
    }

    func testParsesSyntheticLog() throws {
        let url = try write(header() + syntheticBody(count: 2500))
        let log = try A1Log.read(url)
        XCTAssertEqual(log.gyro.count, 2500)
        XCTAssertEqual(log.rateHz, 1000)
        XCTAssertEqual(log.duration, 2.5, accuracy: 1e-9)
        XCTAssertEqual(log.gyro[0].x, 0.1745329, accuracy: 1e-4)
        XCTAssertEqual(log.gyro[0].y, -0.1745329, accuracy: 1e-4)
        XCTAssertEqual(log.gyro[0].z, 0, accuracy: 1e-6)
        let c = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: log.start)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second],
                       [2026, 10, 24, 18, 44, 36])
    }

    func testRejectsNonSenseFlow() throws {
        let url = try write(header(magic: "NotAFlow!") + syntheticBody(count: 10))
        XCTAssertThrowsError(try A1Log.read(url))
    }

    func testRejectsFileShorterThanHeader() throws {
        let url = try write(Data(header().prefix(0x100)))
        XCTAssertThrowsError(try A1Log.read(url))
    }

    func testIgnoresTruncatedFinalRecord() throws {
        let url = try write(header() + syntheticBody(count: 5) + record().prefix(9))
        XCTAssertEqual(try A1Log.read(url).gyro.count, 5)
    }

    func testResyncsAfterStrayBytes() throws {
        let body = record(gx: 328) + Data([0x01, 0x02, 0x03, 0x04, 0x05]) + record(gx: 328)
            + Data([0xAA]) + record(gx: 328)
        let log = try A1Log.read(try write(header() + body))
        XCTAssertEqual(log.gyro.count, 3)
        XCTAssertEqual(log.gyro[2].x, 0.1745329, accuracy: 1e-4)
    }

    func testFindSkipsTempAndHidden() throws {
        let a = try write(Data(), "a/2026_mix.bin")
        let b = try write(Data(), "b/deep/x_mix.bin")
        _ = try write(Data(), "a/Temp/y_mix.bin")
        _ = try write(Data(), ".hidden/z_mix.bin")
        _ = try write(Data(), "a/other.bin")
        let found = A1Log.find(in: root).map { $0.standardizedFileURL.path }
        XCTAssertEqual(found, [a, b].map { $0.standardizedFileURL.path }.sorted())
    }

    func testRealLog() throws {
        guard let dir = ProcessInfo.processInfo.environment["MLV2DNG_GYRO_DIR"] else {
            throw XCTSkip("set MLV2DNG_GYRO_DIR to run")
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("2026-10-24_18-44-36_mix.bin")
        let log = try A1Log.read(url)
        XCTAssertEqual(log.gyro.count, 32799)
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: log.start)
        XCTAssertEqual([c.hour, c.minute, c.second], [18, 44, 36])
    }
}
