// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2DNGCore

final class ResolveDesqueezeTests: XCTestCase {
    typealias RD = ResolveDesqueeze

    override func setUp() { L10n.bundle = L10nTests.bundle("en") }
    override func tearDown() { L10n.bundle = L10nTests.bundle("en") }

    let shoot = RD.Target(prefix: "/Users/me/MLV Mounts/Tests mlv2dng", factor: 3)

    // MARK: Lua strings

    func testLuaStringPicksAFreeLevel() {
        let bridged = NSString(string: "“mlv2dng 1x3”") as String
        XCTAssertEqual(RD.luaString(bridged), "[[“mlv2dng 1x3”]]")
        XCTAssertEqual(RD.luaString("/a b/c"), "[[/a b/c]]")
        XCTAssertEqual(RD.luaString("x]]y"), "[=[x]]y]=]")
        XCTAssertEqual(RD.luaString("x]]y]=]z"), "[==[x]]y]=]z]==]")
        // A trailing "]" (or "]=") would close the literal early at the lower level.
        XCTAssertEqual(RD.luaString("a]"), "[=[a]]=]")
        XCTAssertEqual(RD.luaString("a]="), "[[a]=]]")
        // Lua drops a leading newline: one is added so the value survives.
        XCTAssertEqual(RD.luaString("\nx"), "[[\n\nx]]")
        XCTAssertEqual(RD.luaString(""), "[[]]")
    }

    func testLuaStringNeverContainsItsCloserInside() {
        for s in ["]]", "]=]", "]==]]]", "a]]=]]==]]===]", "”«»'\"\\ é", "]"] {
            let lit = RD.luaString(s)
            let level = lit.dropFirst().prefix { $0 == "=" }.count
            let close = "]" + String(repeating: "=", count: level) + "]"
            XCTAssertTrue(lit.hasSuffix(close))
            let inner = lit.dropFirst(level + 2).dropLast(level + 2)
            XCTAssertEqual(String(inner), s)
            let combined = String(inner) + close
            XCTAssertEqual(combined.range(of: close).map { combined.distance(from: combined.startIndex, to: $0.lowerBound) }, inner.count,
                         "early close in \(lit)")
        }
    }

    // MARK: Script generation

    func testScriptListsTargetsAndFlags() {
        let s = RD.script(targets: [shoot, RD.Target(prefix: "/m/B]]x/", factor: 2)])
        XCTAssertTrue(s.contains("local DRY_RUN = false"))
        XCTAssertTrue(s.contains("{ prefix = [[/Users/me/MLV Mounts/Tests mlv2dng]], factor = 3 },"))
        // trailing slash dropped, "]]" escaped by level
        XCTAssertTrue(s.contains("{ prefix = [=[/m/B]]x]=], factor = 2 },"))
        XCTAssertTrue(s.contains("local SUMMARY = nil"))
        XCTAssertTrue(s.contains("\"Input Sizing Preset\""))
        XCTAssertTrue(s.contains("RESULT applied=%d already=%d other_preset=%d missing_preset=%s no_resolve=%d no_project=%d dry_run=%d product=%s"))
        XCTAssertTrue(s.contains("local p = t.prefix .. \"/\""), "prefixes match whole path components")
        XCTAssertTrue(RD.script(targets: [shoot], dryRun: true).contains("local DRY_RUN = true"))
    }

    func testScriptAddsDecomposedSpelling() {
        let nfc = "/Users/me/MLV Mounts/Tourn\u{E9}e"
        let s = RD.script(targets: [RD.Target(prefix: nfc, factor: 3)])
        XCTAssertTrue(s.contains("[[\(nfc)]]"))
        XCTAssertTrue(s.contains("[[\(nfc.decomposedStringWithCanonicalMapping)]]"))
        XCTAssertEqual(RD.matchList([shoot, shoot]).count, 1, "duplicates collapse")
    }

    func testScriptWithSummaryCarriesTemplates() {
        L10n.bundle = L10nTests.bundle("fr")
        let s = RD.script(targets: [shoot], summary: .current(againHint: .menuScript))
        XCTAssertFalse(s.contains("local SUMMARY = nil"))
        XCTAssertTrue(s.contains("function SUMMARY.show"))
        XCTAssertTrue(s.contains("[3] = [[« mlv2dng 1x3 »]]"))
        XCTAssertTrue(s.contains("{1} plans désanamorphosés dans Resolve (préréglage Input Sizing {2})."))
        XCTAssertTrue(s.contains("Puis relancez Workspace → Scripts → mlv2dng Desqueeze."))
        XCTAssertTrue(s.contains("Width = 3."), "the free-version hint names the factor")
    }

    // MARK: Parsing

    func testParseFullResult() {
        let out = "some fuscript banner\nRESULT applied=2 already=1 other_preset=3 missing_preset=3,2 no_resolve=0 no_project=0 dry_run=1 product=DaVinci Resolve Studio\n"
        XCTAssertEqual(RD.parse(out), .report(RD.Report(applied: 2, already: 1, otherPreset: 3, missingPreset: [2, 3],
                                                        dryRun: true, product: "DaVinci Resolve Studio")))
    }

    func testParseFlags() {
        XCTAssertEqual(RD.parse("RESULT applied=0 already=0 other_preset=0 missing_preset= no_resolve=1 no_project=0 dry_run=0 product="),
                       .report(RD.Report(noResolve: true)))
        let r = RD.parse("RESULT applied=0 already=0 other_preset=0 missing_preset= no_resolve=0 no_project=1 dry_run=0 product=DaVinci Resolve Studio")
        XCTAssertEqual(r, .report(RD.Report(noProject: true, product: "DaVinci Resolve Studio")))
        XCTAssertTrue(r.reachedResolve)
        XCTAssertFalse(RD.parse("RESULT applied=0 already=0 other_preset=0 missing_preset= no_resolve=1 product=").reachedResolve)
    }

    func testParseErrorsAndGarbage() {
        XCTAssertEqual(RD.parse("ERROR attempt to index a nil value"), .failed("attempt to index a nil value"))
        XCTAssertEqual(RD.parse(""), .failed("no output"))
        XCTAssertEqual(RD.parse("hello\nworld"), .failed("hello / world"))
        // Malformed RESULT lines are failures, not zero counts.
        if case .failed = RD.parse("RESULT applied=x already=0 other_preset=0 missing_preset= no_resolve=0") {} else { XCTFail() }
        if case .failed = RD.parse("RESULT applied=1") {} else { XCTFail("missing fields") }
        if case .failed = RD.parse("RESULT applied=1 already=0 other_preset=0 missing_preset=a no_resolve=0") {} else { XCTFail() }
        XCTAssertFalse(RD.parse("garbage").reachedResolve)
    }

    // MARK: Running

    func testTraversalIgnoresResolveCollectionMetadata() async throws {
        try XCTSkipUnless(RD.fuscriptURL() != nil, "Resolve Lua interpreter is not installed")
        let fixture = """
        local function clip(path)
          return {
            GetClipProperty = function(self, key)
              if key == "File Path" then return path end
              if key == "Input Sizing Preset" then return "None" end
            end,
            SetClipProperty = function(self, key, value)
              assert(key == "Input Sizing Preset" and value == "mlv2dng 1x3")
              return true
            end
          }
        end
        local child = {
          GetClipList = function() return { clip("/test/shoot/child.dng"), __flags = 256 } end,
          GetSubFolderList = function() return { __flags = 256 } end
        }
        local root = {
          GetClipList = function() return {
            clip("/test/shoot/audio.wav"), clip("/test/shoot/_PREVIEW.gif"),
            clip("/test/shoot/root.dng"), __flags = 256
          } end,
          GetSubFolderList = function() return { child, __flags = 256 } end
        }
        resolve = {
          GetProductName = function() return "DaVinci Resolve Studio" end,
          GetProjectManager = function() return {
            GetCurrentProject = function() return {
              GetMediaPool = function() return { GetRootFolder = function() return root end } end
            } end
          } end
        }
        """
        // Both a menu-script global and the external interpreter's Resolve() factory
        // must be resolved through fuscript's environment rather than raw _G.
        for suffix in ["", "local fixtureResolve = resolve; resolve = nil; Resolve = function() return fixtureResolve end"] {
            let script = fixture + "\n" + suffix + "\n" + RD.script(targets: [.init(prefix: "/test/shoot", factor: 3)])
            let output = try await RD.fuscriptRunner()(script)
            XCTAssertEqual(RD.parse(output), .report(RD.Report(applied: 2, product: "DaVinci Resolve Studio")))
        }
    }

    func testRunPassesScriptAndMapsRunnerErrors() async {
        let seen = Locked<String>("")
        let ok: RD.Runner = { script in
            seen.set(script)
            return "RESULT applied=1 already=0 other_preset=0 missing_preset= no_resolve=0 no_project=0 dry_run=1 product=X"
        }
        let outcome = await RD.run(targets: [shoot], dryRun: true, runner: ok)
        XCTAssertEqual(outcome, .report(RD.Report(applied: 1, dryRun: true, product: "X")))
        XCTAssertTrue(seen.get().contains("local DRY_RUN = true"))
        let timeout = await RD.run(targets: [shoot], runner: { _ in throw RD.RunError.timedOut })
        let missing = await RD.run(targets: [shoot], runner: { _ in throw RD.RunError.notInstalled })
        XCTAssertEqual(timeout, .timedOut)
        XCTAssertEqual(missing, .notInstalled)
        if case .failed = await RD.run(targets: [shoot], runner: { _ in throw RD.RunError.launch("nope") }) {} else { XCTFail() }
    }

    func testFuscriptRunnerTimesOutAndReadsOutput() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Fake fuscript: `-l lua <file>` → prints the file, or sleeps when it contains "SLEEP".
        let fake = dir.appendingPathComponent("fuscript")
        try "#!/bin/sh\nif grep -q SLEEP \"$3\"; then sleep 30; fi\necho \"args=$1 $2\"\ncat \"$3\"\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let runner = RD.fuscriptRunner(timeout: 1, locate: { fake })
        let out = try await runner("print('hi')")
        XCTAssertTrue(out.contains("args=-l lua"))
        XCTAssertTrue(out.contains("print('hi')"))
        let start = Date()
        do { _ = try await runner("-- SLEEP"); XCTFail("should time out") } catch {
            XCTAssertEqual(error as? RD.RunError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        do { _ = try await RD.fuscriptRunner(locate: { nil })("x"); XCTFail() } catch {
            XCTAssertEqual(error as? RD.RunError, .notInstalled)
        }
    }

    func testFuscriptLocation() {
        XCTAssertEqual(RD.fuscriptURL(fileExists: { $0.hasPrefix("/Applications/DaVinci Resolve/") })?.path,
                       "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript")
        XCTAssertNil(RD.fuscriptURL(fileExists: { _ in false }))
    }

    // MARK: Messages

    func testSuccessMessages() {
        let t = [shoot]
        func msg(_ r: RD.Report) -> String { RD.message(for: .report(r), targets: t).text }
        XCTAssertEqual(msg(RD.Report(applied: 4)), "4 clips desqueezed in Resolve (Input Sizing preset “mlv2dng 1x3”).")
        XCTAssertEqual(msg(RD.Report(applied: 1, otherPreset: 2)),
                       "1 clip desqueezed in Resolve (Input Sizing preset “mlv2dng 1x3”).\n\n2 clips kept their own sizing preset.")
        XCTAssertEqual(msg(RD.Report(already: 3)), "Already done.")
        XCTAssertEqual(msg(RD.Report(already: 1, otherPreset: 1)), "Already done.\n\n1 clip kept its own sizing preset.")
        XCTAssertEqual(msg(RD.Report()), "No anamorphic clip from mlv2dng found in the open project.")
        XCTAssertFalse(RD.message(for: .report(RD.Report(applied: 1)), targets: t).isError)
    }

    func testMissingPresetMessage() {
        let (text, isError) = RD.message(for: .report(RD.Report(missingPreset: [3])), targets: [shoot])
        XCTAssertTrue(isError)
        XCTAssertEqual(text, """
        Resolve has no Input Sizing preset named “mlv2dng 1x3” yet. Create it once:

        In Resolve: Color page → select a 1x3 clip → Sizing → Input Sizing → set Width to 3 → … menu → save as a new preset named “mlv2dng 1x3”.

        Then click Desqueeze in Resolve again.
        """)
        let two = RD.message(for: .report(RD.Report(applied: 2, missingPreset: [2])),
                             targets: [shoot, RD.Target(prefix: "/m/x", factor: 2)]).text
        XCTAssertTrue(two.hasPrefix("2 clips desqueezed in Resolve (Input Sizing preset “mlv2dng 1x3”)."))
        XCTAssertTrue(two.contains("set Width to 2"))
    }

    func testNoConnectionMessages() {
        let expected = "Couldn't talk to DaVinci Resolve. Automatic desqueeze needs DaVinci Resolve Studio running with a project open, and Preferences → System → General → External scripting using: Local. With the free version, set it by hand: Color page → Sizing → Input Sizing → Width = 3."
        for o in [RD.Outcome.report(RD.Report(noResolve: true)), .notInstalled] {
            XCTAssertEqual(RD.message(for: o, targets: [shoot]).text, expected)
            XCTAssertTrue(RD.message(for: o, targets: [shoot]).isError)
        }
        XCTAssertEqual(RD.message(for: .timedOut, targets: [shoot]).text, "DaVinci Resolve didn't answer in time. " + expected)
        XCTAssertEqual(RD.message(for: .failed("boom"), targets: [shoot]).text,
                       "The Resolve desqueeze script failed.\n\nDetails: boom")
        XCTAssertEqual(RD.message(for: .report(RD.Report(noProject: true)), targets: [shoot]).text,
                       "Open a project in DaVinci Resolve, then try again.")
    }

    func testFrenchMessages() {
        L10n.bundle = L10nTests.bundle("fr")
        XCTAssertEqual(RD.message(for: .report(RD.Report(applied: 2, otherPreset: 1)), targets: [shoot]).text,
                       "2 plans désanamorphosés dans Resolve (préréglage Input Sizing « mlv2dng 1x3 »).\n\n1 plan a gardé son propre préréglage de sizing.")
        XCTAssertEqual(RD.hintSuffix(), "Ou utilisez Désanamorphoser dans Resolve.")
    }

    // MARK: Menu script

    func testInstallMenuScriptWritesOnlyItsFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rd-\(UUID().uuidString)/Scripts/Utility", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        XCTAssertTrue(RD.installMenuScript(targets: [shoot], in: dir))
        try "keep".write(to: dir.appendingPathComponent("Other.lua"), atomically: true, encoding: .utf8)
        XCTAssertTrue(RD.installMenuScript(targets: [], in: dir))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["Other.lua", "mlv2dng Desqueeze.lua"])
        let text = try String(contentsOf: dir.appendingPathComponent(RD.menuScriptName), encoding: .utf8)
        XCTAssertTrue(text.contains("function SUMMARY.show"))
        XCTAssertFalse(text.contains("Tests mlv2dng"), "rewritten with the current (empty) target list")
        // Unwritable location: logged, no throw.
        XCTAssertFalse(RD.installMenuScript(targets: [shoot], in: URL(fileURLWithPath: "/dev/null/x")))
    }
}

/// Opt-in check against the real DaVinci Resolve Studio: `MLV2DNG_RESOLVE_LIVE=1 swift test --filter ResolveDesqueezeLiveTests`.
/// `MLV2DNG_RESOLVE_DRY=1` reports without changing anything; `MLV2DNG_RESOLVE_PREFIX` overrides the mount path.
final class ResolveDesqueezeLiveTests: XCTestCase {
    func testLiveRun() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["MLV2DNG_RESOLVE_LIVE"] == "1", "set MLV2DNG_RESOLVE_LIVE=1 to talk to Resolve")
        let prefix = env["MLV2DNG_RESOLVE_PREFIX"] ?? "/Users/julienbecker/MLV Mounts/Tests mlv2dng"
        let target = ResolveDesqueeze.Target(prefix: prefix, factor: 3)
        let script = ResolveDesqueeze.script(targets: [target], dryRun: env["MLV2DNG_RESOLVE_DRY"] == "1")
        let out = try await ResolveDesqueeze.fuscriptRunner()(script)
        print("LIVE OUTPUT >>>\n\(out)<<<")
        let outcome = ResolveDesqueeze.parse(out)
        print("LIVE OUTCOME: \(outcome)")
        L10n.bundle = L10nTests.bundle("en")
        print("LIVE MESSAGE: \(ResolveDesqueeze.message(for: outcome, targets: [target]).text)")
        XCTAssertTrue(outcome.reachedResolve)
    }
}
