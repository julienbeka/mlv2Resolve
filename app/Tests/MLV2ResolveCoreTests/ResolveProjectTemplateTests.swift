import XCTest
@testable import MLV2ResolveCore

final class ResolveProjectTemplateTests: XCTestCase {
    func testPortableProjectPreparesReadOnlyPlaybackRateBeforeImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for fps in [23.976, 25, 29.97, 47.952, 119.88, 17.25] {
            let url = try ResolveProjectTemplate.make(playbackFrameRate: fps, cacheDirectory: root)
            let xml = try ResolveProjectTemplate.projectXML(in: url)
            XCTAssertEqual(try ResolveProjectTemplate.playbackFrameRate(in: xml), fps, accuracy: 0.0001)
            XCTAssertFalse(xml.contains("/Users/"))
            XCTAssertEqual(try ResolveProjectTemplate.make(playbackFrameRate: fps, cacheDirectory: root), url)
        }
    }
    func testMenuScriptReferencesDurablePreparedModel() throws {
        let clip = ResolveProject.Media(name: "A", directory: "/mnt/A", pattern: "/mnt/A/A_%06d.dng", first: 0, last: 1, wav: nil, width: 1920, height: 1080, factor: 1, fps: 25)
        let script = ResolveProject.script(shoots: [.init(name: "Film", media: [clip])], menu: true)
        XCTAssertTrue(script.contains(AppDataPaths.support.appendingPathComponent("Resolve Models").path))
        XCTAssertFalse(script.contains("mlv2Resolve-project-models"))
    }
    func testPlaybackRateMustBeFiniteAndPositive() {
        for fps in [0, -1, Double.nan, Double.infinity, Double.leastNonzeroMagnitude] {
            XCTAssertThrowsError(try ResolveProjectTemplate.make(playbackFrameRate: fps))
        }
    }
}
