import XCTest
@testable import MLV2DNGCore

final class ResolvePresetTests: XCTestCase {
    let original = "<?xml version=\"1.0\"?><SmPTZRInputPresetList DbId=\"library\"><FieldsBlob/><PresetList><Element><SmPTZRPreset><Name>None</Name><Presets>7b7d</Presets></SmPTZRPreset></Element></PresetList></SmPTZRInputPresetList>"

    func testInstallBacksUpAndIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("presets.xml")
        try Data(original.utf8).write(to: file)
        XCTAssertEqual(ResolvePresets.prepare(factors: [3, 5], file: file, isRunning: { false }), .created)
        let installed = try Data(contentsOf: file)
        let xml = String(decoding: installed, as: UTF8.self)
        XCTAssertTrue(xml.contains("mlv2dng 1x3"))
        XCTAssertTrue(xml.contains("mlv2dng 1x5"))
        XCTAssertTrue(xml.contains("<Name>None</Name>"))
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "bak" }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), Data(original.utf8))
        XCTAssertEqual(ResolvePresets.prepare(factors: [3, 5], file: file, isRunning: { false }), .ready)
        XCTAssertEqual(try Data(contentsOf: file), installed)
    }

    func testRunningOrUnknownFormatNeverWrites() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(original.utf8).write(to: file)
        XCTAssertEqual(ResolvePresets.prepare(factors: [3], file: file, isRunning: { true }), .manual)
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
        try Data("<unknown/>".utf8).write(to: file)
        XCTAssertEqual(ResolvePresets.prepare(factors: [3], file: file, isRunning: { false }), .manual)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "<unknown/>")
    }

    func testResolveLaunchingDuringPreparationPreventsWrite() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(original.utf8).write(to: file)
        var checks = 0
        XCTAssertEqual(ResolvePresets.prepare(factors: [3], file: file, isRunning: {
            checks += 1
            return checks > 1
        }), .manual)
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
    }

    func testMissingFileAndUnsupportedFactorsUseManualFallback() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(ResolvePresets.prepare(factors: [3], file: file, isRunning: { false }), .manual)
        XCTAssertEqual(ResolvePresets.prepare(factors: [7], file: file, isRunning: { false }), .manual)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testConflictingUserPresetIsPreserved() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let conflict = original.replacingOccurrences(of: "<Name>None</Name>", with: "<Name>mlv2dng 1x3</Name>")
        try Data(conflict.utf8).write(to: file)
        XCTAssertEqual(ResolvePresets.prepare(factors: [3], file: file, isRunning: { false }), .manual)
        XCTAssertEqual(try Data(contentsOf: file), Data(conflict.utf8))
    }

    func testFitVariantInstallationIsIdempotentAndPreservesOtherPresets() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(original.utf8).write(to: file)
        let sizing = ResolvePresets.Sizing(name: "mlv2dng 1x3 Fit", factor: 3, zoom: 0.5)
        XCTAssertEqual(ResolvePresets.prepare(sizing: [sizing], file: file, isRunning: { false }), .created)
        XCTAssertEqual(ResolvePresets.prepare(sizing: [sizing], file: file, isRunning: { false }), .ready)
        let xml = try XMLDocument(contentsOf: file)
        let names = try xml.nodes(forXPath: "//Name").compactMap(\.stringValue)
        XCTAssertEqual(names, ["None", "mlv2dng 1x3 Fit"])
        let hex = try XCTUnwrap(xml.nodes(forXPath: "//Presets").last?.stringValue)
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        let decoded = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(decoded.contains("K~10300001}I PB{Para|1.5}"))
        XCTAssertTrue(decoded.contains("K~10300002}I PB{Para|0.5}"))
    }
    func testPayloadUsesObservedWidthAndHeightFields() {
        for factor in [3, 5] {
            let hex = ResolvePresets.payload(factor)
            let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
            let decoded = String(decoding: bytes, as: UTF8.self)
            XCTAssertTrue(decoded.contains("K~10300001}I PB{Para|\(factor)}"))
            XCTAssertTrue(decoded.contains("K~10300002}I PB{Para|1}"))
        }
    }
}
