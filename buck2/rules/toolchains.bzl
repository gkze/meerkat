# The Rust and C toolchains (buck2/toolchains), with what Buck cannot hash
# in their command lines.
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

def rustup(release: str, tool: str) -> list[str]:
    """`tool` (rustc, rustfmt, cargo, ...) from rustup's `release`. Without
    RUSTUP_AUTO_INSTALL=0, rustup downloads a release it lacks from inside
    whichever actions first run it, all at once."""
    return ["/usr/bin/env", "RUSTUP_TOOLCHAIN=" + release, "RUSTUP_AUTO_INSTALL=0", tool]

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
    def tool(path):
        # The xcrun shims in /usr/bin pick the developer directory from
        # DEVELOPER_DIR, else from `xcode-select`; Swift's `[swift]
        # developer_dir` is the one. MEERKAT_XCODE_BUILD is its build, as
        # in Swift actions, for the key.
        return cmd_args(
            "/usr/bin/env",
            "DEVELOPER_DIR=" + ctx.attrs.developer_dir,
            "MEERKAT_XCODE_BUILD=" + ctx.attrs.xcode_build,
            path,
        )

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
