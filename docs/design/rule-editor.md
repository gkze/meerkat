# In-app rule editor

The Rules page edits rule files in place: an editor with tsrs's diagnostics
inline, a Problems bar naming their source, the rules directory's files on the
trailing side, and Revert, Save, Try It, Open in Your Editor and an Enabled
switch for the file's rules. Saving writes the file, the daemon reloads it as
it reloads any saved file, and a "Saved and reloaded" confirmation follows.
Completions, hovers and code actions come from tsrs. Unsaved edits survive
quitting as drafts, a crashed tsrs restarts, and when no language server runs a
banner says so and problems come from the daemon's compile of the saved file.
A change to the open file from outside shows at once, or, under unsaved edits,
stops Save until you choose a version.
The file list creates, renames and moves files to the Trash, the page's New
Rule button (⌘N) creates one from the table too, and a watcher on the rules
folder keeps the list current. Themes are chosen in Settings › Editor or
the View menu. Try It runs the unsaved text on events with every effect
captured ("Dry run"). What was measured and checked is under "Evidence".

## Task contract

Requested outcome: open a rule file from the rules directory in the app,
see type errors as you type, save, and see the daemon reload the rule.

Acceptance: in a preview build, open `recorder.ts`, introduce a type error,
see it underlined with its message, fix it, save, and see the Rules page
show the rule reloaded.

## Decision

| | |
|---|---|
| Required capability | A native (AppKit/SwiftUI) source editor for TypeScript with syntax highlighting, range decorations for diagnostics and a cursor/selection API; an LSP client for tsrs's language server over stdio. |
| Chosen | [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor) 0.15.2 (MIT) for the view, with CodeEditTextView 0.12.1 and CodeEditLanguages 0.1.20 under it; ChimeHQ's [LanguageServerProtocol](https://github.com/ChimeHQ/LanguageServerProtocol) 0.14.2 and JSONRPC 0.9.2 (BSD-3-Clause) for the protocol. |
| Strongest alternative | View: STTextView (GPL or a commercial licence) or a WKWebView with Monaco (not native: its own text system, menus and accessibility). Protocol: ChimeHQ's LanguageClient on top of LanguageServerProtocol. |
| Decisive tradeoff | CodeEditSourceEditor is the only maintained, permissively licensed native editor with tree-sitter highlighting; its cost is a prebuilt grammar binary (below) and a slow upstream. LanguageClient would add five packages (FSEventsWrapper, swift-glob, Semaphore, Queue, ProcessEnv) for restart, lazy initialization and file watching, none of which one stdio server for one directory needs; the process channel it provides is about 30 lines here (`RuleLanguageServer`). |
| Validation | All of it compiles with Swift 6.4 / Xcode 27 for macOS 27 (SwiftPM, then Buck). Dependencies build in their own language modes (Swift 5 for most). See "Evidence". |

Revisit when CodeEditSourceEditor stops building on a new Xcode, or when
the editor needs more than its API offers (it already works around two
gaps: no hover API, and a suggestion window that can't refresh an item's
documentation). Restarting tsrs is about 60 lines in `RuleEditorModel`, so
it is no reason to take LanguageClient.

## Design

- `RuleLanguageServer` (actor) runs `tsrs --lsp --stdio` with the rules
  directory as working directory and workspace folder, so tsrs reads the
  daemon's `tsconfig.json` and `.meerkat/meerkat.d.ts`: what it reports is
  what the daemon's next compile reports. Sample mode writes the same
  editor support into its scratch folder (`SampleData.rulesDirectory`). tsrs is located as the CLI and the
  daemon locate it (`TypeScriptToolchain.locate`: `MEERKAT_TSRS`, else
  `Contents/Resources/typescript/tsrs` in the app).
- tsrs pushes no diagnostics for `.ts` files; it answers
  `textDocument/diagnostic` (pull). `RuleEditorModel` sends the whole text
  on each change (`didChange` without a range) and pulls 250 ms after typing
  pauses (a pull took 11 ms on recorder.ts). Hints (unused names) are not
  shown as problems.
- `RuleEditor` shows them twice: an underline per range (CodeEditTextView's
  emphasis layer) with the first message on a line written after its end,
  and the Problems bar, where a row moves the cursor to the problem.
- Saving writes the file atomically and sends `didSave`; the daemon's
  watcher recompiles, and the file list shows each file's state from the
  Rules page's report (Running, n errors, Off).
- **Drafts.** 250 ms after typing pauses, and when the app quits, the open
  file's unsaved text is written to `~/Library/Application
  Support/<bundle id>/Rule Drafts/<sha256 of the path>.json`, with the
  file's text when editing began. Opening a file with a draft restores it
  under a "Restored unsaved changes" notice (Discard Changes, Keep), which
  also says when the file changed on disk since. Saving, reverting or
  answering Don't Save removes the draft. The toolbar's Revert asks first:
  replacing the text view's text clears its undo history, so nothing else
  brings the edits back. Switching files with unsaved edits
  asks Save / Don't Save / Cancel. Closing the window or quitting
  doesn't ask: the edits are kept either way, as in macOS apps that
  autosave, and the window's close button shows the edited dot meanwhile.
  The draft is written before tsrs hears of the edit, so a slow or silent
  tsrs never holds it up. A draft that can't be written, or can't be moved
  with its file on rename, is said in a banner above the editor rather than
  lost quietly. One that can't be read isn't taken for none: it's moved
  aside (`<hash>.unreadable-<uuid>.json`), the banner says where, and the
  file opens as saved. Moving a file with a draft to the Trash warns, open
  or not. A rules folder the editor can't watch is said in the same banner:
  changes made outside Meerkat then don't show until the editor opens again.
- **The session.** `AppState.ruleEditor` (`RuleEditorSession`) holds the
  editor model, whether the page shows it, the Try It panel and the cursor
  and scroll position, as `AppState` holds the page models: following a
  link to the Event Explorer and coming back finds the editor as it was.
- **Restarts.** `RuleEditorModel` supervises the server: when tsrs exits it
  shows "tsrs · restarting (n of 5)", takes problems from the daemon
  meanwhile, and starts a new server after 0.5, 1, 2, 4 and 8 s, re-opening
  the file with the current text. A server that ran for a minute resets the
  count. After five exits in a row, or with no tsrs at all, the
  no-language-server banner stays, with Try Again. Writes racing an exit can't end the app: the
  server ignores SIGPIPE, as meerkatd does, and JSONRPC fails pending
  requests when the pipe closes.
- **Deadlines.** A tsrs that runs but doesn't answer would otherwise hold
  every request, and closing the editor, forever. `RuleLanguageServer.Limits`
  bounds each message: 30 s for `initialize`, 10 s for anything after, and
  a request past its limit counts as an exit ("didn't answer …"), so the
  restart policy above applies. So does a document notification (open,
  change, save, close, files changed) that fails ("missed …"): tsrs would
  hold other text than the editor, and only a new server, which opens the
  file afresh, is back in step. A failed request only goes unanswered.
  Stopping sends `shutdown` and `exit` for up
  to 2 s, then SIGTERM, then SIGKILL 2 s later, and isn't cut short by the
  editor closing. `withDeadline` (MeerkatKit, shared with the daemon
  client) runs the call unstructured, since a task group would wait for a
  call that ignores cancellation; the process's end ends the abandoned call.
- **Files.** The file list's add button makes `<name>.ts` from a template
  (a timer rule that logs, exported under a camelCase name built from the
  file name's identifier characters; tsrs reports no problems in it) after a sheet
  that checks the name as it's typed; a file's context menu renames it
  within its folder, so a library file in a subfolder never moves up where
  it would run (its draft moves with it; its rules get new ids, which name
  the file),
  moves it to the Trash after a confirmation (`FileManager.trashItem`, never
  a delete), or shows it in Finder. The naming rules and the template are
  `RuleFileSource` (`RuleFiles.swift`, with the drafts' `RuleDrafts`), which
  the sheet that makes a rule from a process card uses too; the name sheet
  (`FileNameSheet`) and a file's state at the last compile
  (`RulesModel.status(of:)`) belong to the Rules page, which uses them
  without the editor.
- **The folder.** The file list is the files the daemon compiles
  (`RuleCompiler.ruleSources`), so the two can't disagree. While the editor
  is open, an `FSEventStream` on the rules directory keeps it current and sends tsrs
  `workspace/didChangeWatchedFiles`, because tsrs doesn't watch the folder
  itself and otherwise learns of a new file only when it restarts. Problems
  are checked again after each change.
- **Completions** (`RuleCompletions`, a `CodeSuggestionDelegate`).
  The editor asks after a letter, a digit or one of `. " ' \` /` (tsrs's
  trigger characters without space, `<`, `@`, `#` and `*`), and on
  Control-Space. tsrs answers with labels only, so the word before the
  cursor (inside a string, everything back to the quote, since event names
  hold dots) is what an item replaces, unless the item carries a
  `textEdit` (string literals do). The list is filtered here as typing
  continues, because CodeEditSourceEditor asks for that synchronously.
  Ten items are resolved (`completionItem/resolve`) before the window
  shows, and the next ten whenever one is selected: the window shows a
  resolved item's signature, highlighted, and its documentation, but reads
  them only when the item is selected.
- **Hovers** (`RuleHovers`, a text view coordinator). A tracking area
  on the text view; when the pointer rests on a word for 0.6 s, the editor
  sends `textDocument/hover` and shows the answer in a popover anchored at
  the hovered range (`TextLayoutManager.rectForOffset`): the signature in
  monospace, then the documentation. The client declares Markdown, because
  tsrs's plain-text hover runs the signature into the documentation.
  Typing, moving off the word or leaving the editor closes it.
- **Fixes** (`RuleFix`, `RuleLanguageServer.codeActions`). After each check
  the model sends one `textDocument/codeAction` for the whole file with
  tsrs's own diagnostics and `only: ["quickfix", "source"]`. An action that
  names problems the editor lists is that problem's: a Fix button (its title
  as tooltip and accessibility label), or a Fix menu when there are several.
  The rest are the File Actions menu in the Problems header: tsrs's Organize
  Imports, Remove Unused Imports, Sort Imports, Fix All and Add All Missing
  Imports, when they apply. The offer is stored with the text version it was
  computed for, so `fixes` is empty from the moment the text changes until
  the next check: positions can't outlive their text. `RuleFix.offered` is
  the trust boundary: it keeps only actions whose edits are all for the open
  file, need no command, fit the text without overlapping, and change it.
  tsrs sends `edit` inline, so nothing is resolved, and the client doesn't
  declare `documentChanges`, so `changes` is the only form. Edits go through
  `replaceCharacters`, last first (so same-position inserts keep tsrs's
  order, as LSP requires), in one undo group; the model hears them as an
  ordinary edit. With the daemon's problems showing there are no fixes.
- **Themes** (`RuleEditorTheme`, `RuleEditorThemes.swift`). System (semantic
  colors), Catppuccin, Dracula, GitHub,
  Gruvbox, Nord, One, Solarized and Tokyo Night, chosen in Settings › Editor
  (with a preview) or the View menu, both one `UserDefaults` value. Each has
  light and dark variants that follow the app's appearance, except Dracula
  and Nord, which are dark in both (`isDarkOnly`, which the Settings note
  and the tests read). A palette has fewer colors than `EditorTheme` has
  roles; the mapping is on `RuleEditorPalette`. Comment colors in Nord, One and Tokyo Night are a
  step lighter or darker than the originals so they stay readable.

## Dry run

`DaemonRequest.dryRun(DryRunRequest)` compiles a rule file's unsaved text
and runs one of its rules on events, and answers `DaemonReply.dryRun`
(`DryRunReport`): what each event did, every effect the handler asked for,
logs, errors and timings. Types are in `MeerkatIPC/DryRun.swift`, the work in
`MeerkatDaemon/Rules/RuleDryRunner.swift`. `meerkat rules dry-run <file>`
is the same request from the command line.

An effect a live rule would have refused is refused in a dry run too, before
anything is simulated: `EffectAuthorizer.admit` checks both, including a
`state.set` value over 1 MiB and a `store.record` window not under the rule's
timeout.

**The invariant: a dry run sends no notification, writes no state and runs
no process.** It holds by construction, not by a flag on the effect path:

- `RuleDryRunner` has no `EffectExecutor`, and `Daemon` gives it none. Effects
  end in `EffectSimulator`, whose only access to anything outside itself is
  reading the rule's stored state. Grants are checked by `EffectAuthorizer`,
  split out of the executor, so a missing grant fails the handler as it
  would live.
- The draft runs in a `HandlerHost` of its own, stopped at the end of the
  run. It is never the engine's host, so a runaway handler stops only the
  dry run, and nothing reaches the running rules' queues, breakers or log.
- The file's code may read what its rules grant through Deno's APIs, and
  write nothing: `fs.write` is dropped (`RuleDryRunner.permissions`). A
  handler that writes a file with Deno fails with Deno's error. Deno gives
  rule code no process or network access, live or here.
- The compile uses a copy of the rules directory's sources in the cache
  directory, with the text in place of the file. The rules directory, whose
  watcher reloads rules, is only read, and the copy is removed.

`DryRunTests.noEffectExecutes` runs a rule that notifies, writes state,
execs and writes a file, checks that none of it happened, then saves the
same text and checks that all of it does.

**What a handler sees.** `state.get` reads the rule's stored value, with this
run's simulated writes on top, so a second event sees the first's write.
Every other effect gets a placeholder of its result type, derived from the
catalog (`TypeSchema.placeholder`): empty strings, zeros, `undefined` for an
optional result. That includes reads of the outside world (`clipboard.read`,
`windows.list`, `defaults.read`): they can prompt for a permission, and what
they return isn't a draft's to have. So code that branches on an `exec`'s
output or an `http` status takes the empty path; the report shows each such
effect as `simulated`, and the inspector's fixed note says so.

**Events.** `.sampled(seconds:maxEvents:)` subscribes with the rule's
parameters and collects first (at most 120 s), then runs them: the reply
arrives when the sample ends. `.examples` uses the kind's documented
examples. `.given` takes events the caller holds, checked against the kind's
payload schema. There is no recorded-event store, so the inspector's Recorded
means events the app kept, such as the Event Explorer's. The rule's origin
filter and `match` apply (`RuleDefinition.admission`, shared with the
dispatcher), so an event they turn away is reported as skipped; rate limits
and debounce don't. One run has at most 64 events, 180 s of handlers (checked between
events) and 4 MiB of captured text, and only one runs at a time: a second
request is refused, not queued. Each request compiles the whole directory
and starts a host (about 0.2 s in tests, with small rules directories).

**What the editor calls.**

```swift
let request = DryRunRequest(
    file: "low-battery.ts", text: unsavedText, rule: nil,
    events: .sampled(seconds: 30, maxEvents: 16))
guard case .dryRun(let report) = try await client.send(.dryRun(request)) else { return }
```

`client.send` throws `ClientError.daemon` when the request can't run (a
bad name, invalid events, a run in progress). Otherwise read
`report.outcome`: `.ran`, `.rejected` (show `diagnostics`), or `.chooseRule`
(several rules, or an unknown name: offer `rules`, send `rule`). Each of
`report.runs` is one row in the inspector: `event`, `result`, `effects`, `logs`,
`milliseconds`. `fileLogs` is what the file's top-level code logged.

This API answers once, at the end of the run. Rows arriving during a sample
would need a `DaemonPush` per event, which the runner could add without
changing the rest.

**The inspector** (`RuleTryIt`, `RuleDryRunModel`). The toolbar's
Try It opens it in place of the file list. Live, Recorded and Example are
`.sampled`, `.given` and `.examples`:

- Live samples for 10 s, 30 s or 2 min, up to 16 events. The reply comes at
  the end, so the panel shows "Sampling kind · 0:12 of 0:30", then "Running
  the rule…", and says beforehand that rows appear when the sample ends. The
  panel doesn't subscribe itself and feed `.given`: it would have to apply
  the rule's parameters and compile once per batch.
- Recorded is what the Event Explorer holds, of the rule's kind, newest 64,
  oldest first. Nothing held says so and opens the Explorer.
- Each row shows the time, kind, payload and result, then effects (Simulated,
  Read or Refused), the handler's logs and its time. The footer counts events,
  skips, failures and effects, with compile, load and handler times.
- The fixed note says handlers get empty placeholders, so a branch on an
  `exec` or `http` result takes the empty path, and `state.get` is real. A
  simulated effect's placeholder isn't shown; a read's value and a refusal
  are, as the handler really got them.
- `.rejected` lists the diagnostics, `.chooseRule` points at the rule picker
  (shown when a file has several rules). A report stays after edits with
  "The text has changed since this run".
- meerkatd can't stop a run, so there's no Stop, and runs one at a time.
  A run and its answer carry their file (`RuleDryRunModel.state(for:)`):
  another file's panel shows neither, says which file is running, and
  shows its answer again on going back to it.
- A failed run is classified like every other request to meerkatd
  (`DaemonFault`) and told in the same words (its map's dry-run context): a
  refusal shows meerkatd's words, an unreachable daemon says so, and a
  meerkatd that is a different build, which can't decode the request, gets
  the title "meerkatd is a different build" and the advice to run
  `meerkat agent restart`, not the raw error.
- `MEERKAT_SAMPLE_DATA` answers from `SampleData.dryRun` after 2 s.

Save and Enabled stay in the toolbar above; the panel doesn't repeat them.

## Build wiring

Package.swift names the packages for SourceKit-LSP and Xcode; Buck builds
them from source like every other package (`buck2/third_party/swift`), with
three capabilities beyond a plain Swift target:

- **Objective-C and C targets with their own layout** (CodeEditTextViewObjC,
  TextStory's `Internal`, tree-sitter's `TreeSitter`): sources anywhere in
  the target, a public headers directory other than `include`, a generated
  module map over headers when the package has none, C defines and header
  search paths. The C++ toolchain has no Objective-C compiler, so `.m` files
  are compiled as `-x objective-c -fobjc-arc`.
- **A binary target**: CodeEditLanguages ships every grammar it supports as
  one prebuilt static `CodeLanguagesContainer.xcframework` (34 MB zipped,
  375 MB unpacked, arm64 and x86_64). `prebuilt_framework` unpacks it and
  adds it to Swift's framework search path and the link.
- **Resources**: CodeEditLanguages reads its highlight queries and
  CodeEditSymbols its symbol images through `Bundle.module`.
  `swift_resource_bundle` builds `<package>_<module>.bundle` (copied
  directories, asset catalogs through actool) and the accessor; the bundles
  travel with the app target (`SwiftResourcesInfo`) and the bundler copies
  them into `Contents/Resources`.

`buck2/conformance` derives all of it from the manifests, so
`//buck2/third_party/swift:manifest_test` fails when a pin change alters
sources, headers, defines, linked libraries or resources. Privacy manifests
are not built.

## Evidence

Unless noted, builds and tests ran on the build Mac, and previews were built
with `buck2 run //Tools/RemoteBuild:remote -- preview` (compiled on the build
Mac, signed on the signing Mac). The preview ran against the installed daemon,
with `MEERKAT_TSRS` pointing at the installed app's tsrs, since the preview
bundle has no tsrs of its own.

- **Acceptance (2026-10-29): met.** recorder.ts opened from the Rules page
  with highlighting and the file list; a line `const bad: number = "x";`
  showed `bad` underlined, "Type 'string' is not assignable to type 'number'."
  after the line, and the Problems bar `recorder.ts:23:7 … TS2322`. Changing
  `"x"` to `1` cleared it within the 250 ms check; Save (⌘S) cleared
  "Edited", the editor's footer (the Rules page's report) showed "compiled
  1 second ago", and `meerkat rules` listed `recorder.ts#continuous` loaded
  with lint findings for the new line. The file was then restored
  byte-for-byte; the Rules table showed "Compiled 20 seconds ago" with both
  rules running.
- **Idle cost (2026-10-29)** (60 s at rest, editor showing recorder.ts): the
  app used 0.11 s of CPU (0.03 s with the table showing instead); tsrs used
  0.10 s, with a 26 MB footprint (20 MB resident). The app's footprint was
  84–90 MB with the editor open or closed. tsrs exits when the editor is
  closed.
- **Binary size (2026-10-29)**: the debug executable is 129 MB; 91 MB of it is
  `__TEXT,__const`, the grammars' parse tables (200 `tree_sitter_*`
  languages and scanners linked). The installed release executable without
  the editor was 14 MB. A release build with the editor was not measured.
- **Build (2026-10-29)**: a cold build of the editor's packages took about a
  minute; the container archive adds a 31 MB download (in the
  CodeEditLanguages archive) and 375 MB unpacked in buck-out.
- **On screen (2026-10-29)**: the toolbar, Enabled switch and "No problems"
  row checked live. The server is tsrs, bundled in the app, so the banner says
  Meerkat.app's tsrs is missing or didn't start, with the reason, and the
  status reads "tsrs · ready". The window title stays "Rules" with the file in
  the subtitle, because RootView owns the title. Underlines are straight, not
  dotted, and there is no gutter dot: CodeEditTextView's emphasis styles have
  neither.
- **Accessibility (2026-10-29)**: setting the editor's text through
  accessibility (`AXValue`) replaces the buffer without
  CodeEditSourceEditor's change callback, so the model never sees it; AX caret
  placement by point also lands at the wrong offset. Keyboard input works.
  VoiceOver and other assistive edits are therefore untested and likely
  broken upstream.
- **Unit tests for daily use (2026-10-29).** `buck2 test
  //Tests/MeerkatAppTests:MeerkatAppTests` passed 21 tests, 12 of them in
  `RuleEditorTests`: file names and templates, drafts (round trip, restore on
  open with and without a change on disk, removal on save, revert and Don't
  Save), create without overwriting, rename moving the draft, trash through an
  injected Trash that opens the next file, the restart delays, Try Again
  locating tsrs again, a fake tsrs that exits with status 3 shown as
  "restarting (1 of 5)" and then restarted, the draft written when the editor
  closes, word boundaries and hover parsing. Both format checks passed, and
  the preview built and signed.
- **tsrs outside the app (2026-10-29).** The new-file template has no
  problems; completions after `Math.` return 46 labels without detail or
  documentation, which `completionItem/resolve` adds; string-literal
  completions (`on: "`) return 77 event names with `textEdit`s; hovers
  declared as Markdown return a fenced signature and prose.
- **Live check in the preview (2026-10-30)**, through accessibility clicks and
  window captures. It found five defects the unit tests could not:
  - `SourceEditor` reads its text binding only when created, so switching
    files, Revert, Discard and restoring a draft changed the model and not
    the screen, and typing after a switch would have written the old
    file's text into the new one. Fix: `ProblemAnnotations.show` calls
    `TextViewController.setText` when `RuleEditorModel.opens` changes.
  - A tsrs killed by a signal was not reported, so the editor stayed on
    "tsrs · ready" with no server. Fix: every exit is reported.
  - Clicking a problem didn't move the cursor: setting
    `SourceEditorState.cursorPositions` has no effect (upstream's check
    compares the value with itself). Fix: it calls `setCursorPositions`.
  - The notice combined its buttons into one accessibility element, so
    Keep pressed Discard Changes. Fix: only the text is combined. No other
    `.combine` in the app wrapped a control.
  - A save with errors showed "Saved and reloaded". Fix: it says "Saved with
    errors". The inline message could also land on top of the code, measured
    before layout. Fix: `apply` lays out first.

  Verified after those fixes: the add button and sheet (name, note, Create,
  template on disk); switching files; `kill -9` of the preview's tsrs, twice,
  showing "tsrs · restarting (2 of 5)" and "meerkatd · on save (tsrs)", then a
  new tsrs and "tsrs · ready"; a draft restored on open with the notice,
  "Edited" subtitle and edited dot; Keep and Discard Changes; a draft kept
  across Quit; underline, inline message and Problems row from tsrs, and the
  row jumping to Ln 9, Col 9; "Saved and reloaded" (up to 5 s after the save,
  the page's poll; the daemon's `compiledAt` matched the save); with no
  `MEERKAT_TSRS`, the no-language-server banner ("meerkatd · on save (tsrs)",
  orange "No language server") with Try Again looking again, and a save with a
  type error listing meerkatd's TS2339 in Problems with "1 error" on the file;
  "Saved with errors". The drafts were written to the drafts folder in the
  editor's format, not typed, because background keystrokes don't reach the
  text view. `buck2 test`: 23 tests passed, 14 in `RuleEditorTests`, and both
  format checks.
- **Fixes (2026-10-30).** Against tsrs in a copy of the rules folder, with the
  client capabilities the app declares: TS2304 with an export elsewhere gets
  "Add import from …" (and "Add all missing imports"), TS2420 "Implement
  interface", and most other errors nothing, including "Did you mean" spelling
  errors and unused declarations. Organize, Remove Unused, Sort and Fix All
  are always listed, so no-ops are filtered out. One request returned all of
  them with their diagnostics; `file:` URIs with spaces and non-ASCII names
  came back as sent. A Fix All with same-position inserts, applied last first,
  left only the errors it doesn't cover and one new TS2564 from the stub it
  wrote. `buck2 test`: `RuleEditorTests` passed, including five tests decoding
  tsrs's JSON shape (edit order, adjacent edits, UTF-16 positions, what is
  never offered, fixes to problems); both format checks passed; the preview
  built and signed. No test covers the request from the model, the buttons or
  the undo step, which need the view.
- **Try It (2026-10-30).** `buck2 test`: 44 app tests passed, 11 in
  `RuleDryRunTests` (what each source sends, the Explorer's events by kind and
  order, a report kept with its text, refusals, a dropped run's answer, one
  run at a time, progress wording, rows and summaries), and both format
  checks; the preview built and signed. In the preview, with accessibility
  clicks and window captures: the panel and Recorded's empty state; Example
  against an installed meerkatd of a different build, which answered
  "different build" and showed the restart message; with
  `MEERKAT_SAMPLE_DATA`, the progress line and a report with Ran, Read,
  Simulated and Skipped rows, logs and the footer.
- **Themes (2026-10-30).** `buck2 test //...`: 848 passed; the one failure was
  `buckify_test`, which needs reindeer on the PATH of the build Mac.
  `RuleEditorThemeTests` checks every palette's contrast and which variant
  each appearance gets; it caught the System theme's teal at 2.2:1 on white,
  which is darkened in light mode. Checked in the preview: Dracula restored
  from `UserDefaults`, the View menu changing the theme in place with
  highlighting intact, Solarized following a switch to Light, and Settings ›
  Editor's preview.
- **Live check in the installed app (2026-10-30)**, with full-screen control,
  in throwaway files. Verified: typing, the edited state and a draft written
  by typing; completions after `ctx.`, their documentation and applying one; a
  hover; the sheet's "already exists" note; Don't Save; Rename, with the draft
  moving; Move to Trash with its confirmation; a Fix button adding an import,
  with its title as tooltip; one ⌘Z undoing it whole and the Fix returning;
  File Actions › Fix All; a killed tsrs restarting. Try It against the real
  daemon: Example on the unsaved text showing `state.set` and `notify` as
  Simulated and `state.get` as Read with the simulated value; a rejected
  capability in the list; Live's progress line and "No events" on a 300 s
  timer. `meerkat rules dry-run` reported `would notify` for the renderer
  rule, with both rule files unchanged.

  It found two gaps. A file added to the rules folder outside the editor
  wasn't known to tsrs until tsrs restarted, so it got no Fix button and
  reached the file list late; the fix is the folder watcher (see "The
  folder"). An unknown capability (`state: true`) passed tsrs and was rejected
  only by the loader, because `capabilities` inferred its type from the
  literal; the fix is `OnlyGrants` in `meerkat.d.ts`, which makes it a type
  error, and `typesRejectCommonMistakes` covers a top-level, a nested and an
  allow-list field.
- **Live check, part three (2026-10-30), in the installed app with background
  control.** Try It's Recorded mode ran ten `cpu.sample` events the Event
  Explorer had captured; the rule picker appeared for a file with two rules;
  Run during a run from `meerkat rules dry-run` showed "meerkatd refused the
  dry run"; closing the panel and switching files during a Live sample dropped
  its answer, and Try It came back empty on the new file. The other dark theme
  variants were seen on screen; the light ones rest on the contrast and
  variant tests.

## `meerkat lsp` (investigated, not built)

tsrs's own language server already gives the type errors, so a
`meerkat lsp` subcommand is worth having only for what tsrs cannot know:

- **Lint findings**: Oxlint (with tsrslint's type-aware rules),
  meerkat-lint's `meerkat/*` rules and Oxfmt. Oxlint 1.89, which Meerkat.app
  ships, has its own `oxlint --lsp`; meerkat-lint has none.
- **Load results**: what only the loader decides, such as a file that
  creates rules but exports none, which the daemon reports as a
  `RuleDiagnostic` with tool `loader`.
- **One entry point for other editors**, without knowing where the app
  keeps tsrs.

Shape: `meerkat lsp` runs the bundled `tsrs --lsp --stdio` and relays
messages both ways unchanged, except `textDocument/diagnostic` responses,
to which it appends the file's lint and loader diagnostics, translated from
`RuleDiagnostic` (1-based line and column to LSP's 0-based UTF-16
positions; `tool` as `source`; `code`). Those come from the daemon's report
over XPC (`.rules`, as `meerkat rules` reads it), so they describe the last
saved state; running `RuleLinter` in process instead would cover unsaved
text but duplicate the daemon's lint pass. Cost: the relay (the JSONRPC
package's framing, or a byte relay that parses only diagnostic responses),
the translation, and a refresh request (`workspace/diagnostic/refresh`)
when the daemon's report changes. The app would then run `meerkat lsp`
instead of tsrs, so the editor and other editors see the same thing.

## Licences

CodeEditSourceEditor and CodeEditTextView are MIT. CodeEditLanguages and
CodeEditSymbols publish no licence at any revision (upstream issues
CodeEditLanguages#93, #94, #96 and CodeEditSymbols#23, #24 ask for one).
They ship as they are, by decision (2026-11-06): THIRD_PARTY_NOTICES marks
both "no license published", and //Tools/Notices lets them through only as
exceptions naming their versions, so a bump is reviewed again. The prebuilt
grammar container carries no notices for its grammars, so //Tools/Notices
fetches each of the 37 grammars' licence files at the revision the container
pins.

## Next steps

- **Rest of the live check**: the Fix menu with two candidates, no Fix with
  the server stopped, and choosing a rule from Try It's picker. Each needs
  real typing or a pop-up, which only full-screen control can drive.
- **Signature help**: tsrs offers it on `(` and `,`; CodeEditSourceEditor
  has no view for it, so it would be another popover like the hover.
- **Dry run rows as they happen**, if the wait for a sample proves too long:
  a `DaemonPush` per event ("Dry run").
- **Grammar size**: building only tree-sitter-typescript from source would
  replace the 375 MB container, but CodeEditLanguages' Swift references
  every grammar, so it means a fork or an upstream option.
- Problems on lines not laid out yet get no inline message until the next
  check.
- Quitting with unsaved edits doesn't ask (they are kept as a draft). A
  prompt, if one is wanted, belongs in the app delegate's
  `applicationShouldTerminate`, outside the editor.
