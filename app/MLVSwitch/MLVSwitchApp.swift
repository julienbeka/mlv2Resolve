// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import MLVSwitchCore

@main
struct MLVSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        MenuBarExtra("MLV Switch", systemImage: "film.stack") {
            Text("MLV Switch")
        }
    }
}
