# The Meerkat app

Status: implemented; this document records the conventions of the SwiftUI
app in `Sources/MeerkatApp`, so that a change to it does not have to
rediscover them. The app is a client of `meerkatd` over XPC
(`Sources/MeerkatIPC`); [meerkatd.md](meerkatd.md) is the authority for the
daemon and its IPC, and [rule-editor.md](rule-editor.md) for the Rules
page's editor and Try It, which this note does not repeat. Where the app
sits among the other processes is in [../architecture.md](../architecture.md).

Contents: [Scenes and navigation](#scenes-and-navigation) ·
[Models](#models) · [Live metrics](#live-metrics) ·
[Failure model](#failure-model) · [Agent control](#agent-control) ·
[Presentation](#presentation) · [The main actor](#the-main-actor) ·
[Sample data and previews](#sample-data-and-previews) ·
[Testing](#testing) · [Known limits](#known-limits)

## Scenes and navigation

`MeerkatApp` declares one `Window`, not a `WindowGroup`. Every page model,
and the rule editor's one buffer, belongs to the app, so a second window
would show and edit the same state twice. Closing the window quits the app,
and File › New is removed (`CommandGroup(replacing: .newItem)`).

The second scene is the standard `Settings` window (`SettingsView`), with
three panes: General (appearance, the background agent, Automation),
Sampling and Editor. Settings holds lasting choices only; one-off daemon
actions (Restart, Reinstall) are on the Daemon health page, beside the
status they act on.

`RootView` is a `NavigationSplitView`: the sidebar lists the Overview and
one row per `Resource` under Live, Rules under Automate, and the Event
Explorer and Health under Daemon. The page showing is
`AppState.destination`, which is never empty: the sidebar binds it through
`Sidebar.selection`, which drops the nil a Command-click on the selected
row sends, so the sidebar and the page always agree. The View menu's
Overview, Event Explorer, Rules and Daemon Health commands (⌘1 to ⌘4) set
the same property. Links between pages go through
`AppState.showEvent` and `AppState.showRule`, never by a page reaching
into another page's view.

The sheet for making a rule from a process (`ProcessRuleSheet`) is
presented by the window from `AppState.newRuleFor`, not by the process
card: the card is a popover, which closes before the sheet opens. Details
panels are page content (`trailingPanel`), not `.inspector`, whose divider
cut through the toolbar's search field; View › Show Inspector reaches them
through the `detailsPanel` focused value (`DetailsPanelCommands`).

## Models

Page models are `@MainActor @Observable` classes created once by
`AppState`; a process card's model, made per card, is the exception.
Models live there rather than in their pages, so a page keeps its state
(chart history, selection, a capture) across a visit to another page.
Each page still starts and stops its own subscriptions and polling with
its visibility.

| Model | Feeds | Lifetime of its work |
|---|---|---|
| `MetricsModel` | The Overview, the resource pages, the sidebar's live values | Subscriptions while a metrics page is on screen and the window is visible ("Live metrics") |
| `RulesModel` | Rules page, sidebar badge, the explorer's "used by", process cards | `meerkat.rule` for the window's lifetime (`RootView`'s task); polling every 5 s while the Rules page shows (counts have no event) |
| `HealthModel` | Daemon health page | `status` every 2 s and `meerkat.dropped`, while the page shows |
| `ExplorerModel` | Event Explorer | The catalog on appearance, one subscription the user starts, stopped when the page disappears; the capture is kept |
| `RuleDryRunModel`, `RuleEditorSession` | The Rules page's editor and Try It | [rule-editor.md](rule-editor.md) |
| `AgentControl` | Settings, Health toolbar, every agent banner | Actions only ("Agent control") |
| `ProcessCardModel` | One process card | `process.sample` while the card is open; owned by the card's `@State` |

There is one `DaemonClient` (one XPC session, one heartbeat) for the whole
app. `AppState` hands most models `daemon`, an `any DaemonConnection` that
sample data replaces; the Event Explorer, process cards and `AgentControl`
always take the real client.

Pages are split into small views that each read only what they draw, so
Observation invalidates the smallest part. The Overview reads only the
connection state and which feeds failed; each card is its own view; the
sidebar's resource rows (`ResourceRow`) and the Rules badge are their own
views. A CPU sample (4 Hz at the Live preset) then redraws the CPU card
and its sidebar row, nothing else. Keep that shape when adding a property
a page reads.

## Live metrics

`MetricsModel` is the dashboard's view of the daemon. Its doc comment holds
the table of what it subscribes to, at what rates and for which view; that
table is the authority, and `SamplingRates` builds every parameter in one
place so the Sampling pane validates exactly what will be asked for. Every
number comes from the daemon's event sources, the same ones rules use, so
the Mac samples once however many consumers there are, as long as their
parameters match (`EventHub` keys instances by kind and parameters).

The model subscribes to all of its feeds exactly while two things hold: a
page that shows them is on screen, and the window is not occluded.

- Pages declare themselves with `.metricsFeed(model)`, which calls
  `start` and `stop`. Viewers are counted, and `stop` defers its check to
  the next turn, because changing pages can remove the old page before
  the new one appears in the same update; the feed carries over instead of
  every subscription being remade.
- `onAppear`, not `.task`, starts it: a task starts after the update that
  removed the previous page, whose `stop` would already have run.
- Occlusion (`NSApplication.didChangeOcclusionStateNotification`) cancels
  every subscription, and the daemon stops sources nobody else uses.
  `MEERKAT_ALWAYS=1` ignores occlusion, to measure the real cost.
- New rates from Settings restart the subscriptions and clear chart
  history rather than mixing two sample spacings on one chart.

The sidebar's live values come from the same model, so they hold their
last values while another page (Rules, Health, the explorer) is showing.

Three event kinds describe processes, for three different views:

| Kind | Subscribed by | Gives | Shown in |
|---|---|---|---|
| `process.top` | `MetricsModel` | The three busiest by CPU and by disk I/O; rows every `rows` seconds, ranking every `rank` | The Overview's CPU and Disk cards |
| `process.list` | `MetricsModel` | Every process at each listing, idle ones included; each page sorts it by its own measure | The resource pages' process tables |
| `process.sample` | `ProcessCardModel` | One process, by pid and start time, until it exits | The process card's tiles and their last minute |

`process.top`'s ranking and `process.list` share the `rank` interval, the
costly full enumeration. Only this user's processes carry footprint, disk
and energy; another user's report CPU only. A counter that cannot be read
is nil, shown as "–", and adds no chart point rather than a zero nobody
measured.

## Failure model

Failures are told apart by what they are about, where they were caught.
`DaemonFault` classifies one once, from the typed
`DaemonClient.ClientError`; its text is for display only.

| What failed | Where it shows | What happens next |
|---|---|---|
| The connection: `unreachable`, `differentBuild`, `resubscribeFailed` or an unexpected reply on any metrics feed | `MetricsModel.connection` becomes `.unavailable`; the Overview shows `ConnectionBanner` above its cards | Every feed is cancelled (`lost`) and all of them subscribe again after `retryDelay` (5 s), while the window stays visible and a page shows them |
| One feed: the daemon refused it or ended it (`ClientError.daemon`), or ended it without a reason | `feedFailures[kind]`, shown as a `FeedFailureNote` on each card whose `Resource.feeds` lists the kind and each page whose `Resource.pageFeeds` does (the CPU, Memory, Disk and Power pages add `process.list`, which no card shows) | Only that feed retries, backing off from 5 s to 60 s (`longestFeedRetry`); its next payload clears the mark; the other feeds keep running |
| `battery.sample` refused when subscribing | `battery = .unavailable`: "This Mac reports no battery telemetry" | Not retried: a Mac without a battery always refuses. A battery feed that ends later is an ordinary failed feed, not "no battery" |
| A page's first request (`LoadState.failed`) | `DaemonLoadGate`, then `DaemonUnavailableView`: why, and the one action most likely to fix it | Try Again, or the fix button |
| A later poll, with a good answer on screen | `StaleBanner` over the last good data (Rules, Health) | The next poll |
| The process card's `process.sample`: refused, ended, the connection lost, or ended with no word while the process runs | `ProcessCardModel.problem`: "Not updating: … Trying again."; tiles keep their last values | The card follows the process again, backing off from 5 s to 60 s; the next sample clears the problem. A process that has exited meanwhile (`ProcessTable`) is not followed again, and the card shows it exited |

A feed failure means the daemon still answers, so `FeedFailureNote` offers
no agent action. Only a connection failure names an agent problem:
`DaemonProblem` turns the fault and the registration status into one title
and explanation, shared by the banner and the full-page view, and
`AgentFixButton` picks the action (Install, Open Login Items, Restart for a
different build, Reinstall for registered but silent).

The process card retries on its own rather than through `MetricsModel`:
it follows one process, which may exit while its feed is down, so before
subscribing again it checks the process table, and stops once the process
has gone. The daemon ends the feed itself when it cannot read the process
several times in a row; the card shows that reason while it waits.

## Agent control

`AgentControl` owns the LaunchAgent's registration and its actions for every
surface that offers them (Settings › General, the Health toolbar, the agent
banners), so all of them show the same state and the same action in
progress. `SMAppService` sends no change notifications, so `status` is a
cached read, refreshed when Settings, a banner or the full-page view
appears, and after every action.

- **One confirmation policy.** `Action.confirmation` says what to ask
  before Turn Off, Restart and Reinstall, which stop a daemon that may be
  running rules; installing starts one that is not running and is not
  asked about. Every surface asks through the `confirmingAgentAction`
  view modifier with a `pending` action, never with a dialog of its own.
- **One way to wait.** Install, Turn On and Reinstall go through
  `AgentRegistration.installAndAwait`, the route `meerkat agent install`
  takes: it reads the daemon's identity, registers off the caller's actor,
  and succeeds when a daemon other than the one before answers, or when
  Login Items holds the agent for approval. Registered but silent within
  `startLimit` is a failure that says so. Restart is
  `restartAndAwait` (`launchctl kickstart -k`), with the same wait.
- **One action at a time.** `perform` ignores a request while `action` is
  set.
- **Where errors show.** `AgentControl.error` holds the last action's
  failure. The banners and `DaemonUnavailableView` show it in place of
  their usual detail, and Settings › General below the status. The Health
  toolbar (`DaemonActions`) keeps its own `failure` for actions started
  there and alerts with it, so a failure from a banner is reported at the
  banner and not later as an alert on the Health page.

After a fix succeeds, the banner calls `MetricsModel.reconnect`, which
subscribes again at once rather than at the next retry.

## Presentation

- **Numbers.** `Format` in `Dashboard.swift` turns figures into text
  through the locale's number format; `MemorySize` does sizes with the
  system's memory byte-count style (binary multiples labelled GB, as
  Activity Monitor shows them); `RateUnit` picks KB/s or MB/s per reading.
  `String(format:)` always writes a POSIX ".", so a figure beside a memory
  size would disagree with it; don't use it for anything shown.
- **Values from the daemon.** A payload is untrusted: a number from one
  stays `Double` and must not reach a trapping conversion such as
  `Int(_:)`, which would kill the app. `DroppedReport.dropped` stays
  `Double` for that reason, `JSONDisplay.format` checks its range before
  `Int64(_:)`, and `MemorySize.bytes` clamps. Values the app stores, such
  as custom sampling rates in `UserDefaults`, are checked when read back
  (`SamplingRates(json:)`).
- **Status colors.** `Theme.normal`, `.warn` and `.critical` are the
  status colors for fills, chart marks and glyphs. Text in a status color
  goes through `Theme.text(_:)`, which swaps them for `NSColor.normalText`,
  `warnText` and `criticalText`: in the light appearance the system green,
  orange and red do not reach WCAG AA's 4.5:1 as small text. Any other
  color passes through unchanged. `FeedFailureNote` shows both: an orange
  glyph beside secondary text.
- **Accessibility.** Controls whose meaning is in another column carry it
  in their label: each rule's checkbox in the Rules table is a `Toggle`
  labelled with the rule's name, with `labelsHidden()`, so VoiceOver names
  the rule it switches. An Overview card is one button for VoiceOver, so
  the processes it lists are offered as its accessibility actions ("Show
  details for …", `ProcessDetailActions`), and the rows themselves are tap
  gestures with the button trait rather than buttons, which would reach
  VoiceOver a second time. Charts are hidden or summarized by a label
  ("Memory pressure, last 2 min"); `RollingNumber` gives VoiceOver the
  plain text.
- **Rendering cost.** Live numbers (`RollingNumber`) and scrolling charts
  (`SlidingPlot`) animate in Core Animation, committed once per sample. A
  chart spans its whole window from the first sample, filling in from the
  right, and glides linearly for the gap between samples, so it scrolls at
  a steady pace and shows the newest sample in full one sample later. It
  draws one departed sample past its hidden left edge, so a sample that
  cuts a glide short leaves no gap there. A new value range eases over the
  same glide instead of snapping.
  The SwiftUI equivalents (`.numericText()`, animated Swift Charts) rebuilt
  the window's display list every frame: about a third of a core for the
  Overview at the Relaxed preset (2026-10-29). `MEERKAT_PLAIN=1` (no
  charts) and `MEERKAT_NO_SAMPLE=1` (one ranking, then stop) isolate
  rendering cost.

## The main actor

The models are main-actor isolated, so anything that can wait on another
process, a name lookup or a slow volume is kept off it. The app once froze,
Quit included, on `NSWorkspace.open(_:)`, which waits on Launch Services
until the handling app (a code editor for a rule file) has launched; every
file or folder the app opens now goes through `Finder.open`, which does
not wait.

| Work | Where |
|---|---|
| Requests and subscriptions to meerkatd | `async` `DaemonConnection` calls; there is no synchronous request |
| The host name (`ProcessInfo.hostName` can wait on a lookup) | `Task.detached` in `MetricsModel.init` |
| Startup volume capacity ("important usage" computes purgeable space) | `Task.detached` in `refreshVolume`, at most every 30 s |
| A churn root's volume name (the root comes from `meerkat.json` and may be on a slow volume) | `Task.detached` in `resolveScopeName`; views read `scopeName` |
| Registering (`AgentRegistration.install`) and `launchctl kickstart` | `Task.detached` inside `AgentRegistration.installAndAwait` and `restartAndAwait` |
| tsrs, the rule editor's language server | The `RuleLanguageServer` actor |

Reading and writing the open rule file and its draft (`RuleEditorModel`,
`RuleDrafts`) are local and small, and stay on the main actor.

## Sample data and previews

`MEERKAT_SAMPLE_DATA=1`, in debug builds only, makes `AppState` hand the
models a `SampleDaemon` (`SampleData.swift`) instead of the real
connection. Its replies are written as the daemon's JSON, so they go
through the same decoding, and they fill the Overview, resource pages,
Rules, Health and Try It without rule files or a running daemon. Rule
toggles change only the sample report; nothing reaches the installed
daemon, whose rules sample data must never change. `AgentControl`
simulates its actions (a 2 s wait, then the new status) without touching
the registration. The Event Explorer and process cards still use the real
daemon. The rest of the app's switches are in
[development.md, "Environment switches"](../development.md#environment-switches).

To look at a change without replacing the installed app or its agent,
build the preview bundle ([building.md, "Previewing app
changes"](../building.md#previewing-app-changes)): only the app, under
its own bundle identifier, talking to the installed daemon, and a debug
build, so sample data works.

## Testing

`buck2 test //Tests/MeerkatAppTests:MeerkatAppTests` covers the models'
logic against stand-in daemons:

- `MetricsFeedTests`, `MetricsRetryTests`: one feed ending leaves the
  others running and clears on its next payload; a battery refused at
  subscribe is "no battery", one ending later is not; a lost connection
  stops every feed; a page change keeps the feed, and no retry outlives the
  last viewer.
- `ProcessCardFeedTests`: an unreadable counter adds no point; an ended
  feed is the card's problem, in the daemon's words, until the card's
  next sample; a silent end is a problem too; a process that exited is not
  followed again.
- A failed `process.list` shows on the four pages that use it and on no
  card (`aFailedProcessListShowsOnThePagesThatUseIt`).
- `DaemonWaitTests.swift`: the shared register-then-wait against silent, old,
  new and cancelled daemons, and typed event decoding (a payload of another
  shape is a different build).
- `DaemonProblemTests`, `StatusTextTests` (contrast of the text colors, and
  that only status colors change), `SamplingTests`, `MemorySizeTests`,
  rolling series, the sample daemon, and the rule files the app writes,
  type-checked with the bundled tsrs.
- `RuleEditorTests`, `RuleDryRunTests`, `RuleEditorThemeTests`: see
  [rule-editor.md](rule-editor.md).

None of this shows that a page looks or behaves right. Layout, both
appearances, VoiceOver, the confirmation dialogs, banners appearing and
clearing against a daemon that is stopped and restarted, occlusion
stopping the feeds, and the agent actions against the real registration
need a person, or full-screen control, using the built app; say so when a
change was not checked that way.

## Known limits

- The process card shows only what the daemon reports now. History (when a
  process ran hot, what it started earlier) needs an event history the app
  does not keep (`ProcessFacts`).
- The rule editor's open items are in
  [rule-editor.md, "Next steps"](rule-editor.md#next-steps).
