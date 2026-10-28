// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import ServiceManagement
import MLV2ResolveCore

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
        a.messageText = String(localized: "mlv2Resolve needs to restart to change the language.")
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
        ScrollViewReader { proxy in
        Form {
            Section("General") {
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
            }
            Section("Dual ISO") {
                Picker("Processing", selection: Binding(get: { state.mode }, set: { value in Task { await state.setMode(value) } })) {
                    Text("Smooth Editing").tag(DualISOMode.montageFluide)
                    Text("Grading Quality").tag(DualISOMode.qualiteEtalonnage)
                }
                Text("Smooth Editing uses a fast Dual ISO preview for playback and editing. Grading Quality uses full interpolation for grading and final rendering, with more processing required.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ResolveSettingsSection(state: state, projects: state.projects)
            if let gyro = state.gyro {
                GyroSettingsSections(gyro: gyro)
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
        .onChange(of: state.settingsSection) { _, section in proxy.scrollTo(section, anchor: .top) }
        .onAppear { proxy.scrollTo(state.settingsSection, anchor: .top) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ResolveSettingsSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var projects: ResolveProjectStore
    var body: some View {
        Section("Resolve") {
            Picker("Timeline Size", selection: $state.timelineSize) {
                Text("Automatic · Match footage").tag(ResolveTimelineSize.automatic)
                Text(verbatim: "UHD · 3840 × 2160").tag(ResolveTimelineSize.uhd)
                Text(verbatim: "HD · 1920 × 1080").tag(ResolveTimelineSize.hd)
            }
            Text("New projects use this size and the footage frame rate. HD and UHD fit the entire image, including anamorphic footage. Existing projects keep their settings.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Timeline Frame Rate", selection: $state.timelineFrameRate) {
                Text("Automatic · Majority of footage").tag(Double?.none)
                ForEach(AppState.timelineFrameRates, id: \.self) { fps in
                    Text(verbatim: formatNumber(fps, digits: fps == fps.rounded() ? 0 : 3) + " fps").tag(Optional(fps))
                }
            }
            Text("Automatic uses the most common frame rate among the mounted shots. A chosen frame rate applies to new timelines only.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Add all shots to timeline", isOn: $state.includeAllShots)
            TextField("Timeline Name", text: $state.timelineName, prompt: Text(verbatim: "All shots"))
            Text("Enabled: add all imported shots to the new timeline. Disabled: prepare an empty timeline with the color nodes. A blank name uses All shots.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Color Management", selection: $state.colorManagement) {
                Text("Rec709-A Conversion").tag(ResolveColorManagement.conversionRec709A)
                Text(verbatim: "Kodak 2383").tag(ResolveColorManagement.kodak2383)
            }
            Text("New projects use DaVinci WG/Intermediate for the timeline and Rec.709-A for output. CinemaDNG decoding stays P3 D60 / Linear.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if state.colorManagement == .conversionRec709A {
                Text("One active timeline CST: P3-D60 / Linear → DaVinci Wide Gamut / Rec.709-A.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Two active timeline nodes: CST P3-D60 / Linear → Rec.709 / Cineon Film Log, then Resolve’s Rec709 Kodak 2383 D60 LUT.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(projects.links) { link in
                HStack {
                    VStack(alignment: .leading) {
                        Text(verbatim: link.name).lineLimit(1)
                        Text(verbatim: link.source).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Remove") { state.removeResolveProjectLink(link) }
                }
            }
            Button("Clear Project Links") { state.clearResolveProjectLinks() }.disabled(projects.links.isEmpty)
            Text("Removes all cached links used by Open Project. Projects in Resolve and footage are kept. Remove an individual link here if its project can no longer be found.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.id("resolve")
    }
}
