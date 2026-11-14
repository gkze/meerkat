# launchd jobs: listing, controlling and editing LaunchAgents and LaunchDaemons

Status: proposed 2026-11-11; nothing is built. It would amend the
"Out of scope" list in [effects.md](effects.md) only if decision D1 below
chooses system-level writes; the phases before that stay inside what effects.md
already allows.

Contents: [Question](#question) · [Task contract](#task-contract) ·
[Evidence](#evidence) · [Privilege](#privilege) ·
[Talking to launchd](#talking-to-launchd) · [Model](#model) ·
[Operations](#operations) · [The plist](#the-plist) ·
[The editor](#the-editor) · [Surfaces](#surfaces) ·
[Harm model](#harm-model) · [Watching jobs](#watching-jobs) ·
[Failure](#failure) · [Testing](#testing) · [Phases](#phases) ·
[Open decisions](#open-decisions)

## Question

Meerkat shows what the Mac is doing, and much of what runs in the background
is a launchd job. Can the app and the CLI list every job in every domain,
show its definition and state, and create, change, remove, load, unload,
enable, disable, start and stop jobs, with both a structured editor and the
plist's text, with completions for launchd's keys? What does each need, and
what must stay out?

## Task contract

Requested outcome: launchd jobs as a first-class part of Meerkat, for the
user's agents and the system's agents and daemons.

Acceptance criteria:

1. `meerkat jobs list` and an app page list the jobs of the user's GUI domain
   and the system domain, with each job's plist, whether it is loaded,
   running (pid), disabled, and allowed in Login Items.
2. For the user's own agents (`~/Library/LaunchAgents`): create, edit,
   delete (to the Trash), load, unload, enable, disable, start, restart and
   stop, from the CLI and the app, with every outcome read back from launchd.
3. The plist opens as text with launchd's keys completed and checked as you
   type, and as a form over the same text: an edit in either is an edit of
   one buffer, and the file keeps its comments, key order and layout.
4. No surface lets an untrusted party (MCP clients, rule code) define what a
   job runs. Meerkat's own jobs cannot be changed from this surface.
5. System-level writes (`/Library/LaunchDaemons`, the `system` domain) are
   decided explicitly (D1), not reached by accident.

## Evidence

Measured on macOS 27.2 on 2026-11-11, as an unprivileged user, or read from
`launchctl(1)` and the ServiceManagement SDK headers:

| Fact | Evidence | Consequence |
|---|---|---|
| `launchctl print gui/<uid>`, `print system`, `print-disabled gui/<uid>` and `print-disabled system` all succeed unprivileged | exit status 0 for each | the whole Mac can be listed without root |
| The output of the newer subcommands (`print`, `print-disabled`) "is not guaranteed to remain stable"; the legacy `list` output should match earlier releases | `launchctl(1)`, CAVEATS; `print`'s own entry calls its output "NOT API" | parse `print` best-effort only; prefer `list` and the files |
| `launchctl list` prints `PID`, `Status`, `Label` per job of the caller's domain, tab-separated; `list <label>` prints one job as an old-style property list | sampled | a stable source for the user's own domain |
| `enable` and `disable` persist across boots and work only on the system, user and user-login domains | `launchctl(1)` | disabled is a state of its own, separate from loaded |
| The disabled overrides are kept in `/private/var/db/com.apple.xpc.launchd/disabled.<uid>.plist`, owned by root, mode 0644 | `ls -l` | readable, but a private file: `print-disabled` is the interface, the file a fallback at most |
| `SMAppService.statusForLegacyPlist(at:)` (macOS 13) reports whether the user allowed a plist in `/Library/LaunchDaemons`, `/Library/LaunchAgents` or `~/Library/LaunchAgents` in Login Items | `SMAppService.h` | Background Task Management's switch has a public read API |
| `~/Library/LaunchAgents` is the user's (0700); `/Library/LaunchAgents` and `/Library/LaunchDaemons` are root's (0755); `/System/Library/Launch*` are on the sealed system volume | `ls -ld` | writes outside the user folder need root |
| Binary plists: none of 24 in the user folder, 1 of 4 in `/Library/LaunchAgents`, 1 of 23 in `/Library/LaunchDaemons`, 103 of 425 in `/System/Library/LaunchDaemons`, 116 of 487 in `/System/Library/LaunchAgents` | first bytes `bplist` | binary is common in what is read-only anyway, rare in what is writable |
| launchd keeps the plist it read when a job was loaded; restarting the job runs the old definition | observed for meerkatd (`AgentRegistration.install`) | saving a loaded job's plist does not change the job until it is unloaded and loaded again |

## Privilege

| Scope | Read | Write the plist | bootstrap, bootout | enable, disable | kickstart, kill |
|---|---|---|---|---|---|
| `~/Library/LaunchAgents`, `gui/<uid>` | user | user | user | user | user |
| `/Library/LaunchAgents`, loaded per user in `gui/<uid>` | user | root | user, own GUI domain | user, own GUI domain | user |
| `/Library/LaunchDaemons`, `system` | user | root | root | root | root |
| `/System/Library/…` | user | never (sealed volume) | mostly refused | root, and refused for some | root |

Phases 1 to 4 below cover the user rows only: everything is read everywhere,
and changed only where the user can change it without root. System-level
writes are D1.

## Talking to launchd

| | |
|---|---|
| Required capability | Bootstrap, boot out, enable, disable, kickstart and signal any job in the user's GUI domain; read every domain's jobs and their state. |
| Chosen | `/bin/launchctl`, run through `ChildProcess` (deadline, own process group, bounded output), behind one owner, `Launchctl` (MeerkatKit). Mutations read only the exit status and stderr. Reads prefer, in order: the plist files (the definition), `launchctl list` (stable, the caller's domain), then `print` and `print-disabled` through a parser that leaves a field unknown rather than failing the listing. |
| Strongest alternative | `SMAppService`, which is public and structured but manages only jobs inside the calling app's bundle. `launch_msg` and the `SMJob*` functions are deprecated, and launchd's XPC interface is private. |
| Decisive tradeoff | `launchctl` is the only supported way to act on a job Meerkat does not own. Its newer output is not stable, so nothing a mutation decides may depend on parsing it. |
| Validation | Live tests in the user's GUI domain with a plist under a temporary folder and a unique label (`bootstrap` takes any path), booted out in teardown; parser tests on recorded `print` output from each macOS release the CI covers; a parser failure is a degraded field, never a failed listing. |

`AgentRegistration` already runs `launchctl print`, `bootout` and
`kickstart -k` through a blocking `Process` with no deadline. It moves onto
`Launchctl`, so a hung `launchctl` can no longer hold its caller forever, and
Meerkat has one way to run it. `ProcessSampler`'s `ps` has the same shape
and the same fix, independent of this work.

## Model

A job's identity is its domain and label, not its file:

```swift
public enum LaunchDomain: Hashable, Sendable { case system, gui(uid_t), user(uid_t) }
public struct LaunchJobID: Hashable, Sendable { let domain: LaunchDomain; let label: LaunchLabel }
```

`LaunchLabel` is validated where it enters (a CLI argument, an XPC message,
a plist's `Label`, a rule's request): non-empty, bounded in bytes, and only
the characters launchd's own labels use, so that no label reaches
`launchctl` as an option or as a path. A plist's file name and its `Label`
usually agree, but launchd goes by `Label`; a mismatch is a warning.

State is independent axes, not one status, because each changes on its own
and each has its own command:

| Axis | Values | Source |
|---|---|---|
| Defined | a plist at a path, which parses; or none (a job submitted from an app bundle, like meerkatd) | the file |
| Loaded | in the domain or not | `list` (own domain), `print` (others) |
| Running | a pid, or not; the last exit status | `list`, `print` |
| Disabled | an override of enabled or disabled, or none | `print-disabled` |
| Allowed | allowed, needs approval, or not applicable, in Login Items | `SMAppService.statusForLegacyPlist(at:)` |
| Applied | whether the loaded definition is the file on disk now | Meerkat's own record of what it loaded, else unknown |

"Applied" is the one launchd does not report. A job saved since it was
loaded is shown as "saved, not applied" until it is loaded again.

## Operations

Each operation says what it does when there is nothing to do, so a repeat is
safe:

| Operation | Does | Already in that state |
|---|---|---|
| create | writes a new plist in `~/Library/LaunchAgents`, mode 0644, atomically, refusing a file that exists; optionally loads it | refused: replacing is `update` |
| update | replaces the plist's text atomically; with apply, unloads and loads it | text unchanged: success, nothing written |
| delete | unloads it if loaded, then moves the file to the Trash (`FileManager.trashItem`, as rule files are) | no file: success |
| load, unload | `bootstrap`, `bootout` | success, nothing done |
| enable, disable | `enable`, `disable` on the job's domain | success |
| start | `kickstart` | running: success |
| restart | `kickstart -k` | not running: starts it |
| stop | `kill SIGTERM`; with `KeepAlive`, launchd starts it again, and the app says so and offers unload instead | not running: success |

Every operation reads launchd's state back after acting and reports that, not
the command's exit status alone.

## The plist

The text is the authority for an XML plist. Structured edits are applied as
the smallest text edit to the range of the value they change, so a file keeps
its comments, key order, indentation and any keys Meerkat does not know.
Round-tripping through `PropertyListSerialization` would drop all of them.

- **Parser.** A plist's XML vocabulary is small (`plist`, `dict`, `key`,
  `array`, `string`, `integer`, `real`, `true`, `false`, `date`, `data`), so
  Meerkat owns a parser that keeps each node's source range, and does not
  take on a general XML library. XML's own subtleties (entities, CDATA,
  comments, the doctype) are what make this risky, so it is held to
  `PropertyListSerialization`: on every plist under `/System/Library` and
  `/Library`, both must read the same value.
- **Binary plists** are shown read-only, decoded by
  `PropertyListSerialization`. Editing one asks to convert it to XML first;
  in the user folder there are none today.
- **`PlistSchema`, the launchd keys.** One Swift declaration per key: its
  name, its plist type, unions where launchd takes more than one shape
  (`KeepAlive` is a boolean or a dictionary of conditions;
  `StartCalendarInterval` a dictionary or an array of them), allowed values
  (`ProcessType`), nested dictionaries (`Sockets`, `KeepAlive`'s conditions),
  and a one-line description written for Meerkat, not copied from
  `launchd.plist(5)`. Completions, hover text, validation, the form and
  `meerkat jobs keys` all read it.
- **Not `TypeSchema`.** `TypeSchema` describes JSON and projects to JSON
  Schema and TypeScript; plists distinguish integers from reals and have dates
  and data, and need unions `TypeSchema` does not have. They change for
  different reasons, so they stay two schemas.
- **Unknown keys** are kept and reported as warnings: launchd ignores keys it
  does not know, and a newer macOS adds keys.
- **`EnvironmentVariables`** often holds tokens. Its values are shown in the
  app masked until revealed, and never leave the app or the CLI (see
  "Harm model").

## The editor

The Rules page's editor is about 2,600 lines shaped around rules: tsrs,
`RuleDrafts`, `RuleCompiler.ruleSources` and the Rules page's status. The
generic part (the buffer, drafts, changes from outside, atomic saves, range
decorations, the Problems bar, themes) moves into a document editor core with
a small language seam: a diagnostics provider, a completion provider and a
highlighter. Rules keep tsrs behind it. Plists get an in-process provider over
`PlistSchema`; there is no language server for plists, and none is needed for
one schema.

The form and the text are two views of one buffer, with one undo history. The
form shows the common keys as controls (`Label`, `Program` or
`ProgramArguments`, `RunAtLoad`, `KeepAlive`, `StartInterval`,
`StartCalendarInterval`, `WatchPaths`, `StandardOutPath`,
`StandardErrorPath`, `WorkingDirectory`, `EnvironmentVariables`,
`ProcessType`, `ThrottleInterval`) and every other key in an outline. Text
that does not parse disables the form, with the parse error, until it parses
again.

Highlighting needs a grammar for XML. Whether CodeEditLanguages' prebuilt
container has one is not checked (D5); its HTML grammar is the fallback.

## Surfaces

| Surface | Reads | Changes |
|---|---|---|
| CLI, `meerkat jobs …` | every domain, `--json` | the user's agents; `check <file>` validates a plist against `PlistSchema` |
| App, a Launch Jobs page under Automate | every domain | the user's agents, with the form and the text |
| MCP | a read-only resource listing jobs and their state, without `EnvironmentVariables` values or arguments after the program | nothing |
| Rules | an event kind of job states ("Watching jobs") | start, restart, stop, enable and disable of labels the rule allows; never create, update or delete |

The CLI and the app act on launchd themselves, as `AgentRegistration` does:
they are the user, and the daemon runs as the same user, so routing the
user's own changes through the daemon would add a hop and no boundary. The
daemon uses `Launchctl` only for its event source and the rule effects.

## Harm model

- **Defining a job is running any program, at every login.** A plist names
  what launchd runs, so whoever writes one has `exec` of anything,
  persistently. That is the escalation [mcp.md](mcp.md) ("Harm model", D7)
  gives for keeping rule authoring off MCP, and it applies here: no MCP tool
  and no rule effect creates, changes or removes a plist. Only the user, at
  the CLI or in the app, does.
- **Controlling an existing job is narrower**: it runs only what the user
  already defined. Rules get it under an allow list of labels,
  `launchd.control: { allow: [label, …] }`, the shape `exec` and `defaults`
  already use.
- **Meerkat's own jobs** (`DaemonService.label`, and any other job the
  bundle registers) are listed but not changed from this surface: the CLI
  and the app send them to `meerkat agent` and Settings, and rule effects
  refuse them by label, as `defaults.write` refuses Meerkat's domain. A rule
  could otherwise unload the daemon it runs in.
- **What leaves the Mac's user.** Job lists name installed software, and
  plists carry arguments and environment values that can be secrets. Over
  MCP and in event payloads, `EnvironmentVariables` values and every argument
  after the program are left out; the job event kind is observed by name
  (`observe.allow`), and MCP denies it by default with the other kinds that
  carry text other programs wrote.
- **Already true today.** A rule granted `fs.write` over a folder holding
  `~/Library/LaunchAgents` can write a plist, and so run anything at the
  next login. This design does not create that, but it makes it visible
  (D3).

## Watching jobs

launchd announces no change of a job's state. A `launchd.jobs` state kind
would combine three sources the daemon already has the mechanics for:
FSEvents on the three plist folders (a job defined, changed or removed), the
process events for the pids it knows (a job exited), and a bounded poll of
`launchctl list` for the user's domain (loaded, unloaded, started by launchd
on demand). The poll's interval is D4. The system domain is listed from its
folders and, best-effort, `print system`, and is polled more slowly.

## Failure

- **`bootstrap` errors say little** (`Bootstrap failed: 5: Input/output
  error`). The primary error is kept as `launchctl` gave it, and Meerkat adds
  what it can find out after it (`print`, the plist's own check), marked as
  its own explanation.
- **Ordered mutations.** `delete` unloads first and moves the file to the
  Trash only if that worked, so no loaded job is left without its file.
  `update` with apply writes the file, then unloads and loads; if the load
  fails, the job is unloaded and the new file is on disk, and the result says
  exactly that, with the previous text kept to restore.
- **Reads degrade, mutations fail closed.** A field `print` no longer
  provides becomes unknown, observably; a mutation whose read-back cannot be
  made reports the state as unknown rather than as done.
- **Nothing from outside traps.** Labels, pids, exit statuses and plist
  values from `launchctl` or a file are validated where they enter, never
  through a trapping conversion (AGENTS.md, "Trust boundaries").

## Testing

| Risk | Layer |
|---|---|
| Parser ranges, minimal edits, unknown keys kept | pure tests on fixtures |
| Parser agrees with `PropertyListSerialization` | every plist under `/System/Library` and `/Library`, read-only |
| `PlistSchema` checks, completions, unions | pure tests |
| Label and value validation at each entry | pure tests, including hostile labels (`-k`, `../x`, empty, oversized) |
| Each operation's effect and its no-op | live, in the user's GUI domain, a temporary plist path and a unique label, booted out in teardown |
| `print` parsing degrades, not fails | recorded output per macOS release, plus a mangled copy |
| Rule effects authorize by label and refuse Meerkat's own | `EffectAuthorizer` tests, with `Launchctl` behind a recording fake as `SystemControls` is |
| The page and the editor | MeerkatAppTests, then the real app |

## Phases

1. **One `Launchctl`.** The bounded runner and its parsers; `AgentRegistration`
   onto it.
2. **Read everything.** The model, `meerkat jobs list` and `show`, the app
   page read-only, the MCP resource.
3. **The user's agents.** Every operation in "Operations" for
   `~/Library/LaunchAgents`, in the CLI and the app, with the plist as text
   (validated, no completions yet).
4. **The editor.** The document editor core, the plist parser and
   `PlistSchema`, completions, the form.
5. **Rules.** The `launchd.jobs` kind and the `launchd.control` effects.
6. **System level**, if D1 says so.

## Open decisions

| # | Decision | Options | Leaning, and what would decide it |
|---|---|---|---|
| D1 | System-level writes | never; the CLI run under `sudo` (it runs `launchctl` itself, so it needs no helper); a privileged helper registered with `SMAppService.daemon`, with a code-signing peer requirement and an authorization right per operation | Read-only until there is a use for more. Then `sudo meerkat jobs …` first: no new component and no new attack surface. A helper only if the app itself must do it, and then as its own design note, as the network filter's system extension had. Not `do shell script … with administrator privileges`: that is script text, which effects.md already declines for Apple Events. |
| D2 | The command's name | `meerkat jobs`; `meerkat launchd` | `jobs`: it names what the user handles, not the mechanism. |
| D3 | `fs.write` grants over a LaunchAgents folder | allow silently; warn at load; refuse unless the grant names the folder exactly | Warn at load, naming what the grant allows. |
| D4 | Poll interval for `launchd.jobs` | fixed; follows the sampling preset | Measure `launchctl list`'s cost first; start at 5 s for the user's domain, 60 s for the system's. |
| D5 | XML highlighting | CodeEditLanguages' XML grammar, if the container has one; its HTML grammar; none | Check the container. |
| D6 | `/Library/LaunchAgents` writes | with D1; with an administrator prompt of their own | With D1: the same privilege, so the same decision. |
