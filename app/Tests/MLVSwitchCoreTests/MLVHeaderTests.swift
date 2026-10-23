// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLVSwitchCore

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
    static func data(sampling: (UInt8, UInt8, UInt8, UInt8)?, withRAWC: Bool = true) -> Data {
        var d = block("MLVI", payload: [UInt8](repeating: 0, count: 36))
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
}
