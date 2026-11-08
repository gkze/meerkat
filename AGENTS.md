# Working on Meerkat

Meerkat is a macOS system monitor: a Swift daemon that runs users' TypeScript
rules in an embedded Deno runtime, with a CLI, a SwiftUI app and an MCP server.
`docs/architecture.md` is the map, `docs/design/` holds each part's reasons,
and `docs/development.md` has the checks, style, tests, releases and CI in full.
These are for changing Meerkat. For using it, see `meerkat skills`.

## Build and check

Buck2 is the build. `Package.swift` exists for editors and is checked against the
BUCK files.

```bash
Tools/check          # everything: warnings as errors, formatting, lints, tests
Tools/check --fix    # first rewrites formatting, lint fixes and generated files
buck2 run //:install-hooks   # Git hooks: file checks and secrets on commit, format and lint on push
```

A cold build takes tens of minutes and most of a machine's cores. If you have a
faster or spare Mac, use `buck2 run //Tools/RemoteBuild:remote` (docs/building.md,
"Building on another Mac"). Every check is its own target, so run the one you need:
`buck2 test //Sources/MeerkatKit:MeerkatKit-format`. Tools/check builds in
debug; `buck2 run //Tools/Bundler:app -- --identity -` builds the release
bundle, as CI does.

Run the narrowest targets that cover what you changed, then `Tools/check` once
before you finish:

| You changed | Run |
|---|---|
| Swift in `Sources/<Module>` | `buck2 test //Sources/<Module>:<Module>-format //Sources/<Module>:<Module>-lint` |
| The CLI, its output or exit statuses | `buck2 test //Tests/CLITests:CLITests` |
| The daemon, rules, effects or MCP | `buck2 test //Tests/MeerkatDaemonTests:MeerkatDaemonTests` |
| MeerkatKit, MeerkatStore or the sources | `buck2 test //Tests/MeerkatKitTests:MeerkatKitTests` |
| The app | `buck2 test //Tests/MeerkatAppTests:MeerkatAppTests`, then the real app |
| An agent skill (`AgentSkills.swift`) | CLITests and MeerkatDaemonTests: they parse every command and tool it names |
| A catalog or `meerkat.json`'s schema | `buck2 run //:fix`, then MeerkatDaemonTests, which compare the generated files |
| `Package.swift` or a BUCK file's deps | `buck2 test //:package_swift_test` |
| Markdown | `buck2 test //:markdown-lint //:markdown-links` |
| `prek.toml` | `buck2 test //:hygiene` |

Passing tests don't show a UI works. Exercise the real app for anything a person
sees, and say so if you couldn't.

## Generated files

Change the authority, not the output. A check fails when one is stale. `buck2 run
//:fix` regenerates them all.

| File | From | Stale when |
|---|---|---|
| `Sources/meerkat-rules/meerkat.d.ts` | the Swift event and effect catalogs | `DeclarationTests` (MeerkatDaemonTests) |
| `Sources/meerkat-rules/meerkat.schema.json` | the configuration's types (`MeerkatConfiguration.schema`) | `ConfigurationTests` (MeerkatDaemonTests) |
| `Sources/meerkat-rules/deno.d.ts` | Deno's libraries the runtime composes, at the pinned crates | `//Sources/meerkat-runtime:declarations_test` |
| `Sources/meerkat-runtime/MeerkatRuntimeBindings/`, `CMeerkatRuntime/include/meerkat_runtime.h` | the Rust crate, through UniFFI | `//Sources/meerkat-runtime/bindgen:bindings_current` |
| `buck2/third_party/rust/BUCK`, `Cargo.lock` | `Cargo.toml` and `fixups/`, through Reindeer | `//buck2/third_party/rust/check:buckify_test` |
| `buck2/third_party/swift/modules.bzl` | each Swift package's manifest at its pin in `buck2/third_party/swift/BUCK` | `//buck2/third_party/swift:manifest_test` |
| `Tools/Notices/bundled_crates.bzl` | the Cargo.lock files `LOCKFILES` in `Tools/Notices/BUCK` pins | `//Tools/Notices:notices` |
| `docs/images/meerkat-icon.png` | `Tools/Bundler/AppIcon.icon`, through actool at `[swift] developer_dir` | `//Tools/Bundler:icon_test` |

## Rules of the repository

- **Pre-alpha, no compatibility code.** No shims, legacy decoders, version
  branches or dual paths. Change the format and move on.
- **Nothing specific to one machine.** Host names and personal paths go in
  `.buckconfig.local`, which is ignored. Anyone must be able to build this.
- **Generators live in the pipeline.** No loose scripts: a task that produces a
  committed file is a Buck target with a staleness check.
- **Comments say why.** Match the code around you: its density, naming and idiom.
- **Docs are part of the change.** Keep the README, `docs/` and the design notes true.

## Trust boundaries

Rule code, MCP clients and everything in an event payload are untrusted. Rules can
only do what they declare, and no rule may reach Meerkat's own settings, rules or
state. `docs/design/mcp.md` ("Harm model") and `docs/design/effects.md` say why.

Validate a value where it enters, and never let one from outside reach a trapping
conversion like `Int(_:)`. A trap kills the whole daemon, and with it every rule.
