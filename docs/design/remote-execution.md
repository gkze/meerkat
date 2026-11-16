# Building on another Mac: remote builds and Buck2 remote execution

Status: `//Tools/RemoteBuild:remote` is implemented (docs/building.md, "Building
on another Mac"), and so is toolchain identity in action keys for Rust and C
(fix 1 below; Python's version is outside the keys by decision, see
[Python](#python)). Buck2 remote execution is implemented too, off unless a
Mac's `.buckconfig.local` turns it on (docs/building.md, "Remote
execution"), and was first run against NativeLink with two Mac workers
([Remote execution, as built](#remote-execution-as-built)). The sections
before that one are the evaluation it followed.

Contents: [Question](#question) · [Remote builds](#remote-builds) ·
[What actions reference](#what-actions-reference) ·
[What remote execution would need](#what-remote-execution-would-need) ·
[Remote execution, as built](#remote-execution-as-built) ·
[Cache sharing](#cache-sharing) · [Effort](#effort) ·
[Recommendation](#recommendation) · [Python](#python)

## Question

A cold build is long enough to get in the way on the Mac you work on. A
developer may have other Macs to spare, of two kinds:

- a **build host** with the same toolchain: the Xcode build `[swift]
  xcode_build` names, rustup with the `[rust] release`, buck2 and Python
  3.12 or later;
- a **tools-only host** with the Command Line Tools and no Xcode (so no
  `actool`), Rust or buck2.

"Here" below is the Mac that holds the signing identity. Can Buck2 remote
execution (RE), with for example NativeLink as the content-addressed store
(CAS), action cache (AC), scheduler and worker, spread the build over such
hosts, and is it worth it compared with building a whole bundle on one
build host and signing here?

## Remote builds

`//Tools/RemoteBuild:remote` builds a bundle on one build host, named in
the git-ignored `.buckconfig.local` (`[remote_build] host`, and optionally
`path` and `directory`):

It copies the checkout there, has Buck build every part, copies the parts
back and runs the bundler here, where the signing identity is: the steps are
in [building.md, "Building on another Mac"](../building.md#building-on-another-mac).

Measured on an M1 Max (10 cores) build host: a cold `app-debug` took 13.5
minutes (4,949 actions); a run with nothing changed takes about 15 seconds,
most of it rsync and the toolchain check. Each host keeps its own
`buck-out`, so nothing built on the build host is reused by builds or tests
here.

The cold build's actions, by category (`buck2 log what-ran` on the build
host):

| Actions | Category                                         | Remotable today                     |
| ------- | ------------------------------------------------ | ----------------------------------- |
| ~3,140  | rustc (metadata and codegen, two per crate)       | yes, given the fixes below          |
| 1,507   | `http_archive` (unpacking crate archives)         | yes, cheap either way               |
| 179     | Rust build scripts                                | mostly; some probe the host         |
| ~115    | Swift (`swift_compile`, `swift_sources`, links)   | compiles no: `local_only`           |
| ~10     | genrules, C compiles, npm unpacks, archives       | yes                                 |

Count is not time: the Swift compiles (swift-syntax for the macro plugins,
the app, the daemon) and the V8-bearing Rust crates are the long poles.
Timing per category was not measured; `buck2 log what-ran` with durations
on the next cold build would give it.

## What actions reference

Remote execution runs an action in a fresh directory on the worker, with
only its declared inputs and the environment the action itself sets. Local
actions also see the Buck daemon's environment. What each toolchain
reaches for, and whether the action's cache key covers it:

- **Swift** (`buck2/rules/swift`): `swiftc` and the SDK by absolute path
  under `[swift] developer_dir` (`/Applications/Xcode.app/...`). Every Swift
  action runs with `DEVELOPER_DIR` set to that directory (`xcode_env` in
  `buck2/rules/toolchains.bzl`), so what it runs through an `xcrun` shim
  (actool) is that Xcode's too. The key covers the Xcode through the
  `MEERKAT_XCODE_BUILD` environment variable, which `xcode_test` keeps equal
  to the real build. Compiles are
  `local_only = True` because they share an implicit module cache at
  `buck-out/swift-module-cache`, written outside Buck's outputs. They cannot
  run remotely as they are.
- **C and C++, and every link of a Rust binary** (`buck2/toolchains`
  `cxx`, from `xcode_clang_tools` in `buck2/rules/toolchains.bzl`):
  `/usr/bin/clang`, `/usr/bin/clang++`, `/usr/bin/ar`. These are `xcrun`
  shims, which pick the developer directory from `DEVELOPER_DIR`, else
  `xcode-select`. Each runs as `/usr/bin/env
  DEVELOPER_DIR=<[swift] developer_dir> MEERKAT_XCODE_BUILD=<[swift]
  xcode_build> /usr/bin/clang`, so it uses the same Xcode as Swift and its
  build is in the key. On a tools-only host these actions fail rather than
  compile with the Command Line Tools' clang.
- **Rust** (`rustup_toolchain` in `buck2/rules/toolchains.bzl`): `rustc`,
  `clippy-driver` and `rustdoc` from rustup's proxies on `PATH`, each run as
  `/usr/bin/env RUSTUP_TOOLCHAIN=<[rust] release> RUSTUP_AUTO_INSTALL=0
  rustc`. The release is pinned in `.buckconfig` and is in every Rust
  action's command line, including the scripts the prelude writes around
  rustc (the build scripts' `RUSTC` shim, the linker wrapper, clippy's
  sysroot query) and `rustc_cfg`. rustfmt and reindeer's cargo run the same
  release. `//buck2/rules:rust_test` fails when rustup lacks the release, or
  when `rustc` on `PATH` is not rustup's (which would ignore the variable).
  `RUSTUP_AUTO_INSTALL=0` matters: without it rustup downloads a missing
  release from inside the first actions that run it, all at once. Without
  the pin, rustup's default would choose, and it can differ between hosts.
- **Python** (prelude `system_python_toolchain` and bootstrap): `python3`
  from `PATH`, 3.12 or later (`//buck2/rules:python_test`, and
  `//Tools/RemoteBuild`'s check). Not in the key; see [Python](#python).
- **Paths in outputs**: debug builds embed absolute source and output paths.
  `//Tools/RemoteBuild` puts the checkout at the same path on the build host
  unless `[remote_build] directory` says otherwise; a worker's per-action
  directory would differ, which matters for reproducibility checks and
  debugging, not for correctness.

## What remote execution would need

Buck2 talks to any REAPI v2 service. Wiring it in is small:
`[buck2_re_client]` addresses (engine, CAS, action cache) and the digest
algorithm in `.buckconfig`, and `remote_enabled = True` (with
`use_limited_hybrid` or local fallback) plus platform properties in
`buck2/platforms/defs.bzl`'s `CommandExecutorConfig`, which today says
`remote_enabled = False`. NativeLink runs natively on macOS as one process
holding the CAS, the AC, the scheduler and a worker, or as separate
processes. These details are from the Buck2 and NativeLink documentation
and were not exercised.

The work is in making actions safe to run and to share elsewhere:

1. **Toolchain identity in the key** (done for Rust and C, see
   [What actions reference](#what-actions-reference)). A shared cache
   returns whatever any host produced for the same key, so every toolchain
   the key does not name must match exactly, forever, or results get mixed.
   The variable goes on the command line (`/usr/bin/env NAME=value tool`)
   rather than in an action's environment because the prelude has no
   environment hook for C actions or for the scripts it writes around
   rustc, and the command line reaches all of them. A rustup toolchain's
   absolute path would also have worked for Rust, but it contains the home
   directory, which Starlark cannot read.
2. **Swift compiles off the shared module cache.** Explicit module builds
   (the driver precompiles each Clang and Swift module dependency as its own
   output), or a module cache per action, so compiles have only declared
   inputs. Until then only Rust, C and links can go remote, and the Swift
   long poles stay on whichever Mac runs `buck2`.
3. **Workers that match.** Every worker needs the Xcode build `[swift]
   xcode_build` names at `[swift] developer_dir` (a tools-only host has
   none, and installing it needs an Apple ID), rustup with the `[rust]
   release`, Python 3.12+, and the same macOS SDK. Platform properties
   could send Rust-only work to a worker without Xcode, but links use
   Xcode's clang, so such a worker could only compile crates that link
   nothing (rlibs), not build scripts or binaries.
4. **Build scripts that probe the host.** Some of the 179 read the
   environment or run tools at build time; on a worker they see the
   worker's. Each would need checking when it first runs remotely.
5. **An always-on service.** CAS storage (the debug bundle's parts alone are
   ~600 MB, `meerkatd` ~500 MB of it; a build host's `buck-out/v2/art`
   after a day of builds reached 17 GB), eviction, and a LaunchAgent on the
   host that serves it, on a private network without TLS or behind it.

## Remote execution, as built

`buck2/platforms/defs.bzl` builds the execution platform's executor from
`[meerkat] remote_execution`: off, everything runs here; on, actions run
remotely (limited hybrid: here only when they cannot run there), asking for
a worker by `OSFamily`, `xcode_build` and `rust_release`. A second execution
platform, never remote, takes the targets that name `LOCAL_EXECUTION` in
`exec_compatible_with`.

Running the debug app and daemon on NativeLink 1.8.5 (CAS, action cache,
scheduler and an 18-slot worker on one Mac, a 10-slot worker on another)
found what a single machine hides, each an input an action reads without
declaring it, and each fixed where it is:

- **A Swift package's C headers.** swift-nio's `CNIOAtomics` includes
  `cpp_magic.h`, beside its sources, which only the unpacked archive had.
  Each C target now has its whole directory as an input
  (`buck2/third_party/swift/defs.bzl`).
- **cranelift's build scripts.** cranelift-assembler-x64's records the
  absolute paths of the files it generates, and cranelift-codegen's reads
  them through cranelift-codegen-meta. Both run here
  (`buck2/rules/buildscript.bzl`, `LOCAL_BUILD_SCRIPTS`), where the paths
  stay valid; Reindeer generates every build script's target through it.
  That is a workaround, meant to last until a patch passes the files'
  contents instead, as Deno's do: it keeps two short scripts here, and builds
  the crates they link a second time, for the local platform.
- **Deno's extension sources.** deno_core 0.413 records each extension
  file's absolute path when the crate compiles (`include_js_files!`, under
  `CARGO_MANIFEST_DIR`, which the prelude makes absolute) and deno_snapshots'
  build script reads them back; on a worker that path is the directory it
  compiled in. Four files of those crates are taken from Reindeer's own
  archive of each crate with a patch from `buck2/third_party/rust/overlays`
  applied, and mapped back into the crates (`extra_mapped_srcs`); the
  patches apply to whatever release Cargo.lock resolves, and the build fails
  on one they no longer fit. `buck2/rules/cargo.bzl`, through which Reindeer
  generates every crate's download, makes those two archives visible to that
  package. Two embed the files instead of recording paths: deno_core's `extensions.rs` (`mode=included`) and
  deno_runtime's `shared.rs` (`99_main.js`). Two keep lazy loading as it
  was: deno_runtime's `snapshot.rs` writes an embedded lazy file under
  `OUT_DIR` so deno_snapshots still transpiles it into the residual tables
  the runtime loads lazy modules from, and deno_core's `extension_set.rs`
  leaves those files to that table, so a worker does not transpile them
  again as it starts (it did, and rules took longer to load than their 5 s
  limit allows under load).

  The patches apply in every build, not only with remote execution on: two
  Deno runtimes from one tree would be a dual path (AGENTS.md), with the
  shipped one tested by Tools/check and the patched one only where remote
  execution is on, though the lazy-module tables and rule loading differ
  between them. One Deno, the tested one, ships. It costs the shipped daemon
  the extensions' sources in the binary as well as the snapshot: measured on
  one Mac, the same tree with and without the patches, the release daemon
  grows from 253.0 MB to 263.7 MB (+4.2%) and the debug one from 508.2 MB to
  513.2 MB (+1.0%). Rule tests take the same time either way (6.3 to 6.4 s,
  three alternating runs each). That cost was accepted (2026-11-15) over the
  alternative that avoids it, a NativeLink used only as a shared cache, with
  no remote execution and so no patches. The fix upstream would be deno_core
  recording paths relative to something every action has; until then the
  patches are what remote execution costs.

  Keeping the crates
  that record paths here instead does not work: a crate compiled here and
  one compiled remotely see different builds of the same proc macros, which
  rustc rejects, so every crate they depend on would have to stay here too.

Two settings mattered on the service: macOS's default open-file limit for a
LaunchAgent is too low for a build's uploads (raise `NumberOfFiles` and
NativeLink's `max_open_files`), and a LaunchAgent with `ProcessType`
`Background` is throttled enough that workers miss their keepalives. A
worker runs actions with an empty environment, so it passes `PATH` and
`HOME` through (`additional_environment`). A Mac with the application
firewall on must allow NativeLink, or other Macs' connections are accepted
and then never answered.

## Cache sharing

A shared action cache without remote workers is the cheaper half: every Mac
runs actions itself, uploads results, and takes hits from the others
(`remote_cache_enabled` and `allow_cache_uploads` in the executor config,
with a CAS and AC such as NativeLink's on a spare Mac). It gives every Mac
the others' work for ordinary `buck2 build` and `buck2 test`, not only for
bundles. It has the same prerequisite as remote execution, toolchain
identity in the key (fix 1, done for Rust and C); without it, a host with a
different rustup default or `xcode-select` would silently poison the cache
for everyone. Whether Buck uploads the results of `local_only` actions (the
Swift compiles) to the cache was not checked; if not, Swift still compiles
on every Mac.

## Effort

| Step                                                                     | Effort         | Gives                                        |
| ------------------------------------------------------------------------ | -------------- | -------------------------------------------- |
| `//Tools/RemoteBuild`                                                    | done           | whole bundles built elsewhere, signed here   |
| Toolchain identity in action keys (fix 1), Rust pinned in the repo       | done (Rust, C) | safe sharing; also correct local caching     |
| NativeLink CAS + AC on one host, cache-only on every Mac                 | a day or two   | every Mac reuses the others' builds and tests |
| Workers (Macs with Xcode and rustup), Rust and C remote                  | days           | parallel Rust across hosts                   |
| Swift explicit module builds, Swift remote                               | days to weeks  | the Swift long poles off the working Mac too |

## Recommendation

Use `//Tools/RemoteBuild:remote` for bundles; it covers the need (cold
builds off the Mac you work on) with no service to run, and its toolchain
check keeps it honest.

Remote execution now builds the app and daemon (see
[Remote execution, as built](#remote-execution-as-built)), and every
worker needs Xcode. It spreads Rust, C and links over the workers, and
their results over every Mac through the shared cache. The Swift compiles
still run on the Mac running Buck until explicit module builds; a
RemoteBuild run puts that Mac on the build host, next to the service. The
Deno patches are the cost: they must be redone, or dropped, with each
deno_core and deno_runtime release (Sources/meerkat-runtime/deno.bzl pins
them), and the shipped daemon is 4.2% larger for them.

## Python

Python's version stays outside the keys, with only the 3.12 floor checked.
The prelude runs Python only for its own helpers: the wrapper around every
rustc (`rustc_action.py`), the build-script runner, and the C compiler shim
(`from_any_dir.py`). They start processes and move files; none of them
writes anything into an output that depends on the interpreter's version,
so a different Python 3.12+ builds the same artifacts. Putting the exact
version into the key would rebuild every Rust crate at each Python patch
release (some package managers update it often) for no change in output,
and pinning one version would require the same Python on every host. What
does depend on Python is whether the build works at all, and the 3.12
floor is checked (`//buck2/rules:python_test`, `//Tools/RemoteBuild`). If an
output ever does depend on it, the same `/usr/bin/env` approach applies to
the bootstrap interpreter, with a pinned `[python] version` in
`.buckconfig`.
