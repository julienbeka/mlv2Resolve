// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2DNGCore

final class LegacyMigrationTests: XCTestCase {
    private func suite(_ tag: String) -> UserDefaults {
        let name = "LegacyMigrationTests-\(tag)-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testCopiesSavedStateOnce() {
        let old = suite("old"), new = suite("new")
        old.set(Data([1, 2]), forKey: "lastFolder")
        old.set(["a", "b"], forKey: "mountedShoots")
        old.set(2, forKey: "dualISOMode")
        old.set(false, forKey: "fixBadPixels")
        old.set(true, forKey: "mainWindowShownOnce")
        XCTAssertTrue(LegacyMigration.migrateDefaults(into: new, from: old))
        XCTAssertEqual(new.data(forKey: "lastFolder"), Data([1, 2]))
        XCTAssertEqual(new.stringArray(forKey: "mountedShoots"), ["a", "b"])
        XCTAssertEqual(new.integer(forKey: "dualISOMode"), 2)
        XCTAssertEqual(new.object(forKey: "fixBadPixels") as? Bool, false)
        XCTAssertNil(new.object(forKey: "fixFocusPixels"))
        XCTAssertNil(new.object(forKey: "mainWindowShownOnce"))
        XCTAssertTrue(new.bool(forKey: LegacyMigration.migratedKey))
        // Second run: lastFolder present, nothing is overwritten.
        old.set(Data([9]), forKey: "lastFolder")
        XCTAssertFalse(LegacyMigration.migrateDefaults(into: new, from: old))
        XCTAssertEqual(new.data(forKey: "lastFolder"), Data([1, 2]))
    }

    func testNoMigrationWhenNewDomainAlreadyHasState() {
        let old = suite("old"), new = suite("new")
        old.set(Data([1]), forKey: "lastFolder")
        new.set(Data([7]), forKey: "lastFolder")
        XCTAssertFalse(LegacyMigration.migrateDefaults(into: new, from: old))
        XCTAssertEqual(new.data(forKey: "lastFolder"), Data([7]))
        XCTAssertNil(new.object(forKey: LegacyMigration.migratedKey))
    }
}
