// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2ResolveCore

final class DependenciesTests: XCTestCase {
    private let dylib = "/usr/local/lib/libfuse-t.dylib"

    func testReady() {
        let d = Dependencies(fileExists: { $0 == self.dylib }, fuseTVersion: { "1.2.6" })
        XCTAssertEqual(d.check(), .ready)
    }
    func testMissingWhenDylibAbsent() {
        let d = Dependencies(fileExists: { _ in false }, fuseTVersion: { "1.2.6" })
        XCTAssertEqual(d.check(), .fuseTMissing)
    }
    func testOutdated() {
        let d = Dependencies(fileExists: { _ in true }, fuseTVersion: { "1.1.0" })
        XCTAssertEqual(d.check(), .fuseTOutdated(found: "1.1.0", minimum: "1.2.6"))
    }
    func testNumericComparison() {
        let d = Dependencies(fileExists: { _ in true }, fuseTVersion: { "1.10.0" })
        XCTAssertEqual(d.check(), .ready)
    }
    func testMissingWhenVersionUnknown() {
        let d = Dependencies(fileExists: { _ in true }, fuseTVersion: { nil })
        XCTAssertEqual(d.check(), .fuseTMissing)
    }
    func testResolveNilWhenNone() {
        XCTAssertNil(resolveAppURL(fileExists: { _ in false }))
    }
    func testResolvePrefersResolveThenStudio() {
        let studio = "/Applications/DaVinci Resolve Studio/DaVinci Resolve Studio.app"
        XCTAssertEqual(resolveAppURL(fileExists: { $0 == studio })?.path, studio)
        XCTAssertEqual(resolveAppURL(fileExists: { _ in true })?.path,
                       "/Applications/DaVinci Resolve/DaVinci Resolve.app")
    }
    func testParseHighestCoreVersion() {
        XCTAssertEqual(Dependencies.highestCoreVersion(in: ["org.fuse-t.core.1.2.9", "org.fuse-t.fskit.1.2.9", "org.fuse-t.core.1.10.0", "org.fuse-t.core.1.2.6"]), "1.10.0")
        XCTAssertNil(Dependencies.highestCoreVersion(in: ["org.fuse-t.fskit.1.2.9"]))
    }
}
