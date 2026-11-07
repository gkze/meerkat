import Foundation
import MeerkatIPC
import MeerkatKit
import Observation

/// One delivered event, with what the table shows computed once on arrival
/// rather than on every redraw.
struct ReceivedEvent: Identifiable {
    /// Arrival order in this app session. The envelope's sequence restarts
    /// with the daemon, so it cannot identify a row on its own.
    let id: Int
    let envelope: EventEnvelope
    let date: Date
    let summary: String
}

/// One `family.` prefix of the catalog, in catalog order.
struct EventFamily: Identifiable {
    let name: String
    let entries: [CatalogEntry]
    var id: String { name }
}

/// The event explorer's view of meerkatd: the catalog, and one live
/// subscription to whichever kind the user starts.
///
/// Nothing here knows any event's Swift type. Payloads stay `JSONValue` and
/// the catalog describes them, so a kind added to the daemon appears here
/// without app changes.
@MainActor
@Observable
final class ExplorerModel {
    enum StreamState: Equatable {
        case idle
        case starting
        case live
        case failed(String)
    }

    static let eventLimit = 500

    private(set) var catalog: [CatalogEntry] = []
    private(set) var catalogState: LoadState = .loading
    private(set) var streamState: StreamState = .idle
    /// Newest first, capped at `eventLimit`. Kept after stopping so the
    /// capture can still be inspected.
    private(set) var events: [ReceivedEvent] = []
    /// The kind whose events are in `events`, if any.
    private(set) var streamingKind: String?

    var selectedKind: String?

    /// Parameters another page asked the explorer to start with, as JSON
    /// text, for the kind they belong to. The parameter field takes them
    /// once when that kind's detail appears.
    private var pendingParameters: (kind: String, text: String)?

    private let client: DaemonClient
    private var stream: Task<Void, Never>?
    /// Bumped by every start and stop, so a superseded stream's late
    /// completion cannot overwrite the state of the one that replaced it.
    private var generation = 0
    private var nextEventID = 0

    /// `client` is the app's one connection to the daemon, shared by every page.
    init(client: DaemonClient) {
        self.client = client
    }

    /// Selects `kind`, optionally with parameters to subscribe with, as a
    /// link from another page does. Any capture of another kind is dropped,
    /// since the page may not be on screen to see the selection change.
    func open(_ kind: String, parameters: JSONValue? = nil) {
        if selectedKind != kind { reset() }
        pendingParameters = parameters.map { (kind, $0.compactText) }
        selectedKind = kind
    }

    /// The parameters `open` left for `kind`, handed over once.
    func takePendingParameters(for kind: String) -> String? {
        guard let pending = pendingParameters, pending.kind == kind else { return nil }
        pendingParameters = nil
        return pending.text
    }

    var selectedEntry: CatalogEntry? {
        guard let selectedKind else { return nil }
        return catalog.first { $0.descriptor.name == selectedKind }
    }

    func families(matching query: String) -> [EventFamily] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let matching =
            needle.isEmpty
            ? catalog
            : catalog.filter {
                $0.descriptor.name.localizedStandardContains(needle)
                    || $0.descriptor.summary.localizedStandardContains(needle)
            }
        var order: [String] = []
        var grouped: [String: [CatalogEntry]] = [:]
        for entry in matching {
            let family = entry.descriptor.family
            if grouped[family] == nil { order.append(family) }
            grouped[family, default: []].append(entry)
        }
        return order.map { EventFamily(name: $0, entries: grouped[$0] ?? []) }
    }

    func loadCatalog() async {
        if catalogState == .loaded { return }
        catalogState = .loading
        do {
            catalog = try await client.catalog()
            catalogState = .loaded
        } catch {
            catalogState = .failed(DaemonFault(error))
        }
    }

    /// Replaces any running subscription with one to `kind`.
    func start(_ kind: String, parameters: JSONValue) {
        stop()
        events = []
        streamingKind = kind
        streamState = .starting
        let generation = generation
        let client = client
        stream = Task { [weak self] in
            do {
                let envelopes = try await client.subscribe(kind, parameters: parameters)
                self?.update(.live, for: generation)
                // Cancelling this task ends the iteration, which terminates
                // the stream and unsubscribes.
                for try await envelope in envelopes {
                    guard let self, self.generation == generation else { return }
                    self.append(envelope)
                }
                self?.update(.idle, for: generation)
            } catch {
                self?.update(.failed("\(error)"), for: generation)
            }
        }
    }

    func stop() {
        generation += 1
        stream?.cancel()
        stream = nil
        if streamState == .starting || streamState == .live { streamState = .idle }
    }

    func clear() {
        events = []
    }

    /// Stops and forgets the capture, for when the selected kind changes.
    func reset() {
        stop()
        streamState = .idle
        events = []
        streamingKind = nil
    }

    private func update(_ state: StreamState, for generation: Int) {
        guard self.generation == generation else { return }
        streamState = state
    }

    private func append(_ envelope: EventEnvelope) {
        nextEventID += 1
        events.insert(
            ReceivedEvent(
                id: nextEventID,
                envelope: envelope,
                date: Date(epochMilliseconds: envelope.time),
                summary: envelope.payload.summary
            ), at: 0)
        if events.count > Self.eventLimit {
            events.removeLast(events.count - Self.eventLimit)
        }
    }
}
