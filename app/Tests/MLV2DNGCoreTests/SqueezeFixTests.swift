// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2DNGCore

final class SqueezeFixTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        L10n.bundle = L10nTests.bundle("en")
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("SqueezeFix-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() {
        L10n.bundle = L10nTests.bundle("en")
        try? FileManager.default.removeItem(at: tmp)
    }

    private func c(_ name: String, _ x: Int, _ y: Int, _ w: Int = 1600, _ h: Int = 2008)
        -> (name: String, sampling: SqueezeFix.Sampling) { (name, (x, y, w, h)) }

    /// Comparable form of the result (tuples are not Equatable).
    private func fixes(_ clips: [(name: String, sampling: SqueezeFix.Sampling)]) -> [String: [Int]] {
        SqueezeFix.corrections(for: clips).mapValues { [$0.x, $0.y] }
    }

    // MARK: Rule

    func testMajorityCorrectsOddClip() {
        let clips = [c("A.MLV", 3, 1), c("B.MLV", 3, 1), c("C.MLV", 1, 1), c("D.MLV", 3, 1), c("E.MLV", 3, 1),
                     c("F.MLV", 3, 1)]
        XCTAssertEqual(fixes(clips), ["C.MLV": [3, 1]])
    }

    func testNoMajorityNoFix() {
        XCTAssertEqual(fixes([c("A.MLV", 3, 1), c("B.MLV", 3, 1), c("C.MLV", 1, 1), c("D.MLV", 1, 1)]), [:])
        // 2 of 4 is not a strict majority even against two different minorities.
        XCTAssertEqual(fixes([c("A.MLV", 3, 1), c("B.MLV", 3, 1), c("C.MLV", 1, 1), c("D.MLV", 3, 5)]), [:])
    }

    func testDifferentSizeNotTouched() {
        let clips = [c("A.MLV", 3, 1), c("B.MLV", 3, 1), c("C.MLV", 3, 1),
                     c("D.MLV", 1, 1, 1920, 1080)]  // other size: its own group of one
        XCTAssertEqual(fixes(clips), [:])
        // Each size is judged on its own.
        let mixed = clips + [c("E.MLV", 1, 1), c("F.MLV", 1, 1, 1920, 1080), c("G.MLV", 1, 1, 1920, 1080)]
        XCTAssertEqual(fixes(mixed), ["E.MLV": [3, 1]])
    }

    func testSmallGroupNotTouched() {
        XCTAssertEqual(fixes([c("A.MLV", 3, 1), c("B.MLV", 1, 1)]), [:])
        XCTAssertEqual(fixes([c("A.MLV", 3, 1)]), [:])
        XCTAssertEqual(fixes([]), [:])
    }

    func testThreeClipsTwoAgainstOne() {
        XCTAssertEqual(fixes([c("A.MLV", 1, 1), c("B.MLV", 3, 1), c("C.MLV", 3, 1)]), ["A.MLV": [3, 1]])
    }

    // MARK: Headers, engine option, shoot factor, message

    private func writeClip(_ name: String, _ sampling: (UInt8, UInt8, UInt8, UInt8)?, size: (Int, Int)? = (1600, 2008)) throws -> Clip {
        let url = tmp.appendingPathComponent(name)
        let d = SyntheticMLV.data(sampling: sampling, size: size)
        try d.write(to: url)
        return Clip(name: (name as NSString).deletingPathExtension, files: [url], bytes: Int64(d.count))
    }

    private func shoot(_ clips: [Clip]) -> Shoot { Shoot(name: "S", folder: tmp, volumeName: "", clips: clips) }

    func testSamplingReadsRAWCAndRAWI() throws {
        let a = try writeClip("A.MLV", (1, 2, 1, 0))
        let s = try XCTUnwrap(MLVHeader.sampling(of: a.files[0]))
        XCTAssertEqual([s.x, s.y, s.width, s.height], [3, 1, 1600, 2008])
        XCTAssertNil(MLVHeader.sampling(of: try writeClip("B.MLV", nil).files[0]), "no RAWC")
        XCTAssertNil(MLVHeader.sampling(of: try writeClip("C.MLV", (1, 2, 1, 0), size: nil).files[0]), "no RAWI")
        XCTAssertNil(MLVHeader.sampling(of: tmp.appendingPathComponent("missing.MLV")))
    }

    func testFixesFromHeadersEngineArgumentAndShootSqueeze() throws {
        // The odd clip comes first: the shoot factor must still be the majority's.
        let clips = [try writeClip("M25-1745.MLV", (1, 0, 1, 0)), try writeClip("M25-1735.MLV", (1, 2, 1, 0)),
                     try writeClip("M25-1744.MLV", (3, 0, 1, 0)), try writeClip("M25-1750.MLV", (1, 2, 1, 0)),
                     try writeClip("M25-1799.MLV", nil)]  // no RAWC: never corrected
        let fixes = SqueezeFix.fixes(for: shoot(clips))
        XCTAssertEqual(fixes, [SqueezeFix.Fix(name: "M25-1745.MLV", fromX: 1, fromY: 1, toX: 3, toY: 1)])
        XCTAssertEqual(fixes.first?.squeeze, 3)
        XCTAssertEqual(SqueezeFix.engineArgument(fixes), "--sampling-fix=M25-1745.MLV:3x1")
        XCTAssertNil(SqueezeFix.engineArgument([]))
        XCTAssertEqual(SqueezeFix.shootSqueeze(shoot(clips), fixes: fixes), 3)
        XCTAssertEqual(SqueezeFix.shootSqueeze(shoot(clips), fixes: []), 3, "uncorrected: 3 of 5 already 1x3")
        // Uncorrected, two clips 1x1 against one 1x3: the majority wins, not the first clip.
        let few = [try writeClip("X1.MLV", (1, 2, 1, 0)), try writeClip("X2.MLV", (1, 0, 1, 0)),
                   try writeClip("X3.MLV", (1, 0, 1, 0))]
        XCTAssertNil(SqueezeFix.shootSqueeze(shoot(few), fixes: []))
        XCTAssertNil(SqueezeFix.shootSqueeze(shoot([try writeClip("N.MLV", (1, 0, 1, 0))]), fixes: []))
    }

    func testEngineArgumentSeveralAndUnsafeNames() {
        let f = [SqueezeFix.Fix(name: "A.MLV", fromX: 1, fromY: 1, toX: 3, toY: 1),
                 SqueezeFix.Fix(name: "a,b.MLV", fromX: 1, fromY: 1, toX: 3, toY: 1),
                 SqueezeFix.Fix(name: "B.MLV", fromX: 3, fromY: 1, toX: 1, toY: 1)]
        XCTAssertEqual(SqueezeFix.engineArgument(f), "--sampling-fix=A.MLV:3x1,B.MLV:1x1")
    }

    func testMessageEnglishAndFrench() {
        let one = [SqueezeFix.Fix(name: "M25-1745.MLV", fromX: 1, fromY: 1, toX: 3, toY: 1)]
        XCTAssertNil(SqueezeFix.message([]))
        XCTAssertEqual(SqueezeFix.message(one), "M25-1745: header says 1x1, corrected to 1x3 like the other clips")
        let two = one + [SqueezeFix.Fix(name: "M25-1800.MLV", fromX: 1, fromY: 1, toX: 3, toY: 1)]
        XCTAssertEqual(SqueezeFix.message(two),
                       "M25-1745, M25-1800: header says 1x1, corrected to 1x3 like the other clips")
        L10n.bundle = L10nTests.bundle("fr")
        XCTAssertEqual(SqueezeFix.message(one), "M25-1745 : l'en-tête indique 1x1, corrigé en 1x3 comme les autres plans")
    }

    /// Real shoot (read-only): `MLV2DNG_SHOOT_20261025` = folder with M25-1735/1744/1745/1750/1752/1753.MLV,
    /// all RAWI 1600x2008, RAWC 3x1 except M25-1745 (1x1). Keys are MLV file names.
    func testRealShoot20261025() throws {
        guard let path = ProcessInfo.processInfo.environment["MLV2DNG_SHOOT_20261025"], !path.isEmpty else {
            throw XCTSkip("MLV2DNG_SHOOT_20261025 not set")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.uppercased().hasSuffix(".MLV") }.sorted()
        let clips = names.compactMap { n -> (name: String, sampling: SqueezeFix.Sampling)? in
            MLVHeader.sampling(of: folder.appendingPathComponent(n)).map { (n, $0) }
        }
        XCTAssertEqual(clips.count, names.count, "every clip has RAWC and RAWI")
        XCTAssertEqual(fixes(clips), ["M25-1745.MLV": [3, 1]])
        let shoot = Shoot(name: "20261025", folder: folder, volumeName: "",
                          clips: names.map { Clip(name: $0, files: [folder.appendingPathComponent($0)], bytes: 0) })
        let f = SqueezeFix.fixes(for: shoot)
        XCTAssertEqual(SqueezeFix.engineArgument(f), "--sampling-fix=M25-1745.MLV:3x1")
        XCTAssertEqual(SqueezeFix.shootSqueeze(shoot, fixes: f), 3)
    }
}
