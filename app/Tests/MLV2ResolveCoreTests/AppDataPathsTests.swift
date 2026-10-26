import XCTest
@testable import MLV2ResolveCore

final class AppDataPathsTests: XCTestCase {
    func testMigrationPreservesBothExistingDestinationAndLegacyProfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: old.appendingPathComponent("profiles"), withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at: new.appendingPathComponent("profiles"), withIntermediateDirectories:true)
        try Data("legacy".utf8).write(to: old.appendingPathComponent("profiles/a.json"))
        try Data("current".utf8).write(to: new.appendingPathComponent("profiles/a.json"))
        try Data("other".utf8).write(to: old.appendingPathComponent("profiles/b.json"))
        try AppDataPaths.copyMissing(from:old,to:new)
        XCTAssertEqual(try String(contentsOf:new.appendingPathComponent("profiles/a.json"),encoding:.utf8),"current")
        XCTAssertEqual(try String(contentsOf:new.appendingPathComponent("profiles/b.json"),encoding:.utf8),"other")
        XCTAssertTrue(FileManager.default.fileExists(atPath:old.appendingPathComponent("profiles/a.json").path))
    }
}
