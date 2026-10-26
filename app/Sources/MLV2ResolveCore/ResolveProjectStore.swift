// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

public enum ResolveTimelineSize: String, CaseIterable, Sendable {
    case automatic, uhd, hd
}

/// Associations point into a Resolve library. Clearing them never edits that library.
@MainActor
public final class ResolveProjectStore: ObservableObject {
    public struct Link: Codable, Equatable, Identifiable, Sendable {
        public let source: String
        public let name: String
        public let database: String
        public let folder: [String]
        public var id: String { source }
        public init(source: String, name: String, database: String, folder: [String]) {
            self.source = source; self.name = name; self.database = database; self.folder = folder
        }
    }
    @Published public private(set) var links: [Link] = []
    private let defaults: UserDefaults
    private let receiptsURL: URL?
    private static let key = "resolveProjectLinks"
    public init(defaults: UserDefaults, receiptsURL: URL? = nil) {
        self.defaults = defaults; self.receiptsURL = receiptsURL
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Link].self, from: data) { links = saved }
        reloadReceipts()
    }
    public func record(_ link: Link) {
        links.removeAll { $0.source == link.source }
        links.append(link)
        persist()
    }
    public func remove(_ link: Link) {
        reloadReceipts()
        links.removeAll { $0.source == link.source }; persist()
    }
    public func clear() {
        // Consume/delete receipts before clearing so a later reload cannot resurrect old links.
        if let receiptsURL { try? FileManager.default.removeItem(at: receiptsURL) }
        links = []; persist()
    }
    public func ingest(_ output: String) {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 4, fields[0] == "LINK",
                  let source = Self.unhex(String(fields[1])), let name = Self.unhex(String(fields[2])),
                  let database = Self.unhex(String(fields[3])), !source.isEmpty, !name.isEmpty, !database.isEmpty else { continue }
            record(.init(source: source, name: name, database: database, folder: []))
        }
    }
    public func reloadReceipts() {
        guard let receiptsURL, let data = try? String(contentsOf: receiptsURL, encoding: .utf8) else { return }
        ingest(data)
        try? FileManager.default.removeItem(at: receiptsURL)
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(links), forKey: Self.key) }
    private static func unhex(_ s: String) -> String? {
        guard s.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []; var index = s.startIndex
        while index < s.endIndex {
            let end = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<end], radix: 16) else { return nil }
            bytes.append(byte); index = end
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
