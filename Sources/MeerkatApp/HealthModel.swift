import Foundation
import MeerkatIPC
import MeerkatKit
import Observation

extension SourceStatistics: Identifiable {
    public var id: UInt64 { instance }
}

/// One `meerkat.dropped` report: a source whose subscribers fell behind.
struct DroppedReport: Identifiable {
    let id: Int
    let date: Date
    let kind: String
    let parameters: JSONValue
    /// The rule file whose subscription fell behind; nil for a client of the
    /// daemon (this app, the CLI, MCP) or the daemon's own subscriptions (its
    /// rules-folder watch), as `DroppedEventsPayload.file` says. One source
    /// reports once per file.
    let file: String?
    /// A count from the daemon, kept as decoded: `Int(_:)` would trap on a
    /// value out of its range.
    let dropped: Double
}

/// The daemon's own state for the Daemon health page: status polled while
/// the page is on screen, rates derived from successive polls, and
/// `meerkat.dropped` reports.
@MainActor
@Observable
final class HealthModel {
    static let pollInterval: Duration = .seconds(2)
    static let droppedLimit = 100

    private(set) var status: DaemonStatus?
    private(set) var loadState: LoadState = .loading
    /// Events per second for each source instance, over the last poll
    /// interval. Missing until a source has been seen twice.
    private(set) var rates: [SourceStatistics.ID: Double] = [:]
    /// Newest first, capped at `droppedLimit`.
    private(set) var dropped: [DroppedReport] = []

    private let client: any DaemonConnection
    private var previous: (date: Date, delivered: [SourceStatistics.ID: UInt64])?
    private var nextDroppedID = 0

    init(client: any DaemonConnection) {
        self.client = client
    }

    var startedAt: Date? {
        status.map { Date(epochMilliseconds: $0.startedAt) }
    }

    /// Runs while the page is on screen; cancelled with the page's task.
    func watch() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.poll() }
            group.addTask { await self.followDropped() }
        }
    }

    func refresh() async {
        do {
            let status = try await client.status()
            let now = Date()
            if let previous {
                let elapsed = now.timeIntervalSince(previous.date)
                var rates: [SourceStatistics.ID: Double] = [:]
                for source in status.sources {
                    guard let before = previous.delivered[source.id], elapsed > 0, source.delivered >= before
                    else { continue }
                    rates[source.id] = Double(source.delivered - before) / elapsed
                }
                self.rates = rates
            }
            previous = (now, Dictionary(status.sources.map { ($0.id, $0.delivered) }, uniquingKeysWith: { $1 }))
            if status != self.status { self.status = status }
            if loadState != .loaded { loadState = .loaded }
        } catch {
            loadState = .failed(DaemonFault(error))
            previous = nil
            rates = [:]
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func followDropped() async {
        while !Task.isCancelled {
            do {
                for try await (payload, envelope) in try await client.events(
                    MeerkatDroppedEvent.self, parameters: NoParameters())
                {
                    append(payload, at: envelope.time)
                }
            } catch {
                if Task.isCancelled { return }
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// `time` is Unix epoch milliseconds, as in envelopes.
    private func append(_ report: DroppedEventsPayload, at time: Double) {
        nextDroppedID += 1
        dropped.insert(
            DroppedReport(
                id: nextDroppedID,
                date: Date(epochMilliseconds: time),
                kind: report.kind,
                parameters: report.parameters,
                file: report.file,
                dropped: report.dropped
            ), at: 0)
        if dropped.count > Self.droppedLimit {
            dropped.removeLast(dropped.count - Self.droppedLimit)
        }
    }
}
