# The CLI, MCP and agent skills

`meerkat`, the command line: the daemon and its rules, the MCP server,
the agent skills and one-shot measurements.

## Daemon and rules

```bash
meerkat status                   # daemon, handler host, running sources
meerkat rules                    # loaded and failed rules, diagnostics
meerkat rules reload
meerkat rules logs downloads.ts#new-files
meerkat rules disable downloads.ts#new-files
meerkat rules enable downloads.ts#new-files
meerkat rules check ~/drafts     # type-check a folder; no daemon needed
meerkat rules lint ~/drafts      # lint a folder; writes nothing without --fix
meerkat events list
meerkat events watch memory.pressure
meerkat events watch fs.change --params '{"paths":["~/Documents"]}' --count 5
meerkat effects                  # every effect, its grant and permission; the observation grants
meerkat types --output my.d.ts   # the declarations for this build
meerkat mcp                      # MCP on stdin and stdout, for MCP clients
meerkat skills                   # instructions for coding agents
```

## MCP

`meerkat mcp` is an MCP stdio server for coding agents and chat clients.
Configure the client with the `meerkat` inside Meerkat.app (meerkatd accepts
only clients signed with the app). Claude Code:

```bash
claude mcp add -s user meerkat -- ~/Applications/Meerkat.app/Contents/MacOS/meerkat mcp
```

Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.meerkat]
command = "~/Applications/Meerkat.app/Contents/MacOS/meerkat"
args = ["mcp"]
```

Any other client that starts a stdio server:

```json
{ "command": "~/Applications/Meerkat.app/Contents/MacOS/meerkat", "args": ["mcp"] }
```

Clients that don't expand `~` need the full path.

- **No socket.** The bridge relays bytes over the daemon's XPC service, and
  the MCP server runs inside meerkatd, one session per bridge.
- **Read-only.** The resources are `meerkat://status`, `meerkat://catalog`
  (and `meerkat://catalog/{kind}` with JSON Schemas), `meerkat://types`,
  `meerkat://config`, `meerkat://rules` with each rule's log, and
  `meerkat://samples` (and `meerkat://samples/{label}`). The
  `resource_read` tool reads the same, for clients that call tools but
  don't read resources.
- **Six tools.** `events_sample` watches one event kind for at most 30
  seconds or 500 events. `system_sample` measures one window, as
  `meerkat sample` does, while the policy allows `process.top`, `cpu.sample`
  and `memory.sample`, whose data it carries; it leaves out the host name,
  which none of them carries. `samples_compare` compares two labels of the
  sample store, as `meerkat compare` does, over each label's newest `limit`
  samples (default 100). `rules_check`
  type-checks text without running it, and reads no file outside the rules
  folder. `rules_dry_run` runs a rule already saved in the rules folder on its
  event's examples, with its effects captured and stored state left out. No
  client can run code of its own, or write a rule. Replies are JSON, and
  structured content when they are objects; `resource_read` of
  `meerkat://types` is the TypeScript, as text.
- **Prompts.** The [agent skills](#agent-skills) are also MCP prompts.
- **Sensitive event kinds are off by default.** Kinds that need a privacy
  permission are not offered, and neither are the kinds that carry arbitrary
  text from other programs (`log.entry`, `darwin.notification`,
  `distributed.notification`, `iokit.*`, `power.assertions`). `meerkat.json` can allow or deny
  kinds and change the limits, live ([Configuration](configuration.md#configuration)). An
  allowed permission kind still needs its grant: MCP never prompts for one.
- **Bounded replies.** A resource read or tool reply over `outputKiB`
  is cut to it and marked `truncated`; a rule's log keeps its newest entries
  instead, and `events_sample` stops adding events once theirs would pass it.
- **Restarts.** When meerkatd restarts, can't be reached, or turns a message
  away because the session is backed up or closing, the bridge exits with
  status 69, and the client starts it again. A line from the client longer
  than 4 MiB, or a meerkatd of a different build, ends the session with
  status 1: a new bridge would meet it too.

The design and the remaining steps are in
[docs/design/mcp.md](design/mcp.md).

## Agent skills

Meerkat ships instructions for coding agents, and hands them out two ways: as
skills, and as MCP prompts with the same text. `meerkat-diagnose` finds out
what a Mac is doing, and `meerkat-rules` writes, checks and tries a rule.

```bash
meerkat skills                            # what this build has
meerkat skills show meerkat-rules         # print one SKILL.md
meerkat skills install --to ~/.claude/skills
```

Use the folder your agent reads skills from, and run `install` again after
upgrading. It won't replace a skill you've edited without `--force`. There is
no plugin package: one would copy the skills' text, and `skills install`
already writes this build's.

Commands an agent acts on keep to one contract, which `meerkat --help` states:
`--json` wherever there's data, and exit statuses that mean what they say.
`CLITests` holds every command to having `--json` or a stated reason not to,
and runs the built `meerkat` to check each status, stream and error object
below for the failures that need no daemon. A failed check (rules, lint, format,
`config check`, `agent status`) exits 1 with or without `--json`, and its
findings are its output. A file or folder that doesn't exist is 66, a daemon or
tool the app ships that isn't there is 69 (a daemon that doesn't answer in
time, or answers what wasn't asked, included), a usage error is 64, and an
`agent install` whose daemon didn't answer yet is 75; `ExitStatus` is the one
list, which the help prints. A daemon that refuses a request, or is a
different build, is 1. With
`--json`, any other failure, a usage error included, writes one object to
stderr, `{"error": {"status": 69, "message": "..."}}`, after any notes in
text; so does a usage error of a command that always prints JSON (`events
watch`, `config show`, `config schema`). A command that names no operation,
like a bare `meerkat`, prints its help to stdout and exits 0.

## Measurement

```bash
meerkat sample --window 5 --top 8 --churn ~/Library --table
meerkat sample --window 10 --pretty # JSON to stdout
meerkat sample --window 10 --system-only --table
meerkat --help                      # also: help sample|analyze|compare
```

Arguments are parsed with
[swift-argument-parser](https://github.com/apple/swift-argument-parser), so
values are type-checked: a malformed or non-positive `--window`, `--top`,
`--repeat`, `--retain` and so on is rejected (exit 64) rather than silently
replaced with a default.

One sample measures one window: process CPU and disk, machine-wide CPU and,
with `--churn`, file changes all cover the same `--window` seconds, and
memory and load are read at its end. A process writing in the rows is in
that sample's churn. Stores written by builds that measured churn in a
window of its own, before the processes, can't be read for that pairing.

Each process row carries:

- `name`: short, for display
- `path`: the executable from `proc_pidpath`; omitted when unknown
- `startedAt`: Unix epoch milliseconds; together with `pid` it identifies the
  process instance
- `uid`

`--system-only` keeps the rows whose executable ships with macOS, whichever
user the process runs as:

- **Kept:** `/System/`, `/usr/`, `/bin/`, `/sbin/` and `/Library/Apple/`,
  plus cryptexes (`/System/Volumes/Preboot/Cryptexes/<name>/…` and
  `/System/Cryptexes/<name>/…`). Cryptexes are judged by the path inside the
  cryptex, so WebKit's XPC services count and Safari does not.
- **Dropped:** Apple's apps in `/System/Applications/`, `/usr/local/`, every
  other `/Library/` path (third-party daemons, agents and system extensions,
  and Xcode's `/Library/Developer/`), and any other `/System/Volumes/` path.

This is a path rule; code signatures are not read. A row with no known path
is excluded.

## Before/after measurements

```bash
BIN=meerkat
DB=~/Library/Application\ Support/com.gkze.meerkat/samples.db

# 1. Baseline: 10 samples, long windows, labelled and written to the store
$BIN sample --repeat 10 --label baseline --window 30 --db $DB

# 2. Make exactly one change

# 3. After: identical flags, different label
$BIN sample --repeat 10 --label after --window 30 --db $DB

# 4. Compare medians, ranges and deltas
$BIN compare $DB
```

`compare` prints per-label medians with the observed min–max, the delta
between two labels, and two warnings (`--json` gives the same as data, and
MCP's `samples_compare` the same for two labels, over each label's newest
100 samples unless it is given another `limit`):

- **Overlapping ranges:** the distributions are not separable at this n, so
  there is no result yet.
- **High within-label variance:** that metric's own spread is comparable to
  the effect, so a delta is not evidence.

Measured here with 3 samples per label and _no change made_:

| Metric          | Label A           | Label B             | Reading                            |
| --------------- | ----------------- | ------------------- | ---------------------------------- |
| `churn_events`  | 37 [24–60]        | 115 [110–189]       | 211% "change" with nothing changed |
| `compressed_mb` | 9885 [9873–10080] | 10325 [10210–10375] | 4% drift, measurable               |
| `swap_mb`       | 3500 [3500–3500]  | 3500 [3500–3500]    | pinned, unchanged                  |

So n=3 is not enough on a loaded host. Use at least 10 samples with 30 s
windows, and treat a single churn window as noise: it is dominated by
whichever apps happen to be writing.

## Managing the agent

The agent is installed and removed one way, `SMAppService`, whether from the
CLI or from the dashboard's Install button, so either undoes the other:

```bash
meerkat agent install      # or the dashboard's "Install Agent" button
meerkat agent status       # registration state and whether the daemon answers
meerkat agent restart      # restart through launchd, keeping the registration
meerkat agent uninstall
```

`install` and `uninstall` also remove an agent job that another copy of
Meerkat.app registered, such as a deleted build folder. Such a registration
does not show in `status` (it reads `notRegistered`), but launchd keeps
running its job, and once that copy is gone every restart fails with
`EX_CONFIG`.
