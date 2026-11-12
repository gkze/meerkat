import Foundation

/// Keeps a crashing extension from resetting connections again and again.
///
/// Every flow the filter counts stays attached to it, and when the filter's
/// session ends, the kernel resets every attached connection (seen on macOS
/// 27, `NewFlowVerdict.allowAndCount`). One crash costs the connections in
/// flight once; an extension that crashes on every start would cost them on
/// every restart. So the extension keeps this record across runs: a start
/// that finds the last run never stopped cleanly counts as a crash, and after
/// `limit` crashes within `window` it declines to start the filter, which then
/// holds no connection. Once the window passes, the next start is allowed.
public struct CrashGuard: Codable, Sendable, Equatable {
    public static let limit = 3
    public static let window: TimeInterval = 10 * 60

    /// Whether a run is in progress: set at start, cleared at a clean stop.
    public private(set) var running = false
    /// When crashes were found, oldest first, only those within the window.
    public private(set) var crashes: [Date] = []

    public init() {}

    public enum Decision: Equatable, Sendable {
        case start
        /// Too many crashes: refuse until `until`.
        case refuse(until: Date)
    }

    /// At a start: counts the previous run as a crash if it never stopped,
    /// then decides. A refused start leaves no run in progress.
    public mutating func starting(at now: Date) -> Decision {
        if running { crashes.append(now) }
        crashes.removeAll { now.timeIntervalSince($0) >= Self.window || $0 > now }
        if crashes.count >= Self.limit, let oldest = crashes.first {
            running = false
            return .refuse(until: oldest.addingTimeInterval(Self.window))
        }
        running = true
        return .start
    }

    /// At a clean stop.
    public mutating func stopped() {
        running = false
    }
}
