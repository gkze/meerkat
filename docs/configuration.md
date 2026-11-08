# Configuration and storage

`meerkat.json`, and where Meerkat keeps its data.

## Configuration

What the daemon does is fixed when it is built; how far it may go is set
while it runs. Three tiers, from most to least dynamic:

| Tier                                            | Applies                                     | What                                                                                                             |
| ----------------------------------------------- | ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Rules and `meerkat.json` in the rules directory | on save, within a second                    | rules and everything they declare; the MCP policy and limits; the sample store's budget; what file churn watches |
| The `com.gkze.meerkat` defaults domain          | at `meerkat agent restart`                  | where the daemon keeps things ([Storage](#storage))                                                              |
| The build                                       | after a rebuild and `meerkat agent install` | event sources, effects, the MCP surface, the LaunchAgent plist                                                   |

`meerkat.json` is data, never code, checked against a JSON Schema that is
generated from the daemon's own declaration of it
(`MeerkatConfiguration.schema`):
[Sources/meerkat-rules/meerkat.schema.json](../Sources/meerkat-rules/meerkat.schema.json),
and `.meerkat/meerkat.schema.json` in the rules directory, which the daemon
keeps current. Every field is optional; an absent one keeps its default.
[Sources/meerkat-rules/examples/meerkat.json](../Sources/meerkat-rules/examples/meerkat.json)
sets them all:

```json
{
  "$schema": "./.meerkat/meerkat.schema.json",
  "mcp": {
    "events": { "allow": ["log.entry"], "deny": ["fs.change"] },
    "limits": {
      "sampleSeconds": 60,
      "sampleEvents": 1000,
      "outputKiB": 2048,
      "concurrentSamples": 2
    }
  },
  "samples": { "maxAgeDays": 90, "maxMegabytes": 2000 },
  "files": { "root": "~", "exclude": ["~/Library/Caches", "~/Library/Biome"] }
}
```

- **A broken edit changes nothing.** A file that fails validation leaves the
  last version that applied in force (the defaults, if none has), and its
  problem shows in `meerkat status`, `meerkat rules` and the app's Rules
  page. It never waits on the rules' compile, so a rule's type error cannot
  hold it back.
- **What file churn watches.** `files` sets the folder the Files card and
  page measure, and every `fs.churn` subscription that names no `root`. By
  default it is the whole startup volume, less the system's own bookkeeping
  (`/private/var/folders`, `/private/var/db`, the Spotlight and FSEvents
  stores). `exclude` replaces that list. Paths take `~` and are matched the
  way FSEvents reports them, so `/var/folders` means `/private/var/folders`.
  A change applies at the next measurement window, without resubscribing.
- **Rules cannot change it.** Rule code cannot write the rules directory or
  the defaults domain, so no rule can widen the policy it runs under.
- **Commands:** `meerkat config show` prints what applies, with every default
  filled in; `meerkat config check [file]` validates a file without the
  daemon; `meerkat config schema` prints the schema. MCP clients read it as
  `meerkat://config`.

## Storage

| Path                                                        | Defaults key     | Environment         | Contents                                   |
| ----------------------------------------------------------- | ---------------- | ------------------- | ------------------------------------------ |
| `~/.config/meerkat/rules/`                                  | `RulesDirectory` | `MEERKAT_RULES_DIR` | your rules and `meerkat.json`              |
| `~/Library/Application Support/com.gkze.meerkat/samples.db` | `SampleDatabase` | `MEERKAT_DB`        | samples from the `store.record` capability |
| `~/Library/Application Support/com.gkze.meerkat/rules.db`   | `RuleDatabase`   | `MEERKAT_RULE_DB`   | per-rule state and rule logs               |
| `~/Library/Caches/com.gkze.meerkat/`                        | `CacheDirectory` | `MEERKAT_CACHE_DIR` | the rules as tsrs compiled them            |

To move one, set its key in the `com.gkze.meerkat` defaults domain and
restart the daemon; the CLI reads the same keys, and the app follows the
daemon's rules folder:

```bash
defaults write com.gkze.meerkat RulesDirectory ~/Development/my-rules
```

The environment variable, when set, wins over the key. The installed agent's
plist sets none, so they are for tests and development runs.

`meerkat sample --db`, `meerkat compare` and `meerkat analyze` take a
store's path explicitly; pass this one to work with what rules recorded.

The sample store keeps what was measured, once, as integers in the
sampler's units (bytes, microseconds, nanojoules); percentages and MB are
computed when read.

- `samples`: one row per sample: when, label, the measured window,
  machine-wide CPU usage, load and memory. The host is a row in `hosts`.
- `process_samples`: the top-N processes in that window. Each refers to a
  row in `processes` (pid plus start time, so one row follows one process
  across samples), which refers to `executables` (name and path, stored
  once).
- Footprint, disk and energy are NULL for other users' processes, whose
  counters macOS does not give an unprivileged reader. NULL means unknown;
  zero means none.
- `churn`, `churn_paths` and `churn_categories`: FSEvents activity, for
  samples that measured it, with paths stored once in `paths`.

A sample with 20 processes takes about 0.7 KB, plus lookup rows the first
time a process or path appears.

The store bounds itself after every insert: samples more than 30 days older
than the newest one are deleted, and past 500 MB of pages in use the oldest
samples go until it is back under 450 MB. `meerkat.json`'s `samples`
section changes both, live, for any store `meerkat sample --db` writes as
well; while that file is invalid, `--db` refuses to write rather than apply
the defaults. A rule's or the CLI's `retain` keeps the newest N
samples under that writer's own label, within that budget; other labels are
untouched. At one 20-process sample a
minute (about 1 MB a day), the 30 days come to about 30 MB, so the size
limit applies only to much denser recording.

It uses WAL mode, a GRDB `DatabaseMigrator`, and cascade deletes that keep
child rows in step; deleting samples also removes processes, executables
and paths that no remaining sample uses. Queries are built with
[SQLiteData](https://github.com/pointfreeco/sqlite-data)'s `@Table` types and
checked against the migrated schema by a test. Before 1.0 the schema can
change without a migration: opening a store compares its tables, indexes
and triggers with the ones this build creates, so a file written by a
different schema, or one that is not a store at all, is refused unchanged
rather than misread, and the error says to move it aside. `compare`,
`analyze` and MCP open the store read-only and never create or change it.
`meerkat sample --db` keeps sampling when a write fails, and exits 1 after
the run if any did. A store that doesn't exist is exit status 66.

To record a sample on a schedule, use a rule:
[Sources/meerkat-rules/examples/recorder.ts](../Sources/meerkat-rules/examples/recorder.ts) records one
every five minutes. Copy it into the rules directory to use it.
