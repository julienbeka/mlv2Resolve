// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import ServiceManagement
import MLV2DNGCore

enum LaunchAtLogin {
    static let initKey = "launchAtLoginInitialized"
    /// On by default: registered once at first launch.
    static func initializeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: initKey) else { return }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            NSLog("Launch at login: not registering, app not in /Applications (\(Bundle.main.bundleURL.path))")
            return
        }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: initKey)
        } catch { NSLog("Launch at login: \(error)") }
    }
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("Launch at login: \(error)") }
    }
}

enum LanguageSwitch {
    static let choiceKey = "appLanguageChoice"
    /// Current choice, read from the app's own persistent domain (what System Settings also writes).
    static func current() -> AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        return AppLanguage(appleLanguages: domain?["AppleLanguages"] as? [String])
    }
    static func apply(_ lang: AppLanguage) {
        if let langs = lang.appleLanguages { UserDefaults.standard.set(langs, forKey: "AppleLanguages") }
        else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        UserDefaults.standard.set(lang.rawValue, forKey: choiceKey)
        UserDefaults.standard.synchronize()
    }
    /// Spawns a detached helper that waits for this process to exit (30 s cap), reopens the app, then terminates.
    @MainActor static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c",
            "pid=\"$1\"; i=0; while kill -0 \"$pid\" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.2; i=$((i+1)); done; /usr/bin/open -n \"$0\"",
            Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier)]
        do { try p.run() } catch {
            NSLog("Relaunch failed: \(error)")
            let a = NSAlert()
            a.messageText = error.localizedDescription
            a.runModal()
            return
        }
        // Runloop timer, not a GCD block: terminate(_:) with .terminateLater spins a nested loop that
        // never drains further main-queue blocks, so calling it from one would hang the quit.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05)
    }
    @MainActor static func promptRestart() {
        let a = NSAlert()
        a.messageText = String(localized: "mlv2dng needs to restart to change the language.")
        a.addButton(withTitle: String(localized: "Restart Now"))
        a.addButton(withTitle: String(localized: "Later"))
        if a.runModal() == .alertFirstButtonReturn { relaunch() }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var language = LanguageSwitch.current()

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: Binding(get: { launchAtLogin }, set: { on in
                LaunchAtLogin.set(on)
                launchAtLogin = LaunchAtLogin.isEnabled
            }))
            Picker("Language", selection: Binding(get: { language }, set: { new in
                guard new != language else { return }
                language = new
                LanguageSwitch.apply(new)
                DispatchQueue.main.async { LanguageSwitch.promptRestart() }
            })) {
                Text("System").tag(AppLanguage.system)
                Text(verbatim: "English").tag(AppLanguage.en)
                Text(verbatim: "Français").tag(AppLanguage.fr)
            }
            DisclosureGroup("Advanced") {
                Toggle("Fix Dead Pixels", isOn: $state.fixBadPixels)
                Toggle("Fix Focus Pixels", isOn: $state.fixFocusPixels)
                Text("Applied the next time a shoot is mounted.").font(.caption).foregroundStyle(.secondary)
                Button("Open Logs Folder") {
                    let dir = EngineLog.defaultDirectory
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
            }
            Section("About") {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                Text("Inspired by Switch by Danne · MLVFS by David Milligan · focus pixel maps and LJ92 decoder from MLV App (ilia3101 and contributors)")
                Text("Free software under the GPL-3.0-or-later license.")
            }
        }
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled; language = LanguageSwitch.current() }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
