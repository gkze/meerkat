# Developing Meerkat

For changing Meerkat: checks, style, the tooling the app ships, generated
declarations, what the tests cover, releases and CI. [AGENTS.md](../AGENTS.md)
is the short version for coding agents; the [README](../README.md) is for
using and building Meerkat.

## Checks

```bash
Tools/check          # debug build of everything outside buck2/third_party, then buck2 test //...
Tools/check --fix    # buck2 run //:fix first: formatting, lint fixes, generated files
```

Every check is its own Buck test target, so any one runs alone:

```bash
buck2 test //Sources/MeerkatKit/...         # a module's format and lint checks
buck2 test //Tests/MeerkatDaemonTests:MeerkatDaemonTests -- --test-arg=--filter --test-arg=Lint
buck2 test //Sources/meerkat-rules/...                         # tsrs, Oxlint, meerkat-lint, Oxfmt
buck2 test //Sources/meerkat-runtime/...                    # the runtime's tests, clippy, rustfmt
buck2 test //:package_swift_test            # Package.swift matches the BUCK files
buck2 test //:                              # Starlark, shell, workflow, TOML, Markdown
buck2 build @buck2/mode/release //Sources/meerkatd:meerkatd
```

The files no module owns have checks in the root [BUCK](../BUCK), each over the
whole repository's files of its kind (tracked or new, not ignored). The
tools are release executables pinned by version and SHA-256 in
[buck2/third_party/tools/defs.bzl](../buck2/third_party/tools/defs.bzl); none ships.

| Files | Checks |
|---|---|
| BUCK, PACKAGE, `.bzl` | `buck2 starlark lint` (`:starlark-lint`); no formatter, as buildifier writes Bazel's layout, not this repository's |
| Shell scripts (by extension or shebang) | ShellCheck (`:shellcheck`), shfmt with 4-space indentation (`:shfmt`) |
| `.github/` | actionlint, with ShellCheck over `run:` steps (`:actionlint`); zizmor, offline, with [.github/zizmor.yml](../.github/zizmor.yml) (`:zizmor`) |
| TOML | tombi formatting and lint, offline (`:toml-format`, `:toml-lint`) |
| Markdown | rumdl, with [.rumdl.toml](../.rumdl.toml) (`:markdown-lint`); lychee, offline, for links to files and headings (`:markdown-links`) |
| Rust dependencies | cargo-deny with [deny.toml](../buck2/third_party/rust/check/deny.toml): licenses, bans and sources (`//buck2/third_party/rust/check:deny_test`), RustSec advisories (`:advisories_test`) |

Generated Starlark (`buck2/third_party/rust/BUCK`, `modules.bzl`) is left to
its generator. `:advisories_test` reads the advisory database as it is when
it runs, so it can fail on a tree that has not changed; the other checks
change only with the repository. The cargo-deny checks, like
`:buckify_test`, read the crates' manifests from crates.io.

Builds are debug unless a mode file says otherwise (`@buck2/mode/release`);
build tools (macro plugins, build scripts) always build optimized. Buck's
output is `buck-out/`, which must be a real directory: the prelude's compiler
shims find the project root by resolving their own path, and `rustc` rejects
sources reached through a link. To keep it off an indexed volume, put the
checkout on the other volume.

[Package.swift](../Package.swift) and `Package.resolved` remain for SourceKit-LSP
and Xcode, and `Sources/meerkat-rules/package.json` and `Sources/meerkat-rules/bun.lock` for the editor's
TypeScript; conformance tests fail when they and the BUCK files disagree.
`buck2/third_party/swift/modules.bzl` is generated from the Swift packages'
manifests at their pins: after changing a pin, `buck2 run
//buck2/third_party/swift:regenerate` rewrites it, and
`:manifest_test` fails while it is stale.
`buck2 build //Tools/Bundler:lint-toolchain --out .build/lint-toolchain`
stages the lint tools where development builds of meerkatd and meerkat look
for them.

In Zed, install the Starlark extension. [.zed/settings.json](../.zed/settings.json)
selects its native Buck2 language server (`buck2 lsp`) for this project instead
of Starpls, whose Bazel defaults report false errors for Buck imports, built-ins
and type annotations. `buck2` must be on Zed's PATH.

## Swift and Rust style

- Swift is formatted and linted by swift-format from the toolchain
  (`swift format`), configured in [.swift-format](../.swift-format): 4-space
  indentation, 120 columns, and the opt-in rule against blank lines inside
  braces. Doc-comment validation is off, because it requires every
  parameter to be documented once one is, and these comments document only
  the non-obvious ones. Its rules against code that traps are off: those
  are SwiftLint's.
- SwiftLint ([.swiftlint.yml](../.swiftlint.yml)) runs only rules swift-format
  does not run, none about style: force casts, `try!`, force unwraps and
  implicitly unwrapped optionals, which trap and so stop the daemon, and
  other likely bugs. Each module has a
  `<name>-lint` test beside `<name>-format`; test modules use
  [Tests/.swiftlint.yml](../Tests/.swiftlint.yml), which allows the forces. A
  force that is provably safe says why beside its
  `// swiftlint:disable:next` comment.
- Every Swift target builds with warnings as errors and the upcoming features
  ExistentialAny, MemberImportVisibility and ImmutableWeakCaptures
  ([Package.swift](../Package.swift) says which targets are left out and why).
- The Rust crates are formatted by rustfmt
  ([rustfmt.toml](../rustfmt.toml)) and linted by clippy with the
  pedantic group, any finding failing the crate's `:clippy` test; each crate's
  lint levels are its `rustc_flags` in its BUCK file.

## TypeScript checks

`buck2 test //Sources/meerkat-rules/...` (or `bun run check`, which runs it) type-checks the
examples with [tsrs](https://github.com/oxc-project/tsrs), the Rust port of
the TypeScript 7 compiler, which is also what the daemon compiles rules with.
tsrs is pre-1.0; it is pinned exactly, and a version change goes through
these checks.

It then lints `Sources/meerkat-rules`, `Sources/meerkat-runtime/js` and
`Sources/meerkat-runtime/types` with Oxlint and with
[meerkat-lint](../Sources/meerkat-lint/README.md), and checks formatting with Oxfmt
(`buck2 run //Sources/meerkat-rules:fmt` rewrites). Oxlint runs every stable category as an error, with
type-aware rules through [tsrslint](https://github.com/maschwenk/tsrslint), a
Rust port of tsgolint.

- The policy is [Sources/meerkat-lint/policy/oxlintrc.json](../Sources/meerkat-lint/policy/oxlintrc.json), which
  says why each disabled rule is off.
- [.oxlintrc.json](../.oxlintrc.json) extends it with this repository's ignores
  and overrides. Every rules folder gets the same policy, and a test compares
  the two resolved configurations.
- The generated `meerkat.d.ts` and `deno.d.ts` are skipped by both linters.

## The shipped lint toolchain

Meerkat.app ships, in `Contents/Resources/lint/`:

- Oxc's standalone Oxlint and Oxfmt, from GitHub releases, pinned by version
  and SHA-256 in [buck2/third_party/js/BUCK](../buck2/third_party/js/BUCK) to the versions in
  `Sources/meerkat-rules/package.json`
- tsrslint, from npm, at `Sources/meerkat-rules/bun.lock`'s version and integrity
- meerkat-lint

`//Tools/Bundler:lint-toolchain` is that directory; the daemon tests run
against it.

The standalone Oxlint has no JavaScript plugin host and skips JS plugins
without a warning, which is why the `meerkat/*` rules are a native binary.

## Generated declarations

`Sources/meerkat-rules/meerkat.d.ts` is generated from the event catalog and
`Sources/meerkat-rules/meerkat.schema.json` from the configuration's types.
Tests fail when they are stale, and this rewrites them:

```bash
buck2 run //Sources/meerkat-rules:regenerate
```

`Sources/meerkat-rules/deno.d.ts` is a copy of the declarations the runtime composes at build
time (`Sources/meerkat-runtime/build.rs`) and exports to the daemon. Editors and
`meerkat rules check`, which does not link the runtime, read the copy.
`//Sources/meerkat-runtime:declarations_test` fails when it is stale, and this rewrites it:

```bash
buck2 run //Sources/meerkat-runtime:regenerate
```

`Sources/meerkat-runtime` holds the runtime's Swift API and C header, generated by
`Sources/meerkat-runtime/bindgen` from `//Sources/meerkat-runtime:meerkat_runtime`, the one
static library meerkatd links;
`Sources/meerkat-runtime/src/protocol.rs` is the host protocol's only definition.
`Tools/check` fails when the bindings are stale, and this rebuilds the
library and rewrites them:

```bash
buck2 run //Sources/meerkat-runtime/bindgen:regenerate
```

## What the tests cover

Besides unit tests, the suite exercises real OS boundaries without
privileges: FSEvents, kqueue process events, disk images attached and
detached (DiskArbitration and IOKit matching), volume mounts, CoreAudio
aggregate devices, notify(3) and distributed notifications, power assertions
(`caffeinate`), disk and loopback throughput, and the unified log
(`logger`).

- Permission-gated sources are tested for the error they give without a
  grant, since a test runner has no bundle to grant one to.
- The daemon tests run real rules end to end through the TypeScript compiler
  and the embedded Deno runtime, including a handler that never returns.
- The MCP tests drive a session's server with JSON-RPC lines in both protocol
  eras: caching hints, listen streams, error codes, the resources, the
  policy, `events_sample`'s bounds and the other tools' refusals.
- `CLITests` holds every command to the output contract: `--json` or a
  stated reason not to. It runs the built `meerkat` for the failures that
  need no daemon, and checks each one's exit status, stream and JSON error.
- `MEERKAT_LIVE_APP_TESTS=1` also launches and quits Calculator to test
  application events.

## Environment switches

For the app:

| Variable                | Effect                                                                                                  |
| ----------------------- | ------------------------------------------------------------------------------------------------------- |
| `MEERKAT_ALWAYS=1`      | Ignore the occlusion gate (measure the real cost)                                                       |
| `MEERKAT_NO_SAMPLE=1`   | Take one ranking, then stop (isolate rendering cost)                                                    |
| `MEERKAT_PLAIN=1`       | Replace charts with blank space (isolate chart cost)                                                    |
| `MEERKAT_SAMPLE_DATA=1` | Debug builds only: fill the Overview, Rules and Health pages and Try It with built-in sample replies instead of the daemon's |

For the daemon and tools, besides the storage overrides above (development
only: the bundled toolchains are part of what is signed):

| Variable                                | Effect                                                               |
| --------------------------------------- | -------------------------------------------------------------------- |
| `MEERKAT_TSRS`, `MEERKAT_RUNTIME_TYPES` | Use this tsrs (and runtime declarations) instead of the bundled ones |
| `MEERKAT_LINT_TOOLCHAIN`                | Use this lint toolchain directory instead of the bundled one         |
| `MEERKAT_SIGNING_IDENTITY`              | The bundler's signing identity                                       |

## Releases

The version is `[meerkat] version` in [.buckconfig](../.buckconfig), a SemVer
2.0.0 version without build metadata (`0.2.0-alpha.1`). Changing it is what
releases: [.github/workflows/ci.yml](../.github/workflows/ci.yml) runs
`Tools/check` on every push and pull request (on the runner
[CI runner](#ci-runner) describes), and on another runner builds
the release bundle, signed ad hoc, and runs its `meerkat rules check` and
`rules lint` with the tools it bundles. On a push to `main`,
`buck2 run //Tools/Release:plan` compares the version with the `v*` tags (the
flow is in [docs/architecture.md](architecture.md#build-and-release)):

- no `v<version>` tag yet: the release job builds every part of Meerkat.app
  and stops Buck, and only then reads the secrets, to assemble it, sign it
  with the Developer ID identity, notarize and staple it. It publishes
  `Meerkat-<version>.zip` and the bundle's `THIRD_PARTY_NOTICES` as a GitHub
  release tagged `v<version>` at that commit (a pre-release when the version
  has a pre-release part). Its notes are GitHub's, generated from the
  commits and pull requests since the previous tag: there is no changelog
  file, so the history is the one record of what changed. It runs only in a repository whose Actions
  variable `MEERKAT_RELEASE` is `true`, so a repository without it, or
  without the secrets, checks without publishing;
- already tagged: nothing is published;
- below the latest release: the plan fails, on pull requests too.

The bundle's `CFBundleShortVersionString` is the version's
`major.minor.patch` (macOS takes nothing else there), and `CFBundleVersion`
is the number of commits, so a release build needs the full history.

To build a release locally, with a Developer ID Application identity in the
keychain and an App Store Connect API key:

```bash
MEERKAT_NOTARY_KEY=AuthKey_XXXXXXXXXX.p8 MEERKAT_NOTARY_KEY_ID=XXXXXXXXXX MEERKAT_NOTARY_ISSUER=<issuer-uuid> \
  buck2 run //Tools/Bundler:app -- --notarize --archive build/Meerkat.zip
```

The release job reads the identity and the key from the `release`
environment's secrets, which the workflow's header lists.

## CI runner

Every CI job runs on the runner label the repository's Actions variable
`MEERKAT_RUNNER` names. The repository defines no runner of its own. Without
the variable, as in a fork, no job runs. A pull request from a fork runs no
job either, as the runner may be self-hosted, the machine the release job
signs on; a maintainer checks one by pushing its commits to a branch of the
repository. The runner must be a macOS 27 Apple silicon machine with:

- Xcode at the build `[swift] xcode_build` names, as one of
  `/Applications/Xcode*.app` (the toolchain action selects it by build);
- rustup on `PATH` (the action installs the `[rust] release`, and reindeer
  is installed with its cargo);
- `curl`, `zstd` and `jq` on `PATH`, for buck2 and the pins, and `gh` for the
  release job;
- network access to GitHub, crates.io, npm and the other pinned downloads.

The action installs buck2 and Python itself. A self-hosted runner holds the
Developer ID identity and the notary key while the release job runs, so it
should be ephemeral, or a machine only this repository's jobs use.

## The app icon

The icon is `Tools/Bundler/AppIcon.icon`. Edit it in Icon Composer (bundled
with Xcode); its layers are the SVGs in its `Assets/` folder. The bundler
compiles it with `actool` into `Assets.car` and `AppIcon.icns`, and takes
`CFBundleIconName` from what `actool` reports.

`docs/images/meerkat-icon.png`, the icon the README shows, is the 256-pixel
image of that `AppIcon.icns`, compiled the same way by the Xcode at
`[swift] developer_dir` (`//Tools/Bundler:readme-icon`).
`//Tools/Bundler:icon_test` fails when it is stale, as after an edit to the
icon or a new Xcode, and this rewrites it:

```bash
buck2 run //Tools/Bundler:regenerate
```

## Gotchas worth knowing

- **mach timebase.** `ri_user_time` and friends come back in mach
  absolute-time ticks, not nanoseconds. On Apple Silicon a tick is
  41.666667 ns, so dividing by 1e9 undercounts every CPU number by 41×.
  `MachTime` handles it and a test guards the assumption.
- **EPERM for other users.** `proc_pid_rusage` fails for processes you do not
  own (WindowServer, for example). Those rows come from `ps` instead: CPU time
  at 10 ms resolution, with footprint, disk and energy reported as 0 because
  `ps` cannot supply them. `proc_name` fails for them too, so their name is
  taken from the executable path, which `proc_pidpath` returns unprivileged.
- **TCC silences FSEvents.** Protected paths emit no events rather than
  errors.
- **Disk I/O is a cumulative counter**, so it is meaningful only as a delta
  between two snapshots.
- **Pids are reused.** Deltas, the name cache and every process effect use
  pid plus start time (`kinfo_proc`), so a reused pid is never mistaken for
  the process that had it before.
- **Main run loop.** NSWorkspace, distributed-notification and CoreGraphics
  callbacks are delivered only while the main thread runs `CFRunLoopRun()`.
- **Bluetooth without a usage string kills the process.** macOS terminates a
  process that touches Bluetooth without `NSBluetoothAlwaysUsageDescription`
  in its Info.plist. `bluetooth.devices` checks for the key before using
  IOBluetooth, and refuses to start under a test runner.
- **Interface counters from `getifaddrs` are 32-bit** and wrap every 4 GB, so
  `network.sample` reads the 64-bit `if_data64` from `NET_RT_IFLIST2`.
