// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import MLV2ResolveCore

struct MainWindowView: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            if state.settingsPresented {
                VStack(spacing: 0) {
                    HStack {
                        Label("Settings", systemImage: "gearshape").font(.title3.weight(.semibold))
                        Spacer()
                        Button { state.settingsPresented = false } label: { Image(systemName: "sidebar.left") }
                            .buttonStyle(.borderless).help("Close Settings")
                            .accessibilityLabel("Close Settings")
                    }.padding(20)
                    SettingsView(state: state)
                }
                .frame(width: 380)
                .modifier(SettingsSurface())
                .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        HStack(spacing: 14) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                                .resizable().interpolation(.high)
                                .frame(width: 64, height: 64)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(verbatim: "mlv2Resolve").font(.largeTitle.weight(.semibold))
                                Text("Your footage. Ready for Resolve.").foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(.quaternary, in: Capsule())
                    }.padding(.bottom, 2)
                    if let alert = state.alert {
                        banner(alert, tint: .orange, icon: "exclamationmark.triangle.fill") { state.clearAlert() }
                    }
                    if let info = state.info {
                        banner(info, tint: .blue, icon: "info.circle.fill") { state.clearInfo() }
                    }
                    WorkflowSection(number: "01", title: "Footage", subtitle: "Virtual CinemaDNG, without copying your footage.", icon: "externaldrive") {
                        mountSection
                    }
                    WorkflowSection(number: "02", title: "Gyro Sync", subtitle: "SenseFlow A1 · Lens and motion matching", icon: "gyroscope") {
                        if let gyro = state.gyro {
                            GyroProgressLabel(gyro: gyro)
                            GyroShootsSection(state: state, gyro: gyro)
                        }
                    }
                    ResolveSection(state: state, projects: state.projects)
                    WorkflowSection(number: "04", title: "Settings", subtitle: "Make this workflow yours.", icon: "slider.horizontal.3") {
                        HStack {
                            Button("Settings…", systemImage: "gearshape") { state.showSettings() }
                            if state.needsFuseT { Button("Install FUSE-T…") { AppDelegate.shared?.showOnboarding() } }
                            Spacer()
                        }
                        Text("Mount your shoots, wait for gyro sync, then create a Resolve project. Keep the folders mounted while editing.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("mlv2Resolve stays available in the menu bar. Click its Dock icon to return to this window.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(24).frame(maxWidth: 1040)
                    .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: state.settingsPresented ? 960 : 700, idealWidth: 880, minHeight: 600, idealHeight: 800)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: state.settingsPresented)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { state.settingsPresented.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help("Settings").accessibilityLabel("Settings")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in state.projects.reloadReceipts() }
    }

    private var mountSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    if let folder = state.folder {
                        Text(verbatim: folder.lastPathComponent).font(.headline)
                        Text(verbatim: folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else { Text("Choose the folder containing your MLV shoots.").foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Choose Folder…") { MenuActions.chooseFolder(state: state) }
            }
            ForEach(state.shoots, id: \.folder) { shoot in
                let key = GyroSyncCoordinator.key(of: shoot)
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill").font(.title3).foregroundStyle(.secondary)
                    Toggle(isOn: Binding(get: { state.mounted.contains(key) }, set: { _ in Task { await state.toggle(shoot) } })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: shoot.name).fontWeight(.medium)
                            Text(verbatim: shootTitle(shoot)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.toggleStyle(.switch).disabled(state.busy.contains(key))
                    if state.busy.contains(key) { ProgressView().controlSize(.small) }
                }.padding(.vertical, 4)
            }
            if state.folder != nil && state.shoots.isEmpty {
                Label("No MLV shoots found in this folder.", systemImage: "folder.badge.questionmark").foregroundStyle(.secondary)
            }
            HStack {
                Button("Unmount All", systemImage: "eject") { Task { await state.unmountAll() } }
                    .disabled(state.mounted.isEmpty || !state.busy.isEmpty)
                Button("Show DNGs in Finder", systemImage: "folder") { MenuActions.showDNGsInFinder() }
                Spacer()
            }.controlSize(.small)
        }
    }

    private func banner(_ text: String, tint: Color, icon: String, clear: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: clear) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Close")
        }.padding(14).background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct WorkflowSection<Content: View>: View {
    let number: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(.tint)
                    .frame(width: 38, height: 38).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: number).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.05)))
    }
}

struct ResolveSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var projects: ResolveProjectStore
    @State private var existingPrompt = false
    private var working: Bool { state.openingResolve || state.waitingForResolveGyro || state.desqueezing }
    private var relevant: [ResolveProjectStore.Link] {
        distinctLinks(projects.links.filter { state.mounted.contains($0.source) })
    }
    private var uniqueLinks: [ResolveProjectStore.Link] {
        distinctLinks(projects.links)
    }
    private func distinctLinks(_ links: [ResolveProjectStore.Link]) -> [ResolveProjectStore.Link] {
        var seen = Set<[String]>()
        return links.filter { seen.insert([$0.database, $0.name] + $0.folder).inserted }
    }
    var body: some View {
        WorkflowSection(number: "03", title: "Editing", subtitle: "From mounted footage to your edit.", icon: "play.rectangle") {
            HStack(spacing: 10) {
                if let url = MenuActions.resolveURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 42, height: 42)
                        .accessibilityLabel("DaVinci Resolve")
                }
                Text(verbatim: "DaVinci Resolve").font(.headline)
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Title of the project to create")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Title of the project to create", text: $state.projectName, prompt: Text(verbatim: "My Project"))
                    .textFieldStyle(.roundedBorder).disabled(working)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                Button {
                    projects.reloadReceipts()
                    if relevant.isEmpty { MenuActions.createProject(state: state) } else { existingPrompt = true }
                } label: { Label("Create Project", systemImage: "plus.rectangle.on.rectangle").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(working || state.mounted.isEmpty || MenuActions.resolveURL == nil)
                Menu {
                    ForEach(uniqueLinks) { link in
                        Button { MenuActions.openLinked(link, state: state) } label: {
                            Text(verbatim: link.name)
                        }
                    }
                } label: { Label("Open Project", systemImage: "folder").frame(maxWidth: .infinity) }
                    .disabled(working || projects.links.isEmpty || MenuActions.resolveURL == nil)
                Button { MenuActions.openResolve(state: state) } label: { Label("Open Resolve", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity) }
                    .disabled(working || MenuActions.resolveURL == nil)
                Button { MenuActions.desqueeze(state: state) } label: { Label("Desqueeze in Resolve", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right").frame(maxWidth: .infinity) }
                    .disabled(working || state.desqueezeTargets.isEmpty || MenuActions.resolveURL == nil)
            }.buttonStyle(.bordered).controlSize(.large)
            if MenuActions.resolveURL == nil {
                Text("DaVinci Resolve wasn't found — you can install it later.").font(.caption).foregroundStyle(.secondary)
            } else if projects.links.isEmpty {
                Text("No linked project yet. Create a project from your mounted shoots.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("A linked project already exists", isPresented: $existingPrompt, titleVisibility: .visible) {
            ForEach(relevant) { link in Button("Open \(link.name)") { MenuActions.openLinked(link, state: state) } }
            Button("Create New Project") { MenuActions.createProject(state: state) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Open the linked project or create a separate project. Existing projects are preserved.") }
    }
}

private struct SettingsSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            content.glassEffect(.regular, in: Rectangle())
        } else if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor))
        } else {
            content.background(.regularMaterial)
        }
    }
}
