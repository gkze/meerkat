/// Runs disk-image tests one at a time across suites.
///
/// Those tests attach real images and assert on which disks and volumes the
/// OS reports; another suite attaching its own image at the same moment makes
/// a correct report look wrong. Swift Testing's `.serialized` only orders
/// tests within one suite, hence this gate.
actor DiskImageGate {
    static let shared = DiskImageGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // Ownership passes straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }
}
