// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A snapshot of the mounted media; the same worker is used externally and from Resolve's Scripts menu.
public enum ResolveProject {
    public struct Media: Equatable, Sendable {
        public let name: String
        public let directory: String
        public let pattern: String
        public let first: Int
        public let last: Int
        public let wav: String?
        public let width: Int
        public let height: Int
        public let factor: Int
        public let fps: Double
        public init(name: String, directory: String, pattern: String, first: Int, last: Int, wav: String?,
                    width: Int, height: Int, factor: Int, fps: Double) {
            self.name = name; self.directory = directory; self.pattern = pattern; self.first = first; self.last = last
            self.wav = wav; self.width = width; self.height = height; self.factor = factor; self.fps = fps
        }
    }
    public struct ShootMedia: Equatable, Sendable {
        public let name: String
        public let source: String
        public let sources: [String]
        public let media: [Media]
        public let warnings: [String]
        public init(name: String, media: [Media], warnings: [String] = [], source: String? = nil, sources: [String]? = nil) {
            self.name = name; self.source = source ?? name; self.media = media; self.warnings = warnings
            self.sources = sources ?? [source ?? name]
        }
    }
    /// One creation action combines all mounted folders; format voting includes every clip.
    public static func combined(_ shoots: [ShootMedia], name: String) -> [ShootMedia] {
        guard let first = shoots.first else { return [] }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return [.init(name: trimmed.isEmpty ? "mlv2Resolve" : trimmed,
                      media: shoots.flatMap(\.media),
                      warnings: shoots.flatMap { shoot in shoot.warnings.map { shoot.name + ": " + $0 } },
                      source: first.source, sources: shoots.flatMap(\.sources))]
    }
    public struct Format: Equatable, Sendable {
        public let width: Int, height: Int
        public let fps: Double
        public let differentFPS: [String]
    }
    public struct Sequence: Equatable, Sendable {
        public let pattern: String
        public let first: Int, last: Int
        public let wav: String?
    }
    public static let menuScriptName = "mlv2Resolve.lua"
    public static var projectTemplateURL: URL { Bundle.module.url(forResource: "resolve-project-cst", withExtension: "drp")! }
    public static var gyroTemplateURL: URL { Bundle.module.url(forResource: "resolve-clip-gyro", withExtension: "drt")! }
    public static var timelineTemplateURL: URL { Bundle.module.url(forResource: "resolve-timeline-cst", withExtension: "drt")! }

    /// The most frequent desqueezed resolution wins; tied counts use the largest resolution.
    /// Cadence is rounded to 0.001 fps to absorb header noise.
    public static func format(_ media: [Media], timelineSize: ResolveTimelineSize = .automatic, frameRate: Double? = nil) -> Format? {
        let valid = media.filter { $0.width > 0 && $0.height > 0 && $0.factor > 0 && $0.fps.isFinite && $0.fps > 0 }
        guard !valid.isEmpty else { return nil }
        struct Size: Hashable { let width: Int, height: Int }
        let sizes = Dictionary(grouping: valid) { Size(width: $0.width * $0.factor, height: $0.height) }
        let winner = sizes.max { a, b in
            if a.value.count != b.value.count { return a.value.count < b.value.count }
            let aPixels = a.key.width * a.key.height, bPixels = b.key.width * b.key.height
            return aPixels == bPixels ? a.key.width < b.key.width : aPixels < bPixels
        }!.key
        let rates = valid.map { ($0.fps * 1000).rounded() / 1000 }
        let counts = Dictionary(grouping: rates, by: { $0 }).mapValues(\.count)
        let maxCount = counts.values.max()!
        let majorityFPS = rates.first { counts[$0] == maxCount }!
        let fps = frameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? majorityFPS
        let size = timelineSize == .hd ? (1920, 1080) : timelineSize == .uhd ? (3840, 2160) : (winner.width, winner.height)
        return Format(width: size.0, height: size.1, fps: fps,
                      differentFPS: valid.filter { abs($0.fps - fps) > 0.001 }.map(\.name))
    }

    /// Input Sizing expands after scale-to-fit: correct the cropped dimension, including tall frames.
    public static func uhdZoom(_ c: Media) -> Double {
        let rawFit = min(3840 / Double(c.width), 2160 / Double(c.height))
        return min(1, min(3840 / (Double(c.width * c.factor) * rawFit), 2160 / (Double(c.height) * rawFit)))
    }

    /// A per-format variant is needed only when fitting RAW pixels then desqueezing would crop.
    /// Close camera ratios keep the ordinary preset (4.8K / 5.2K differ by less than 0.1%).
    public static func sizing(for c: Media, format: Format) -> ResolvePresets.Sizing {
        let rawFit = min(Double(format.width) / Double(c.width), Double(format.height) / Double(c.height))
        let fullFit = min(Double(format.width) / Double(c.width * c.factor), Double(format.height) / Double(c.height))
        let zoom = min(1, fullFit / rawFit)
        if zoom > 0.995 { return .standard(c.factor) }
        return .init(name: ResolveDesqueeze.presetName(c.factor) + " Fit \(format.width)x\(format.height) \(c.width)x\(c.height)",
                     factor: c.factor, zoom: zoom)
    }

    public static func sizingPresets(shoots: [ShootMedia], timelineSize: ResolveTimelineSize = .automatic) -> [ResolvePresets.Sizing] {
        var presets = Set<ResolvePresets.Sizing>()
        for shoot in shoots {
            // Any source resolution may have been the majority on the project's first run.
            // Preinstall these variants while Resolve is closed; later runs read the project's actual size.
            var formats = shoot.media.map { Format(width: $0.width * $0.factor, height: $0.height, fps: $0.fps, differentFPS: []) }
            formats += [Format(width: 3840, height: 2160, fps: 25, differentFPS: []), Format(width: 1920, height: 1080, fps: 25, differentFPS: [])]
            for c in shoot.media where c.factor > 1 {
                presets.insert(.standard(c.factor))
                for format in formats { presets.insert(sizing(for: c, format: format)) }
            }
        }
        return presets.sorted { $0.name < $1.name }
    }

    public static func sequence(in directory: URL) -> Sequence? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let re = try! NSRegularExpression(pattern: "^(.*)_([0-9]{6})\\.[dD][nN][gG]$")
        let frames: [(URL, String, Int)] = files.compactMap { url in
            let n = url.lastPathComponent as NSString
            guard let m = re.firstMatch(in: n as String, range: NSRange(location: 0, length: n.length)),
                  let index = Int(n.substring(with: m.range(at: 2))) else { return nil }
            return (url, n.substring(with: m.range(at: 1)), index)
        }.sorted { $0.2 < $1.2 }
        guard let first = frames.first, let last = frames.last, frames.allSatisfy({ $0.1 == first.1 }) else { return nil }
        let wav = files.first { $0.pathExtension.lowercased() == "wav" && $0.deletingPathExtension().lastPathComponent == first.1 }
        return Sequence(pattern: directory.appendingPathComponent(first.1 + "_%06d." + first.0.pathExtension).path,
                        first: first.2, last: last.2, wav: wav.map { directory.appendingPathComponent($0.lastPathComponent).path })
    }

    /// Blocking filesystem/header work; callers run this off the main actor. Uses the mount's correction map.
    public static func discover(_ shoot: Shoot, mount: URL, corrections: [String: Int]) -> ShootMedia {
        var media: [Media] = [], warnings: [String] = []
        for clip in shoot.clips {
            guard let mlv = clip.files.first,
                  let directory = GyroSyncCoordinator.clipDir(mountPoint: mount, mlv: mlv),
                  let seq = sequence(in: directory), let metadata = MLVHeader.videoFormat(of: mlv) else {
                warnings.append(clip.name); continue
            }
            let factor = corrections[SqueezeFix.relativeName(of: mlv, in: shoot.folder)] ?? MLVHeader.horizontalSqueeze(of: mlv) ?? 1
            media.append(Media(name: clip.name, directory: directory.path, pattern: seq.pattern, first: seq.first,
                               last: seq.last, wav: seq.wav, width: metadata.width, height: metadata.height,
                               factor: factor, fps: metadata.fps))
        }
        return ShootMedia(name: shoot.name, media: media, warnings: warnings, source: shoot.folder.standardizedFileURL.path)
    }

    public static func script(shoots: [ShootMedia], approvedCurrent: String? = nil, menu: Bool = false, timelineSize: ResolveTimelineSize = .automatic, createOnly: Bool = false, receiptsURL: URL? = nil, includeAllShots: Bool = true, timelineName: String = "All shots", frameRate: Double? = nil) -> String {
        let quote = ResolveDesqueeze.luaString
        var lua = "local SHOOTS = {\n"
        for shoot in shoots {
            let f = format(shoot.media, timelineSize: timelineSize, frameRate: frameRate) ?? Format(width: 0, height: 0, fps: 25, differentFPS: [])
            lua += "{name=\(quote(shoot.name)),source=\(quote(shoot.source)),sources={\(shoot.sources.map(quote).joined(separator: ","))},width=\(f.width),height=\(f.height),fps=\(f.fps),clips={\n"
            for c in shoot.media {
                lua += "{name=\(quote(c.name)),dir=\(quote(c.directory)),nfd=\(quote(c.directory.decomposedStringWithCanonicalMapping)),path=\(quote(c.pattern)),first=\(c.first),last=\(c.last),wav=\(c.wav.map(quote) ?? "nil"),factor=\(c.factor),width=\(c.width),height=\(c.height),zoom=\(uhdZoom(c))},\n"
            }
            lua += "},warnings={\((shoot.warnings + f.differentFPS.map { $0 + " (fps)" }).map(quote).joined(separator: ","))}},\n"
        }
        lua += "}\nlocal APPROVED = \(approvedCurrent.map(quote) ?? "nil")\nlocal MENU = \(menu)\n"
        lua += "local TEXT = {switch=\(quote(text("Switch Resolve project?", "Changer de projet Resolve ?"))),cancel=\(quote(text("Cancel", "Annuler"))),open=\(quote(text("Open", "Ouvrir"))),guide=\(quote(guide)),done=\(quote(text("Project preparation finished. See the console for details.", "Préparation terminée. Consultez la console pour le détail.")))}\n"
        lua += "local PROJECT_TEMPLATE = \(quote(projectTemplateURL.path))\nlocal TIMELINE_TEMPLATE = \(quote(timelineTemplateURL.path))\nlocal GYRO_TEMPLATE = \(quote(gyroTemplateURL.path))\nlocal INCLUDE_ALL_SHOTS = \(includeAllShots)\nlocal TIMELINE_NAME = \(quote(timelineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "All shots" : timelineName.trimmingCharacters(in: .whitespacesAndNewlines)))\nlocal CREATE_ONLY = \(createOnly)\nlocal RECEIPTS = \(receiptsURL.map { quote($0.path) } ?? "nil")\n"
        let url = Bundle.module.url(forResource: "resolve-project", withExtension: "lua")!
        return lua + (try! String(contentsOf: url, encoding: .utf8))
    }

    public static func openScript(link: ResolveProjectStore.Link, approvedCurrent: String? = nil, menu: Bool = false) -> String {
        let q = ResolveDesqueeze.luaString
        let prefix = """
        local TARGET = \(q(link.name))
        local DATABASE = \(q(link.database))
        local FOLDERS = {\(link.folder.map(q).joined(separator: ","))}
        local APPROVED = \(approvedCurrent.map(q) ?? "nil")
        local MENU = \(menu)
        local TEXT = {switch=\(q(text("Save current project and open", "Enregistrer le projet actuel et ouvrir"))),cancel=\(q(text("Cancel", "Annuler"))),open=\(q(text("Open", "Ouvrir")))}
        """
        let url = Bundle.module.url(forResource: "resolve-open", withExtension: "lua")!
        return prefix + "\n" + (try! String(contentsOf: url, encoding: .utf8))
    }

    @MainActor
    public static func open(link: ResolveProjectStore.Link, runner: ResolveDesqueeze.Runner,
                            confirmSwitch: (String, String) async -> Bool) async -> (text: String, isError: Bool) {
        var approved: String?
        for _ in 0..<4 {
            do {
                let output = try await runner(openScript(link: link, approvedCurrent: approved))
                if output.split(whereSeparator: \.isNewline).contains("OPENED") {
                    return (text("Project opened: ", "Projet ouvert : ") + link.name, false)
                }
                if case .switchProject(let current) = parse(output) {
                    guard await confirmSwitch(current, link.name) else { return message(.cancelled) }
                    approved = current
                } else { return message(parse(output)) }
            } catch { return (error.localizedDescription, true) }
        }
        return message(.failed(text("The active project kept changing. Try again.", "Le projet actif a changé plusieurs fois. Réessayez.")))
    }

    public enum Outcome: Equatable, Sendable {
        case unavailable
        case cancelled
        case switchProject(String)
        case report(imported: Int, already: Int, failed: Int, missing: Int, studio: Bool, warnings: [String])
        case failed(String)
    }
    public static func parse(_ output: String) -> Outcome {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines.reversed() {
            if line == "NO_RESOLVE" { return .unavailable }
            if line.hasPrefix("SWITCH ") { return .switchProject(String(line.dropFirst(7))) }
            if line.hasPrefix("ERROR ") { return .failed(String(line.dropFirst(6))) }
            if line.hasPrefix("PROJECT ") {
                var values: [String: Int] = [:]
                for field in line.dropFirst(8).split(separator: " ") {
                    let kv = field.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2, let n = Int(kv[1]), n >= 0 else { return .failed(line) }
                    values[String(kv[0])] = n
                }
                guard let imported = values["imported"], let already = values["already"], let failed = values["failed"],
                      let missing = values["missing"], let studio = values["studio"], studio <= 1 else { return .failed(line) }
                return .report(imported: imported, already: already, failed: failed, missing: missing, studio: studio == 1,
                               warnings: lines.filter { $0.hasPrefix("WARNING ") }.map { String($0.dropFirst(8)) })
            }
        }
        return .failed(String(output.suffix(500)))
    }

    /// A short-lived probe bounds startup waiting independently of the longer import timeout.
    @MainActor
    public static func waitForConnection(runner: ResolveDesqueeze.Runner, attempts: Int = 30,
                                          retryDelay: Duration = .seconds(2), budget: Duration = .seconds(60)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: budget)
        let probe = """
        local r=resolve
        if not r then local ok,v=pcall(function() return Resolve() end); if ok then r=v end end
        if r then print('CONNECTED') else print('NO_RESOLVE') end
        """
        for index in 0..<max(0, attempts) {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do {
                let output = try await runner(probe)
                if output.split(whereSeparator: \.isNewline).contains("CONNECTED") { return true }
            } catch ResolveDesqueeze.RunError.notInstalled { return false }
            catch { /* Resolve may still be starting. */ }
            guard index + 1 < attempts, ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: min(retryDelay, ContinuousClock.now.duration(to: deadline))) }
            catch { return false }
        }
        return false
    }

    /// Runs shoots separately so approval applies only to the next switch, never to an entire batch.
    @MainActor
    public static func execute(shoots: [ShootMedia], runner: ResolveDesqueeze.Runner,
                               confirmSwitch: (String, String) async -> Bool,
                               connectionAttempts: Int = 30, retryDelay: Duration = .seconds(2),
                               timelineSize: ResolveTimelineSize = .automatic, createOnly: Bool = false,
                               onReceipt: (String) -> Void = { _ in }, includeAllShots: Bool = true, timelineName: String = "All shots", frameRate: Double? = nil) async -> Outcome {
        var imported = 0, already = 0, failed = 0, missing = 0
        var studio = true, warnings: [String] = []
        for shoot in shoots {
            if shoot.media.isEmpty {
                let skipped = shoot.warnings.isEmpty ? [shoot.name] : shoot.warnings
                warnings += skipped.map { shoot.name + ": " + $0 }
                failed += skipped.count
                continue
            }
            var approved: String?
            var attempts = 0
            while true {
                if Task.isCancelled { return .cancelled }
                let outcome: Outcome
                do {
                    let output = try await runner(script(shoots: [shoot], approvedCurrent: approved, timelineSize: timelineSize, createOnly: createOnly, includeAllShots: includeAllShots, timelineName: timelineName, frameRate: frameRate))
                    onReceipt(output)
                    outcome = parse(output)
                }
                catch { return .failed(error.localizedDescription) }
                switch outcome {
                case .unavailable:
                    attempts += 1
                    guard attempts < connectionAttempts else { return .unavailable }
                    do { try await Task.sleep(for: retryDelay) } catch { return .cancelled }
                    continue
                case .switchProject(let current):
                    guard await confirmSwitch(current, shoot.name) else { return .cancelled }
                    approved = current
                    continue
                case let .report(i, a, f, m, isStudio, notes):
                    imported += i; already += a; failed += f; missing += m; studio = isStudio; warnings += notes
                default: return outcome
                }
                break
            }
        }
        return .report(imported: imported, already: already, failed: failed, missing: missing, studio: studio, warnings: warnings)
    }

    public static func message(_ outcome: Outcome) -> (text: String, isError: Bool) {
        switch outcome {
        case .unavailable:
            return (text("Resolve did not connect. With Studio, enable Preferences → System → General → External scripting using: Local, then try again. With the free version, follow this guide.\n\n", "Resolve ne répond pas. Avec Studio, activez Preferences → System → General → External scripting using: Local, puis réessayez. Avec la version gratuite, suivez ce guide.\n\n") + guide, false)
        case .cancelled: return (text("Project switch cancelled.", "Changement de projet annulé."), false)
        case .switchProject: return (text("Project switch needs confirmation.", "Le changement de projet demande confirmation."), true)
        case .failed(let reason): return (text("Resolve project preparation failed: ", "La préparation du projet Resolve a échoué : ") + reason, true)
        case let .report(i, a, f, m, studio, warnings):
            var message = text("Projects ready: ", "Projets prêts : ") + "\(i) " + text("clips imported, ", "plans importés, ") + "\(a) " + text("already present.", "déjà présents.")
            if f > 0 { message += "\n\(f) " + text("clips failed to import.", "plans n’ont pas pu être importés.") }
            if !warnings.isEmpty { message += "\n\n" + warnings.joined(separator: "\n") }
            if m > 0 || !studio { message += "\n\n" + guide }
            return (message, f > 0)
        }
    }

    public static func installMenuScript(shoots: [ShootMedia], in directory: URL, timelineSize: ResolveTimelineSize = .automatic, createOnly: Bool = false, receiptsURL: URL? = nil, includeAllShots: Bool = true, timelineName: String = "All shots", frameRate: Double? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script(shoots: shoots, menu: true, timelineSize: timelineSize, createOnly: createOnly, receiptsURL: receiptsURL, includeAllShots: includeAllShots, timelineName: timelineName, frameRate: frameRate).write(to: directory.appendingPathComponent(menuScriptName), atomically: true, encoding: .utf8)
    }

    static func text(_ en: String, _ fr: String) -> String {
        L10n.bundle.preferredLocalizations.first?.hasPrefix("fr") == true ? fr : en
    }
    public static var guide: String {
        text("Wait for gyro sync to finish. With Resolve Studio, enable Preferences → System → General → External scripting using: Local. With the free version, click the desired action in mlv2Resolve, then run Workspace → Scripts → mlv2Resolve in Resolve. The menu script performs that action.\n\nAll mounted folders are combined in one named project. Size and frame rate are project settings. The portable colour model prepares DWG/Intermediate and the timeline CST nodes.",
             "Attendez la fin de la synchro gyro. Avec Resolve Studio, activez Preferences → System → General → External scripting using: Local. Avec la version gratuite, cliquez sur l’action souhaitée dans mlv2Resolve, puis lancez Workspace → Scripts → mlv2Resolve dans Resolve. Le script exécute cette action.\n\nTous les dossiers montés sont réunis dans un projet nommé. La taille et la cadence sont réglées au niveau du projet. Le modèle couleur portable prépare DWG/Intermediate et les CST de timeline.")
    }
}
