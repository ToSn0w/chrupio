import Foundation
import os

private let watchdogLog = Logger(subsystem: "Chrupio", category: "watchdog")

/// Pings the main thread from a background queue. When it hasn't answered for `stallAfter` seconds, recording and
/// detection are frozen (they all run there), so it logs a fault and posts a notification once per stall.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()
    static let stallAfter: TimeInterval = 10

    private let queue = DispatchQueue(label: "com.chrupio.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Touched only on `queue`. Uptime, not `Date`: it stops while the Mac sleeps, so a night's sleep isn't a stall.
    private var lastAnswer = ProcessInfo.processInfo.systemUptime
    private var alerted = false

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [self] in check() }
        timer.resume()
        self.timer = timer
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [self] in
            let answered = ProcessInfo.processInfo.systemUptime
            queue.async { [self] in
                lastAnswer = max(lastAnswer, answered)
                if alerted {
                    alerted = false
                    watchdogLog.error("main thread answering again")
                }
            }
        }
        let silent = now - lastAnswer
        guard silent > Self.stallAfter, !alerted else { return }
        alerted = true
        watchdogLog.fault("main thread stalled for \(Int(silent), privacy: .public) s; recording and detection are frozen")
        Notifier.post(title: "Chrupio is frozen",
                      body: "Meetings aren't being recorded. Quit Chrupio and open it again.", enabled: true)
    }
}
