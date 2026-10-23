// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2DNGCore

final class ShootScannerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShootScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func make(_ path: String, size: Int = 0) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: size))
        return url
    }

    func testFolderWithMLVIsOneShoot() throws {
        try make("T/A.MLV", size: 5)
        let shoots = try ShootScanner.scan(root.appendingPathComponent("T"))
        XCTAssertEqual(shoots.count, 1)
        XCTAssertEqual(shoots[0].name, "T")
        XCTAssertEqual(shoots[0].clips.count, 1)
        XCTAssertEqual(shoots[0].clips[0].name, "A")
        XCTAssertEqual(shoots[0].totalBytes, 5)
    }

    func testParentWithSubfolders() throws {
        try make("P/2026-10-23/A.MLV")
        try make("P/2026-08-29/B.MLV")
        try make("P/vide/notes.txt")
        let shoots = try ShootScanner.scan(root.appendingPathComponent("P"))
        XCTAssertEqual(shoots.map(\.name), ["2026-10-23", "2026-08-29"])
    }

    func testSpannedClipIsOneClip() throws {
        try make("T/A001.M01", size: 30)
        try make("T/A001.MLV", size: 10)
        try make("T/A001.M00", size: 20)
        let shoots = try ShootScanner.scan(root.appendingPathComponent("T"))
        XCTAssertEqual(shoots[0].clips.count, 1)
        let clip = shoots[0].clips[0]
        XCTAssertEqual(clip.bytes, 60)
        XCTAssertEqual(clip.files.map(\.lastPathComponent), ["A001.MLV", "A001.M00", "A001.M01"])
    }

    func testUnicodeNames() throws {
        let name = "Tournage été 2026 🎬"
        try make("P/\(name)/A.MLV")
        let shoots = try ScanHelper.scan(root.appendingPathComponent("P"))
        XCTAssertEqual(shoots.count, 1)
        XCTAssertEqual(shoots[0].name.precomposedStringWithCanonicalMapping,
                       name.precomposedStringWithCanonicalMapping)
    }

    func testOnlyOneLevelDeep() throws {
        try make("P/a/b/C.MLV")
        XCTAssertEqual(try ShootScanner.scan(root.appendingPathComponent("P")), [])
    }

    func testExtensionsCaseInsensitive() throws {
        try make("T/a.mlv", size: 1)
        try make("T/a.m00", size: 2)
        let shoots = try ShootScanner.scan(root.appendingPathComponent("T"))
        XCTAssertEqual(shoots[0].clips.count, 1)
        XCTAssertEqual(shoots[0].clips[0].files.count, 2)
    }

    func testOrphanM00AndHiddenFilesIgnored() throws {
        try make("T/A.MLV")
        try make("T/B.M00")
        try make("T/._A.MLV")
        try make("T/.hidden.MLV")
        let shoots = try ShootScanner.scan(root.appendingPathComponent("T"))
        XCTAssertEqual(shoots[0].clips.map(\.name), ["A"])
        XCTAssertEqual(shoots[0].clips[0].files.count, 1)
    }

    func testMixedCaseSpanGroups() throws {
        try make("T/a001.mlv", size: 10)
        try make("T/A001.M00", size: 20)
        try make("T/b002.MLV")
        try make("T/b002.m+1", size: 5)
        let shoots = try ShootScanner.scan(root.appendingPathComponent("T"))
        XCTAssertEqual(shoots[0].clips.map(\.name), ["a001", "b002"])
        XCTAssertEqual(shoots[0].clips[0].bytes, 30)
        XCTAssertEqual(shoots[0].clips[0].files.map(\.lastPathComponent), ["a001.mlv", "A001.M00"])
        XCTAssertEqual(shoots[0].clips[1].files.count, 1) // .m+1 rejected
    }

    func testClipsSortedAscending() throws {
        try make("T/B.MLV")
        try make("T/A.MLV")
        let shoots = try ScanHelper.scan(root.appendingPathComponent("T"))
        XCTAssertEqual(shoots[0].clips.map(\.name), ["A", "B"])
    }

    func testUnreadableRootThrows() {
        XCTAssertThrowsError(try ShootScanner.scan(root.appendingPathComponent("missing")))
    }
}

private enum ScanHelper {
    static func scan(_ url: URL) throws -> [Shoot] { try ShootScanner.scan(url) }
}
