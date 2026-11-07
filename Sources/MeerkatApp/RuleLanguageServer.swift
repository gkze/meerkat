import Foundation
import JSONRPC
import LanguageServerProtocol
import MeerkatIPC

/// tsrs's language server (`tsrs --lsp --stdio`), run for the rules
/// directory while the rule editor is open.
///
/// tsrs is the compiler the daemon type-checks with, and the rules
/// directory carries the daemon's `tsconfig.json` and generated
/// `.meerkat/meerkat.d.ts`, so what the server reports is what the daemon's
/// next compile will report. It answers diagnostics on request
/// (`textDocument/diagnostic`) and pushes none for `.ts` files, so the
/// editor asks after each change; completions and hovers are requests too.
///
/// One open document at a time: the editor shows one file. The process is
/// not restarted here: `onExit` reports the exit and `RuleEditorModel`
/// starts a new server.
///
/// Every message has a deadline (`Limits`): a server that is alive but
/// doesn't answer is reported through `onExit` like one that exited, so the
/// editor's restart policy applies to it too, and `stop()` ends the process
/// whether or not it answers.
actor RuleLanguageServer {
    enum Failure: Error, CustomStringConvertible {
        case exited(status: Int32)
        case killed(signal: Int32)
        /// Alive, but it didn't answer `method` in time.
        case unresponsive(method: String, limit: Duration)

        var description: String {
            switch self {
            case .exited(let status): "tsrs's language server exited (status \(status))"
            case .killed(let signal): "tsrs's language server was killed (signal \(signal))"
            case .unresponsive(let method, let limit):
                "tsrs's language server didn't answer \(method) within \(limit)"
            }
        }
    }

    /// How long each part of a server's life may take.
    struct Limits: Sendable {
        /// The `initialize` handshake, which loads the project.
        var start: Duration = .seconds(30)
        /// Any later request or notification; a pull of diagnostics takes
        /// milliseconds.
        var request: Duration = .seconds(10)
        /// The `shutdown` request and `exit`, when stopping.
        var shutdown: Duration = .seconds(2)
        /// From SIGTERM to SIGKILL.
        var termination: Duration = .seconds(2)

        static let standard = Limits()
    }

    private let process: Process
    private let connection: JSONRPCServerConnection
    private let folder: WorkspaceFolder
    private let limits: Limits
    private let onExit: @Sendable (Failure) -> Void
    /// Finishes when the process has ended.
    private let terminated: AsyncStream<Void>
    private var requests: Task<Void, Never>?
    /// Ending the process, once however many callers stop it.
    private var ending: Task<Void, Never>?

    /// A write racing the server's exit would otherwise end the app with
    /// SIGPIPE; ignored, the write fails and the session reports it closed.
    private static let brokenPipesIgnored: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Starts the server; `onExit` runs when the process ends, however it
    /// ends, or stops answering: after `stop()` nobody is listening any more.
    init(
        compiler: URL, rulesDirectory: URL, limits: Limits = .standard,
        onExit: @escaping @Sendable (Failure) -> Void
    ) throws {
        _ = Self.brokenPipesIgnored
        let process = Process()
        process.executableURL = compiler
        process.arguments = ["--lsp", "--stdio"]
        process.currentDirectoryURL = rulesDirectory
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // The server logs over the protocol (window/logMessage); stderr is
        // noise, and an undrained pipe would block it.
        process.standardError = FileHandle.nullDevice

        let (data, continuation) = DataChannel.DataSequence.makeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(chunk)
            }
        }
        let (terminated, ended) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { process in
            continuation.finish()
            ended.finish()
            let status = process.terminationStatus
            onExit(process.terminationReason == .exit ? .exited(status: status) : .killed(signal: status))
        }
        let writer = input.fileHandleForWriting
        let channel = DataChannel(writeHandler: { try writer.write(contentsOf: $0) }, dataSequence: data)
        try process.run()

        self.process = process
        self.limits = limits
        self.onExit = onExit
        self.terminated = terminated
        connection = JSONRPCServerConnection(dataChannel: channel)
        folder = WorkspaceFolder(uri: rulesDirectory.absoluteString, name: rulesDirectory.lastPathComponent)
    }

    /// The `initialize` handshake. Call once, before anything else.
    func start() async throws {
        requests = Task { [connection, folder] in
            for await event in await connection.eventSequence {
                if case .request(_, let request) = event { await Self.answer(request, folder: folder) }
            }
        }
        let capabilities = ClientCapabilities(
            workspace: nil,
            textDocument: TextDocumentClientCapabilities(
                synchronization: TextDocumentSyncClientCapabilities(
                    dynamicRegistration: false, willSave: false, willSaveWaitUntil: false, didSave: true),
                // Markdown puts a hover's signature in a code block of its
                // own; plain text runs it into the documentation.
                completion: CompletionClientCapabilities(
                    completionItem: .init(snippetSupport: false, documentationFormat: [.markdown, .plaintext]),
                    contextSupport: true),
                hover: HoverClientCapabilities(dynamicRegistration: false, contentFormat: [.markdown, .plaintext]),
                codeAction: CodeActionClientCapabilities(
                    dynamicRegistration: false,
                    codeActionLiteralSupport: .init(codeActionKind: ValueSet(valueSet: [.Quickfix, .Source]))),
                diagnostic: DiagnosticClientCapabilities(relatedDocumentSupport: false)),
            window: nil, general: nil, experimental: nil)
        let parameters = InitializeParams(
            processId: Int(ProcessInfo.processInfo.processIdentifier),
            clientInfo: .init(name: "Meerkat"), locale: nil, rootPath: nil, rootUri: folder.uri,
            initializationOptions: nil, capabilities: capabilities, trace: nil, workspaceFolders: [folder])
        try await bounded("initialize", within: limits.start) { connection in
            _ = try await connection.initialize(parameters)
            try await connection.initialized(InitializedParams())
        }
    }

    func open(_ uri: DocumentUri, text: String, version: Int) async throws {
        try await bounded("textDocument/didOpen") { connection in
            try await connection.textDocumentDidOpen(
                DidOpenTextDocumentParams(
                    textDocument: TextDocumentItem(uri: uri, languageId: .typescript, version: version, text: text)))
        }
    }

    /// The whole text as the new version: rule files are small, and a full
    /// replacement cannot drift from the editor's buffer.
    func change(_ uri: DocumentUri, text: String, version: Int) async throws {
        try await bounded("textDocument/didChange") { connection in
            try await connection.textDocumentDidChange(
                DidChangeTextDocumentParams(
                    uri: uri, version: version,
                    contentChanges: [TextDocumentContentChangeEvent(range: nil, rangeLength: nil, text: text)]))
        }
    }

    func saved(_ uri: DocumentUri) async throws {
        try await bounded("textDocument/didSave") { connection in
            try await connection.textDocumentDidSave(DidSaveTextDocumentParams(uri: uri))
        }
    }

    /// Files that changed on disk, which tsrs doesn't watch itself: until
    /// told, it doesn't know a file added to the folder.
    func filesChanged(_ changes: [FileEvent]) async throws {
        try await bounded("workspace/didChangeWatchedFiles") { connection in
            try await connection.sendNotification(
                .workspaceDidChangeWatchedFiles(DidChangeWatchedFilesParams(changes: changes)))
        }
    }

    func close(_ uri: DocumentUri) async throws {
        try await bounded("textDocument/didClose") { connection in
            try await connection.textDocumentDidClose(
                DidCloseTextDocumentParams(textDocument: TextDocumentIdentifier(uri: uri)))
        }
    }

    func diagnostics(_ uri: DocumentUri) async throws -> [Diagnostic] {
        try await bounded("textDocument/diagnostic") { connection in
            try await connection.diagnostics(
                DocumentDiagnosticParams(textDocument: TextDocumentIdentifier(uri: uri))
            ).items ?? []
        }
    }

    /// Completions at `position`. tsrs sends labels only (no edits, detail
    /// or documentation): the caller replaces the word before the cursor
    /// and resolves an item for its documentation.
    func completions(
        _ uri: DocumentUri, at position: Position, trigger: String?
    ) async throws -> [CompletionItem] {
        let context =
            trigger.map { CompletionContext(triggerKind: .triggerCharacter, triggerCharacter: $0) }
            ?? CompletionContext(triggerKind: .invoked, triggerCharacter: nil)
        return try await bounded("textDocument/completion") { connection in
            try await connection.completion(
                CompletionParams(textDocument: TextDocumentIdentifier(uri: uri), position: position, context: context)
            )?.items ?? []
        }
    }

    /// The item with its detail (the signature) and documentation.
    func resolve(_ item: CompletionItem) async throws -> CompletionItem {
        try await bounded("completionItem/resolve") { connection in try await connection.completeItemResolve(item) }
    }

    func hover(_ uri: DocumentUri, at position: Position) async throws -> Hover? {
        try await bounded("textDocument/hover") { connection in
            try await connection.hover(TextDocumentPositionParams(uri: uri, position: position))
        }
    }

    /// Quick fixes for `diagnostics` and whole-file actions, edits included:
    /// tsrs has nothing to resolve later. Bare commands aren't edits the
    /// editor can apply, so they're left out.
    func codeActions(_ uri: DocumentUri, in range: LSPRange, for diagnostics: [Diagnostic]) async throws -> [CodeAction]
    {
        let context = CodeActionContext(diagnostics: diagnostics, only: [.Quickfix, .Source], triggerKind: .invoked)
        let response = try await bounded("textDocument/codeAction") { connection in
            try await connection.codeAction(
                CodeActionParams(textDocument: TextDocumentIdentifier(uri: uri), range: range, context: context))
        }
        return (response ?? []).compactMap { option in
            if case .optionB(let action) = option { action } else { nil }
        }
    }

    /// Asks a running server to shut down, then ends the process whether
    /// or not it answered: SIGTERM, then SIGKILL. Bounded by `limits`, and
    /// not cut short by the caller's cancellation, so the editor closing
    /// still gives tsrs its chance to exit cleanly.
    func stop() async {
        requests?.cancel()
        guard process.isRunning || ending != nil else { return }
        if ending == nil { ending = Task { await end() } }
        await ending?.value
    }

    private func end() async {
        try? await withDeadline(limits.shutdown) { [connection] in
            try await connection.shutdown()
            try await connection.exit()
        }
        if process.isRunning { process.terminate() }
        let ended: Void? = try? await withDeadline(limits.termination) { [terminated] in
            for await _ in terminated {}
        }
        if ended == nil, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// `body` within `limit`; past it the server counts as gone, which
    /// `onExit` reports, and `stop()` ends it.
    private func bounded<T: Sendable>(
        _ method: String, within limit: Duration? = nil,
        _ body: @escaping @Sendable (JSONRPCServerConnection) async throws -> T
    ) async throws -> T {
        let limit = limit ?? limits.request
        do {
            return try await withDeadline(limit) { [connection] in try await body(connection) }
        } catch is DeadlineExceeded {
            onExit(.unresponsive(method: method, limit: limit))
            throw DeadlineExceeded()
        }
    }

    /// Requests the server sends: the editor has no settings, folders
    /// beyond the rules directory, or UI for edits the server proposes.
    private static func answer(_ request: ServerRequest, folder: WorkspaceFolder) async {
        switch request {
        case .workspaceConfiguration(let params, let reply):
            await reply(.success(params.items.map { _ in LSPAny.null }))
        case .workspaceFolders(let reply):
            await reply(.success([folder]))
        case .workspaceApplyEdit(_, let reply):
            await reply(.success(ApplyWorkspaceEditResult(applied: false, failureReason: "not supported")))
        case .windowShowMessageRequest(_, let reply):
            await reply(.success(nil))
        case .windowShowDocument(_, let reply):
            await reply(.success(ShowDocumentResult(success: false)))
        case .clientRegisterCapability(_, let reply), .clientUnregisterCapability(_, let reply),
            .workspaceCodeLensRefresh(let reply), .workspaceSemanticTokenRefresh(let reply),
            .windowWorkDoneProgressCreate(_, let reply):
            await reply(nil)
        case .custom(_, _, let reply):
            await reply(.success(.null))
        }
    }
}

extension NSString {
    /// The LSP position (0-based line, UTF-16 character) of a text offset.
    nonisolated func lspPosition(of offset: Int) -> Position {
        var line = 0
        var lineStart = 0
        for index in 0..<min(offset, length) where character(at: index) == 0x0A {
            line += 1
            lineStart = index + 1
        }
        return Position(line: line, character: offset - lineStart)
    }

    /// The text offset of an LSP position, or nil past the end.
    nonisolated func offset(ofLSP position: Position) -> Int? {
        var line = 0
        var index = 0
        while line < position.line {
            guard index < length else { return nil }
            if character(at: index) == 0x0A { line += 1 }
            index += 1
        }
        let offset = index + position.character
        return offset <= length ? offset : nil
    }
}
