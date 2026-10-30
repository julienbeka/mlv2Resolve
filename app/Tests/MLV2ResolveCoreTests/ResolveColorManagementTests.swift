import XCTest
@testable import MLV2ResolveCore

final class ResolveColorManagementTests: XCTestCase {
    func testNewProjectUsesGroupGradesAndEmptyTimeline() {
        let script = ResolveProject.script(shoots: [])
        XCTAssertTrue(script.contains("local COLOR_POST_NODE_COUNT = 1"))
        XCTAssertTrue(script.contains("colorGroup:GetName()~='All'"))
        XCTAssertTrue(script.contains("GetPreClipNodeGraph()"))
        XCTAssertTrue(script.contains("GetPostClipNodeGraph()"))
        XCTAssertTrue(script.contains("AssignToColorGroup(colorGroup)"))
        XCTAssertTrue(script.contains("graph:GetNumNodes()~=0"))
        XCTAssertTrue(script.contains("{'separateColorSpaceAndGamma','0'}"))
        XCTAssertTrue(script.contains("{'colorSpaceTimeline','DaVinci WG/Intermediate'}"))
        XCTAssertTrue(script.contains("{'colorSpaceOutput','Rec.709-A'}"))
        XCTAssertFalse(script.contains("SetNodeEnabled(2,false)"))
    }

    func testKodakChoiceIsWrittenIntoBothDirectAndWorkspaceScripts() throws {
        for menu in [false, true] {
            let script = ResolveProject.script(shoots: [], menu: menu, colorManagement: .kodak2383)
            XCTAssertTrue(script.contains("resolve-color-kodak2383.drt"))
            XCTAssertTrue(script.contains("local COLOR_POST_NODE_COUNT = 2"))
            XCTAssertTrue(script.contains("Film Looks/Rec709 Kodak 2383 D60.cube"))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try ResolveProject.installMenuScript(shoots: [], in: root, colorManagement: .kodak2383)
        let installed = try String(contentsOf: root.appendingPathComponent(ResolveProject.menuScriptName), encoding: .utf8)
        XCTAssertTrue(installed.contains("local COLOR_POST_NODE_COUNT = 2"))
    }
}
