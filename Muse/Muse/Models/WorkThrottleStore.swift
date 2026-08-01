//
//  WorkThrottleStore.swift
//  Muse
//
//  Watches thermal state, power source and Low Power Mode, and tells the
//  background passes when they may spawn work.
//
//  Pattern B with ZERO AppState integration — not even a forwarded
//  `objectWillChange`. The two views that show throttle state observe this
//  store directly.
//
//  `waitUntilRunnable()` SUSPENDS while paused rather than returning false.
//  That is what makes a pause resumable: the analyze pass keeps its claim, its
//  in-flight files finish normally, and nothing new starts until the machine
//  cools down or the user presses Resume — no cancel, no restart, no marker
//  churn.
//

import Foundation
import Combine
import IOKit.ps

@MainActor
final class WorkThrottleStore: ObservableObject {
    static let shared = WorkThrottleStore()

    @Published private(set) var mode: ThrottlePolicy.Mode = .normal
    @Published private(set) var onBattery = false

    /// Persisted across relaunch — a pause that silently clears itself reads
    /// as broken.
    var userPaused: Bool {
        get { AppSettings.analysisPaused }
        set {
            AppSettings.analysisPaused = newValue
            objectWillChange.send()
            recompute()
        }
    }

    private var runLoopSource: CFRunLoopSource?
    private var cancellables: Set<AnyCancellable> = []
    /// Continuations parked while `.paused`, resumed as one when it lifts.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {
        NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        installPowerSourceCallback()
        recompute()
    }

    /// Returns immediately unless paused. Cancellation-safe: a cancelled task
    /// awaiting this simply resumes when the pause lifts, and its own
    /// `Task.isCancelled` check does the rest — there is no state to unwind.
    func waitUntilRunnable() async {
        guard mode == .paused else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// The concurrency the caller should use for its NEXT spawn. Re-read per
    /// spawn so a machine that heats up mid-pass narrows without a restart.
    var currentConcurrency: Int { ThrottlePolicy.concurrency(mode) }

    /// Same, for a pass with its own full-speed width. Re-read per spawn: a
    /// backfill that honours only the pause gate keeps running 2–4 wide on
    /// battery / Low Power Mode while the analyze pass has narrowed to 1,
    /// which is the opposite of what §9 decided.
    func concurrency(normal: Int) -> Int { ThrottlePolicy.scaled(mode, normal: normal) }

    private func recompute() {
        onBattery = Self.isOnBattery()
        let next = ThrottlePolicy.mode(thermal: ProcessInfo.processInfo.thermalState,
                                       onBattery: onBattery,
                                       lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                       userPaused: userPaused)
        guard next != mode else { return }
        mode = next
        if next != .paused { releaseWaiters() }
    }

    private func releaseWaiters() {
        let parked = waiters
        waiters = []
        for continuation in parked { continuation.resume() }
    }

    // MARK: - Power source

    /// Public `IOPS*` API only — no entitlement, no private symbols.
    private static func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue()
        else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    private func installPowerSourceCallback() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ raw in
            guard let raw else { return }
            let store = Unmanaged<WorkThrottleStore>.fromOpaque(raw).takeUnretainedValue()
            MainActor.assumeIsolated { store.recompute() }
        }, context)?.takeRetainedValue() else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }
}
