// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2ResolveCore

final class ResolveProjectTests: XCTestCase {
    typealias RP = ResolveProject
    func clip(_ name: String, width: Int = 1600, height: Int = 2008, factor: Int = 3, fps: Double = 25) -> RP.Media {
        .init(name: name, directory: "/mount/\(name)", pattern: "/mount/\(name)/\(name)_%06d.dng",
              first: 0, last: 99, wav: "/mount/\(name)/\(name).wav", width: width, height: height, factor: factor, fps: fps)
    }
    func testMajorityResolutionAndCadence() throws {
        let media = [clip("a"), clip("b"), clip("c", width: 1736, height: 2178),
                     clip("d", width: 1920, height: 1080, factor: 1, fps: 24)]
        let format = try XCTUnwrap(RP.format(media))
        XCTAssertEqual(format.width, 4800)
        XCTAssertEqual(format.height, 2008)
        XCTAssertEqual(format.fps, 25)
        XCTAssertEqual(format.differentFPS, ["d"])
        XCTAssertNil(RP.format([]))
        XCTAssertEqual(RP.uhdZoom(clip("a")), 0.7437037, accuracy: 0.000001)
        XCTAssertEqual(RP.uhdZoom(clip("s", width: 1920, height: 1080, factor: 1)), 1)
    }
    func testResolutionTieUsesLargestAndFive4KBeatTwo5K() throws {
        let four = (0..<5).map { clip("a\($0)") }
        let five = (0..<2).map { clip("b\($0)", width: 1736, height: 2178) }
        XCTAssertEqual(RP.format(four + five)?.width, 4800)
        XCTAssertEqual(RP.format([four[0], five[0]])?.width, 5208)
    }
    @MainActor
    func testUndiscoverableShootIsReportedAlongsideValidShoot() async {
        let outcome = await RP.execute(shoots: [.init(name: "missing", media: [], warnings: ["A"]), .init(name: "valid", media: [clip("b")])], runner: { _ in
            "PROJECT imported=1 already=0 failed=0 missing=0 studio=1"
        }, confirmSwitch: { _,_ in false })
        if case let .report(imported, _, failed, _, _, warnings) = outcome {
            XCTAssertEqual(imported, 1); XCTAssertEqual(failed, 1)
            XCTAssertTrue(warnings.contains(where: { $0.contains("missing") && $0.contains("A") }))
        } else { XCTFail() }
    }
    func testSequenceDiscoveryUsesExplicitBoundsAndIgnoresSidecars() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A_000003.dng", "A_000004.dng", "A.wav", "_PREVIEW.gif", "A.log", "A.gyroflow"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let seq = try XCTUnwrap(RP.sequence(in: root))
        XCTAssertEqual(seq.first, 3); XCTAssertEqual(seq.last, 4)
        XCTAssertEqual(seq.pattern, root.path + "/A_%06d.dng")
        XCTAssertEqual(seq.wav, root.path + "/A.wav")
    }
    func testScriptCreatesProjectImportsPairsAndSecondRunLeavesExistingUntouched() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil, "Resolve Lua interpreter unavailable")
        let script = RP.script(shoots: [.init(name: "20261025", media: [clip("a"), clip("b")])])
        let output = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\n" + script + "\n" + "existing = true\n" + script + "\nassert(imports == 4 and syncs == 2 and settings == 11 and presets == 0)")
        XCTAssertFalse(output.contains("ERROR"), output)
        XCTAssertTrue(output.contains("imported=2"), output)
        XCTAssertTrue(output.contains("already=2"), output)
    }
    func testSwitchRequiresConsentBeforeAnyMutation() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil, "Resolve Lua interpreter unavailable")
        let output = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\ncurrentName = 'Personal'\n" + RP.script(shoots: [.init(name: "20261025", media: [clip("a")])]))
        XCTAssertTrue(output.contains("SWITCH Personal"), output)
        XCTAssertFalse(output.contains("ERROR"), output)
        XCTAssertFalse(output.contains("imported=1"), output)
    }
    func testEmptyStartupProjectDoesNotRequireSavingOrConfirmation() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil, "Resolve Lua interpreter unavailable")
        for name in ["Untitled Project", "Untitled", "Sans titre", "Projet sans titre"] {
            let setup = """
            currentName='\(name)'
            local pm=resolve:GetProjectManager()
            local p=pm:GetCurrentProject()
            p.GetTimelineCount=function() return 0 end
            local save=pm.SaveProject
            pm.SaveProject=function(self)
              assert(currentName~='\(name)', 'Must not save the empty startup project')
              return save(self)
            end
            """
            let output = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\n" + setup + "\n" + RP.script(shoots: [.init(name: "20261025", media: [clip("a")])]))
            XCTAssertFalse(output.contains("ERROR"), output)
            XCTAssertFalse(output.contains("SWITCH"), output)
            XCTAssertTrue(output.contains("imported=1"), output)
        }
    }

    func testUntitledProjectWithWorkOrSavedInLibraryStillRequiresConsent() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil, "Resolve Lua interpreter unavailable")
        let conditions = [
            "p.GetTimelineCount=function() return 1 end",
            "pool:ImportMedia({'/personal/a.mov'})",
            "pool:GetRootFolder().GetSubFolderList=function() return {{GetClipList=function() return {{}} end, GetSubFolderList=function() return {} end}} end",
            "pm.GetProjectListInCurrentFolder=function() return {'Untitled Project'} end",
            "p.GetTimelineCount=function() error('API unavailable') end",
        ]
        for condition in conditions {
            let setup = """
            currentName='Untitled Project'
            local pm=resolve:GetProjectManager()
            local p=pm:GetCurrentProject()
            local pool=p:GetMediaPool()
            p.GetTimelineCount=function() return 0 end
            pm.SaveProject=function() error('No permission to save yet') end
            \(condition)
            """
            let output = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\n" + setup + "\n" + RP.script(shoots: [.init(name: "20261025", media: [clip("a")])]))
            XCTAssertTrue(output.contains("SWITCH Untitled Project"), output)
            XCTAssertFalse(output.contains("ERROR"), output)
        }
    }

    func testSaveFailureForRealProjectStillCancelsSwitch() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil, "Resolve Lua interpreter unavailable")
        let setup = """
        currentName='Personal'
        resolve:GetProjectManager().SaveProject=function() return false end
        """
        let output = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\n" + setup + "\n" + RP.script(shoots: [.init(name: "20261025", media: [clip("a")])], approvedCurrent: "Personal"))
        XCTAssertTrue(output.contains("Could not save current project; switch cancelled"), output)
        XCTAssertFalse(output.contains("imported=1"), output)
    }

    func testFreeCreatesUHDAndZoomedRushsOnlyOnCreation() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil, "Resolve Lua interpreter unavailable")
        let output = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\nstudio = false\n" + RP.script(shoots: [.init(name: "20261025", media: [clip("a")])]) + "\nassert(zoom > 0.743 and zoom < 0.745 and rushs == 1)")
        XCTAssertFalse(output.contains("ERROR"), output)
        XCTAssertTrue(output.contains("imported=1"), output)
    }
    func testPartialImportFailureDoesNotStopFollowingClipAndMissingPresetIsReported() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil, "Resolve Lua interpreter unavailable")
        let setup = """
        local p=resolve:GetProjectManager():CreateProject('20261025')
        local pool=p:GetMediaPool()
        local original=pool.ImportMedia
        pool.ImportMedia=function(self,list)
          if type(list[1])=='table' and list[1].FilePath:find('/a/',1,true) then return {} end
          return original(self,list)
        end
        currentName=nil
        p.SetPreset=function() return false end
        p.SetSetting=function() return true end
        """
        let output = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\n" + setup + "\n" + RP.script(shoots: [.init(name: "20261025", media: [clip("a"), clip("b")])]))
        XCTAssertTrue(output.contains("imported=1 already=0 failed=1 missing=0"), output)
        XCTAssertFalse(output.contains("ERROR"), output)
    }
    func testGyroProgressCountsPendingAndRunningAsUnfinished() {
        let progress = GyroProgress(states: [.pending, .running, .existing, .noLog, .failed("x"), .synced(r2: 1, log: "a", offsetMs: 0)])
        XCTAssertTrue(progress.isActive)
        XCTAssertEqual(progress.completed, 4)
        XCTAssertEqual(progress.total, 6)
        XCTAssertFalse(GyroProgress(states: []).isActive)
    }
    func testProtocolRejectsGarbageAndPreservesSwitchName() {
        XCTAssertEqual(RP.parse("banner\nSWITCH My project\n"), .switchProject("My project"))
        XCTAssertEqual(RP.parse("NO_RESOLVE"), .unavailable)
        if case .failed = RP.parse("PROJECT imported=oops") {} else { XCTFail() }
    }
    @MainActor
    func testExecutionWaitsForConnectionAndAsksBeforeSwitching() async {
        let outputs = Locked<[String]>(["NO_RESOLVE", "SWITCH Personal", "PROJECT imported=1 already=0 failed=0 missing=0 studio=1"])
        let scripts = Locked<[String]>([])
        let outcome = await RP.execute(shoots: [.init(name: "shoot", media: [clip("a")])], runner: { script in
            scripts.set(scripts.get() + [script])
            var queue = outputs.get(); let out = queue.removeFirst(); outputs.set(queue); return out
        }, confirmSwitch: { current, target in
            XCTAssertEqual(current, "Personal"); XCTAssertEqual(target, "shoot"); return true
        }, connectionAttempts: 2, retryDelay: .zero)
        XCTAssertEqual(outcome, .report(imported: 1, already: 0, failed: 0, missing: 0, studio: true, warnings: []))
        XCTAssertEqual(scripts.get().count, 3)
    }
    @MainActor
    func testDecliningSwitchStopsExecution() async {
        let calls = Locked<Int>(0)
        let result = await RP.execute(shoots: [.init(name: "shoot", media: [clip("a")])], runner: { _ in
            calls.set(calls.get() + 1); return "SWITCH Personal"
        }, confirmSwitch: { _, _ in false }, retryDelay: .zero)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(calls.get(), 1)
    }
    @MainActor
    func testConnectionProbeStopsAtLimitWithoutPreparingProjects() async {
        let calls = Locked<Int>(0)
        let connected = await RP.waitForConnection(runner: { _ in calls.set(calls.get() + 1); return "NO_RESOLVE" }, attempts: 2, retryDelay: .zero)
        XCTAssertFalse(connected)
        XCTAssertEqual(calls.get(), 2)
    }
    func testDefaultNamedUserPresetIsPreserved() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil, "Resolve Lua interpreter unavailable")
        let setup = """
        local p=resolve:GetProjectManager():CreateProject('20261025')
        local pool=p:GetMediaPool()
        local original=pool.ImportMedia
        pool.ImportMedia=function(self,list)
          local out=original(self,list)
          if type(list[1])=='table' then
            out[1].GetClipProperty=function(self,k) if k=='Input Sizing Preset' then return 'Default' else return list[1].FilePath end end
            out[1].SetClipProperty=function() error('User sizing must be preserved') end
          end
          return out
        end
        currentName=nil
        """
        let output = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\n" + setup + "\n" + RP.script(shoots: [.init(name: "20261025", media: [clip("a")])]))
        XCTAssertTrue(output.contains("failed=0"), output)
        XCTAssertFalse(output.contains("ERROR"), output)
    }
    func testDiscoveryUsesMountCorrectionAndReadsFormatWithoutRTCI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mlv = root.appendingPathComponent("A.MLV")
        var data = SyntheticMLV.data(sampling: (1,0,1,0), size: (1600,2008))
        data.replaceSubrange(44..<52, with: [25,0,0,0,1,0,0,0])
        try data.write(to: mlv)
        let mount = root.appendingPathComponent("mount")
        let directory = mount.appendingPathComponent("AMLV_1_2026-10-25_0001_C0000")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("A_000000.dng"))
        let shoot = Shoot(name: "S", folder: root, volumeName: "", clips: [.init(name: "A", files: [mlv], bytes: 0)])
        let result = RP.discover(shoot, mount: mount, corrections: ["A.MLV": 3])
        XCTAssertEqual(result.media.count, 1)
        XCTAssertEqual(result.media.first?.factor, 3)
        XCTAssertEqual(RP.format(result.media)?.width, 4800)
        XCTAssertEqual(result.media.first?.fps, 25)
        XCTAssertNil(result.media.first?.wav)
    }
    func testMixedAspectAnamorphicUsesSizingThatFitsNativeTimeline() throws {
        let source = clip("wide", width: 1920, height: 1080)
        let format = try XCTUnwrap(RP.format([clip("a"),clip("b"),source]))
        let sizing = RP.sizing(for: source, format: format)
        XCTAssertNotEqual(sizing.name, "mlv2Resolve 1x3")
        let rawFit = min(4800.0 / 1920, 2008.0 / 1080)
        XCTAssertEqual(1920 * rawFit * 3 * sizing.zoom, 4800, accuracy: 0.01)
        XCTAssertLessThanOrEqual(1080 * rawFit * sizing.zoom, 2008)
        XCTAssertEqual(RP.sizing(for: clip("b", width: 1736, height: 2178), format: format).name, "mlv2Resolve 1x3")
    }
    func testStudioAppliesFitVariantToDifferentAspectClip() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil, "Resolve Lua interpreter unavailable")
        let setup = """
        local p=resolve:GetProjectManager():CreateProject('20261025')
        local pool=p:GetMediaPool(); local original=pool.ImportMedia
        pool.ImportMedia=function(self,list)
          local out=original(self,list)
          if type(list[1])=='table' and list[1].FilePath:find('/wide/',1,true) then
            out[1].SetClipProperty=function(self,k,v)
              assert(k=='Input Sizing Preset' and v=='mlv2Resolve 1x3 Fit 4800x2008 1920x1080'); fitApplied=true; return true
            end
          end
          return out
        end
        currentName=nil
        """
        let output = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\n" + setup + "\n" + RP.script(shoots: [.init(name: "20261025", media: [clip("a"),clip("b"),clip("wide",width: 1920,height: 1080)])]) + "\nassert(fitApplied)")
        XCTAssertFalse(output.contains("ERROR"), output)
        XCTAssertTrue(output.contains("imported=3 already=0 failed=0"), output)
    }
    func testNewClipsFitExistingTimelineAfterMajorityChanges() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil, "Resolve Lua interpreter unavailable")
        let setup = """
        local p=resolve:GetProjectManager():CreateProject('20261025')
        existing=true
        p.GetSetting=function(self,k) if k=='timelineResolutionWidth' then return '4800' else return '2008' end end
        local pool=p:GetMediaPool(); local original=pool.ImportMedia
        pool.ImportMedia=function(self,list)
          local out=original(self,list)
          if type(list[1])=='table' and list[1].FilePath:find('/wide',1,true) then
            out[1].SetClipProperty=function(self,k,v)
              assert(v=='mlv2Resolve 1x3 Fit 4800x2008 1920x1080'); return true
            end
          end
          return out
        end
        """
        let media = [clip("a"),clip("wide1",width:1920,height:1080),clip("wide2",width:1920,height:1080)]
        let output = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\n" + setup + "\n" + RP.script(shoots: [.init(name: "20261025", media: media)]))
        XCTAssertTrue(output.contains("imported=3 already=0 failed=0"), output)
        XCTAssertFalse(output.contains("ERROR"), output)
        let presets = RP.sizingPresets(shoots: [.init(name:"20261025", media:media)])
        XCTAssertTrue(presets.contains { $0.name == "mlv2Resolve 1x3 Fit 4800x2008 1920x1080" })
    }
    // Strict Resolve boundary double. All project/media mutations must follow the spec's arguments and order.
    let fixture = """
    existing=false; studio=true; currentName=nil; imports=0; syncs=0; settings=0; presets=0; rushs=0; zoom=0
    local items={}
    local modelMedia={}
    local function item(path)
      return {GetClipProperty=function(self,k) if k=='File Path' then return path else return '' end end,
              SetClipProperty=function(self,k,v) assert(k=='Input Sizing Preset' and v=='mlv2Resolve 1x3'); return true end}
    end
    local root={GetClipList=function() return items end, GetSubFolderList=function() return {__flags=256} end}
    local pool={GetRootFolder=function() return root end, SetCurrentFolder=function() return true end,
      ImportMedia=function(self, list)
        imports=imports+1
        local info=list[1]
        local p=type(info)=='table' and info.FilePath or info
        if type(info)=='table' then assert(info.StartIndex==0 and info.EndIndex==99 and p:match('%%06d.dng$')) end
        local x=item(p); table.insert(items,x); return {x}
      end,
      AutoSyncAudio=function(self,pair,opts) assert(#pair==2 and opts[1]==0 and opts[2]==true); syncs=syncs+1; return true end,
      ImportTimelineFromFile=function(self,path,options)
        if path:match('resolve%-clip%-gyro.drt$') then
          return {GetItemListInTrack=function() return {{
            GetMediaPoolItem=function() return modelMedia end,
            GetNodeGraph=function() return {GetNumNodes=function() return 1 end,GetToolsInNode=function() return {'OFX: Gyroflow(Niyien)'} end} end,
            CopyGrades=function(self,targets) gyroCopied=(gyroCopied or 0)+#targets; for _,t in ipairs(targets) do t.gyro=true end; return true end
          }} end}
        end
        assert(path:match('resolve%-timeline%-cst.drt$') and options.timelineName=='All shots'); rushs=rushs+1
        return {SetName=function() return true end, SetSetting=function() return true end, GetNodeGraph=function() return {
          GetNumNodes=function() return 2 end, SetNodeEnabled=function() return true end} end}
      end,
      CreateEmptyTimeline=function(self,name) assert(name=='__mlv2Resolve_format_anchor'); return {} end,
      DeleteTimelines=function() modelRemoved=true; return true end,
      DeleteClips=function(self,clips) assert(#clips==1 and clips[1]==modelMedia); modelMediaRemoved=true; return true end,
      AppendToTimeline=function(self,clips) return {{
        GetNodeGraph=function(self) return {GetNumNodes=function() return 1 end,GetToolsInNode=function() return self.gyro and {'OFX: Gyroflow(Niyien)'} or {} end} end,
        SetProperty=function(self,k,v) zoom=v; return true end}} end}
    local project={GetName=function() return currentName end, SetPreset=function(self,n) assert(not existing and n=='mlv2Resolve'); presets=presets+1; return true end,
      SetSetting=function(self,k,v) assert(not existing); settings=settings+1; return true end,
      GetTimelineByIndex=function(self,i)
        assert(i==1); rushs=rushs+1
        return {SetName=function() return true end, SetSetting=function() return true end, GetNodeGraph=function() return {
          GetNumNodes=function() return 2 end, SetNodeEnabled=function() return true end} end}
      end,
      GetMediaPool=function() return pool end, SetCurrentTimeline=function() return true end}
    local pm={GetCurrentProject=function() if currentName then return project end end,
      GetProjectListInCurrentFolder=function() if existing then return {'20261025'} else return {} end end,
      ImportProject=function(self,path,name) assert(path:match('resolve%-project%-cst.drp$')); projectModelImported=true; return true end,
      CreateProject=function(self,n) assert(not existing); currentName=n; return project end,
      LoadProject=function(self,n) currentName=n; return project end, SaveProject=function() return true end}
    resolve={GetProjectManager=function() return pm end, GetProductName=function() return studio and 'DaVinci Resolve Studio' or 'DaVinci Resolve' end,
             AUDIO_SYNC_MODE=1, AUDIO_SYNC_TIMECODE=0, AUDIO_SYNC_RETAIN_VIDEO_METADATA=2}
    """
}

extension ResolveProjectTests {
    func testModelMediaIsRemovedEvenWhenResolveImportsItAtRoot() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil)
        let out = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\n" + RP.script(shoots:[.init(name:"20261025",media:[clip("a")])]) + "\nassert(modelMediaRemoved); print('MODEL_MEDIA_REMOVED')")
        XCTAssertTrue(out.contains("MODEL_MEDIA_REMOVED"),out)
    }
    func testCadenceWarningExplainsSourceAndProjectRates() {
        let script = RP.script(shoots:[.init(name:"Film",media:[clip("a",fps:24),clip("b"),clip("c")])])
        XCTAssertTrue(script.contains("24 fps"))
        XCTAssertTrue(script.contains("25 fps"))
        XCTAssertFalse(script.contains("a (fps)"))
    }
    func testGyroflowNodeIsCopiedToEveryCreatedTimelineClipAndModelRemoved() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil)
        let output = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\n" + RP.script(shoots:[.init(name:"20261025",media:[clip("a"),clip("b")])]) + "\nassert(gyroCopied==2 and modelRemoved); print('GYROFLOW_VERIFIED')")
        XCTAssertTrue(output.contains("GYROFLOW_VERIFIED"),output)
    }
    func testMissingSizingPresetStillDesqueezesAndFitsTimelineClips() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil)
        let setup = """
        local p=resolve:GetProjectManager():CreateProject('20261025')
        currentName=nil
        local pool=p:GetMediaPool(); local original=pool.ImportMedia
        pool.ImportMedia=function(self,list)
          local out=original(self,list)
          out[1].SetClipProperty=function() return false end
          return out
        end
        pool.AppendToTimeline=function(self,clips)
          return {{GetNodeGraph=function() return {GetNumNodes=function() return 1 end,GetToolsInNode=function() return {'OFX: Gyroflow(Niyien)'} end} end, SetProperty=function(self,k,v)
            if k=='ZoomGang' then assert(v==false); unganged=true
            elseif k=='ZoomX' then zx=v elseif k=='ZoomY' then zy=v end
            return true
          end}}
        end
        """
        let out = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\n" + setup + "\n" + RP.script(shoots:[.init(name:"20261025",media:[clip("a")])], timelineSize:.hd) + "\nassert(unganged and math.abs(zx/zy-3)<0.0001 and math.abs(zy-0.7437037)<0.0001); print('DESQUEEZE_VERIFIED')")
        XCTAssertTrue(out.contains("DESQUEEZE_VERIFIED"),out)
    }
    func testProjectOwnsFormatAndExplicitOutputGammaAndTimelineInherits() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil)
        let setup = """
        local p=resolve:GetProjectManager():CreateProject('20261025')
        currentName=nil
        projectSettings={}
        p.SetSetting=function(self,k,v) projectSettings[k]=v; return true end
        local pool=p:GetMediaPool(); local original=pool.ImportTimelineFromFile
        pool.ImportTimelineFromFile=function(self,path,opts)
          local t=original(self,path,opts)
          if path:match('resolve%-clip%-gyro.drt$') then return t end
          t.SetSetting=function(self,k,v) assert(k=='useCustomSettings' and v=='0'); inherited=true; return true end
          return t
        end
        """
        let out = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\n" + setup + "\n" + RP.script(shoots:[.init(name:"20261025",media:[clip("a")])], timelineSize:.hd, frameRate:29.97) + "\nassert(inherited and projectSettings.colorSpaceOutput=='DaVinci WG' and projectSettings.colorSpaceOutputGamma=='DaVinci Intermediate' and projectSettings.timelineFrameRate=='29.97' and projectSettings.timelineResolutionWidth=='1920'); print('PROJECT_SETTINGS_VERIFIED')")
        XCTAssertTrue(out.contains("PROJECT_SETTINGS_VERIFIED"),out)
    }
    func testPortableTimelineTemplateReceivesFormatAndNodeStates() async throws {
        try XCTSkipUnless(ResolveDesqueeze.fuscriptURL() != nil)
        let setup = """
        local p=resolve:GetProjectManager():CreateProject('20261025')
        currentName=nil
        local pool=p:GetMediaPool()
        pool.ImportTimelineFromFile=function(self,path,options)
          assert(path:match('resolve%-timeline%-cst.drt$') and options.timelineName=='My edit' and projectModelImported)
          modelImported=true
          return {SetName=function(self,name) assert(name=='My edit'); renamed=true; return true end, SetSetting=function(self,k,v) return true end,
            GetNodeGraph=function() return {GetNumNodes=function() return 2 end,
              SetNodeEnabled=function(self,i,on) assert((i==1 and on) or (i==2 and not on)); statesSet=(statesSet or 0)+1; return true end} end}
        end
        pool.CreateEmptyTimeline=function(self,name) assert(name=='__mlv2Resolve_format_anchor'); return {} end
        """
        let out = try await ResolveDesqueeze.fuscriptRunner()(fixture + "\n" + setup + "\n" + RP.script(shoots:[.init(name:"20261025",media:[clip("a",width:1920,height:1080,factor:1)])], timelineSize:.hd, includeAllShots:false, timelineName:"My edit") + "\nassert(modelImported and renamed and statesSet==2 and zoom==0); print('TEMPLATE_VERIFIED')")
        XCTAssertFalse(out.contains("ERROR"),out)
        XCTAssertTrue(out.contains("imported=1"),out)
        XCTAssertTrue(out.contains("TEMPLATE_VERIFIED"),out)
    }
}
