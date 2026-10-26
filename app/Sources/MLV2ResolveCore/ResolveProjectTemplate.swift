// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// Playback rate is read-only in Resolve's API. Set its serialized float in the empty
/// colour project before import. The distributed settings use a standard raw Zstd frame
/// so no third-party codec or Python installation is needed on the user's Mac.
enum ResolveProjectTemplate {
    private static let lock = NSLock()
    enum Failure: LocalizedError {
        case invalidRate, invalidModel, command(String)
        var errorDescription: String? {
            switch self {
            case .invalidRate: "Invalid Resolve playback frame rate"
            case .invalidModel: "The bundled Resolve project model has an unsupported settings format"
            case .command(let detail): "Could not prepare the Resolve project model: " + detail
            }
        }
    }
    static func make(playbackFrameRate fps: Double, cacheDirectory: URL? = nil) throws -> URL {
        guard fps.isFinite, fps > 0, Float(fps).isFinite, Float(fps) > 0 else { throw Failure.invalidRate }
        lock.lock(); defer { lock.unlock() }
        let source = ResolveProject.projectTemplateURL
        let fingerprint = SHA256.hash(data: try Data(contentsOf: source) + Data(String(Float(fps).bitPattern).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let root = cacheDirectory ?? AppDataPaths.support.appendingPathComponent("Resolve Models", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("resolve-project-cst-" + fingerprint + ".drp")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let work = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let extracted = work.appendingPathComponent("project", isDirectory: true)
        _ = try command("/usr/bin/ditto", ["-x", "-k", source.path, extracted.path])
        let xmlURL = extracted.appendingPathComponent("project.xml")
        let xml = try String(contentsOf: xmlURL, encoding: .utf8)
        let edited = try replacingPlaybackRate(in: xml, fps: fps)
        try edited.write(to: xmlURL, atomically: true, encoding: .utf8)
        let packed = work.appendingPathComponent("project.drp")
        _ = try command("/usr/bin/ditto", ["-c", "-k", extracted.path, packed.path])
        try Data(contentsOf: packed).write(to: output, options: .atomic)
        return output
    }
    static func projectXML(in archive: URL) throws -> String {
        let data = try command("/usr/bin/unzip", ["-p", archive.path, "project.xml"])
        guard let result = String(data: data, encoding: .utf8) else { throw Failure.invalidModel }
        return result
    }
    private static func command(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.command(String(data: result, encoding: .utf8) ?? path) }
        return result
    }
    private struct Model {
        let range: Range<String.Index>
        let map: [UInt8]
        let oldSize: Int
        let settings: [UInt8]
    }
    private static func model(in xml: String) throws -> Model {
        let expression = try NSRegularExpression(pattern: #"<SM_Config\b[^>]*>[\s\S]*?<FieldsBlob>([0-9a-f]+)</FieldsBlob>"#)
        guard let match = expression.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { throw Failure.invalidModel }
        let hex = Array(xml[range].utf8)
        guard hex.count.isMultiple(of: 2) else { throw Failure.invalidModel }
        func digit(_ c: UInt8) throws -> UInt8 {
            switch c { case 48...57: c - 48; case 97...102: c - 87; default: throw Failure.invalidModel }
        }
        var map: [UInt8] = []; map.reserveCapacity(hex.count / 2)
        for i in stride(from: 0, to: hex.count, by: 2) { map.append(try digit(hex[i]) * 16 + digit(hex[i+1])) }
        // QDataStream map's first QByteArray is SetupBA; reject a changed schema rather than guessing.
        guard map.count >= 56, Array(map[12..<26]) == Array("SetupBA".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }),
              Array(map[26..<31]) == [0,0,0,12,0] else { throw Failure.invalidModel }
        let oldSize = try integer(map, 31, little: false)
        guard oldSize >= 21, 35 + oldSize <= map.count,
              Array(map[35..<39]) == [0,0,0,1], map[43] == 0x81,
              Array(map[44..<49]) == [0x28,0xb5,0x2f,0xfd,0xa0] else { throw Failure.invalidModel }
        let size = try integer(map, 49, little: true)
        let block = Int(map[53]) | Int(map[54]) << 8 | Int(map[55]) << 16
        guard block & 7 == 1, block >> 3 == size, 56 + size == 35 + oldSize else { throw Failure.invalidModel }
        return Model(range: range, map: map, oldSize: oldSize, settings: Array(map[56..<56+size]))
    }
    private static func integer(_ data: [UInt8], _ start: Int, little: Bool) throws -> Int {
        guard start >= 0, start + 4 <= data.count else { throw Failure.invalidModel }
        let bytes = Array(data[start..<start+4])
        return (little ? bytes.reversed() : bytes).reduce(0) { $0 << 8 | Int($1) }
    }
    private static func bytes(_ value: UInt32, little: Bool) -> [UInt8] {
        let b = [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        return little ? b.reversed() : b
    }
    private static func varint(_ data: [UInt8], index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < data.count else { throw Failure.invalidModel }
            let byte = data[index]; index += 1
            guard shift != 63 || byte <= 1 else { throw Failure.invalidModel }
            result |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return result }
        }
        throw Failure.invalidModel
    }
    /// Protobuf field 248, fixed32: identified by before/after exports of a single UI change
    /// (24 → 25 fps), then verified by importing the modified project into Resolve 21.1.1.
    private static func playbackRange(_ data: [UInt8]) throws -> Range<Int>? {
        var i = 0; var found: Range<Int>?
        while i < data.count {
            let key = try varint(data, index: &i)
            guard key >> 3 > 0 else { throw Failure.invalidModel }
            switch key & 7 {
            case 0: _ = try varint(data, index: &i)
            case 1: i += 8
            case 2:
                let count = try varint(data, index: &i)
                guard count <= UInt64(data.count - i) else { throw Failure.invalidModel }
                i += Int(count)
            case 5:
                if key >> 3 == 248 {
                    guard found == nil else { throw Failure.invalidModel }
                    found = i..<i+4
                }
                i += 4
            default: throw Failure.invalidModel
            }
            guard i <= data.count else { throw Failure.invalidModel }
        }
        return found
    }
    static func playbackFrameRate(in xml: String) throws -> Double {
        let settings = try model(in: xml).settings
        guard let range = try playbackRange(settings) else { return 24 }
        return Double(Float(bitPattern: UInt32(try integer(settings, range.lowerBound, little: true))))
    }
    private static func replacingPlaybackRate(in xml: String, fps: Double) throws -> String {
        let model = try model(in: xml)
        var raw = model.settings
        let value = bytes(Float(fps).bitPattern, little: true)
        if let range = try playbackRange(raw) { raw.replaceSubrange(range, with: value) }
        else { raw += [0xc5,0x0f] + value }
        guard raw.count < 131072 else { throw Failure.invalidModel }
        let block = UInt32(raw.count << 3 | 1)
        let frame: [UInt8] = [0x28,0xb5,0x2f,0xfd,0xa0] + bytes(UInt32(raw.count), little: true)
            + Array(bytes(block, little: true).prefix(3)) + raw
        let payload = [UInt8(0x81)] + frame
        let valueData: [UInt8] = [0,0,0,1] + bytes(UInt32(payload.count), little: false) + payload
        let map = Array(model.map[..<31]) + bytes(UInt32(valueData.count), little: false) + valueData
            + Array(model.map[(35+model.oldSize)...])
        var result = xml
        result.replaceSubrange(model.range, with: map.map { String(format: "%02x", $0) }.joined())
        return result
    }
}
