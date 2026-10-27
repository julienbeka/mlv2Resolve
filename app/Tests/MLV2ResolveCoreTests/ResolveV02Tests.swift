import XCTest
@testable import MLV2ResolveCore

final class ResolveV02Tests: XCTestCase {
    func testMountedFoldersCombineIntoOneNamedProjectAndKeepEveryLink() throws {
        let shoots = [ResolveProject.ShootMedia(name: "Day 1", media: [clip], source: "/day1"),
                      ResolveProject.ShootMedia(name: "Day 2", media: [clip, clip], source: "/day2")]
        let grouped = try XCTUnwrap(ResolveProject.combined(shoots, name: "  My film  ").first)
        XCTAssertEqual(grouped.name, "My film")
        XCTAssertEqual(grouped.media.count, 3)
        XCTAssertEqual(grouped.sources, ["/day1", "/day2"])
        XCTAssertEqual(ResolveProject.combined([], name: "Empty"), [])
    }
    let clip = ResolveProject.Media(name: "A", directory: "/mnt/A", pattern: "/mnt/A/A_%06d.dng", first: 0, last: 100, wav: nil, width: 1600, height: 2008, factor: 3, fps: 24)
    func testTimelineSizesKeepCadenceAndEntireAnamorphicImage() throws {
        for (size, width, height) in [(ResolveTimelineSize.automatic,4800,2008),(.uhd,3840,2160),(.hd,1920,1080)] {
            let f = try XCTUnwrap(ResolveProject.format([clip], timelineSize: size))
            XCTAssertEqual(f.width,width); XCTAssertEqual(f.height,height); XCTAssertEqual(f.fps,24)
            let sizing = ResolveProject.sizing(for: clip, format: f)
            let rawFit = min(Double(width)/1600,Double(height)/2008)
            XCTAssertLessThanOrEqual(4800 * rawFit * sizing.zoom, Double(width)+0.001)
            XCTAssertLessThanOrEqual(2008 * rawFit * sizing.zoom, Double(height)+0.001)
        }
    }
    func testFrameRateDefaultsToMajorityAndCanBeOverridden() {
        let other = ResolveProject.Media(name:"B",directory:"/b",pattern:"/b/B_%06d.dng",first:0,last:10,wav:nil,width:1920,height:1080,factor:1,fps:25)
        XCTAssertEqual(ResolveProject.format([clip,clip,other])?.fps,24)
        XCTAssertEqual(ResolveProject.format([clip,clip,other], frameRate:29.97)?.fps,29.97)
        XCTAssertEqual(ResolveProject.format([clip], frameRate:.nan)?.fps,24)
    }
    @MainActor func testAssociationsPersistDistinctSourcesAndClearOnlyLinks() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ResolveProjectStore(defaults: defaults)
        let a = ResolveProjectStore.Link(source: "/diskA/shoot", name: "shoot", database: "db", folder: ["Films"])
        let b = ResolveProjectStore.Link(source: "/diskB/shoot", name: "shoot 2", database: "db", folder: [])
        store.record(a); store.record(b)
        XCTAssertEqual(ResolveProjectStore(defaults: defaults).links.count,2)
        defaults.set("keep", forKey: "gyroLenses")
        store.clear()
        XCTAssertTrue(ResolveProjectStore(defaults: defaults).links.isEmpty)
        XCTAssertEqual(defaults.string(forKey:"gyroLenses"),"keep")
    }
    @MainActor func testAllShotsPreferencesPersistAndEmptyNameFallsBack() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MountManager(mlvfs: URL(fileURLWithPath:"/missing"), fpmDir: URL(fileURLWithPath:"/tmp"), indexDir: URL(fileURLWithPath:"/tmp"), paths: MountPaths(root: URL(fileURLWithPath:"/tmp")), launcher: FakeLauncher(unmounter: FakeUnmounter()), unmounter: FakeUnmounter())
        let state = AppState(manager:manager,defaults:defaults,scan:{ _ in [] })
        XCTAssertTrue(state.includeAllShots)
        XCTAssertEqual(state.timelineName,"All shots")
        XCTAssertEqual(state.projectName,"My Project")
        state.projectName = "  My film  "
        state.includeAllShots = false; state.timelineName = "  My edit  "
        let restored = AppState(manager:manager,defaults:defaults,scan:{ _ in [] })
        XCTAssertEqual(restored.resolvedProjectName,"My film")
        restored.projectName = "   "
        XCTAssertEqual(restored.resolvedProjectName,"My Project")
        XCTAssertFalse(restored.includeAllShots)
        XCTAssertEqual(restored.resolvedTimelineName,"My edit")
        restored.timelineName = "   "
        XCTAssertEqual(restored.resolvedTimelineName,"All shots")
    }

    func testOpenOnlyScriptHasNoCreateOrImportOperations() {
        let link = ResolveProjectStore.Link(source:"/disk/shoot",name:"shoot",database:"db",folder:["Films"])
        let script = ResolveProject.openScript(link:link)
        XCTAssertFalse(script.contains(":CreateProject("))
        XCTAssertFalse(script.contains(":ImportMedia("))
        XCTAssertTrue(script.contains(":LoadProject("))
        XCTAssertTrue(script.contains(":SaveProject("))
    }
}
