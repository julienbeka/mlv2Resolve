// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// « Desqueeze in Resolve »: applies the Input Sizing preset « mlv2Resolve 1x<N> » to the media pool items of the
/// open Resolve project that come from shoots mounted by mlv2Resolve.
///
/// Resolve's scripting API has no Input Sizing keys, but `SetClipProperty("Input Sizing Preset", name)` applies a
/// user-created preset. The work is done by a self-contained Lua script run through Resolve's `fuscript` (Studio only,
/// with Preferences → System → General → External scripting using: Local). The script prints one line:
///
///     RESULT applied=<n> already=<n> other_preset=<n> missing_preset=<f,...> no_resolve=<0|1> no_project=<0|1> dry_run=<0|1> product=<name>
///
/// (or `ERROR <message>` when the script itself failed). Rules: a clip already on the wanted preset is `already`;
/// a clip on any other preset is left alone (`other_preset`, the user's choice wins); otherwise the preset is set
/// (`applied`), and a refusal means the preset does not exist yet (`missing_preset`).
public enum ResolveDesqueeze {
    /// One mounted anamorphic shoot: its mount point path (no trailing slash) and its squeeze factor.
    public struct Target: Equatable, Hashable, Sendable {
        public let prefix: String
        public let factor: Int
        public init(prefix: String, factor: Int) {
            self.prefix = prefix.count > 1 && prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            self.factor = factor
        }
    }

    /// Counts printed by the script.
    public struct Report: Equatable, Sendable {
        public var applied = 0
        public var already = 0
        public var otherPreset = 0
        public var missingPreset: [Int] = []
        public var noResolve = false
        public var noProject = false
        public var dryRun = false
        public var product = ""
        public init(applied: Int = 0, already: Int = 0, otherPreset: Int = 0, missingPreset: [Int] = [],
                    noResolve: Bool = false, noProject: Bool = false, dryRun: Bool = false, product: String = "") {
            self.applied = applied
            self.already = already
            self.otherPreset = otherPreset
            self.missingPreset = missingPreset
            self.noResolve = noResolve
            self.noProject = noProject
            self.dryRun = dryRun
            self.product = product
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The script ran and printed its RESULT line (which may say Resolve was unreachable).
        case report(Report)
        /// fuscript did not finish within the timeout.
        case timedOut
        /// No fuscript: Resolve is not installed where expected.
        case notInstalled
        /// The script printed an ERROR line, garbage, or could not be launched.
        case failed(String)

        /// Studio answered (the scripting connection works), whatever the counts.
        public var reachedResolve: Bool {
            if case let .report(r) = self { return !r.noResolve }
            return false
        }
    }

    public enum RunError: LocalizedError, Equatable {
        case timedOut
        case notInstalled
        case launch(String)

        public var errorDescription: String? {
            switch self {
            case .timedOut:
                return String(localized: "Resolve stopped reporting progress before the timeout. The project may be partially prepared; check it in Resolve before trying again.", bundle: L10n.bundle)
            case .notInstalled:
                return String(localized: "Resolve scripting executable was not found.", bundle: L10n.bundle)
            case .launch(let detail): return detail
            }
        }
    }

    /// Runs a Lua script and returns everything it printed (stdout + stderr).
    public typealias Runner = @Sendable (_ script: String) async throws -> String

    public static let defaultTimeout: TimeInterval = 20

    public static func presetName(_ factor: Int) -> String { "mlv2Resolve 1x\(factor)" }

    /// The menu script Resolve lists under Workspace → Scripts.
    public static let menuScriptName = "mlv2Resolve Desqueeze.lua"

    /// `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility`.
    public static var menuScriptsDirectory: URL {
        resolveSupportDirectory.appendingPathComponent("Fusion/Scripts/Utility", isDirectory: true)
    }

    /// Resolve's per-user support folder; it exists once Resolve has been run.
    public static var resolveSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Blackmagic Design/DaVinci Resolve", isDirectory: true)
    }

    static let log = Logger(subsystem: "net.mlv2dng.app", category: "resolve")

    // MARK: Running

    /// Generates the script for `targets`, runs it and parses its output. Never throws.
    public static func run(targets: [Target], dryRun: Bool = false, runner: Runner) async -> Outcome {
        let output: String
        do {
            output = try await runner(script(targets: targets, dryRun: dryRun))
        } catch RunError.timedOut {
            return .timedOut
        } catch RunError.notInstalled {
            return .notInstalled
        } catch {
            return .failed(String(describing: error))
        }
        return parse(output)
    }

    /// Locates `fuscript` inside the installed Resolve at each call (Resolve may be installed or moved later).
    public static func fuscriptURL(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        let apps = [
            "/Applications/DaVinci Resolve/DaVinci Resolve.app",
            "/Applications/DaVinci Resolve Studio/DaVinci Resolve Studio.app",
        ]
        return apps.map { URL(fileURLWithPath: $0).appendingPathComponent("Contents/Libraries/Fusion/fuscript") }
            .first { fileExists($0.path) }
    }

    /// The real runner: writes the script to a temporary file and runs `fuscript -l lua <file>`, killing it after
    /// `timeout` seconds (of silence when `resetTimeoutOnOutput` is enabled). Runs off the caller's thread.
    public static func fuscriptRunner(timeout: TimeInterval = defaultTimeout, resetTimeoutOnOutput: Bool = false,
                                      onOutput: (@Sendable (String) -> Void)? = nil,
                                      locate: @escaping @Sendable () -> URL? = { fuscriptURL() }) -> Runner {
        { script in
            guard let fuscript = locate() else { throw RunError.notInstalled }
            return try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(with: Result { try runProcess(fuscript, script: script, timeout: timeout, resetTimeoutOnOutput: resetTimeoutOnOutput, onOutput: onOutput) })
                }
            }
        }
    }

    static func runProcess(_ executable: URL, script: String, timeout: TimeInterval, resetTimeoutOnOutput: Bool = false, onOutput: (@Sendable (String) -> Void)? = nil) throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlv2Resolve-desqueeze-\(UUID().uuidString).lua")
        do { try script.write(to: file, atomically: true, encoding: .utf8) } catch {
            throw RunError.launch(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process()
        p.executableURL = executable
        p.arguments = ["-l", "lua", file.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw RunError.launch(error.localizedDescription) }
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let lastOutput = OSAllocatedUnfairLock(initialState: ProcessInfo.processInfo.systemUptime)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + timeout, repeating: min(1, timeout))
        timer.setEventHandler {
            guard p.isRunning,
                  ProcessInfo.processInfo.systemUptime - lastOutput.withLock({ $0 }) >= timeout else { return }
            timedOut.withLock { $0 = true }
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
        timer.resume()
        defer { timer.cancel() }
        var data = Data()
        var pending = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if resetTimeoutOnOutput {
                lastOutput.withLock { $0 = ProcessInfo.processInfo.systemUptime }
            }
            data.append(chunk)
            if let onOutput {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    onOutput(String(decoding: pending[..<newline], as: UTF8.self))
                    pending.removeSubrange(...newline)
                }
            }
        }
        p.waitUntilExit()
        if timedOut.withLock({ $0 }) { throw RunError.timedOut }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Parsing

    /// Reads the last RESULT (or ERROR) line; anything else is a failure carrying the tail of the output.
    public static func parse(_ output: String) -> Outcome {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines.reversed() {
            if line.hasPrefix("RESULT ") { if let r = parseResult(line) { return .report(r) } else { break } }
            if line.hasPrefix("ERROR ") { return .failed(String(line.dropFirst(6))) }
        }
        let tail = lines.filter { !$0.isEmpty }.suffix(3).joined(separator: " / ")
        return .failed(tail.isEmpty ? "no output" : String(tail.prefix(300)))
    }

    static func parseResult(_ line: String) -> Report? {
        var body = Substring(line.dropFirst("RESULT ".count))
        var r = Report()
        // `product=` is last and may contain spaces.
        if let range = body.range(of: " product=") ?? (body.hasPrefix("product=") ? body.range(of: "product=") : nil) {
            r.product = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            body = body[..<range.lowerBound]
        }
        var seen = Set<String>()
        for field in body.split(separator: " ") {
            let kv = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { return nil }
            let key = String(kv[0]), value = String(kv[1])
            seen.insert(key)
            switch key {
            case "applied": guard let n = Int(value), n >= 0 else { return nil }; r.applied = n
            case "already": guard let n = Int(value), n >= 0 else { return nil }; r.already = n
            case "other_preset": guard let n = Int(value), n >= 0 else { return nil }; r.otherPreset = n
            case "missing_preset":
                let parts = value.split(separator: ",")
                let factors = parts.compactMap { Int($0) }
                guard factors.count == parts.count else { return nil }
                r.missingPreset = Array(Set(factors)).sorted()
            case "no_resolve": r.noResolve = value == "1"
            case "no_project": r.noProject = value == "1"
            case "dry_run": r.dryRun = value == "1"
            default: break // forward compatible
            }
        }
        guard seen.isSuperset(of: ["applied", "already", "other_preset", "missing_preset", "no_resolve"]) else { return nil }
        return r
    }

    // MARK: Lua generation

    /// Lua long-bracket literal `[==[ … ]==]` with the lowest level whose closing bracket cannot occur early.
    static func luaString(_ s: String) -> String {
        // A leading newline is dropped by Lua: add one so it survives.
        let body = s.hasPrefix("\n") || s.hasPrefix("\r") ? "\n" + s : s
        var level = 0
        while true {
            let eq = String(repeating: "=", count: level)
            let close = "]" + eq + "]"
            let combined = body + close
            if let first = combined.range(of: close),
               combined.utf8.distance(from: combined.utf8.startIndex, to: first.lowerBound) == body.utf8.count {
                return "[" + eq + "[" + body + close
            }
            level += 1
        }
    }

    /// The prefixes the script matches: each mount path, plus its decomposed (NFD) spelling when it differs, in
    /// case Resolve reports paths decomposed.
    static func matchList(_ targets: [Target]) -> [Target] {
        var out: [Target] = []
        var seen = Set<String>()
        for t in targets.sorted(by: { ($0.prefix, $0.factor) < ($1.prefix, $1.factor) }) {
            for p in [t.prefix.precomposedStringWithCanonicalMapping, t.prefix.decomposedStringWithCanonicalMapping, t.prefix]
            where !p.isEmpty && seen.insert(p).inserted {
                out.append(Target(prefix: p, factor: t.factor))
            }
        }
        return out
    }

    /// The self-contained script. `summary` adds a human summary printed after the RESULT line (Resolve menu script).
    public static func script(targets: [Target], dryRun: Bool = false, summary: Summary? = nil) -> String {
        var lua = """
        -- mlv2Resolve Desqueeze
        -- Generated by mlv2Resolve. Applies the Input Sizing preset "mlv2Resolve 1x<N>" to the media pool clips of the
        -- current project that come from anamorphic shoots mounted by mlv2Resolve. Clips on another preset are left alone.
        -- Rewritten by mlv2Resolve whenever the mounted anamorphic shoots change: edits will be lost.
        local DRY_RUN = \(dryRun ? "true" : "false")
        local TARGETS = {

        """
        for t in matchList(targets) {
            lua += "  { prefix = \(luaString(t.prefix)), factor = \(t.factor) },\n"
        }
        lua += "}\n"
        if let summary {
            lua += summary.lua(factors: Array(Set(targets.map(\.factor))).sorted())
        } else {
            lua += "local SUMMARY = nil\n"
        }
        lua += """
        local s = { applied = 0, already = 0, other = 0, missing = {}, no_resolve = 0, no_project = 0, product = "" }

        local function connect()
          -- fuscript exposes globals through the script environment; rawget(_G, ...)
          -- bypasses that environment and can hide an available Resolve connection.
          local r = resolve
          if r == nil then
            local ok, v = pcall(function() return Resolve() end)
            if ok then r = v end
          end
          return r
        end

        local function prop(item, key)
          local ok, v = pcall(function() return item:GetClipProperty(key) end)
          if not ok or v == nil then return nil end
          if type(v) == "table" then v = v[key] end
          if v == nil then return nil end
          return tostring(v)
        end

        local function factorFor(path)
          for _, t in ipairs(TARGETS) do
            local p = t.prefix .. "/"
            if path:sub(1, #p) == p then return t.factor end
          end
          return nil
        end

        local timelineItems = {}
        local function indexTimelines(project)
          -- Older hosts may not expose timeline traversal; retain the media-pool preset path there.
          local ok, count = pcall(function() return project:GetTimelineCount() end)
          if not ok or not count then return end
          for n=1,count do
            local timeline=project:GetTimelineByIndex(n)
            for track=1,timeline:GetTrackCount("video") do
              for _,entry in ipairs(timeline:GetItemListInTrack("video",track) or {}) do
                local media=entry:GetMediaPoolItem()
                local path=media and prop(media,"File Path")
                if path and factorFor(path) then
                  timelineItems[path]=timelineItems[path] or {}
                  table.insert(timelineItems[path],{item=entry,timeline=timeline})
                end
              end
            end
          end
        end
        local function fitTimeline(media,path,factor)
          local entries=timelineItems[path]
          if not entries or #entries==0 then return nil end
          local resolution=prop(media,"Resolution") or ""
          local width,height=resolution:match("(%d+)%s*x%s*(%d+)")
          width,height=tonumber(width),tonumber(height)
          if not width or not height or width<=0 or height<=0 then return nil end
          local changed,other=false,false
          for _,entry in ipairs(entries) do
            local item,timeline=entry.item,entry.timeline
            local x,y=tonumber(item:GetProperty("ZoomX")),tonumber(item:GetProperty("ZoomY"))
            if x and y and y~=0 and math.abs(x/y-factor)<0.0001 then
              -- Already desqueezed; preserve a user's subsequent crop/zoom.
            elseif x and y and math.abs(x-1)<0.0001 and math.abs(y-1)<0.0001 then
              local tw=tonumber(timeline:GetSetting("timelineResolutionWidth"))
              local th=tonumber(timeline:GetSetting("timelineResolutionHeight"))
              if not tw or not th or tw<=0 or th<=0 then return nil end
              local rawFit=math.min(tw/width,th/height)
              local zoom=math.min(1,math.min(tw/(width*factor),th/height)/rawFit)
              if not DRY_RUN and (not item:SetProperty("ZoomGang",false) or
                  not item:SetProperty("ZoomX",factor*zoom) or not item:SetProperty("ZoomY",zoom)) then return "failed" end
              changed=true
            else other=true end
          end
          if other then return "other" end
          return changed and "applied" or "already"
        end

        local function visit(folder)
          local clips = folder:GetClipList() or {}
          -- Resolve lists can also carry numeric metadata such as __flags.
          -- Only the indexed list entries are media-pool objects.
          for _, item in ipairs(clips) do
            local path = prop(item, "File Path")
            -- Mounted folders also contain WAV audio and GIF previews. A refusal
            -- on those is not evidence that a DNG sizing preset is missing.
            local f = path and path:lower():match("%.dng$") and factorFor(path)
            if f then
              local want = "mlv2Resolve 1x" .. f
              local cur = prop(item, "Input Sizing Preset")
              if cur == "" or cur == "None" then cur = nil end
              local fitted = cur == nil and fitTimeline(item,path,f) or nil
              if fitted == "applied" then s.applied = s.applied + 1
              elseif fitted == "already" then s.already = s.already + 1
              elseif fitted == "other" then s.other = s.other + 1
              elseif fitted == "failed" then s.missing[f] = true
              elseif cur == want then
                s.already = s.already + 1
              elseif cur ~= nil then
                s.other = s.other + 1
              elseif s.missing[f] then
                -- this preset is known to be missing: no point trying again
              elseif DRY_RUN then
                s.applied = s.applied + 1
              else
                local ok, done = pcall(function() return item:SetClipProperty("Input Sizing Preset", want) end)
                if ok and done then s.applied = s.applied + 1 else s.missing[f] = true end
              end
            end
          end
          for _, sub in ipairs(folder:GetSubFolderList() or {}) do visit(sub) end
        end

        local function main()
          local r = connect()
          if r == nil then s.no_resolve = 1; return end
          local okp, name = pcall(function() return r:GetProductName() end)
          if okp and name ~= nil then s.product = tostring(name) end
          local pm = r:GetProjectManager()
          local project = pm and pm:GetCurrentProject()
          if project == nil then s.no_project = 1; return end
          local pool = project:GetMediaPool()
          local root = pool and pool:GetRootFolder()
          if root == nil then s.no_project = 1; return end
          indexTimelines(project)
          visit(root)
        end

        local ok, err = pcall(main)
        if not ok then
          print("ERROR " .. string.gsub(tostring(err), "%c", " "))
        else
          local m = {}
          for f in pairs(s.missing) do m[#m + 1] = f end
          table.sort(m)
          print(string.format("RESULT applied=%d already=%d other_preset=%d missing_preset=%s no_resolve=%d no_project=%d dry_run=%d product=%s",
            s.applied, s.already, s.other, table.concat(m, ","), s.no_resolve, s.no_project, DRY_RUN and 1 or 0,
            (string.gsub(s.product, "%c", " "))))
          if SUMMARY then SUMMARY.show(s, m) end
        end

        """
        return lua
    }

    /// Writes the Resolve menu script (Workspace → Scripts → mlv2Resolve Desqueeze) into `dir`, creating the folders.
    /// Only touches that one file. Failures are logged, never thrown.
    @discardableResult
    public static func installMenuScript(targets: [Target], in dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let text = script(targets: targets, summary: .current(againHint: .menuScript))
            try text.write(to: dir.appendingPathComponent(menuScriptName), atomically: true, encoding: .utf8)
            return true
        } catch {
            log.error("Couldn't write the Resolve menu script: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: User messages

    public enum AgainHint: Sendable { case app, menuScript }

    /// Text and severity for the NSAlert shown after a run.
    public static func message(for outcome: Outcome, targets: [Target]) -> (text: String, isError: Bool) {
        let factors = Array(Set(targets.map(\.factor))).sorted()
        let width = factors.isEmpty ? "3" : factors.map(String.init).joined(separator: " / ")
        switch outcome {
        case .report(let r) where r.noResolve:
            return (noConnection(width: width), true)
        case .report(let r) where r.noProject:
            return (noProjectText(), true)
        case .report(let r):
            let lines = summaryLines(applied: r.applied, already: r.already, other: r.otherPreset,
                                     missing: r.missingPreset, factors: factors, again: .app)
            return (lines.joined(separator: "\n\n"), !r.missingPreset.isEmpty)
        case .timedOut:
            return (String(localized: "DaVinci Resolve didn't answer in time.", bundle: L10n.bundle) + " "
                    + noConnection(width: width), true)
        case .notInstalled:
            return (noConnection(width: width), true)
        case .failed(let detail):
            return (String(localized: "The Resolve desqueeze script failed.", bundle: L10n.bundle) + "\n\n"
                    + String(localized: "Details: \(detail)", bundle: L10n.bundle), true)
        }
    }

    /// Shared by the app alert and (as templates) the Lua summary, so both say the same thing.
    static func summaryLines(applied: Int, already: Int, other: Int, missing: [Int], factors: [Int],
                             again: AgainHint) -> [String] {
        var lines: [String] = []
        let missingSet = Set(missing)
        let presets = quotedList(factors.filter { !missingSet.contains($0) })
        if applied == 1 { lines.append(appliedOneText(presets: presets)) }
        else if applied > 1 { lines.append(appliedManyText(n: "\(applied)", presets: presets)) }
        else if already > 0 && missing.isEmpty { lines.append(alreadyText()) }
        if other == 1 { lines.append(keptOneText()) } else if other > 1 { lines.append(keptManyText(n: "\(other)")) }
        if !missing.isEmpty {
            lines.append(missingIntroText(presets: quotedList(missing)))
            for f in missing { lines.append(missingStepText(factor: "\(f)", preset: presetName(f))) }
            lines.append(againText(again))
        }
        if lines.isEmpty { lines.append(nothingText()) }
        return lines
    }

    static func quotedList(_ factors: [Int]) -> String {
        factors.map { String(localized: "“\(presetName($0))”", bundle: L10n.bundle) }.joined(separator: ", ")
    }

    static func appliedOneText(presets: String) -> String {
        String(localized: "1 clip desqueezed in Resolve.", bundle: L10n.bundle)
    }
    static func appliedManyText(n: String, presets: String) -> String {
        String(localized: "\(n) clips desqueezed in Resolve.", bundle: L10n.bundle)
    }
    static func keptOneText() -> String {
        String(localized: "1 clip kept its own sizing preset.", bundle: L10n.bundle)
    }
    static func keptManyText(n: String) -> String {
        String(localized: "\(n) clips kept their own sizing preset.", bundle: L10n.bundle)
    }
    static func alreadyText() -> String { String(localized: "Already done.", bundle: L10n.bundle) }
    static func nothingText() -> String {
        String(localized: "No anamorphic clip from mlv2Resolve found in the open project.", bundle: L10n.bundle)
    }
    static func missingIntroText(presets: String) -> String {
        String(localized: "Resolve has no Input Sizing preset named \(presets) yet. Create it once:", bundle: L10n.bundle)
    }
    static func missingStepText(factor: String, preset: String) -> String {
        String(localized: "In Resolve: Color page → select a 1x\(factor) clip → Sizing → Input Sizing → set Width to \(factor) → … menu → save as a new preset named “\(preset)”.", bundle: L10n.bundle)
    }
    static func againText(_ hint: AgainHint) -> String {
        switch hint {
        case .app: return String(localized: "Then click Desqueeze in Resolve again.", bundle: L10n.bundle)
        case .menuScript: return String(localized: "Then run Workspace → Scripts → mlv2Resolve Desqueeze again.", bundle: L10n.bundle)
        }
    }
    static func noProjectText() -> String {
        String(localized: "Open a project in DaVinci Resolve, then try again.", bundle: L10n.bundle)
    }
    static func noConnection(width: String) -> String {
        String(localized: "Couldn't talk to DaVinci Resolve. Automatic desqueeze needs DaVinci Resolve Studio running with a project open, and Preferences → System → General → External scripting using: Local. With the free version, set it by hand: Color page → Sizing → Input Sizing → Width = \(width).", bundle: L10n.bundle)
    }

    /// Appended to the manual 1x<N> hint once Studio is known to answer in this session.
    public static func hintSuffix() -> String {
        String(localized: "Or use Desqueeze in Resolve.", bundle: L10n.bundle)
    }

    /// Localized templates for the Lua summary (`{1}`, `{2}` are filled in by the script).
    public struct Summary: Equatable, Sendable {
        var appliedOne, appliedMany, keptOne, keptMany, already, nothing, missingIntro, missingStep, again, noProject: String
        var noResolve: String

        public static func current(againHint: AgainHint) -> Summary {
            Summary(appliedOne: appliedOneText(presets: "{1}"), appliedMany: appliedManyText(n: "{1}", presets: "{2}"),
                    keptOne: keptOneText(), keptMany: keptManyText(n: "{1}"), already: alreadyText(),
                    nothing: nothingText(), missingIntro: missingIntroText(presets: "{1}"),
                    missingStep: missingStepText(factor: "{1}", preset: "{2}"), again: againText(againHint),
                    noProject: noProjectText(), noResolve: noConnection(width: "{1}"))
        }

        func lua(factors: [Int]) -> String {
            var q: [Int: String] = [:]
            for f in factors { q[f] = String(localized: "“\(presetName(f))”", bundle: L10n.bundle) }
            let width = factors.isEmpty ? "3" : factors.map(String.init).joined(separator: " / ")
            var lua = "local QUOTED = {\n"
            for f in q.keys.sorted() { lua += "  [\(f)] = \(luaString(q[f]!)),\n" }
            lua += "}\nlocal T = {\n"
            for (k, v) in [("applied_one", appliedOne), ("applied_many", appliedMany), ("kept_one", keptOne),
                           ("kept_many", keptMany), ("already", already), ("nothing", nothing),
                           ("missing_intro", missingIntro), ("missing_step", missingStep), ("again", again),
                           ("no_project", noProject), ("no_resolve", noResolve.replacingOccurrences(of: "{1}", with: width))] {
                lua += "  \(k) = \(luaString(v)),\n"
            }
            lua += """
            }
            local function fmt(t, a, b)
              local r = string.gsub(t, "{1}", function() return tostring(a or "") end)
              r = string.gsub(r, "{2}", function() return tostring(b or "") end)
              return r
            end
            local function quotedList(list)
              local out = {}
              for _, f in ipairs(list) do out[#out + 1] = QUOTED[f] or ("mlv2Resolve 1x" .. f) end
              return table.concat(out, ", ")
            end
            local SUMMARY = {}
            function SUMMARY.show(s, missing)
              local lines = {}
              if s.no_resolve == 1 then
                lines[1] = T.no_resolve
              elseif s.no_project == 1 then
                lines[1] = T.no_project
              else
                local isMissing, ok = {}, {}
                for _, f in ipairs(missing) do isMissing[f] = true end
                local seen = {}
                for _, t in ipairs(TARGETS) do
                  if not isMissing[t.factor] and not seen[t.factor] then seen[t.factor] = true; ok[#ok + 1] = t.factor end
                end
                table.sort(ok)
                local presets = quotedList(ok)
                if s.applied == 1 then lines[#lines + 1] = fmt(T.applied_one, presets)
                elseif s.applied > 1 then lines[#lines + 1] = fmt(T.applied_many, s.applied, presets)
                elseif s.already > 0 and #missing == 0 then lines[#lines + 1] = T.already end
                if s.other == 1 then lines[#lines + 1] = T.kept_one
                elseif s.other > 1 then lines[#lines + 1] = fmt(T.kept_many, s.other) end
                if #missing > 0 then
                  lines[#lines + 1] = fmt(T.missing_intro, quotedList(missing))
                  for _, f in ipairs(missing) do lines[#lines + 1] = fmt(T.missing_step, f, "mlv2Resolve 1x" .. f) end
                  lines[#lines + 1] = T.again
                end
                if #lines == 0 then lines[1] = T.nothing end
              end
              print("")
              print("mlv2Resolve: " .. table.concat(lines, "\\n\\n"))
            end

            """
            return lua
        }
    }
}
