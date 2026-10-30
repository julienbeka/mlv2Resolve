import XCTest
@testable import MLV2ResolveCore

/// Read the portable model independently: regression coverage for CST inputs and graph wiring.
final class ResolveGroupModelTests: XCTestCase {
    struct Field { let n: Int; let wire: Int; let number: UInt64; let data: [UInt8] }
    func fields(_ bytes: [UInt8]) throws -> [Field] {
        var i = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard i < bytes.count else { throw NSError(domain: "protobuf", code: 1) }
                let b = bytes[i]; i += 1; result |= UInt64(b & 127) << shift
                if b < 128 { return result }
            }
            throw NSError(domain: "protobuf", code: 2)
        }
        var out: [Field] = []
        while i < bytes.count {
            let key = try varint(); let n = Int(key >> 3), wire = Int(key & 7)
            guard n > 0 else { throw NSError(domain: "protobuf", code: 3) }
            if wire == 0 { out.append(Field(n: n, wire: wire, number: try varint(), data: [])); continue }
            let count: Int
            switch wire { case 2: count = Int(try varint()); case 1: count = 8; case 5: count = 4; default: throw NSError(domain: "protobuf", code: 4) }
            guard count <= bytes.count - i else { throw NSError(domain: "protobuf", code: 5) }
            out.append(Field(n: n, wire: wire, number: 0, data: Array(bytes[i..<i+count]))); i += count
        }
        return out
    }
    func get(_ fs: [Field], _ n: Int) throws -> Field { try XCTUnwrap(fs.first { $0.n == n }) }
    func parameters(_ bytes: [UInt8]) -> [String: String]? {
        guard let fs = try? fields(bytes) else { return nil }
        if fs.contains(where: { $0.n == 2 && String(bytes: $0.data, encoding: .utf8) == "com.blackmagicdesign.resolvefx.colorspacetransformv2" }) {
            var p: [String: String] = [:]
            for f in fs where f.n == 5 {
                guard let tuple = try? fields(f.data), let name = tuple.first(where: { $0.n == 1 }),
                      let value = tuple.first(where: { $0.n == 2 }), let valueFields = try? fields(value.data) else { continue }
                if let text = valueFields.first(where: { $0.n == 5 }) { p[String(bytes: name.data, encoding: .utf8)!] = String(bytes: text.data, encoding: .utf8)! }
                if let boolean = valueFields.first(where: { $0.n == 3 && $0.wire == 0 }) {
                    p[String(bytes: name.data, encoding: .utf8)!] = String(boolean.number)
                }
            }
            return p
        }
        for f in fs where f.wire == 2 { if let p = parameters(f.data) { return p } }
        return nil
    }
    func graph(_ body: String) throws -> [Field] {
        let hex = Array(body.utf8)
        let b = stride(from: 0, to: hex.count, by: 2).map { UInt8(String(bytes: hex[$0..<$0+2], encoding: .utf8)!, radix: 16)! }
        XCTAssertEqual(Array(b.prefix(6)), [129,40,181,47,253,160])
        let size = (0..<4).reduce(0) { $0 | Int(b[6+$1]) << ($1*8) }
        XCTAssertEqual(b.count, size + 13)
        return try fields(get(fields(Array(b.dropFirst(13))), 1).data)
    }
    func testCSTParametersAndAllGraphConnectionsMatchScreenshots() throws {
        for mode in ResolveColorManagement.allCases {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", mode.colorTemplateURL.path, "project.xml"]
            let pipe = Pipe(); process.standardOutput = pipe; try process.run()
            let xml = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
            let expression = try NSRegularExpression(pattern: "<Name>Version 1_(pre|post)</Name>[\\s\\S]*?<Body>([0-9a-f]+)</Body>")
            let matches = expression.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            XCTAssertEqual(matches.count, 2)
            for m in matches {
                let kind = String(xml[Range(m.range(at: 1), in: xml)!])
                let g = try graph(String(xml[Range(m.range(at: 2), in: xml)!]))
                let nodes = try g.filter { $0.n == 7 }.map { try fields($0.data) }
                XCTAssertEqual(nodes.count, kind == "pre" ? 1 : mode.nodeCount)
                let ids = try Set(nodes.map { try get($0, 1).number })
                var endpoints: [UInt64] = []
                var connectionIDs: Set<UInt64> = []
                for n in [9,10] {
                    let edge = try fields(get(g,n).data)
                    let descriptor = try fields(get(edge,3).data)
                    XCTAssertTrue(ids.contains(try get(descriptor,4).number), "dangling graph endpoint")
                    XCTAssertTrue(connectionIDs.insert(try get(descriptor,1).number).inserted,
                                  "graph connections must have distinct IDs")
                    endpoints.append(try get(descriptor,4).number)
                }
                var links: [UInt64: UInt64] = [:]
                for link in g where link.n == 8 {
                    let f = try fields(link.data)
                    XCTAssertTrue(ids.contains(try get(f,1).number)); XCTAssertTrue(ids.contains(try get(f,3).number))
                    links[try get(f,1).number] = try get(f,3).number
                    XCTAssertTrue(connectionIDs.insert(try get(f,7).number).inserted,
                                  "serial links must not reuse connection IDs")
                }
                var path: Set<UInt64> = [], cursor = endpoints[0]
                while path.insert(cursor).inserted, let next = links[cursor] { cursor = next }
                XCTAssertEqual(cursor, endpoints[1], "serial chain must reach the output")
                XCTAssertEqual(path, ids, "every processing node must be on the input/output path")
                let p = try XCTUnwrap(parameters(get(nodes[0],10).data))
                if kind == "pre" {
                    XCTAssertEqual(p["inputColorSpace"], "P3D60_COLORSPACE"); XCTAssertEqual(p["inputGamma"], "LINEAR_GAMMA")
                    XCTAssertEqual(p["outputColorSpace"], "DWG_COLORSPACE"); XCTAssertEqual(p["outputGamma"], "DAV_INTER_OETF_GAMMA")
                    XCTAssertEqual(p["tmType"], "TM_NONE")
                } else {
                    XCTAssertEqual(p["inputColorSpace"], "DWG_COLORSPACE"); XCTAssertEqual(p["inputGamma"], "DAV_INTER_OETF_GAMMA")
                    XCTAssertEqual(p["outputColorSpace"], "REC709_COLORSPACE")
                    XCTAssertEqual(p["outputGamma"], mode == .kodak2383 ? "CINEON_GAMMA" : "REC709_APPLE_GAMMA")
                    XCTAssertEqual(p["tmType"], mode == .kodak2383 ? "TM_NONE" : "TM_DRT_V2")
                    if mode == .kodak2383 {
                        XCTAssertEqual(nodes.count, 2)
                        XCTAssertEqual(p["doFwdOOTF"], "0")
                        XCTAssertEqual(p["doInvOOTF"], "0")
                    }
                }
            }
        }
    }

    func testLiveProjectCreationWithBothChoices() async throws {
        guard ProcessInfo.processInfo.environment["MLV2RESOLVE_GROUP_LIVE"] == "1" else { throw XCTSkip("set MLV2RESOLVE_GROUP_LIVE=1") }
        let base = ProcessInfo.processInfo.environment["MLV2RESOLVE_GROUP_MEDIA_ROOT"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MLV Mounts/UPDLV").path + "/"
        let cases: [(ResolveColorManagement, Bool, Double)] = [(.conversionRec709A, true, 25), (.kodak2383, true, 25), (.conversionRec709A, false, 29.97)]
        for (mode, populated, fps) in cases {
            let dirs = ["M28-1921MLV_1_2026-10-28_0001_C0000", "M28-1922MLV_1_2026-10-28_0001_C0000"]
            let media = dirs.map { d in ResolveProject.Media(name: d, directory: base+d, pattern: base+d+"/"+d+"_%06d.dng", first: 0, last: 19, wav: nil, width: 1600, height: 2008, factor: 3, fps: 25) }
            let name = "mlv2Resolve - validation finale " + mode.rawValue + " " + UUID().uuidString.prefix(6)
            var script = ResolveProject.script(shoots: [.init(name: name, media: media)], includeAllShots: populated, frameRate: fps, colorManagement: mode)
            script = script.replacingOccurrences(of: "local APPROVED = nil", with: "local APPROVED = TEST_CURRENT")
            script = "local TEST_CURRENT=(resolve or Resolve()):GetProjectManager():GetCurrentProject():GetName()\n" + script
            script += """
            \nlocal r=resolve or Resolve();local pm=r:GetProjectManager();local p=pm:GetCurrentProject();assert(p:GetName()=='\(name)');local t=p:GetCurrentTimeline();assert(t:GetNodeGraph():GetNumNodes()==0);local g=p:GetColorGroupsList()[1];assert(g and g:GetName()=='All');assert(g:GetPreClipNodeGraph():GetNumNodes()==1);assert(g:GetPostClipNodeGraph():GetNumNodes()==\(mode.nodeCount));assert(#g:GetClipsInTimeline(t)==\(populated ? 2 : 0));for _,item in ipairs(t:GetItemListInTrack('video',1)) do assert(item:GetColorGroup():GetName()=='All') end;assert(pm:SaveProject());assert(pm:LoadProject('\(name)'));p=pm:GetCurrentProject();t=p:GetCurrentTimeline();g=p:GetColorGroupsList()[1];assert(g:GetName()=='All' and g:GetPreClipNodeGraph():GetNumNodes()==1 and g:GetPostClipNodeGraph():GetNumNodes()==\(mode.nodeCount));assert(t:GetNodeGraph():GetNumNodes()==0);assert(math.abs(tonumber(p:GetSetting('timelineFrameRate'))-\(fps))<0.001);print('LIVE_GROUP_VERIFIED')
            """
            let out = try await ResolveDesqueeze.fuscriptRunner()(script)
            XCTAssertFalse(out.contains("ERROR"), out); XCTAssertTrue(out.contains("LIVE_GROUP_VERIFIED"), out)
        }
    }
}
