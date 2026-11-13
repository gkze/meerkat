load("//buck2/rules:check.bzl", "GENERATED", "command", "command_test", "files_test", "over_files", "regenerators", "run_all", "swift_format_fix", "swift_format_test", "swiftlint_test")
load("//buck2/rules:conformance.bzl", "swiftpm_graph_test")
load("//buck2/rules:rust.bzl", "rustfmt_fix")
load("//buck2/third_party/tools:defs.bzl", "tool")

# Package.resolved, read by //Tools/Notices; rustfmt.toml, by every crate's
# rustfmt check (buck2/rules/rust.bzl).
[
    export_file(name = file, src = file, visibility = ["PUBLIC"])
    for file in ["Package.resolved", "rustfmt.toml"]
]

# Package.swift (for SourceKit-LSP and Xcode) declares the Swift targets Buck
# builds, with the same dependencies, linker and Swift settings and macOS: every
# first-party Swift or C module that these, every Swift executable and test
# suite, reach. A query attribute takes no patterns, so the roots are listed;
# :package_swift_roots_test fails when they are not every one. Buck-only, so
# left out: //Tools/RemoteBuild, a tool for running Buck elsewhere, like
# //buck2/conformance (outside these directories).
_SWIFTPM_ROOTS = [
    "//Sources/MeerkatApp:MeerkatApp",
    "//Sources/MeerkatNetworkFilterExtension:MeerkatNetworkFilterExtension",
    "//Sources/meerkat:meerkat",
    "//Sources/meerkatd:meerkatd",
    "//Tests/CLITests:CLITests",
    "//Tests/MeerkatAgentTests:MeerkatAgentTests",
    "//Tests/MeerkatAppTests:MeerkatAppTests",
    "//Tests/MeerkatDaemonTests:MeerkatDaemonTests",
    "//Tests/MeerkatIPCTests:MeerkatIPCTests",
    "//Tests/MeerkatKitTests:MeerkatKitTests",
    "//Tests/MeerkatNetworkFilterTests:MeerkatNetworkFilterTests",
    "//Tests/ReleaseVersionTests:ReleaseVersionTests",
    "//Tools/Bundler:bundle",
    "//Tools/Release:release",
]

swiftpm_graph_test(
    name = "package_swift_test",
    targets = """
        filter('^root//(Sources|Tests|Tools)/',
            kind('swift_library|swift_binary|swift_test|clang_module', deps(set({}))))
    """.format(" ".join(_SWIFTPM_ROOTS)),
    minimum_macos = read_root_config("meerkat", "minimum_macos"),
)

# In an isolation directory of its own, as :starlark-lint runs buck2.
command_test(
    name = "package_swift_roots_test",
    command = [
        "/bin/bash",
        "-c",
        r"""
        query="kind('swift_binary|swift_test', //Sources/... + //Tests/... + //Tools/...) - //Tools/RemoteBuild/..."
        diff <(printf '%s\n' "${@/#\/\//root//}" | LC_ALL=C sort) \
            <(buck2 --isolation-dir package-swift-roots uquery "$query" | LC_ALL=C sort) |
            sed -n 's/^> /a Swift executable or test suite _SWIFTPM_ROOTS (\/\/:BUCK) does not list: /p; s/^< /_SWIFTPM_ROOTS lists what is no Swift executable or test suite: /p' >&2
        status=${PIPESTATUS[0]}
        buck2 --isolation-dir package-swift-roots kill > /dev/null 2>&1
        exit "$status"
        """,
        "package_swift_roots_test",
    ] + _SWIFTPM_ROOTS,
    labels = ["lint", "portable"],
)

swift_format_test(
    name = "Package.swift-format",
    srcs = ["Package.swift"],
)

swiftlint_test(
    name = "Package.swift-lint",
    srcs = ["Package.swift"],
    config = ".swiftlint.yml",
)

# Checks of the files no module owns: Starlark, shell, the workflow, TOML and
# Markdown, each over the whole repository (`over_files`, which leaves the
# generated files to their generators). The tools are pinned in
# buck2/third_party/tools.

# buck2's own linter, which knows its dialect (typed Starlark, its built-ins).
# There is no formatter: buildifier, the only one, writes Bazel's layout
# (hanging signatures, reordered attributes), not this repository's.
# It runs in an isolation directory of its own, as a daemon beside the one
# running this test, and stops that daemon after.
command_test(
    name = "starlark-lint",
    command = over_files(
        [
            "/bin/sh",
            "-c",
            'buck2 --isolation-dir starlark-lint starlark lint "$@"; status=$?; ' +
            "buck2 --isolation-dir starlark-lint kill > /dev/null 2>&1; exit $status",
            "starlark-lint",
        ],
        ["*BUCK", "*PACKAGE", "*.bzl"],
    ),
    labels = ["lint", "portable"],
)

# Shell scripts are found by extension or shebang: Tools/check has neither
# `.sh` nor a BUCK target. zsh is not shellcheck's; none is here.
_SHELL_SCRIPTS = [
    "/bin/bash",
    "-c",
    """
    for file; do
        if [[ $file == *.sh || $file == *.bash ]]; then echo "$file"; continue; fi
        IFS= read -r line < "$file" 2> /dev/null || continue
        if [[ $line =~ ^#!.*[/[:space:]](ba|da|k)?sh([[:space:]]|$) ]]; then echo "$file"; fi
    done
    """,
    "shell-scripts",
]

files_test(
    name = "shellcheck",
    command = [tool("shellcheck")],
    pathspecs = ["."],
    keep = _SHELL_SCRIPTS,
    labels = ["lint", "portable"],
)

# 4-space indentation, as the scripts are written; otherwise shfmt's defaults.
_SHFMT = [tool("shfmt"), "--indent", "4"]

files_test(
    name = "shfmt",
    command = _SHFMT + ["--diff"],
    pathspecs = ["."],
    keep = _SHELL_SCRIPTS,
    labels = ["format", "portable"],
)

# The workflow: actionlint for expressions, contexts and the job graph (and
# shellcheck over its `run:` steps), zizmor for injection, credentials and
# permissions. zizmor runs offline: its online audits need a GitHub token.
command_test(
    name = "actionlint",
    command = [tool("actionlint"), "-shellcheck", tool("shellcheck")],
    labels = ["lint", "portable"],
)

files_test(
    name = "zizmor",
    command = [tool("zizmor"), "--offline", "--config", ".github/zizmor.yml"],
    pathspecs = [".github/workflows/*.yml", ".github/actions/*/action.yml", ".github/dependabot.yml"],
    labels = ["lint", "portable"],
)

# Every action the workflow and the composite actions use, pinned to a full
# commit SHA with the version it is as a comment (`uses: o/r@<sha> # v1.2.3`).
# :pinact checks that offline: the SHA's form and the comment's presence. A
# tag or branch ref, or a bare SHA, fails it; `buck2 run //:pinact-fix`
# pins them through GitHub's API. :pinact-verify asks GitHub whether each
# comment names the version its SHA is, which a comment written by hand
# need not.
_ACTION_FILES = [".github/workflows/*.yml", ".github/actions/*/action.yml"]

files_test(
    name = "pinact",
    command = [tool("pinact"), "run", "--fix=false", "--no-api"],
    pathspecs = _ACTION_FILES,
    labels = ["lint", "portable"],
)

files_test(
    name = "pinact-verify",
    command = [tool("pinact"), "run", "--fix=false", "--verify-comment"],
    pathspecs = _ACTION_FILES,
    labels = ["lint", "network", "portable"],
)

command(
    name = "pinact-fix",
    command = over_files([tool("pinact"), "run"], _ACTION_FILES),
)

# TOML, by tombi's defaults. Offline: no schema is fetched.
_TOML_FILES = ["*.toml"]

files_test(
    name = "toml-format",
    command = [tool("tombi"), "format", "--offline", "--check"],
    pathspecs = _TOML_FILES,
    labels = ["format", "portable"],
)

files_test(
    name = "toml-lint",
    command = [tool("tombi"), "lint", "--offline"],
    pathspecs = _TOML_FILES,
    labels = ["lint", "portable"],
)

# Markdown, with .rumdl.toml, and the links between the repository's files
# and to their headings (lychee, offline: no web link is fetched).
# CLAUDE.md is an import directive (`@AGENTS.md`), not a document.
_MARKDOWN_FILES = ["*.md", ":(exclude)CLAUDE.md"]

files_test(
    name = "markdown-lint",
    command = [tool("rumdl"), "check", "--no-cache"],
    pathspecs = _MARKDOWN_FILES,
    labels = ["lint", "portable"],
)

files_test(
    name = "markdown-links",
    command = [tool("lychee"), "--offline", "--include-fragments", "--no-progress"],
    pathspecs = _MARKDOWN_FILES,
    labels = ["lint", "portable"],
)

# Secrets, by gitleaks' rules: in every commit the clone has (a shallow one
# has fewer), and, for the pre-commit hook, in the staged changes. Findings
# print redacted. A false positive goes in .gitleaksignore by the
# fingerprint gitleaks prints, or takes a `gitleaks:allow` comment.
command_test(
    name = "gitleaks",
    command = [tool("gitleaks"), "git", "--redact", "--no-banner"],
    labels = ["lint", "portable"],
)

# The hook passes the index of the commit being made as
# MEERKAT_GIT_INDEX_FILE, not GIT_INDEX_FILE, which a buck2 daemon it starts
# would keep (prek.toml says why); git reads the latter, so it is set back.
command(
    name = "gitleaks-staged",
    command = [
        "/bin/sh",
        "-c",
        'if [ -n "${MEERKAT_GIT_INDEX_FILE-}" ]; then GIT_INDEX_FILE=$MEERKAT_GIT_INDEX_FILE; export GIT_INDEX_FILE; fi; exec "$@"',
        "gitleaks-staged",
        tool("gitleaks"),
        "git",
        "--pre-commit",
        "--staged",
        "--redact",
        "--no-banner",
    ],
)

# prek.toml's file checks (conflict markers, large and case-clashing files,
# shebangs, JSON and YAML syntax, line endings, whitespace) over every
# tracked file: the pre-commit hook runs them over the staged ones. A
# malformed prek.toml fails here too.
command_test(
    name = "hygiene",
    command = [tool("prek"), "run", "--all-files", "--hook-stage", "manual"],
    labels = ["lint", "portable"],
)

# Installs the Git hooks prek.toml declares. The hooks name this prek by its
# path in buck-out, and `prek` on PATH when that is gone: after `buck2
# clean`, run this again.
command(
    name = "install-hooks",
    command = [tool("prek"), "install"],
)

# `buck2 run //:fix` rewrites formatting and applies lint fixes in every
# language (`Tools/check --fix` runs it first); `buck2 test //...` checks.
# Each fixer rewrites the repository's files of its kind (`over_files`).
swift_format_fix(
    name = "swift-format-fix",
    pathspecs = ["*.swift"],
)

rustfmt_fix(
    name = "rustfmt-fix",
    pathspecs = ["*.rs"],
)

command(
    name = "shfmt-fix",
    command = over_files(_SHFMT + ["--write"], ["."], keep = _SHELL_SCRIPTS),
)

command(
    name = "toml-fix",
    command = over_files([tool("tombi"), "format", "--offline"], _TOML_FILES),
)

command(
    name = "markdown-fix",
    command = over_files([tool("rumdl"), "check", "--no-cache", "--fix"], _MARKDOWN_FILES),
)

run_all(
    name = "fix",
    commands = [
        ":swift-format-fix",
        ":rustfmt-fix",
        ":shfmt-fix",
        ":toml-fix",
        ":markdown-fix",
        "//Sources/meerkat-rules:fix",
    ] + regenerators(),
)

# AGENTS.md's table of generated files ("Generated files", its first column)
# names the files GENERATED does, no more and no fewer.
command_test(
    name = "generated_files_test",
    command = [
        "/bin/bash",
        "-c",
        r"""
        listed() {
            awk '/^## /{on = $0 == "## Generated files"; next} on && /^[|] `/' AGENTS.md |
                cut -d '|' -f 2 | grep -o '`[^`]*`' | tr -d '`' | LC_ALL=C sort
        }
        diff <(printf '%s\n' "$@" | LC_ALL=C sort) <(listed) |
            sed -n 's/^< /GENERATED (buck2\/rules\/check.bzl) names, AGENTS.md does not: /p; s/^> /AGENTS.md names, GENERATED does not: /p' >&2
        exit "${PIPESTATUS[0]}"
        """,
        "generated_files_test",
    ] + list(GENERATED),
    labels = ["lint", "portable"],
)
