import Darwin
import Foundation

/// Runs one executable bounded in time and output: the daemon's `exec`
/// effect, and the rules tools (`RuleCompiler.runTool`).
///
/// The child gets its own process group (so a timeout also ends anything it
/// started), only the three pipes as file descriptors, and no shell. All I/O
/// goes through non-blocking dispatch sources, so nothing here blocks a
/// thread, and a child that floods stdout while ignoring stdin cannot
/// deadlock the daemon. The deadline is armed before any I/O starts; after
/// it, or when the calling task is cancelled, the child and its group get
/// SIGTERM and, a second later, SIGKILL. One second after the child exits,
/// whatever in its group still holds the pipes is killed and the result is
/// returned.
public enum ChildProcess {
    public enum Failure: Error, CustomStringConvertible {
        case spawn(path: String, errno: Int32)
        case pipe(Int32)

        public var description: String {
            switch self {
            case .spawn(let path, let code): return "could not start \(path): \(String(cString: strerror(code)))"
            case .pipe(let code): return "could not create pipes: \(String(cString: strerror(code)))"
            }
        }
    }

    /// - Parameters:
    ///   - environment: the child's whole environment; nothing is inherited.
    ///   - directory: its working directory, the caller's when nil.
    ///   - outputLimit: bytes kept of stdout and of stderr, each; the rest is
    ///     read and dropped.
    public static func run(
        path: String, arguments: [String], environment: [String: String], directory: String? = nil,
        stdin input: String?, timeout: Double, outputLimit: Int, onSpawn: @Sendable (pid_t) -> Void = { _ in }
    ) async throws -> ExecResult {
        let (pid, stdinFD, stdoutFD, stderrFD) = try { () throws -> (pid_t, Int32, Int32, Int32) in
            var stdinPipe: [Int32] = [-1, -1]
            var stdoutPipe: [Int32] = [-1, -1]
            var stderrPipe: [Int32] = [-1, -1]
            guard pipe(&stdinPipe) == 0 else { throw Failure.pipe(errno) }
            guard pipe(&stdoutPipe) == 0 else {
                closeAll(stdinPipe)
                throw Failure.pipe(errno)
            }
            guard pipe(&stderrPipe) == 0 else {
                closeAll(stdinPipe + stdoutPipe)
                throw Failure.pipe(errno)
            }
            // Close-on-exec everywhere. Every spawn in the daemon passes on
            // only the descriptors it names (`Process`, and this one with
            // POSIX_SPAWN_CLOEXEC_DEFAULT), so this is for a spawn that
            // doesn't, such as one inside a library: it can still inherit an
            // end in the moment before the flag is set, as Darwin has no
            // pipe2. posix_spawn's dup2 gives the child its three without
            // the flag.
            for descriptor in stdinPipe + stdoutPipe + stderrPipe {
                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            }

            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
            posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
            posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
            if let directory { posix_spawn_file_actions_addchdir(&actions, directory) }

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // Its own process group, and no inherited descriptors beyond the
            // three above (POSIX_SPAWN_CLOEXEC_DEFAULT is Apple's extension).
            // Every signal at its default and none blocked: the daemon
            // ignores SIGTERM and SIGPIPE (meerkatd/main.swift), and a child
            // that inherited that would outlive the timeout's SIGTERM and
            // write on into a closed pipe.
            posix_spawnattr_setflags(
                &attributes,
                Int16(
                    POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                ))
            posix_spawnattr_setpgroup(&attributes, 0)
            var everySignal = sigset_t()
            sigfillset(&everySignal)
            posix_spawnattr_setsigdefault(&attributes, &everySignal)
            var noSignal = sigset_t()
            sigemptyset(&noSignal)
            posix_spawnattr_setsigmask(&attributes, &noSignal)

            let argv = ([path] + arguments).map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                for pointer in argv { free(pointer) }
                for pointer in envp { free(pointer) }
            }

            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
            // The child holds its own copies; the parent keeps only its ends.
            close(stdinPipe[0])
            close(stdoutPipe[1])
            close(stderrPipe[1])
            guard spawned == 0 else {
                closeAll([stdinPipe[1], stdoutPipe[0], stderrPipe[0]])
                throw Failure.spawn(path: path, errno: spawned)
            }
            return (pid, stdinPipe[1], stdoutPipe[0], stderrPipe[0])
        }()
        onSpawn(pid)

        let run = Run(
            pid: pid, stdin: stdinFD, stdout: stdoutFD, stderr: stderrFD,
            input: input.map { Data($0.utf8) }, timeout: timeout, outputLimit: outputLimit)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in run.start(continuation) }
        } onCancel: {
            run.cancel()
        }
    }

    private static func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
    }

    /// The state of one running child, confined to `queue`.
    private final class Run: @unchecked Sendable {
        let pid: pid_t
        let stdin: Int32
        let input: Data?
        let timeout: Double
        let outputLimit: Int
        let queue = DispatchQueue(label: "com.gkze.meerkat.exec")
        var continuation: CheckedContinuation<ExecResult, Never>?

        var readers: [Int32: any DispatchSourceRead] = [:]
        var writer: (any DispatchSourceWrite)?
        var pendingInput = Data()
        var buffers: [Int32: Data] = [:]
        let stdoutFD: Int32
        let stderrFD: Int32
        var exitStatus: Int32?
        var exitSource: (any DispatchSourceProcess)?
        var timedOut = false

        init(
            pid: pid_t, stdin: Int32, stdout: Int32, stderr: Int32, input: Data?, timeout: Double, outputLimit: Int
        ) {
            self.pid = pid
            self.stdin = stdin
            self.stdoutFD = stdout
            self.stderrFD = stderr
            self.input = input
            self.timeout = timeout
            self.outputLimit = outputLimit
        }

        func start(_ continuation: CheckedContinuation<ExecResult, Never>) {
            queue.async { [self] in
                self.continuation = continuation
                // Deadline first: nothing after this can wait unbounded.
                queue.asyncAfter(deadline: .now() + timeout) { [self] in expire() }

                for descriptor in [stdoutFD, stderrFD] {
                    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
                    buffers[descriptor] = Data()
                    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                    source.setEventHandler { [self] in drain(descriptor) }
                    source.setCancelHandler { close(descriptor) }
                    readers[descriptor] = source
                    source.resume()
                }

                let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
                exit.setEventHandler { [self] in reap() }
                exitSource = exit
                exit.resume()
                // The child may have exited before the source was armed.
                reap(blocking: false)

                // stdin through a non-blocking write source: a child that
                // never reads must not hold a thread. (SIGPIPE is ignored by
                // the daemon, so a closed pipe is an error, not a signal.)
                pendingInput = input ?? Data()
                if pendingInput.isEmpty {
                    close(stdin)
                } else {
                    _ = fcntl(stdin, F_SETFL, fcntl(stdin, F_GETFL) | O_NONBLOCK)
                    let source = DispatchSource.makeWriteSource(fileDescriptor: stdin, queue: queue)
                    let descriptor = stdin
                    source.setEventHandler { [self] in feed() }
                    source.setCancelHandler { close(descriptor) }
                    writer = source
                    source.resume()
                }
            }
        }

        private func feed() {
            while !pendingInput.isEmpty {
                // Non-empty, so the buffer has an address.
                let written = pendingInput.withUnsafeBytes { raw in
                    raw.baseAddress.map { write(stdin, $0, raw.count) } ?? 0
                }
                if written > 0 {
                    pendingInput.removeFirst(written)
                } else if written < 0, errno == EAGAIN || errno == EINTR {
                    return
                } else {
                    break
                }
            }
            writer?.cancel()
            writer = nil
        }

        private func drain(_ descriptor: Int32) {
            var chunk = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let count = read(descriptor, &chunk, chunk.count)
                if count > 0 {
                    // Keep reading past the limit (discarding) so the child
                    // never blocks on a full pipe.
                    let room = max(outputLimit - (buffers[descriptor]?.count ?? 0), 0)
                    if room > 0 { buffers[descriptor]?.append(contentsOf: chunk.prefix(min(count, room))) }
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    readers.removeValue(forKey: descriptor)?.cancel()
                    finishIfDone()
                    return
                } else if errno == EAGAIN {
                    return
                }
            }
        }

        private func reap(blocking: Bool = true) {
            guard exitStatus == nil else { return }
            var status: Int32 = 0
            let result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
            guard result == pid else { return }
            exitStatus = status
            exitSource?.cancel()
            exitSource = nil
            // Something the child started may still hold the pipes; give it
            // a second, then end the group and stop reading.
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                if !readers.isEmpty { kill(-pid, SIGKILL) }
                for reader in readers.values { reader.cancel() }
                readers.removeAll()
                writer?.cancel()
                writer = nil
                finishIfDone()
            }
            finishIfDone()
        }

        /// The caller no longer wants the result: the child ends as at the
        /// deadline, without counting as timed out.
        func cancel() {
            queue.async { [self] in end() }
        }

        private func expire() {
            guard exitStatus == nil else { return }
            timedOut = true
            end()
        }

        private func end() {
            guard exitStatus == nil else { return }
            // The group, and the child itself in case it left the group.
            kill(-pid, SIGTERM)
            kill(pid, SIGTERM)
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                if exitStatus == nil {
                    kill(-pid, SIGKILL)
                    kill(pid, SIGKILL)
                }
            }
        }

        private func finishIfDone() {
            guard let status = exitStatus, readers.isEmpty, let continuation else { return }
            self.continuation = nil
            // Input the child never read is abandoned with it.
            writer?.cancel()
            writer = nil
            let signalled = (status & 0x7F) != 0 && (status & 0x7F) != 0x7F
            continuation.resume(
                returning: ExecResult(
                    status: signalled ? nil : (status >> 8) & 0xFF,
                    signal: signalled ? status & 0x7F : nil,
                    stdout: String(decoding: buffers[stdoutFD] ?? Data(), as: UTF8.self),
                    stderr: String(decoding: buffers[stderrFD] ?? Data(), as: UTF8.self),
                    timedOut: timedOut
                ))
        }
    }
}
