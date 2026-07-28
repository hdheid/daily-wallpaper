import AppKit
import Foundation

@MainActor
final class AutomationEventMonitor {
    var onEvent: ((UpdateTrigger) -> Void)?

    private var defaultObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    func start() {
        guard defaultObservers.isEmpty, workspaceObservers.isEmpty else { return }

        let center = NotificationCenter.default
        defaultObservers = [
            center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.calendarDayChanged) }
            },
            center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.timeZoneChanged) }
            },
            center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.clockChanged) }
            },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.screensChanged) }
            }
        ]

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.wake) }
            },
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.sessionActive) }
            },
            workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.spaceChanged) }
            }
        ]
    }

    func stop() {
        let center = NotificationCenter.default
        defaultObservers.forEach(center.removeObserver)
        defaultObservers.removeAll()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()
    }
}

@MainActor
final class RetryTimer {
    private var timer: Timer?

    func schedule(entry: RetrySchedule.Entry, operation: @MainActor @Sendable @escaping () -> Void) {
        cancel()
        let timer = Timer(fire: Date().addingTimeInterval(entry.delay), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { operation() }
        }
        timer.tolerance = entry.tolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
