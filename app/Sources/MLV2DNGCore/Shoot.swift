// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct Clip: Equatable, Sendable {
    public let name: String
    public let files: [URL]
    public let bytes: Int64

    public init(name: String, files: [URL], bytes: Int64) {
        self.name = name
        self.files = files
        self.bytes = bytes
    }
}

public struct Shoot: Equatable, Hashable, Sendable {
    public let name: String
    public let folder: URL
    public let volumeName: String
    public let clips: [Clip]

    public init(name: String, folder: URL, volumeName: String, clips: [Clip]) {
        self.name = name
        self.folder = folder
        self.volumeName = volumeName
        self.clips = clips
    }

    public var totalBytes: Int64 { clips.reduce(0) { $0 + $1.bytes } }
}

extension Clip: Hashable {}
