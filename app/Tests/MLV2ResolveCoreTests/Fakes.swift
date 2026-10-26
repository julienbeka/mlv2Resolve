// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import MLV2ResolveCore

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
    private let sent = Locked<[Int32]>([])
    /// When set, `signal` throws even though the process looks alive (it died meanwhile).
    let failsSignals = Locked(false)

    init(args: [String]) {
        self.args = args
    }

    var isRunning: Bool { state.get().running }
    var wasTerminated: Bool { state.get().terminated }
    /// Signals delivered so far, in order.
    var signals: [Int32] { sent.get() }

    func signal(_ sig: Int32) throws {
        guard isRunning, !failsSignals.get() else { throw MountError.signalFailed(errno: ESRCH) }
        sent.mutate { $0.append(sig) }
    }

    var onExit: (@Sendable (Int32) -> Void)? {
        get { state.get().onExit }
        set { state.mutate { $0.onExit = newValue } }
    }

    func terminate() { stop(15, terminated: true) }

    /// Simulates the process dying on its own (crash, external kill).
    func exit(_ code: Int32) { stop(code, terminated: false) }

    /// Simulates dying without the exit callback having run yet.
    func dieSilently() {
        state.mutate { $0.running = false }
    }

    private func stop(_ code: Int32, terminated: Bool) {
        let (wasRunning, handler) = state.mutate { s -> (Bool, (@Sendable (Int32) -> Void)?) in
            guard s.running else { return (false, nil) }
            s.running = false
            s.terminated = terminated
            return (true, s.onExit)
        }
        guard wasRunning else { return }
        handler?(code)
    }

    /// Value of a `--key=value` argument.
    func value(_ key: String) -> String? {
        args.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }
}

final class FakeUnmounter: Unmounter, @unchecked Sendable {
    private let state = Locked<(mounts: Set<String>, calls: [(path: String, force: Bool)], failing: Set<String>,
                                busy: Set<String>)>(([], [], [], []))

    func markMounted(_ url: URL) { state.mutate { _ = $0.mounts.insert(url.standardizedFileURL.path) } }
    func markUnmounted(_ url: URL) { state.mutate { _ = $0.mounts.remove(url.standardizedFileURL.path) } }
    func failUnmount(_ url: URL) { state.mutate { _ = $0.failing.insert(url.standardizedFileURL.path) } }
    /// Files open on the volume: a polite unmount throws, a forced one works.
    func makeBusy(_ url: URL) { state.mutate { _ = $0.busy.insert(url.standardizedFileURL.path) } }
    var unmounted: [String] { state.get().calls.map(\.path) }
    var forced: [Bool] { state.get().calls.map(\.force) }

    func unmount(_ path: URL, force: Bool) throws {
        let p = path.standardizedFileURL.path
        let failed = state.mutate { s -> Bool in
            s.calls.append((p, force))
            if s.failing.contains(p) || (!force && s.busy.contains(p)) { return true }
            s.mounts.remove(p)
            return false
        }
        if failed { throw MountError.unmountFailed(path) }
    }

    func isMountPoint(_ path: URL) -> Bool {
        state.get().mounts.contains(path.standardizedFileURL.path)
    }
}

/// Simulates the engine: a launch makes the mount point appear (unless disabled).
final class FakeLauncher: ProcessLauncher, @unchecked Sendable {
    let unmounter: FakeUnmounter
    let mountsAppear = Locked(true)
    private let launched = Locked<[FakeProcess]>([])

    init(unmounter: FakeUnmounter) { self.unmounter = unmounter }

    var processes: [FakeProcess] { launched.get() }

    let logs = Locked<[URL?]>([])

    func launch(_ executable: URL, _ args: [String], log: URL?) throws -> any RunningProcess {
        logs.mutate { $0.append(log) }
        let p = FakeProcess(args: args)
        launched.mutate { $0.append(p) }
        if mountsAppear.get() { unmounter.markMounted(URL(fileURLWithPath: args[0])) }
        return p
    }
}
