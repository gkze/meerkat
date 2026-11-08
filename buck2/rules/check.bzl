load("//buck2/third_party/tools:defs.bzl", "tool")

# A check as a test: a command, run from the repository root, that passes
# when it exits 0. `srcs` are what it reads (appended to the command with
# `pass_srcs`); the command names its tools with `$(exe …)` or
# `$(location …)`, which Buck builds first.
#
# Labels: `format` and `lint` mark the checks that build nothing (their
# tools are downloads, Xcode's or rustup's) and that read only the
# repository; the pre-push hook runs every one of them (prek.toml).
# `network` marks a format or lint check that also reads the network, which
# the hook leaves out. A check that builds, such as clippy or meerkat-lint, has
# neither, and runs in Tools/check and CI.

def external_test(command: cmd_args, labels: list[str], env: dict = {}) -> ExternalRunnerTestInfo:
    """A test that runs `command` from the repository root."""
    return ExternalRunnerTestInfo(
        type = "command",
        command = [command],
        env = env,
        labels = labels,
        contacts = [],
        run_from_project_root = True,
        use_project_relative_paths = True,
    )

def _command_test_impl(ctx: AnalysisContext) -> list[Provider]:
    if ctx.attrs.pass_srcs:
        command = cmd_args(ctx.attrs.command, ctx.attrs.srcs)
    else:
        command = cmd_args(ctx.attrs.command, hidden = ctx.attrs.srcs)
    return [DefaultInfo(), external_test(command, ctx.attrs.labels, ctx.attrs.env)]

command_test = rule(
    impl = _command_test_impl,
    attrs = {
        "command": attrs.list(attrs.arg()),
        "env": attrs.dict(attrs.string(), attrs.arg(), default = {}),
        "labels": attrs.list(attrs.string(), default = []),
        "pass_srcs": attrs.bool(default = False),
        "srcs": attrs.list(attrs.source(), default = []),
    },
)

# The environment that makes `xcrun` run the Xcode Buck builds with
# (`[swift] developer_dir`), not xcode-select's.
XCODE_ENV = {"DEVELOPER_DIR": read_root_config("swift", "developer_dir")}

def with_xcode_env(command: list) -> list:
    """`command`, run through `env` with XCODE_ENV, for a RunInfo (which has
    no environment of its own)."""
    return ["/usr/bin/env"] + ["{}={}".format(name, value) for name, value in XCODE_ENV.items()] + command

_SWIFT_FORMAT = with_xcode_env(["/usr/bin/xcrun", "swift-format"])

def swift_format_test(name: str, srcs: list):
    """`swift format lint --strict` over `srcs`, with the repository's
    .swift-format, as Tools/check runs it."""
    command_test(
        name = name,
        command = _SWIFT_FORMAT + ["lint", "--strict", "--configuration", ".swift-format"],
        srcs = srcs,
        pass_srcs = True,
        labels = ["format"],
    )

# Runs a command with the repository's files appended: those git's
# `pathspecs` match, tracked or new and not ignored, that exist. A Buck glob
# stops at package boundaries, and these checks read every package's files.
# `keep`, when given, is a command that prints the ones to keep, one per
# line (//:BUCK's shell-script filter). Every pathspec here names files the
# repository has, so a listing git or `keep` fails, or one that comes back
# empty (a copy without .git, a tree git refuses, a pathspec a rename left
# behind), fails the check: it would otherwise pass having run nothing.
# (Command substitution is in backquotes: Buck reads a dollar sign and a
# parenthesis as one of its macros.)
_OVER_FILES = """
take() { taken=("${@:2:$1}"); }
take "$@"; keep=("${taken[@]}"); shift; shift "${#keep[@]}"
take "$@"; command=("${taken[@]}"); shift; shift "${#command[@]}"
listing=`mktemp` || exit 1
if ! git ls-files -z --cached --others --exclude-standard -- "$@" > "$listing"; then
    rm -f "$listing"
    echo "over_files: git could not list the files (is this a Git work tree?)" >&2
    exit 1
fi
files=()
while IFS= read -r -d '' file; do
    if [[ -e $file ]]; then files+=("$file"); fi
done < "$listing"
if ((${#keep[@]} && ${#files[@]})); then
    if ! "${keep[@]}" "${files[@]}" > "$listing"; then
        rm -f "$listing"
        echo "over_files: the filter of the files failed" >&2
        exit 1
    fi
    files=()
    while IFS= read -r file; do files+=("$file"); done < "$listing"
fi
rm -f "$listing"
if ((${#files[@]} == 0)); then
    echo "over_files: no files match $*" >&2
    exit 1
fi
exec "${command[@]}" "${files[@]}"
"""

def over_files(command: list, pathspecs: list[str], keep: list = []) -> list:
    """`command` over the files `pathspecs` match (see _OVER_FILES). Each
    element of `command` and `keep` must be one argument."""
    return ["/bin/bash", "-c", _OVER_FILES, "over_files", str(len(keep))] + keep + [str(len(command))] + command + pathspecs

def files_test(name: str, command: list, pathspecs: list[str], keep: list = [], env: dict = {}, labels: list[str] = ["lint"]):
    """A check of `command` over the files `pathspecs` match."""
    command_test(name = name, command = over_files(command, pathspecs, keep), env = env, labels = labels)

def swiftlint_test(name: str, srcs: list, config: str):
    """SwiftLint over `srcs` with `config` (a repository path), any finding
    failing. SwiftLint finds SourceKit through the Xcode Buck builds with."""
    command_test(
        name = name,
        command = with_xcode_env([
            tool("swiftlint"),
            "lint",
            "--strict",
            "--quiet",
            "--no-cache",
            "--config",
            config,
        ]),
        srcs = srcs,
        pass_srcs = True,
        labels = ["lint"],
    )

def _command_impl(ctx: AnalysisContext) -> list[Provider]:
    return [DefaultInfo(), RunInfo(args = cmd_args(ctx.attrs.command))]

# A command to `buck2 run`, such as a formatter that rewrites sources (run
# from the repository root, as `buck2 run` does).
command = rule(
    impl = _command_impl,
    attrs = {"command": attrs.list(attrs.arg())},
)

def _run_all_impl(ctx: AnalysisContext) -> list[Provider]:
    script = 'status=0; for command in "$@"; do eval "$command" || status=1; done; exit $status'
    args = cmd_args("/bin/sh", "-c", script, "run_all")
    for dep in ctx.attrs.commands:
        args.add(cmd_args(dep[RunInfo], delimiter = " ", quote = "shell"))
    return [DefaultInfo(), RunInfo(args = args)]

# Runs every command in `commands` (targets with RunInfo) in order, all of
# them even when one fails, and fails if any did.
run_all = rule(
    impl = _run_all_impl,
    attrs = {"commands": attrs.list(attrs.dep(providers = [RunInfo]))},
)

def swift_format_fix(name: str, paths: list[str]):
    """Rewrites the Swift sources under `paths` (repository-relative) with
    swift-format, as `Tools/check --fix` did."""
    command(
        name = name,
        command = _SWIFT_FORMAT + ["format", "--in-place", "--parallel", "--recursive", "--configuration", ".swift-format"] + paths,
    )
