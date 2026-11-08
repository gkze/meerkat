# The dashboard

Meerkat.app, the dashboard, and what its sampling costs.
[design/app.md](design/app.md) has its design.

```bash
open ~/Applications/Meerkat.app
```

The dashboard is a client of `meerkatd`. Its pages:

- **Overview:** CPU, memory, disk, network, power and path churn, with the
  busiest processes. Each card opens its resource's page.
- **CPU, Memory, Disk, Network, Power and Files:** one page per resource,
  with its live chart, a breakdown and the processes or folders behind it.
  The CPU, Memory, Disk and Power (energy) tables list every process the
  page can measure, largest first, and sort by any column. Other users'
  processes report CPU only, so only the CPU table has them.
  They are also in the sidebar, with each one's live value.
- **Process card:** double-click a process on the CPU, Memory, Disk or Power page
  (or choose Show Details) for its card. It follows that one process with
  `process.sample` while open, so it keeps updating after the process
  leaves the ranking. It also shows what it keeps awake, the helpers it
  runs and the rules on process events. From the card you can show it in
  Finder, quit or force quit it (the pid is checked against its start time
  first; quitting a process that isn't an app asks first, as force quitting
  does), or make a rule. **Make a Rule…** writes a `process.hot` rule for
  that process into the rules folder as a TypeScript file you can edit;
  it never replaces an existing file.
- **Rules:** what loaded, what failed and why, what each rule has done, and
  switches to turn rules off and on. **Edit Rules** opens the rule files in
  an editor on the page, with tsrs's type errors as you type; saving
  reloads them like a save from any editor, and **Try It** runs the unsaved
  text on events with every effect captured
  ([docs/design/rule-editor.md](design/rule-editor.md)).
- **Event Explorer:** every event kind the daemon offers, and a live view of
  any one of them.
- **Daemon Health:** the daemon process, the rule runtime, and every running event
  source with its subscribers, throughput and drops.

When the daemon does not answer, the dashboard says why and offers the fix:
install the agent, switch it on in Login Items, restart it when it is a
different build from the app, or reinstall it when it is registered but
silent. Restart and Reinstall ask first, wherever they are offered, since
rules miss events while the daemon restarts. When the daemon answers but one
of its sources fails (a folder `fs.churn` watches goes away, the battery
can't be read), only that card and page say so, and that feed tries again on
its own.

Buck builds the app executable, but it shows a window only from inside the
bundle, which is why `//Tools/Bundler:preview` exists. There is no Xcode
project to keep in step with the BUCK files.

## Sampling cost

Truly "realtime without sampling" is not possible for CPU: `proc_pid_rusage`
returns cumulative counters, so any consumer must read them at some interval.
What can be avoided is putting the _expensive_ read on the hot path. The
Overview's subscriptions therefore run on two clocks, a cheap fast one and
an expensive slow one. With the Normal sampling preset (Settings also offers
Relaxed, Live and Custom):

| Event                                                                    | Interval           | What it reads                                                  | Cost                          |
| ------------------------------------------------------------------------ | ------------------ | -------------------------------------------------------------- | ----------------------------- |
| `cpu.sample`                                                             | 1 s (Live: 0.25 s) | machine CPU from `host_statistics` tick deltas (one mach call) | negligible                    |
| `memory.sample`, `disk.sample`, `network.sample`                         | 1 s                | one chart point each                                           | small                         |
| `battery.sample`                                                         | 5 s, fixed         | the battery controller's readings                              | small                         |
| `process.top`                                                            | rows every 1 s     | re-reads only the ~5 processes displayed (`ps` for other users') | small                         |
| `process.top`                                                            | ranking every 5 s  | full enumeration to rank who is busy                           | the expensive one, kept rare  |
| `process.list`                                                           | every 5 s          | the same enumeration, every row, for the resource pages        | shares the ranking's snapshot |
| `fs.churn`                                                               | 4 s of every 25 s  | FSEvents over the startup volume (`meerkat.json` `files`)      | push-driven within the window |
| `memory.pressure`, `thermal.state`, `power.lowPowerMode`, `power.source` | push               | the header chips                                               | free                          |

- **Occlusion gate.** When the window is hidden or covered, the dashboard
  cancels its subscriptions, and the daemon stops every source nobody else
  uses.
- **Separate scalar and series.** The headline CPU number can update at
  4 Hz (the Live preset) while the chart series update at 1 Hz, because rebuilding Swift Charts
  paths four times a second cost more than the sampling itself.
- **Shared sources need equal parameters.** The daemon shares a source only
  between subscribers with the same parameters, so rates that differ from a
  rule's run their own sampler alongside it.

Sampling cost sits in the daemon. One 60 s measurement on a 14-core M4
Max under heavy unrelated load (load average ~85), from `ps` CPU time, taken
when the dashboard had five subscriptions (`cpu.sample`, `memory.sample`,
`memory.pressure`, `process.top`, `fs.churn`):

| State                              | `meerkatd` CPU                           | Resident |
| ---------------------------------- | ---------------------------------------- | -------- |
| No clients, no rules               | 0 s in 30 s (below the 10 ms resolution) | 15 MB    |
| The dashboard's five subscriptions | 0.45 s in 60 s, ~0.75% of one core       | 21 MB    |

That is one run on a loaded machine: an order of magnitude, not a benchmark.
It has not been repeated with the Overview's current subscriptions. The app's
own rendering cost (measured before the daemon existed: ~17% of one core
while visible and compositing) is unchanged by this design and was not
re-measured.
