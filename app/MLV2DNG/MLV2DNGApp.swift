// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import MLV2DNGCore

@main
struct MLV2DNGApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = AppCore.shared.state

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            MenuLabel(state: state)
        }
        .menuBarExtraStyle(.menu)

    }
}
