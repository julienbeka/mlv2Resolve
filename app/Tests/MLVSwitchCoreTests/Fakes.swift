// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import MLVSwitchCore

/// Tiny lock-protected box so fakes can be Sendable under Swift 6.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    @discardableResult
    func mutate<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

final class FakeProcess: RunningProcess, @unchecked Sendable {
    let args: [String]
    private let state = Locked<(running: Bool, terminated: Bool, onExit: (@Sendable (Int32) -> Void)?)>(
        (true, false, nil))

    init(args: [String]) { self.args = args }

    var isRunning: Bool { state.get().running }
    var wasTerminated: Bool { state.get().terminated }

    var onExit: (@Sendable (Int32) -> Void)? {
        get { state.get().onExit }
        set { state.mutate { $0.onExit = newValue } }
    }

    func terminate() {
        let handler = state.mutate { s -> (@Sendable (Int32) -> Void)? in
            guard s.running else { return nil }
            s.running = false
            s.terminated = true
            return s.onExit
        }
        handler?(15)
    }

    /// Simulates the process dying on its own (crash, external kill).
    func exit(_ code: Int32) {
        let handler = state.mutate { s -> (@Sendable (Int32) -> Void)? in
            guard s.running else { return nil }
            s.running = false
            return s.onExit
        }
        handler?(code)
    }

    /// Value of a `--key=value` argument.
    func value(_ key: String) -> String? {
        args.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }
}

final class FakeLauncher: ProcessLauncher, @unchecked Sendable {
    private let launched = Locked<[(executable: URL, process: FakeProcess)]>([])

    var processes: [FakeProcess] { launched.get().map(\.process) }

    func launch(_ executable: URL, _ args: [String]) throws -> any RunningProcess {
        let p = FakeProcess(args: args)
        launched.mutate { $0.append((executable, p)) }
        return p
    }
}

final class FakeUnmounter: Unmounter, @unchecked Sendable {
    private let state = Locked<(mounts: Set<String>, unmounted: [String])>(([], []))

    func markMounted(_ url: URL) { state.mutate { _ = $0.mounts.insert(url.standardizedFileURL.path) } }
    var unmounted: [String] { state.get().unmounted }

    func unmount(_ path: URL) throws {
        state.mutate {
            $0.unmounted.append(path.standardizedFileURL.path)
            $0.mounts.remove(path.standardizedFileURL.path)
        }
    }

    func isMountPoint(_ path: URL) -> Bool {
        state.get().mounts.contains(path.standardizedFileURL.path)
    }
}

final class RecordingHTTP: @unchecked Sendable {
    private let urls = Locked<[URL]>([])
    var requested: [URL] { urls.get() }
    func get(_ url: URL) async throws { urls.mutate { $0.append(url) } }
}
