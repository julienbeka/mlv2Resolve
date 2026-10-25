// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A lens declared by the user. `calibratedProfiles` are optional Gyroflow lens profile files (JSON).
public struct Lens: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var focalMM: Double
    public var calibratedProfiles: [URL]

    public init(id: UUID = UUID(), name: String, focalMM: Double, calibratedProfiles: [URL] = []) {
        self.id = id; self.name = name; self.focalMM = focalMM; self.calibratedProfiles = calibratedProfiles
    }
}
