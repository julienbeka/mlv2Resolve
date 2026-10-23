// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLVSwitchCore

final class MountPathsTests: XCTestCase {
    let root = URL(fileURLWithPath: "/tmp/MLV Switch", isDirectory: true)

    func shoot(_ name: String, volume: String, folder: String? = nil) -> Shoot {
        Shoot(name: name,
              folder: URL(fileURLWithPath: folder ?? "/Volumes/\(volume)/\(name)", isDirectory: true),
              volumeName: volume, clips: [])
    }

    func testPathIsShootFolderName() {
        let p = MountPaths(root: root)
        XCTAssertEqual(p.mountPoint(for: shoot("2026-10-23", volume: "SSD"), alreadyMounted: [:]),
                       root.appendingPathComponent("2026-10-23"))
    }

    func testSameShootOnOtherDiskKeepsPath() {
        let p = MountPaths(root: root)
        XCTAssertEqual(p.mountPoint(for: shoot("2026-10-23", volume: "Backup"), alreadyMounted: [:]),
                       root.appendingPathComponent("2026-10-23"))
    }

    func testCollisionAddsVolumeName() {
        let p = MountPaths(root: root)
        let a = shoot("2026-10-23", volume: "SSD")
        let b = shoot("2026-10-23", volume: "Backup")
        let url = p.mountPoint(for: b, alreadyMounted: [a: root.appendingPathComponent("2026-10-23")])
        XCTAssertEqual(url, root.appendingPathComponent("2026-10-23 (Backup)"))
    }

    func testAlreadyMountedShootKeepsItsPath() {
        let p = MountPaths(root: root)
        let a = shoot("2026-10-23", volume: "SSD")
        let existing = root.appendingPathComponent("2026-10-23 (SSD)")
        let changed = Shoot(name: a.name, folder: a.folder, volumeName: a.volumeName,
                            clips: [Clip(name: "M1", files: [], bytes: 1)])
        XCTAssertEqual(p.mountPoint(for: changed, alreadyMounted: [a: existing]), existing)
    }

    func testNumericSuffixWhenVolumeVariantTaken() {
        let p = MountPaths(root: root)
        let a = shoot("S", volume: "SSD", folder: "/Volumes/SSD/S")
        let b = shoot("S", volume: "SSD", folder: "/Volumes/SSD/other/S")
        let c = shoot("S", volume: "SSD", folder: "/Volumes/SSD/third/S")
        let mounted = [a: root.appendingPathComponent("S"),
                       b: root.appendingPathComponent("S (SSD)")]
        XCTAssertEqual(p.mountPoint(for: c, alreadyMounted: mounted),
                       root.appendingPathComponent("S (SSD) 2"))
    }

    func testSanitizing() {
        let p = MountPaths(root: root)
        XCTAssertEqual(p.mountPoint(for: shoot("a/b:c", volume: "X"), alreadyMounted: [:]).lastPathComponent, "a-b-c")
        XCTAssertEqual(p.mountPoint(for: shoot("  ", volume: "X"), alreadyMounted: [:]).lastPathComponent, "Tournage")
        XCTAssertEqual(p.mountPoint(for: shoot(".hid", volume: "X"), alreadyMounted: [:]).lastPathComponent, "_hid")
    }
}
