import Foundation
import Darwin

/// Routes SIGINT / SIGTERM / SIGHUP to a handler on a private dispatch queue
/// while a mutation run is in progress. The default action is switched to
/// "ignore" first, so the process never dies before the handler has
/// restored the mutated file; the dispatch source still sees each signal.
public enum SignalTrap {

    public static let interruptSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    /// Install the trap. Returns the uninstaller, which cancels the sources
    /// and puts the previous dispositions back.
    public static func install(
        _ signals: [Int32] = interruptSignals,
        handler: @escaping @Sendable (Int32) -> Void
    ) -> @Sendable () -> Void {
        let queue = DispatchQueue(label: "slopguard.mutate.signals")
        let installed = Installed()
        for number in signals {
            let previous = signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { handler(number) }
            source.resume()
            installed.entries.append((number, previous, source))
        }
        return { installed.uninstall() }
    }

    /// Exit code for a signal: 128 + its number (130 SIGINT, 143 SIGTERM, 129 SIGHUP).
    public static func exitCode(for signal: Int32) -> Int32 {
        128 + signal
    }

    /// The installed sources. Only touched by `install` (before the
    /// uninstaller escapes) and by the uninstaller, under the lock.
    private final class Installed: @unchecked Sendable {
        var entries: [(signal: Int32, previous: sig_t?, source: DispatchSourceSignal)] = []
        private let lock = NSLock()
        private var done = false

        func uninstall() {
            lock.withLock {
                guard !done else { return }
                done = true
                for entry in entries {
                    entry.source.cancel()
                    signal(entry.signal, entry.previous)
                }
            }
        }
    }
}
