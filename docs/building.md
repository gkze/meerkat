# Building from source

Building Meerkat from this repository: what you need, installing a
build, building on another Mac and previewing app changes. To use a
release instead, see the [README](../README.md#install).

## Repository layout

Sources/ holds every module, whatever its language. Each directory is named
after what it builds, in that language's convention: Swift and C modules in
PascalCase (the module name), Swift executables in lowercase (the binary
name), Rust crates and the npm package in kebab-case (the package name).

[docs/architecture.md](architecture.md#source-tree) says what each
directory holds.

## Requirements

- macOS 27 and Xcode 27 (Swift 6.4), at the build `[swift] xcode_build` in
  [.buckconfig](../.buckconfig) names (`//buck2/rules/swift:xcode_test` checks).
  Buck uses the Xcode at `[swift] developer_dir` for Swift and for clang,
  whatever `xcode-select` says.
- [Buck2](https://buck2.build), which builds everything and fetches every
  third-party dependency at a pinned version and checksum, at the release
  `[buck2_release]` in [.buckconfig](../.buckconfig) names
  (`//buck2/rules:buck2_test` checks). Its prelude is bundled, so another
  release could build something else without failing.
- [rustup](https://rustup.rs) on `PATH`, with the Rust release `[rust] release`
  in [.buckconfig](../.buckconfig) names and its clippy and rustfmt
  (`rustup toolchain install <release> --component clippy rustfmt`). Buck runs
  that release, whatever rustup's default (`//buck2/rules:rust_test`
  checks), and never installs it.
- Python 3.12 or later as `python3` on `PATH` when Buck's daemon starts: the
  prelude's helpers run on it, and the Rust build scripts' compiler shim
  needs 3.12 (`Path.relative_to(walk_up=)`). macOS's own `python3` is 3.9,
  and with it the build fails in C compiles of `-sys` crates (cc-rs errors
  in lcms2-sys first). `//buck2/rules:python_test` checks; `buck2 kill`
  after changing `PATH`.
- [reindeer](https://github.com/facebookincubator/reindeer) on `PATH`, at the
  commit `[reindeer] rev` names, only for
  `//buck2/third_party/rust/check:buckify_test` and `buck2 run //:fix`, which
  generate `buck2/third_party/rust/BUCK` from the Rust dependencies
  (`cargo install --locked --git https://github.com/facebookincubator/reindeer --rev <rev> reindeer`)
- [Bun](https://bun.sh), only for editors (`Sources/meerkat-rules/node_modules`)
- An Apple Development or Developer ID signing identity in the keychain. The
  daemon accepts only clients signed by the same team, so the daemon of an
  ad-hoc signed bundle (`--identity -`, which CI builds to check the bundle's
  layout) accepts no client.
  Releases need Developer ID ([Releases](development.md#releases)).

## Install

```bash
buck2 run //Tools/Bundler:app -- --install
```

This builds everything the bundle holds in release mode, whatever the mode
on the command line, and checks that the runtime's checked-in bindings match
the library meerkatd links. It then assembles `build/Meerkat.app`: the app, the CLI, the daemon with
the rule runtime embedded, the agent plist, the TypeScript compiler (tsrs), the
lint tools and the app icon. It signs the bundle with hardened runtime,
copies it to `~/Applications/Meerkat.app`, and registers the agent with
`SMAppService`.

Put the CLI on your PATH:

```bash
ln -sf ~/Applications/Meerkat.app/Contents/MacOS/meerkat ~/.local/bin/meerkat
```

- `--identity` (or `MEERKAT_SIGNING_IDENTITY`) picks the signing identity when
  the keychain has more than one.
- Running `buck2 run //Tools/Bundler:app -- --install` again upgrades in place. It opens
  the app in the background, then registers the agent again, which restarts
  the daemon from the new build and applies plist changes.

## Building on another Mac

A cold build takes long enough to be worth doing on another Mac you can
reach over SSH. `//Tools/RemoteBuild:remote` builds a bundle there, then
assembles, signs and (with `--install`) installs it here. Name the host,
and anything it needs first on `PATH` for a non-interactive SSH command, in
`.buckconfig.local` (Git ignores it; Buck reads it after `.buckconfig`):

```ini
[remote_build]
  # The host, as `ssh` names it.
  host = build-mac
  # Optional: directories put first on PATH there; `~/` is the host's home.
  path = ~/.cargo/bin:/opt/homebrew/bin
  # Optional: where the checkout goes there (default: this checkout's path).
  # It must be empty, or a copy this tool made, and an absolute path of
  # letters, digits and / . _ - + @ , (no `~`): the host's shell reads it.
  directory = /Users/me/src/meerkat
```

```bash
buck2 run //Tools/RemoteBuild:remote -- app-debug
buck2 run //Tools/RemoteBuild:remote -- app --install
buck2 run -c remote_build.host=other-mac //Tools/RemoteBuild:remote -- app
```

The first argument is a `//Tools/Bundler` target; the rest go to the
bundler. The tool:

1. Stops unless the host has the same `buck2 --version`.
2. Copies this checkout to the host (`rsync --delete`, without `buck-out`,
   `.build`, `build`, `.buckd`, `.git`, `node_modules` and the host's own
   `.buckconfig.local`). The directory there must be empty or hold the
   `.meerkat-remote-build` file the first copy writes, so a mistyped
   `directory` stops the tool instead of being erased.
3. Runs the toolchain tests there (`//buck2/rules:buck2_test`,
   `//buck2/rules:python_test`, `//buck2/rules:rust_test`,
   `//buck2/rules/swift:xcode_test`), and stops if the host would not build
   what this Mac would: the buck2 release `[buck2_release]` names, the Xcode
   build `[swift] xcode_build` names, rustup with the `[rust] release`, and
   Python 3.12 or later. Those three pins are this Mac's, passed with `-c`
   to these tests and to the build, so a host `.buckconfig.local` that sets
   one cannot pass the tests against its own value.
4. Runs `buck2 run //Tools/Bundler:<target> --command-args-file` there, so
   Buck builds every part and reports the bundler command instead of
   running it.
5. Copies the parts that command names to `build/remote/<target>/<option>/`
   (`--output` for elsewhere), where unchanged parts are not sent again.
6. Runs the bundler here, from the repository root, with those paths and
   this Mac's `[swift] developer_dir`.

Signing needs this Mac's identity, so it never happens on the host, and the
host needs no keychain: only SSH access and the build requirements above
(the Xcode, rustup with the `[rust] release`, the same buck2 and Python
3.12 or later). Keeping the default `directory`, the same path on both
Macs, keeps the paths in debug info valid here. The parts link only system
libraries, so they run here.
[docs/design/remote-execution.md](design/remote-execution.md)
compares this with Buck2 remote execution.

## Previewing app changes

To check app changes without replacing the installed app or its agent, build
a preview:

```bash
buck2 run //Tools/Bundler:preview
open "build/Meerkat Preview.app"
```

The preview contains only the app, with the same Info.plist and icon, under
its own bundle identifier (`com.gkze.meerkat.preview`), so it keeps its own
defaults. It has no daemon, CLI or LaunchAgent plist: it talks to the
installed daemon and cannot install or replace the agent. It is a debug
build (so `MEERKAT_SAMPLE_DATA=1` works), does not build the runtime, and
cannot be installed. `//Tools/Bundler:app-debug` is the full bundle from a
debug build.
