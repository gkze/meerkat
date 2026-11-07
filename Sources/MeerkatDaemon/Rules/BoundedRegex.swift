import CICU
import Foundation

/// An ICU regular expression whose every match is bounded in time.
///
/// A rule's `match` runs in the daemon on every event, and ICU backtracks:
/// `(a|a)*b` against 16 KiB of `a` would run for longer than anyone waits
/// without a limit (measured: over 6 s for 40 characters). ICU's time limit
/// stops it in about `timeLimit` milliseconds with `U_REGEX_TIME_OUT`.
///
/// One URegularExpression is not safe for concurrent use; the lock
/// serializes matches (one rule's dispatcher is sequential anyway).
final class BoundedRegex: @unchecked Sendable {
    enum Outcome: Equatable {
        case match, noMatch
        /// The matcher stopped without an answer: its time limit, or another
        /// ICU error such as its backtracking stack limit.
        case aborted(String)
    }

    /// In ICU's matcher time-limit units, approximately milliseconds.
    static let timeLimit: Int32 = 50

    let pattern: String
    private let regex: OpaquePointer
    private let lock = NSLock()

    struct InvalidPattern: Error {}

    init(_ pattern: String) throws {
        self.pattern = pattern
        var status = U_ZERO_ERROR
        let units = Array(pattern.utf16)
        guard let regex = uregex_open(units, Int32(units.count), 0, nil, &status),
            status.rawValue <= U_ZERO_ERROR.rawValue
        else {
            throw InvalidPattern()
        }
        uregex_setTimeLimit(regex, Self.timeLimit, &status)
        self.regex = regex
    }

    deinit {
        uregex_close(regex)
    }

    /// Whether the pattern matches anywhere in `text`.
    func evaluate(_ text: String) -> Outcome {
        let units = Array(text.utf16)
        lock.lock()
        defer { lock.unlock() }
        var status = U_ZERO_ERROR
        return units.withUnsafeBufferPointer { buffer -> Outcome in
            uregex_setText(regex, buffer.baseAddress, Int32(buffer.count), &status)
            let found = uregex_find(regex, 0, &status)
            // Detach the text before the buffer goes away.
            var reset = U_ZERO_ERROR
            uregex_setText(regex, [UInt16](), 0, &reset)
            if status == U_REGEX_TIME_OUT { return .aborted("hit its time limit") }
            if status.rawValue > U_ZERO_ERROR.rawValue {
                return .aborted("failed (\(String(cString: u_errorName(status))))")
            }
            return found != 0 ? .match : .noMatch
        }
    }
}
