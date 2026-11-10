import Foundation
import IOKit
import Synchronization

/// Reads from the IORegistry. Every object handed to a body is released after
/// the body returns, so callers never own IOKit references.
enum IORegistry {
    /// Calls `body` for each service of `className` (or a subclass) present
    /// now. Throws when the registry can't be searched, which is not the
    /// same as finding no services.
    static func forEachService(matching className: String, _ body: (io_object_t) -> Void) throws {
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator)
        guard status == KERN_SUCCESS else {
            throw EventError.sourceUnavailable("IOServiceGetMatchingServices(\(className)) failed with \(status)")
        }
        defer { IOObjectRelease(iterator) }
        drain(iterator, body)
    }

    /// Calls `body` for each service left in `iterator`, which rearms a
    /// matching notification.
    static func drain(_ iterator: io_iterator_t, _ body: (io_object_t) -> Void = { _ in }) {
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            body(service)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    /// The first service of `className`, for singletons such as `IOPMrootDomain`.
    static func withService<T>(matching className: String, _ body: (io_object_t) -> T) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return body(service)
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func entryID(_ entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    static func className(_ entry: io_object_t) -> String {
        var name = nameBuffer
        IOObjectGetClass(entry, &name)
        return String(nulTerminated: name)
    }

    /// The entry's name in the registry plane, or nil when it has none.
    static func name(_ entry: io_registry_entry_t) -> String? {
        var name = nameBuffer
        return IORegistryEntryGetName(entry, &name) == KERN_SUCCESS ? String(nulTerminated: name) : nil
    }

    /// `io_name_t`, which Swift imports as a 128-byte tuple.
    private static var nameBuffer: [CChar] { [CChar](repeating: 0, count: 128) }
}

/// An IOKit notification on a port scheduled on a private serial queue, with
/// the context its C callback reads. Teardown runs on that queue, after any
/// callback in flight, and releases the context last.
final class IONotificationRegistration<Context: AnyObject & Sendable>: Sendable {
    private let context: Context
    private let queue: DispatchQueue
    private let active = Mutex<Active?>(nil)

    /// Mach handles, only used on `queue` once scheduled there.
    private struct Active: @unchecked Sendable {
        let port: IONotificationPortRef
        let object: io_object_t
    }

    init(label: String, context: Context) {
        self.context = context
        queue = DispatchQueue(label: "com.gkze.meerkat.\(label)", qos: .utility)
    }

    /// Creates the port and schedules it after `register`, so `register` can
    /// use the port's object before any callback can run.
    ///
    /// - Parameters:
    ///   - call: the registering call, for the error.
    ///   - register: registers on `port` with `refcon` as the callback's
    ///     context, and sets `object`, released when stopping.
    func start(
        _ call: String,
        register: (_ port: IONotificationPortRef, _ refcon: UnsafeMutableRawPointer, _ object: inout io_object_t) ->
            kern_return_t
    ) throws {
        // The callback's reference: released in `stop`, after the port is
        // destroyed, or below when registration fails.
        let reference = Unmanaged.passRetained(context)
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            reference.release()
            throw EventError.sourceUnavailable("IONotificationPortCreate failed")
        }
        var object: io_object_t = IO_OBJECT_NULL
        let status = register(port, reference.toOpaque(), &object)
        guard status == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            reference.release()
            throw EventError.sourceUnavailable("\(call) failed with \(status)")
        }
        active.withLock { $0 = Active(port: port, object: object) }
        IONotificationPortSetDispatchQueue(port, queue)
    }

    func stop() {
        guard let registered = active.withLock({ $0.take() }) else { return }
        let reference = Unmanaged.passUnretained(context)
        queue.async {
            IOObjectRelease(registered.object)
            IONotificationPortDestroy(registered.port)
            reference.release()
        }
    }
}
