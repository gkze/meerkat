# Contributing

Meerkat is pre-alpha: formats, the rule API and stored data change without
migration, and there is no compatibility code to keep old ones working.

- [AGENTS.md](AGENTS.md) is the short guide for anyone changing the code,
  person or agent: the build, which check to run for which change, generated
  files and the repository's rules.
- [docs/development.md](docs/development.md) has the checks, style, tests,
  releases and CI in full; [docs/architecture.md](docs/architecture.md) is
  the map, and [docs/design/](docs/design/) holds each part's reasons.
- `buck2 run //:install-hooks` installs Git hooks that run the quick checks
  (file hygiene and secrets on commit, formatting and lints on push), as
  [docs/development.md, "Git hooks"](docs/development.md#git-hooks) says.
- Run `Tools/check` before you open a pull request. A cold build takes tens
  of minutes; [docs/building.md, "Building on another Mac"](docs/building.md#building-on-another-mac)
  moves it to a spare Mac.
- Pull requests from forks run only the portable checks on GitHub's Linux
  runner; the builds and test suites wait until a maintainer pushes their
  commits to a branch here ([docs/development.md, "CI runner"](docs/development.md#ci-runner)
  says why).
- Report a vulnerability privately, as [SECURITY.md](SECURITY.md) says, not
  in an issue.

Contributions are under the [MIT licence](LICENSE), as the rest of the code is.
