// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2ResolveCore

final class ShootTests: XCTestCase {
    func testTotalBytesSumsClips() {
        let folder = URL(fileURLWithPath: "/Volumes/CARD/DCIM")
        let clips = [
            Clip(name: "M01", files: [folder.appendingPathComponent("M01.MLV")], bytes: 100),
            Clip(name: "M02", files: [folder.appendingPathComponent("M02.MLV")], bytes: 250),
        ]
        let shoot = Shoot(name: "DCIM", folder: folder, volumeName: "CARD", clips: clips)
        XCTAssertEqual(shoot.totalBytes, 350)
    }
}
