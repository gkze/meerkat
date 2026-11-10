# The Rust and C toolchains (buck2/toolchains), with what Buck cannot hash
# in their command lines, and the environment every Xcode tool runs in.
#
# Both come from the host: rustup's Rust and Xcode's clang, outside Buck's
# view. Buck keys an action on its command line, environment and inputs, so
# a host tool's version reaches the key only if the command line names it.
# Each tool here therefore runs as `/usr/bin/env NAME=<version> <tool>`:
# the variable both selects the version and makes it part of every action
# that runs the tool, including the scripts the prelude writes around them
# (the RUSTC, CC, CXX, LD and AR shims of Rust build scripts, the rustc
# linker wrapper, clippy's sysroot query). Changing the version in
# .buckconfig rebuilds what that tool built; //buck2/rules:rust_test and
# //buck2/rules/swift:xcode_test fail until the installed tools agree.

load("@prelude//cxx:cxx_toolchain_types.bzl", "LinkerType")
load("@prelude//rust:rust_toolchain.bzl", "PanicRuntime", "RustToolchainInfo")
load("@prelude//toolchains:cxx.bzl", "CxxToolsInfo")

def env_command(env: dict[str, str], command: list) -> list:
    """`command` run through `/usr/bin/env` with `env`, for what has no
    environment of its own (a toolchain's tool, a RunInfo)."""
    return ["/usr/bin/env"] + ["{}={}".format(name, value) for name, value in env.items()] + command

# The edition of every first-party crate (the toolchain's default) and of
# rustfmt over them.
RUST_EDITION = "2024"

def rustup_env(release: str) -> dict[str, str]:
    """The environment that runs rustup's `release`. Without
    RUSTUP_AUTO_INSTALL=0, rustup downloads a release it lacks from inside
    whichever actions first run it, all at once."""
    return {"RUSTUP_TOOLCHAIN": release, "RUSTUP_AUTO_INSTALL": "0"}

def rustup(release: str, tool: str) -> list[str]:
    """`tool` (rustc, rustfmt, cargo, ...) from rustup's `release`."""
    return env_command(rustup_env(release), [tool])

def xcode_env(developer_dir: str, xcode_build: str) -> dict[str, str]:
    """The environment every Xcode tool runs in. The xcrun shims in /usr/bin
    take the Xcode from DEVELOPER_DIR, else from `xcode-select`;
    `developer_dir` is the one. MEERKAT_XCODE_BUILD is that Xcode's build,
    which puts it in the key of every action that runs one of its tools."""
    return {"DEVELOPER_DIR": developer_dir, "MEERKAT_XCODE_BUILD": xcode_build}

def _rustup_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    def tool(name):
        return RunInfo(args = rustup(ctx.attrs.release, name))

    return [
        DefaultInfo(),
        RustToolchainInfo(
            # One word: the prelude only writes this into its clippy wrapper
            # script, formatting each word as a command line of its own.
            clippy_driver = RunInfo(args = cmd_args(rustup(ctx.attrs.release, "clippy-driver"), delimiter = " ")),
            compiler = tool("rustc"),
            default_edition = ctx.attrs.default_edition,
            nightly_features = ctx.attrs.nightly_features,
            panic_runtime = PanicRuntime("unwind"),
            rustc_flags = ctx.attrs.rustc_flags,
            rustc_target_triple = "aarch64-apple-darwin",
            rustdoc = tool("rustdoc"),
        ),
    ]

# The prelude's `system_rust_toolchain` (rustc, rustdoc and clippy-driver
# from PATH, for macOS on Apple silicon), with the tools from rustup's
# `release` (`[rust] release`). Doctests stay off: rustdoc's
# `--test-builder` takes one path, not a command.
rustup_toolchain = rule(
    impl = _rustup_toolchain_impl,
    attrs = {
        "default_edition": attrs.option(attrs.string(), default = None),
        "nightly_features": attrs.bool(default = True),
        "release": attrs.string(),
        "rustc_flags": attrs.list(attrs.arg(), default = []),
    },
    is_toolchain_rule = True,
)

def _xcode_clang_tools_impl(ctx: AnalysisContext) -> list[Provider]:
    env = xcode_env(ctx.attrs.developer_dir, ctx.attrs.xcode_build)

    def tool(path):
        return cmd_args(env_command(env, [path]))

    return [
        DefaultInfo(),
        CxxToolsInfo(
            compiler = tool("/usr/bin/clang"),
            compiler_type = "clang",
            cxx_compiler = tool("/usr/bin/clang++"),
            asm_compiler = tool("/usr/bin/clang"),
            asm_compiler_type = "clang",
            archiver = tool("/usr/bin/ar"),
            archiver_type = "gnu",
            linker = tool("/usr/bin/clang++"),
            linker_type = LinkerType("darwin"),
        ),
    ]

# The prelude's `path_clang_tools` for `cxx_tools_info_toolchain`: clang,
# clang++ and ar from `developer_dir`'s Xcode. Absolute paths: the prelude's
# compiler shims for Rust build scripts exec them without a PATH search.
xcode_clang_tools = rule(
    impl = _xcode_clang_tools_impl,
    attrs = {
        "developer_dir": attrs.string(),
        "xcode_build": attrs.string(),
    },
)
