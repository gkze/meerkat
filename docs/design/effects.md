# Effects: one catalog for what rules can do, and what they can see

Scope: the core effects (state, notifications, processes, `exec`, `http` and
the sample store), tier A (public macOS APIs that need no root and no privacy
grant) and tier B (public APIs behind a privacy grant). Tier C (anything that
needs root) and controls with no public API are out of scope.

Contents: [Question](#question) · [Catalog](#catalog) ·
[Grants](#grants) · [Observation](#observation) · [Effects](#effects) ·
[Out of scope](#out-of-scope) · [Lifecycle](#lifecycle) ·
[Validation](#validation)

## Question

A handler acts only through effects: it asks, and the daemon checks the
rule's grants and performs the effect ("Effects" in
[meerkatd.md](meerkatd.md)). An effect touches request decoding
(`EffectRequest`), grant parsing (`CapabilityGrants`), the TypeScript
`Grants` and `Context` types, the JavaScript `ctx` and the docs. Without one
source, those are five hand-written copies that nothing keeps in step, and
anything else a rule wants to change goes through `exec`, which runs a
command-line tool.

The question is how to offer many native controls without five copies of
each, and which controls to offer.

## Catalog

`EffectCatalog` (MeerkatKit) declares each grant and each effect once, in
Swift, the way `EventCatalog` declares event kinds. An effect declares:

- its wire name (`process.signal`), a case of `EffectKind`, and where it
  appears on `ctx` (`ctx.process.signal`);
- its request as a `TypeSchema` object, with each field's bounds (numbers,
  string lengths in UTF-8 bytes, list lengths) and default, and whether the method
  takes that object or positional arguments (`signal(target, signal)`);
- its result: nothing, a value with a schema, or a stored value that may be
  absent (`state.get`). A result's schema is its Swift type's
  (`ExecResult`, `HTTPResponse`, `WindowInfo`), so the value the daemon
  encodes is the one the declarations describe;
- the grant it needs: none, a flag, or an allow list and the request field
  checked against it;
- its traits: the field holding the path it acts on and in which form, the
  field holding a defaults domain it changes, and a field that must stay
  under the rule's timeout. The daemon's checks for each come from these,
  so an effect cannot have a path or a domain without its check
  ("Protected state" below), and a request without the field a check reads
  is refused, never let through;
- the macOS permission it needs (Accessibility), or the app it sends Apple
  Events to (Automation), which the executor checks for every effect that
  declares one.

The catalog checks its own data as it is made: every grant an effect names
exists in the right shape, a list grant's subject and each positional
argument are fields, a path grant names the protected path the effect acts
on, and each trait's field is always present. No code that reads the
catalog checks these again.

Text a person reads (a notification's title and its buttons, an assertion's
reason, a tag, a sample's label) is bounded at four bytes for each character
it once counted, so a limit fits as much text in any script; names and ids
keep their byte limits.

Everything else is derived from the catalog:

| Derived | Where | How it stays current |
|---|---|---|
| `Grants` and `Context` in `meerkat.d.ts`, with request and result interfaces | `TypeScriptDeclarations` | Generated; a test fails when the checked-in file is stale |
| Grant parsing and normalization | `CapabilityGrants` | Reads the grant descriptors at load |
| Authorization | `EffectAuthorizer` (the executor and a dry run) | Reads the effect's grant requirement |
| Request checks and defaults | `EffectRequest` | `SchemaValidator` runs the request schema, bounds included, before the typed decode, which reads defaults from the schema |
| Protected paths and domains | `EffectAuthorizer` | Reads the effect's traits |
| The JavaScript `ctx` | `runtime.js` | The daemon sends the effect table with `Load`; the runtime builds `ctx` from it |
| The list of effects and grants | `meerkat effects` | Printed from the catalog |

The typed decode (`EffectRequest`) and the code that performs each effect
stay hand-written Swift: they hold the checks a schema cannot express (a
URL is absolute, a path is inside a grant, a volume is removable). Both
switch over `EffectKind` with no default, so the compiler refuses an effect
either leaves out, and the catalog refuses to exist without a descriptor
for each kind. A request whose kind the catalog doesn't know is refused as
it decodes.

The effect table travels to the runtime as data, not as generated
JavaScript, so the daemon's catalog is the only source and no artifact can
go stale: `DaemonToHost.Load` carries `effects`, the table as JSON text.

## Grants

A rule's `capabilities` names grants by path. Three shapes cover every
grant, and the catalog says which one each grant has:

| Shape | JSON | Examples |
|---|---|---|
| Flag | `true` | `notify`, `process.signal`, `audio`, `windows.control` |
| Allow list | `{ allow: [...] }` | `exec` (absolute paths), `http` (origins), `urls` (schemes), `defaults` (domains), `shortcuts` (names), `observe` (event kinds) |
| Path list | `[...]` | `fs.read`, `fs.write`, `files.trash`, `files.tag` (path prefixes; `~/` is home) |
| Level | one of its names | `process.observe` (`"own"`, then `"all"`, which includes it) |

An allow-list effect is authorized only when the request's subject (the
executable, the origin, the URL scheme, the defaults domain, the shortcut
name, the path) is in the list. Path subjects resolve symlinks before the
check, so a link inside a granted directory cannot reach outside it. A path
is checked in the form its effect acts on: `files.setTags` follows a link to
its target, so the target is checked; `files.trash` moves the link itself,
so the link is (its folder resolved, its own name kept), and a link outside
the grant is not inside it by pointing there. An unknown grant, or an
unknown field inside one, is a load error.

## Observation

A rule may observe only what it declares, as it may act only through what
it declares. Rules run inside meerkatd as the user, so the OS's file
permissions narrow nothing: the boundary is the rule's grants. The scope is
rules: the CLI and the app are the user, and MCP clients keep their own
policy in `meerkat.json` ([mcp.md](mcp.md), "Harm model").

Each event descriptor declares what observing its kind needs
(`EventDescriptor.Observation`), next to the privacy permission it needs, as
each effect declares its grant. A kind behind a permission needs both: the
permission is the daemon's, the grant is the rule's.

| Observation | Kinds | Grant | Checked |
|---|---|---|---|
| `open` | Ambient state about this Mac, not about other people, files or what the user is doing: memory, CPU, throughput, power and thermal, displays and the session, volumes, disks, USB and HID devices, the network's state, audio devices and volume, time, input source and idle time, appearance, locale; and `meerkat.*`, of which each rule sees only its own file's (below) | none | — |
| `paths` | `fs.change`, `fs.churn` | `fs.read` covering every watched path, by real path (as the kernel names it: symlinks resolved, a firmlinked folder's data-volume name mapped to it); none at, inside or above the daemon's state folder (`DaemonPaths.protected`'s read list) unless the subscription excludes it | At load; for `fs.churn` without a `root`, each time the rule subscribes and whenever `meerkat.json` changes |
| `processes` | `process.*`, `app.*` | `process.observe`: `"own"` for the user's own processes, `"all"` for every user's | At load, and per event: with `"own"`, events about other users' processes are dropped and `process.top` and `process.list` rows filtered. `process.sample` of another user's running process is refused at load |
| `named` | `window.focused`, `input.activity`, `pasteboard.changed`, `camera.inUse`, `audio.inUse`, `network.wifi`, `bluetooth.devices`, `session.logins`, `log.entry`, `darwin.notification`, `distributed.notification`, `iokit.attached`, `iokit.detached`, `power.assertions` | `observe: { allow: [kind, ...] }` naming it | At load |

The `named` kinds carry what the user is doing (window titles, input, the
pasteboard), which apps use the camera or microphone, other people (nearby
devices, other accounts, the network's name and so the location), or raw
text other programs wrote (the log, notifications, IOKit, power assertions'
reasons, which also name every user's processes that hold one). An open
kind names no process and no user: a catalog test fails for an open kind
whose payload schema has a `pid` or `uid` field. Watching a path
reveals what happens in it, so it is a read. A process is the user's own by
the daemon's uid; applications are the user's own GUI processes, so either
level covers `app.*`. This mirrors the effects: `process.signal` and
`process.priority` already stop at the user's own processes.

Everything follows from the one field:

| Derived | Where |
|---|---|
| The load check, and its message naming the grant to add (`EffectCatalog.grantText`, as for an effect's refusal) | `ObservationScope.require`, from `RuleDefinition`, so the dry run decides the same way; the file scope `ObservationScope.requireFileScope`, from `RuleEngine.subscribe` and the dry run |
| What a rule sees of each event: other users' processes, other files' `meerkat.rule`, `meerkat.dropped` and `meerkat.notification` events | `ObservationScope.view`, applied per rule at dispatch (and to a dry run's events) before `match`; the source stays shared |
| `NamedEvent`, `EventObservation`, and `capabilities` required by type where a grant is | `TypeScriptDeclarations`, `RuleAPIDeclarations` |
| `observe.allow` names only `named` kinds; any other is an error saying what it needs | `CapabilityGrants` |
| `meerkat events list` (the grant per kind), `meerkat effects` (the observation grants) | the CLI |

The kind supplies what the check reads: the paths its parameters watch
(`PathObservingParameters`), the process they name
(`ProcessObservingParameters`), and what a rule may see of a payload
(`RuleViewedPayload`). A catalog test holds each declared observation to
the kind's side.

Choices the code made:

- **Types require the grant, the load check its content.** For a kind
  that needs one, `capabilities` is required and must hold its grant
  (`fs.read`, a `process.observe` level, or `observe.allow` of kinds observed
  by name), so the usual mistake shows in the editor. Whether `fs.read`
  covers the watched paths depends on the file system, which only the load
  check sees. Whether `observe.allow` names this rule's own kind is the load
  check's too: a conditional type over the grants inferred from the same
  argument does not fail the call in tsrs, the checker that decides what
  loads (tried 2026-11-04 in three placements), though the same type fails
  as expected when given the grants directly.
- **Excluded protected paths.** `fs.churn` counts nothing at or under its
  exclusions (`ChurnAccumulator`), so a scope above the state folder is
  allowed when it excludes it. Without that, `fs.churn` on the default
  scope, the whole volume, could never load. `fs.change` has no exclusions.
- **The file scope is checked where the rule subscribes, and when it
  changes.** `fs.churn` without a root reads the scope at each window, so
  `RuleEngine.subscribe` decides it each time a rule subscribes (as it
  loads, is enabled, or resumes, and after a reload that raced a settings
  change), and the engine checks every running one when `meerkat.json`
  applies (`RuleEngine.recheckFileScope`). A rule outside its grant fails
  with why, before a window of the new scope can finish, and stays loaded
  as a failed rule, so it resumes once its grant covers the scope again,
  across reloads too.
- **`meerkat.*` is seen per file.** The hub counts drops per subscriber,
  so each `meerkat.dropped` report names the entry file whose subscription
  fell behind (none for the daemon itself and its clients); each
  `meerkat.rule` status and `meerkat.notification` response names its file
  too. A rule sees only its own file's, by the payload's view: another
  file's parameters are its paths, predicates and names, and its statuses
  hold its code's errors and what it was refused. The app and the CLI see
  every status and report; responses go only to rules
  (`EventAudience.rules`).

Known limit: a watched path is resolved when the rule loads. Rule code
cannot make symlinks, but another program that swaps a folder on the path
afterwards is not seen, as with the other path checks (meerkatd.md, "Known
limits").

## Effects

| Effect | `ctx` | Grant | API | Tier |
|---|---|---|---|---|
| `state.get`, `state.set`, `state.delete` | `state.get(key)`… | none | rule store | — |
| `notify`, `notify.withdraw` | `notify(request)`, `notify.withdraw(id)` | `notify` | UserNotifications | — |
| `process.signal` | `process.signal(target, signal)` | `process.signal` | `kill` | — |
| `process.priority` | `process.setPriority(target, priority)` | `process.priority` | `setpriority(PRIO_DARWIN_PROCESS)` | — |
| `process.nice` | `process.setNice(target, nice)` | `process.priority` | `setpriority(PRIO_PROCESS)`, 0–20; lowering priority only | A |
| `exec` | `exec(request)` | `exec.allow` | `posix_spawn` | — |
| `http` | `http(request)` | `http.allow` | URLSession | — |
| `store.record` | `store.record(request)` | `store.record` | sample store | — |
| `power.preventSleep`, `power.allowSleep` | `power.preventSleep(request)`, `power.allowSleep(id)` | `power.awake` | `IOPMAssertionCreateWithName` | A |
| `audio.setDefaultDevice`, `audio.setVolume`, `audio.setMute` | `audio.*` | `audio` | CoreAudio `AudioObjectSetPropertyData` | A |
| `apps.open` | `apps.open(request)` | `apps.open` | `NSWorkspace.openApplication` | A |
| `apps.activate`, `apps.hide`, `apps.unhide`, `apps.quit` | `apps.*(target)` | `apps.control` | `NSRunningApplication` | A |
| `urls.open` | `urls.open(url)` | `urls.allow` (schemes) | `NSWorkspace.open` | A |
| `volumes.eject` | `volumes.eject(request)` | `volumes.eject` | DiskArbitration; removable or external volumes only | A |
| `files.trash` | `files.trash(path)` | `files.trash` (paths) | `FileManager.trashItem` | A |
| `files.setTags` | `files.setTags(path, tags)` | `files.tag` (paths) | URL resource values | A |
| `defaults.read`, `defaults.write`, `defaults.delete` | `defaults.*` | `defaults.allow` (domains) | `CFPreferences`, current user | A |
| `shortcuts.run` | `shortcuts.run(request)` | `shortcuts.allow` (names) | `/usr/bin/shortcuts` | A |
| `wifi.setPower` | `wifi.setPower(on)` | `wifi.power` | CoreWLAN | A |
| `clipboard.read`, `clipboard.write` | `clipboard.*` | `clipboard.read`, `clipboard.write` | `NSPasteboard` | B (read) |
| `windows.list`, `windows.set` | `windows.*` | `windows.control` | Accessibility (`AXUIElement`) | B |
| `appearance.setDark` | `appearance.setDark(on)` | `appearance.set` | Apple Events to System Events | B |

### Protected state

No grant reaches the daemon's own settings. An effect that changes a
defaults domain declares the field (`changesDefaultsDomain`): `defaults.write`
and `defaults.delete` refuse the `com.gkze.meerkat` domain, by name in any
case or by path, and the daemon reads that domain alone, not macOS's search
list, so the global domain can't set it either. An effect that acts on a path
declares the field and its form (`Traits.path`): `entry` for the link itself
(`files.trash`), `target` for what it leads to (`files.setTags`). The decode
reads a path from that field alone, so a path effect cannot leave out its
checks: each refuses the paths denied to Deno (`DaemonPaths.protected`, `meerkat.json` among them)
and any folder holding one, comparing the path as the effect acts on it with
each protected path in every form the runtime gives it: as named, each symlink
on its way, and resolved (`CapabilityGrants.forms`; meerkatd.md, "Why embedded
Deno"). A rules folder linked in from elsewhere is still inside the folder
that holds the link, and a settings file linked out to dotfiles is protected
there. Both check and act while no rule's code can
rename anything (meerkat-runtime's `hold_rule_renames`), so a rule cannot
swap a folder on the path between the check and the act; another program
still could (docs/design/meerkatd.md, "Known limits").
A rule could otherwise move the rules directory or change what it runs. The
one path form without these checks is `mountPoint` (`volumes.eject`): it acts
on a whole removable volume, which its grant covers, not on a file. Only
`exec` steps outside this, because an allow-listed executable can do whatever
it does.

Two choices in the table of effects need their reason:

- **Shortcuts through `/usr/bin/shortcuts`.** macOS has no in-process API
  to run a shortcut. The command is Apple's supported interface, and it
  returns the shortcut's output and exit status, which the URL scheme does
  not. It is run with an argument array and no shell, like `exec`.
- **Apple Events as fixed actions, not scripts.** An Automation grant is
  per target app, but script text can address any app, so a grant cannot
  limit what a rule's script reaches. The catalog offers fixed actions
  that the daemon scripts itself (`appearance.setDark`); each new one is a
  catalog entry.

Automation has one more constraint. macOS decides it
for the app a process belongs to, so meerkatd's Apple Events are Meerkat's
(`com.gkze.meerkat`), and it shows the prompt only to an app in the
foreground: for meerkatd, tccd refuses without asking ("Policy disallows
prompt"). So Meerkat › Settings › Automation asks on meerkatd's behalf
(`AutomationPermission.request`), and the one answer covers both. The app
and the daemon both carry the `com.apple.security.automation.apple-events`
entitlement, which the hardened runtime requires.

`windows.list` and `windows.set` declare the Accessibility permission, and
`EffectAuthorizer` checks it before acting: without it they fail with the
System Settings pane to use, the way event sources do (`Permissions.swift`).
`appearance.setDark` names its Automation target in the catalog
(`AutomationTarget.systemEvents`), checks it when it runs, and its error names
Settings › Automation or the System Settings pane. `clipboard.read` has no
check of its own: macOS may ask before the first read.

## Out of scope

- **Root (tier C):** raising a process's priority, other users'
  processes, `pmset` and `sysctl` settings, network configuration, sleeping
  the Mac on demand. These need a privileged helper with its own install,
  signing and approval, and a larger attack surface.
- **No public API:** built-in display brightness and Night Shift, Bluetooth
  power, Focus modes (reachable through a shortcut) and an immediate screen
  lock.
- **Arbitrary scripts:** see the Apple Events choice above.

## Lifecycle

Most effects act once. Two hold something:

- **Power assertions** belong to the rule that made them, under the rule's
  own id for them. Each has a required timeout (at most 24 hours) after
  which macOS releases it. `power.allowSleep(id)` releases it early, and
  reusing the id replaces it. The daemon releases a rule's assertions when
  the rule is unloaded, changed or disabled; an unchanged rule keeps them
  across a reload. macOS releases all of them when the daemon exits.
- **Quit requests** ask the app to quit; they do not wait for it, and an
  app can refuse. `force: true` terminates it.

## Validation

- Catalog tests: every effect's grant exists, every default is valid for its
  field, every catalog effect decodes from its least request and each
  request's defaults reach the typed value, and every effect runs through
  the executor without touching the Mac.
- Grant tests: each shape parses, normalizes and refuses what it should
  (relative paths, `..`, unknown fields, a scheme with a colon).
- Authorization tests: each allow-list subject inside and outside its list,
  symlinks out of a granted directory, `trash` on a link in, and above, a
  protected folder, and on where the settings link leads; the cases both the
  daemon and the runtime run (`protected_cases.json`).
- Observation tests: each class with and without its grant, a watched path
  through a symlink into the state folder and one above it, `process.sample`
  of launchd (root's), delivery with `"own"` of an event about launchd, the
  file scope moving out of a loaded `fs.churn` rule's grant, `meerkat.dropped`
  per file, the dry run, and the types.
- Effects that change the Mac (audio, Wi-Fi, defaults, windows) run behind
  a `SystemControls` protocol, so tests use a recording fake and do not
  change the test machine.
- End-to-end: a rule in the real runtime calls effects through the
  generated `ctx`.
