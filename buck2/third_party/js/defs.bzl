# An npm package from its registry tarball: `<name>.tgz` (the download,
# checked against `sha256`; //buck2/third_party/js:pins_test compares it with
# Sources/meerkat-rules/bun.lock) and `<name>`, its `package/` directory unpacked.
#
# Everything else names a tool's executable through `js_tool()` (a command
# line) or `js_tool_target()` (a file to copy), which keep where each target
# holds it here.

# The platform of the release archives, as their file names spell it.
RELEASE_PLATFORM = "aarch64-apple-darwin"

# Each tool's executable, by its path inside the tool's target (a release
# archive's file, or a file of the npm package), and whether the tool runs
# there, in its target's directory, rather than as a file of its own: tsrs
# resolves its lib.*.d.ts next to itself.
_EXECUTABLES = {
    "oxfmt": ("oxfmt-" + RELEASE_PLATFORM, False),
    "oxlint": ("oxlint-" + RELEASE_PLATFORM, False),
    "tsrs": ("tsrs", True),
    "tsrslint": ("tsrslint", False),
}

def js_tool_subtargets(name: str) -> list[str]:
    """The subtargets tool `name`'s target exposes: its executable, unless
    it runs in its directory."""
    path, in_package = _EXECUTABLES[name]
    return [] if in_package else [path]

def js_tool_target(name: str) -> str:
    """The target of tool `name`'s executable alone, a file."""
    path, in_package = _EXECUTABLES[name]
    if in_package:
        fail("{} runs in its package, //buck2/third_party/js:{}; use js_tool()".format(name, name))
    return "//buck2/third_party/js:{}[{}]".format(name, path)

def js_tool(name: str) -> str:
    """The `$(location …)` of tool `name`'s executable, for a command line."""
    path, in_package = _EXECUTABLES[name]
    if in_package:
        return "$(location //buck2/third_party/js:{})/{}".format(name, path)
    return "$(location {})".format(js_tool_target(name))

def _unpack_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output(ctx.label.name, dir = True)
    ctx.actions.run(
        cmd_args(
            "/bin/sh",
            "-c",
            'mkdir -p "$2" && /usr/bin/tar -xzf "$1" -C "$2" --strip-components 1',
            "--",
            ctx.attrs.tarball,
            out.as_output(),
        ),
        category = "npm_unpack",
    )
    return [DefaultInfo(default_output = out, sub_targets = {
        path: [DefaultInfo(default_output = out.project(path))]
        for path in ctx.attrs.paths
    })]

_unpack = rule(impl = _unpack_impl, attrs = {"paths": attrs.list(attrs.string()), "tarball": attrs.source()})

# `paths` inside the package are exposed as subtargets (`:tsrslint[tsrslint]`).
def npm_package(name: str, package: str, version: str, sha256: str, paths: list[str] = []):
    native.http_file(
        name = name + ".tgz",
        urls = ["https://registry.npmjs.org/{}/-/{}-{}.tgz".format(package, package.split("/")[-1], version)],
        sha256 = sha256,
    )
    _unpack(name = name, tarball = ":{}.tgz".format(name), paths = paths, visibility = ["PUBLIC"])
