// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Corrects clips whose Magic Lantern header reports the wrong sensor sampling (e.g. a 1x3 anamorphic clip
/// whose RAWC says 1x1), by aligning them on the majority of the shoot.
///
/// Clips are keyed by their MLV path relative to the shoot folder (e.g. `M25-1745.MLV`), the same form the
/// engine's `--sampling-fix` option matches against the path below `--mlv-dir`.
public enum SqueezeFix {
    public typealias Sampling = (x: Int, y: Int, width: Int, height: Int)

    /// Rule: clips are grouped by recorded size (width, height); in a group of at least 3 clips where a strict
    /// majority (> 50 %) shares one sampling, every clip of that group with another sampling is corrected to
    /// it. Smaller groups and groups without a strict majority are left alone. Callers pass only clips that
    /// have a RAWC block (others are never corrected).
    /// - Returns: clip name → corrected sampling (x, y), only for the clips to correct.
    public static func corrections(for clips: [(name: String, sampling: Sampling)]) -> [String: (x: Int, y: Int)] {
        struct Size: Hashable { let w: Int, h: Int }
        struct XY: Hashable { let x: Int, y: Int }
        var out: [String: (x: Int, y: Int)] = [:]
        let groups = Dictionary(grouping: clips) { Size(w: $0.sampling.width, h: $0.sampling.height) }
        for group in groups.values where group.count >= 3 {
            var counts: [XY: Int] = [:]
            for c in group { counts[XY(x: c.sampling.x, y: c.sampling.y), default: 0] += 1 }
            guard let top = counts.max(by: { $0.value < $1.value }), top.value * 2 > group.count else { continue }
            for c in group where XY(x: c.sampling.x, y: c.sampling.y) != top.key {
                out[c.name] = (top.key.x, top.key.y)
            }
        }
        return out
    }

    /// One corrected clip.
    public struct Fix: Equatable, Sendable {
        /// MLV path relative to the shoot folder, e.g. `M25-1745.MLV` (see `relativeName`).
        public let name: String
        /// Sampling the header reports.
        public let fromX: Int, fromY: Int
        /// Corrected sampling.
        public let toX: Int, toY: Int

        public init(name: String, fromX: Int, fromY: Int, toX: Int, toY: Int) {
            self.name = name; self.fromX = fromX; self.fromY = fromY; self.toX = toX; self.toY = toY
        }
        /// Corrected horizontal squeeze (1 when not squeezed horizontally).
        public var squeeze: Int { SqueezeFix.horizontalSqueeze(x: toX, y: toY) ?? 1 }
        /// Clip name without the extension, as shown to the user.
        public var clipName: String { ((name as NSString).lastPathComponent as NSString).deletingPathExtension }
    }

    /// The header corrections of a shoot and its squeeze factor, read once per mount (`analyze`).
    public struct Analysis: Equatable, Sendable {
        /// Corrected clips, sorted by name.
        public let fixes: [Fix]
        /// Squeeze factor of the shoot (nil: not anamorphic): the most common horizontal squeeze of its clips
        /// once corrected; on a tie, the earliest clip's.
        public let squeeze: Int?
        public static let none = Analysis(fixes: [], squeeze: nil)

        public init(fixes: [Fix], squeeze: Int?) { self.fixes = fixes; self.squeeze = squeeze }
        /// Corrected squeeze by `Fix.name` (relative MLV path).
        public var squeezeByName: [String: Int] {
            Dictionary(fixes.map { ($0.name, $0.squeeze) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Path of a clip's MLV relative to the shoot folder (the `--mlv-dir`), e.g. `M25-1745.MLV` — the form the
    /// engine's `--sampling-fix` matches. Falls back to the file name for a file outside the folder.
    public static func relativeName(of mlv: URL, in folder: URL) -> String {
        let root = folder.standardizedFileURL.path, path = mlv.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : mlv.lastPathComponent
    }

    /// Whether a name can travel in the engine option (`,` separates entries, `:` the sampling). Clips whose
    /// name contains either are never corrected (Magic Lantern never writes such names).
    static func isSafe(_ name: String) -> Bool { !name.isEmpty && !name.contains(",") && !name.contains(":") }

    /// Reads the RAWC/RAWI of every clip's MLV (first file) once — blocking file I/O, call it off the main
    /// actor (`analyzeDetached`).
    public static func analyze(_ shoot: Shoot) -> Analysis {
        var clips: [(name: String, sampling: Sampling)] = []
        var byName: [String: Sampling] = [:]
        var order: [(name: String, squeeze: Int)] = []
        for clip in shoot.clips {
            guard let mlv = clip.files.first else { continue }
            let name = relativeName(of: mlv, in: shoot.folder)
            if let s = MLVHeader.sampling(of: mlv) {
                clips.append((name, s))
                byName[name] = s
                order.append((name, horizontalSqueeze(x: s.x, y: s.y) ?? 1))
            } else {
                order.append((name, MLVHeader.horizontalSqueeze(of: mlv) ?? 1))  // RAWC without RAWI, or none
            }
        }
        let fixes = corrections(for: clips).compactMap { name, to -> Fix? in
            guard isSafe(name), let from = byName[name] else { return nil }
            return Fix(name: name, fromX: from.x, fromY: from.y, toX: to.x, toY: to.y)
        }.sorted { $0.name < $1.name }
        let fixed = Dictionary(fixes.map { ($0.name, $0.squeeze) }, uniquingKeysWith: { a, _ in a })
        return Analysis(fixes: fixes, squeeze: majority(order.map { fixed[$0.name] ?? $0.squeeze }))
    }

    /// `analyze` on a detached task (never on the caller's actor).
    public static func analyzeDetached(_ shoot: Shoot) async -> Analysis {
        await Task.detached(priority: .userInitiated) { analyze(shoot) }.value
    }

    /// The engine option `--sampling-fix=<relative MLV path>:<sx>x<sy>[,…]`, nil when there is nothing to fix.
    public static func engineArgument(_ fixes: [Fix]) -> String? {
        let items = fixes.filter { isSafe($0.name) }.map { "\($0.name):\($0.toX)x\($0.toY)" }
        return items.isEmpty ? nil : "--sampling-fix=" + items.joined(separator: ",")
    }

    /// Horizontal anamorphic squeeze of a sampling: h for an h:1 ratio with h > 1 (3 for 3x1), else nil.
    public static func horizontalSqueeze(x: Int, y: Int) -> Int? {
        guard x > 0, y > 0 else { return nil }
        var a = x, b = y
        while b != 0 { (a, b) = (b, a % b) }
        let h = x / a, v = y / a
        return (v == 1 && h > 1) ? h : nil
    }

    /// Most common value (earliest on a tie); nil when it is 1 (not anamorphic) or there is none.
    static func majority(_ values: [Int]) -> Int? {
        var counts: [Int: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        guard let best = counts.values.max(), let n = values.first(where: { counts[$0] == best }) else { return nil }
        return n > 1 ? n : nil
    }

    /// Magic Lantern notation of a sampling: vertical x horizontal (3, 1 → « 1x3 »).
    static func label(x: Int, y: Int) -> String { "\(y)x\(x)" }

    /// The info line for a mounted shoot with corrections (nil when none), e.g. « M25-1745: header says 1x1,
    /// corrected to 1x3 like the other clips ». Clips with the same correction share one line.
    public static func message(_ fixes: [Fix]) -> String? {
        guard !fixes.isEmpty else { return nil }
        var order: [String] = []
        var groups: [String: (from: String, to: String, names: [String])] = [:]
        for f in fixes {
            let from = label(x: f.fromX, y: f.fromY), to = label(x: f.toX, y: f.toY)
            let k = from + ">" + to
            if groups[k] == nil { order.append(k); groups[k] = (from, to, []) }
            groups[k]?.names.append(f.clipName)
        }
        return order.compactMap { groups[$0] }.map { g in
            let names = g.names.joined(separator: ", ")
            return String(localized: "\(names): header says \(g.from), corrected to \(g.to) like the other clips",
                          bundle: L10n.bundle)
        }.joined(separator: "\n")
    }
}
