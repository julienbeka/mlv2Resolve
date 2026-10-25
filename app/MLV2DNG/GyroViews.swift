// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MLV2DNGCore

// MARK: Formatting

/// Locale of the app's UI language (not the system's), so numbers match the text around them.
func appLocale(language: String = Bundle.main.preferredLocalizations.first ?? "en") -> Locale {
    Locale(identifier: language.hasPrefix("fr") ? "fr_FR" : "en_US")
}

/// `value` with exactly `digits` decimals, in the app's language (« 0,78 » in French).
func formatNumber(_ value: Double, digits: Int, locale: Locale = appLocale()) -> String {
    value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
}

/// A focal length without a useless « .0 » (« 25 », « 12,5 »).
func formatFocal(_ mm: Double, locale: Locale = appLocale()) -> String {
    mm.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(locale))
}

/// Parses a focal length typed with a point or a comma; nil unless it is a finite number > 0.
func parseFocal(_ text: String) -> Double? {
    let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    guard let v = Double(t), v.isFinite, v > 0 else { return nil }
    return v
}

extension MountingPosition {
    /// Where the SenseFlow A1 sits on the camera.
    var label: String {
        switch self {
        case .top: String(localized: "Top")
        case .bottom: String(localized: "Bottom")
        case .front: String(localized: "Front")
        case .back: String(localized: "Back")
        case .left: String(localized: "Left")
        case .right: String(localized: "Right")
        }
    }
}

extension Lens {
    var label: String { name.isEmpty ? "\(formatFocal(focalMM)) mm" : name }
}

// MARK: Clip state

/// Text, tooltip and look of a clip's gyro state.
struct GyroStateDescription {
    let text: String
    let help: String
    let icon: String
    let tint: Color

    init(_ state: ClipGyroState?) {
        switch state ?? .pending {
        case .pending:
            text = String(localized: "Waiting")
            help = String(localized: "Waiting for its turn: clips are synced one at a time.")
            icon = "clock"; tint = .secondary
        case .running:
            text = String(localized: "Syncing…")
            help = String(localized: "Analyzing the clip's motion and matching it with the gyro log.")
            icon = "arrow.triangle.2.circlepath"; tint = .blue
        case let .synced(r2, log, offsetMs):
            text = String(localized: "Synced (R² \(formatNumber(r2, digits: 2)))")
            help = String(localized: "Synced with \(log), offset \(formatNumber(offsetMs, digits: 0)) ms. R² tells how well the clip's motion matches the gyro (1 = perfect). In Resolve: Gyroflow plugin → Load for current file.")
            icon = "checkmark.circle.fill"; tint = .green
        case .existing:
            text = String(localized: "Existing .gyroflow")
            help = String(localized: "This clip already has a .gyroflow that mlv2dng did not write (e.g. from Gyroflow or NiYien): it is kept. Regenerate to replace it; the current file is backed up first.")
            icon = "doc.fill"; tint = .secondary
        case .noLog:
            text = String(localized: "No log covers this clip")
            help = String(localized: "No SenseFlow A1 log (*_mix.bin) in the chosen folder was recording when this clip was shot.")
            icon = "minus.circle"; tint = .secondary
        case .notEnoughMotion:
            text = String(localized: "Not enough camera motion")
            help = String(localized: "The camera moves too little in this clip to match it with the gyro log. No .gyroflow was written.")
            icon = "exclamationmark.circle"; tint = .orange
        case .ambiguous:
            text = String(localized: "Uncertain match")
            help = String(localized: "Several positions in the log match about as well: rather than guess, no .gyroflow was written.")
            icon = "questionmark.circle"; tint = .orange
        case let .failed(message):
            text = message
            help = String(localized: "Sync failed: \(message)")
            icon = "xmark.octagon.fill"; tint = .red
        }
    }
}

struct GyroStateBadge: View {
    let state: ClipGyroState?
    /// Profile of the written file (shown next to « Synced »).
    var profile: LensProfileKind? = nil
    /// The clip's lens has calibrated profiles: a computed profile then means none of them fitted.
    var lensHasCalibrated = false

    var body: some View {
        let d = GyroStateDescription(state)
        let synced: Bool = { if case .synced? = state { return true } else { return false } }()
        let fallback = synced && profile == .computed && lensHasCalibrated
        HStack(spacing: 4) {
            if state == .running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: d.icon).foregroundStyle(d.tint)
            }
            Text(verbatim: d.text).lineLimit(1).truncationMode(.tail)
            if synced, let profile {
                Text(verbatim: "· " + (profile == .calibrated ? String(localized: "calibrated profile")
                                                              : String(localized: "computed profile")))
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(fallback ? Color.orange : Color.secondary)
            }
        }
        .font(.callout)
        .help(fallback ? d.help + "\n\n" + String(localized: "None of this lens's calibrated profiles matches the clip's format (or its file is unreadable): the computed profile was used.") : d.help)
    }
}

/// Where imported lens profiles are copied (`<root>/<lens id>/<file name>`).
enum LensProfileStore {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mlv2dng", isDirectory: true)
            .appendingPathComponent("lens-profiles", isDirectory: true)
    }

    static func prune(lensID: UUID, keep: [URL]) {
        LensProfile.pruneImported(lensID: lensID, root: root, keep: keep)
    }
}

// MARK: Main window

/// Gyro sync of the mounted shoots: per shoot lens and position, per clip state, lens menu and « Regenerate ».
struct GyroShootsSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var gyro: GyroSyncCoordinator

    var body: some View {
        let shoots = state.shoots.filter { state.mounted.contains(GyroSyncCoordinator.key(of: $0)) }
        if !shoots.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Gyro Sync (SenseFlow A1)").font(.headline)
                if gyro.lenses.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "camera.aperture").foregroundStyle(.blue)
                        Text("Declare your lenses to sync the gyro of the mounted shoots.")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Settings → Lenses…") { AppDelegate.shared?.showSettings(state: state) }
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    // Several mounted shoots start folded, so the window stays a sensible size.
                    ForEach(shoots, id: \.folder) { GyroShootView(shoot: $0, gyro: gyro, expanded: shoots.count == 1) }
                }
            }
        }
    }
}

struct GyroShootView: View {
    let shoot: Shoot
    @ObservedObject var gyro: GyroSyncCoordinator
    @State private var expanded: Bool

    init(shoot: Shoot, gyro: GyroSyncCoordinator, expanded: Bool) {
        self.shoot = shoot
        self.gyro = gyro
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        let key = GyroSyncCoordinator.key(of: shoot)
        let keys = shoot.clips.compactMap(GyroSyncCoordinator.key(of:))
        let synced = keys.filter { if case .synced? = gyro.states[$0] { return true } else { return false } }.count
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("Lens", selection: Binding<UUID?>(
                        get: { gyro.defaultLens(forShoot: key)?.id },
                        set: { id in
                            // Re-picking the same lens must not rewrite the shoot's files.
                            guard id != gyro.defaultLens(forShoot: key)?.id else { return }
                            gyro.setDefaultLens(gyro.lenses.first { $0.id == id }, forShoot: key)
                        })) {
                        Text("None").tag(UUID?.none)
                        ForEach(gyro.lenses) { Text(verbatim: $0.label).tag(Optional($0.id)) }
                    }
                    .help("Lens of the shoot's clips, unless a clip has its own")
                    Picker("Sensor position", selection: Binding(
                        get: { gyro.position(forShoot: key) },
                        set: { p in
                            guard p != gyro.position(forShoot: key) else { return }
                            gyro.setPosition(p, forShoot: key)
                        })) {
                        ForEach(MountingPosition.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                    }
                    .help("Where the SenseFlow A1 is mounted on the camera for this shoot")
                }
                DisclosureGroup(isExpanded: $expanded) {
                    let rows = VStack(alignment: .leading, spacing: 4) {
                        ForEach(shoot.clips, id: \.self) { clip in
                            if let k = GyroSyncCoordinator.key(of: clip) { GyroClipRow(clip: clip, key: k, gyro: gyro) }
                        }
                    }
                    if shoot.clips.count > 8 {
                        ScrollView { rows.padding(.trailing, 12) }.frame(height: 8 * 26)
                    } else {
                        rows
                    }
                } label: {
                    Text(verbatim: shoot.name).bold()
                    + Text(verbatim: "  ")
                    + Text("\(String(synced))/\(String(keys.count)) synced").foregroundColor(.secondary)
                }
            }
            .padding(4)
        }
    }
}

/// A per-clip change that rewrites the clip's `.gyroflow`.
enum ClipGyroChange {
    case lens(UUID?), position(MountingPosition?), regenerate
}

struct GyroClipRow: View {
    let clip: Clip
    let key: String
    @ObservedObject var gyro: GyroSyncCoordinator
    /// Waiting for the user to accept replacing a `.gyroflow` mlv2dng did not write.
    @State private var pending: ClipGyroChange?

    var body: some View {
        let state = gyro.states[key]
        HStack(spacing: 8) {
            Text(verbatim: clip.name).lineLimit(1).frame(width: 96, alignment: .leading)
            GyroStateBadge(state: state, profile: gyro.profileKind(forClip: key),
                           lensHasCalibrated: !(gyro.lens(forClip: key)?.calibratedProfiles.isEmpty ?? true))
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Picker("Lens", selection: Binding<UUID?>(
                    get: { gyro.ownLens(forClip: key)?.id },
                    set: { id in
                        guard id != gyro.ownLens(forClip: key)?.id else { return }
                        request(.lens(id))
                    })) {
                    Text("Shoot default").tag(UUID?.none)
                    ForEach(gyro.lenses) { Text(verbatim: $0.label).tag(Optional($0.id)) }
                }
                .pickerStyle(.inline)
                Picker("Sensor position", selection: Binding<MountingPosition?>(
                    get: { gyro.ownPosition(forClip: key) },
                    set: { p in
                        guard p != gyro.ownPosition(forClip: key) else { return }
                        request(.position(p))
                    })) {
                    Text("Same as shoot").tag(MountingPosition?.none)
                    ForEach(MountingPosition.allCases, id: \.self) { Text(verbatim: $0.label).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(verbatim: menuLabel)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 130, alignment: .trailing)
            .help("Lens and sensor position of this clip (changing them rewrites its .gyroflow)")
            Button("Regenerate") { request(.regenerate) }
                .controlSize(.small)
                .disabled(state == .running)
                .help("Sync this clip again and rewrite its .gyroflow (the current file is backed up first)")
        }
        .confirmationDialog("Replace the existing .gyroflow?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { change in
            Button("Regenerate") { apply(change) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The current file is first backed up to ~/Library/Application Support/mlv2dng/gyroflow-backups.")
        }
    }

    /// Asks first when a `.gyroflow` mlv2dng did not write would be replaced, whatever the clip's state.
    private func request(_ change: ClipGyroChange) {
        if gyro.hasForeignGyroflow(clip: key) { pending = change } else { apply(change) }
    }

    private func apply(_ change: ClipGyroChange) {
        switch change {
        case let .lens(id): gyro.setLens(gyro.lenses.first { $0.id == id }, forClip: key)
        case let .position(p): gyro.setPosition(p, forClip: key)
        case .regenerate: Task { await gyro.regenerate(clip: key) }
        }
    }

    private var menuLabel: String {
        let lens = gyro.ownLens(forClip: key)?.label ?? String(localized: "Shoot default")
        guard let p = gyro.ownPosition(forClip: key) else { return lens }
        return "\(lens) · \(p.label)"
    }
}

// MARK: Settings

/// « Lenses » and « Gyro Sync » sections of the settings.
struct GyroSettingsSections: View {
    @ObservedObject var gyro: GyroSyncCoordinator
    @State private var editing: LensDraft?
    @State private var removing: Lens?

    var body: some View {
        Section("Lenses") {
            if gyro.lenses.isEmpty {
                Text("No lens yet. Add the lenses you shoot with; each mounted shoot then uses its default lens, and any clip can use another one.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(gyro.lenses) { lens in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: lens.label)
                        Text(details(lens)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { editing = LensDraft(lens) }
                    Button("Remove") { removing = lens }
                }
            }
            Button("Add Lens…") { editing = LensDraft() }
        }
        Section("Gyro Sync") {
            Picker("Default sensor position", selection: Binding(
                get: { gyro.defaultPosition }, set: { gyro.defaultPosition = $0 })) {
                ForEach(MountingPosition.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
            }
            Text("Where the SenseFlow A1 is mounted on the camera, for shoots without their own position. Applies to clips synced from now on.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $editing) { draft in
            LensEditor(draft: draft) { saved in
                var all = gyro.lenses
                if let i = all.firstIndex(where: { $0.id == saved.id }) { all[i] = saved } else { all.append(saved) }
                gyro.lenses = all
            }
        }
        .confirmationDialog(removing.map { String(localized: "Remove the lens “\($0.label)”?") } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { lens in
            Button("Remove", role: .destructive) {
                gyro.removeLens(id: lens.id)
                LensProfileStore.prune(lensID: lens.id, keep: [])
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Clips using it are synced again with the lens that now applies, or wait for one. Files mlv2dng did not write are kept; replaced files are backed up first.")
        }
    }

    private func details(_ lens: Lens) -> String {
        let focal = "\(formatFocal(lens.focalMM)) mm"
        let n = lens.calibratedProfiles.count
        if n == 0 { return String(localized: "\(focal) · computed profile") }
        return "\(focal) · \(String(localized: "\(n) calibrated profiles"))"
    }
}

/// A lens being added or edited.
struct LensDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    var name: String
    var focal: String
    var profiles: [URL]
    /// Profiles of the saved lens (kept on cancel).
    let savedProfiles: [URL]
    /// Description of each profile's dimensions, read once (on edit / import), never in `body`.
    var dimensions: [URL: String] = [:]

    init() { id = UUID(); isNew = true; name = ""; focal = ""; profiles = []; savedProfiles = [] }
    init(_ lens: Lens) {
        id = lens.id; isNew = false; name = lens.name; focal = formatFocal(lens.focalMM)
        profiles = lens.calibratedProfiles; savedProfiles = lens.calibratedProfiles
        for url in profiles { dimensions[url] = Self.describe(url) }
    }

    static func describe(_ url: URL) -> String {
        guard let d = try? LensProfile.dimensions(of: url) else { return String(localized: "File missing or unreadable") }
        return String(localized: "Calibrated for \(d.width) × \(d.height), horizontal stretch \(formatFocal(d.stretch))")
    }
}

struct LensEditor: View {
    @State var draft: LensDraft
    let onSave: (Lens) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var importError: String?

    private var focal: Double? { parseFocal(draft.focal) }
    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group { if draft.isNew { Text("New Lens") } else { Text("Edit Lens") } }.font(.headline)
            Form {
                TextField("Name", text: $draft.name, prompt: Text("e.g. 7artisans 25 mm f/1.8"))
                TextField("Focal length (mm)", text: $draft.focal, prompt: Text(verbatim: "25"))
                if !draft.focal.isEmpty && focal == nil {
                    Text("The focal length must be a number greater than 0.")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("Use the real focal length: the one Magic Lantern writes in the MLV is not reliable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Calibrated Gyroflow profiles").font(.subheadline.bold())
            if draft.profiles.isEmpty {
                Text("None: mlv2dng computes a distortion-free profile from the focal length.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(draft.profiles, id: \.self) { url in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: draft.dimensions[url] ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { draft.profiles.removeAll { $0 == url } }
                }
            }
            Text("A calibrated profile is used for the clips whose format matches its dimensions; other clips get the computed profile.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Import Calibrated Profile…") { importProfile() }
            if let importError {
                Text(verbatim: importError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let f = focal, f < 16 {
                Label("For short focal lengths, calibrate the lens in Gyroflow and import its profile",
                      systemImage: "lightbulb")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    // Copies imported in this session and not saved are dropped.
                    LensProfileStore.prune(lensID: draft.id, keep: draft.savedProfiles)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let f = focal, !trimmedName.isEmpty else { return }
                    onSave(Lens(id: draft.id, name: trimmedName, focalMM: f, calibratedProfiles: draft.profiles))
                    LensProfileStore.prune(lensID: draft.id, keep: draft.profiles)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(focal == nil || trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func importProfile() {
        importError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let copy: URL
        do {
            // Copied into Application Support, so the lens keeps its profile if the original moves.
            copy = try LensProfile.importProfile(url, lensID: draft.id, root: LensProfileStore.root)
        } catch LensProfileError.unreadable {
            importError = String(localized: "Couldn't read “\(url.lastPathComponent)”.")
            return
        } catch LensProfileError.invalid {
            importError = String(localized: "“\(url.lastPathComponent)” is not a Gyroflow lens profile (no calib_dimension).")
            return
        } catch {
            importError = String(localized: "Couldn't import “\(url.lastPathComponent)”: \(error.localizedDescription)")
            return
        }
        if !draft.profiles.contains(copy) { draft.profiles.append(copy) }
        draft.dimensions[copy] = LensDraft.describe(copy)
    }
}
