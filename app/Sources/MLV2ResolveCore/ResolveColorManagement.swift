// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Applied only when preparing a new Resolve project and its timeline.
public enum ResolveColorManagement: String, CaseIterable, Sendable {
    case conversionRec709A
    case kodak2383

    public var timelineTemplateURL: URL {
        let name = self == .conversionRec709A ? "resolve-timeline-rec709-a" : "resolve-timeline-kodak2383"
        return Bundle.module.url(forResource: name, withExtension: "drt")!
    }
    public var nodeCount: Int { self == .conversionRec709A ? 1 : 2 }
    public var lutPath: String? {
        self == .kodak2383 ? "Film Looks/Rec709 Kodak 2383 D60.cube" : nil
    }
}
