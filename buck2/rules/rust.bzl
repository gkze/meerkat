load(":check.bzl", "command", "command_test", "over_files")
load(":toolchains.bzl", "RUST_EDITION", "rustup")

# Checks for first-party Rust crates, as `buck2 test` targets: what
# `cargo clippy -- -D warnings` and `cargo fmt --check` did.
#
#   clippy_test   fails when clippy (or rustc) reports anything for a crate
#   rustfmt_test  fails when rustfmt would change a crate's sources
#   rustfmt_fix   `buck2 run` target that rewrites the repository's (cargo fmt)
#
# meerkat_rust_crate is what every first-party crate is: the crate, its tests,
# clippy and rustfmt checks.
#
# The crate's lint levels are its own `rustc_flags`; third-party crates build
# with `--cap-lints=allow`.

def _clippy_test_impl(ctx: AnalysisContext) -> list[Provider]:
    report = ctx.attrs.crate[DefaultInfo].sub_targets["clippy.txt"][DefaultInfo].default_outputs[0]
    return [
        DefaultInfo(default_output = report),
        ExternalRunnerTestInfo(
            type = "clippy",
            # Clippy's report is empty when there is nothing to report.
            command = ["/bin/sh", "-c", 'if [ -s "$1" ]; then cat "$1"; exit 1; fi', "clippy_test", report],
            contacts = [],
        ),
    ]

clippy_test = rule(
    impl = _clippy_test_impl,
    attrs = {"crate": attrs.dep()},
)

def _rustup(tool: str) -> list[str]:
    return rustup(read_root_config("rust", "release"), tool)

# Every crate formats with the repository's rustfmt.toml.
_RUSTFMT = _rustup("rustfmt") + ["--edition", RUST_EDITION, "--config-path", "$(location //:rustfmt.toml)"]

def rustfmt_test(name: str, srcs: list):
    """`rustfmt --check` over `srcs`."""
    command_test(
        name = name,
        command = _RUSTFMT + ["--check"],
        srcs = srcs,
        pass_srcs = True,
        labels = ["format", "portable"],
    )

def rustfmt_fix(name: str, pathspecs: list[str]):
    """Rewrites the Rust sources git's `pathspecs` match (`over_files`)
    with rustfmt, as `cargo fmt` did."""
    command(
        name = name,
        command = over_files(_RUSTFMT, pathspecs),
    )

def meerkat_rust_crate(
    name: str,
    crate: str,
    library: bool = False,
    cargo_name: str | None = None,
    lints: list[str] = ["-Wclippy::pedantic"],
    env: dict[str, str] = {},
    rustc_flags: list[str] = [],
    extra_srcs: list[str] = [],
    format_srcs: list[str] = [],
    clippy_configuration: str | None = None,
    deps: list[str] = [],
    visibility: list[str] = [],
):
    """The crate (`src/lib.rs` for a `library`, else `src/main.rs`) as `name`,
    and `:test`, `:clippy` and `:rustfmt`. `cargo_name` sets what Cargo would
    for a crate reading its CARGO_* variables (`cargo_env`). `extra_srcs` are
    compiled in, `format_srcs` only formatted."""
    package_env, manifest_dir = cargo_env(cargo_name, "0.1.0", native.package_name()) if cargo_name else ({}, [])
    srcs = glob(["src/**/*.rs"])
    compile = dict(
        srcs = srcs + extra_srcs,
        crate = crate,
        crate_root = "src/lib.rs" if library else "src/main.rs",
        env = package_env | env,
        rustc_flags = rustc_flags + manifest_dir + lints,
        deps = deps,
    )
    if clippy_configuration:
        compile["clippy_configuration"] = clippy_configuration
    (native.rust_library if library else native.rust_binary)(name = name, visibility = visibility, **compile)
    native.rust_test(name = "test", **compile)
    clippy_test(name = "clippy", crate = ":test")
    rustfmt_test(name = "rustfmt", srcs = srcs + format_srcs)

def cargo_env(name: str, version: str, manifest_dir: str) -> (dict[str, str], list[str]):
    """What Cargo sets for a first-party crate: its name and version, and
    CARGO_MANIFEST_DIR as the crate directory's absolute path (Cargo's
    value), for code that reaches checked-in files through it. Returns the
    `env` and the `rustc_flags` that set CARGO_MANIFEST_DIR."""
    major, minor, patch = version.split(".")
    return {
        "CARGO_CRATE_NAME": name.replace("-", "_"),
        "CARGO_PKG_NAME": name,
        "CARGO_PKG_VERSION": version,
        "CARGO_PKG_VERSION_MAJOR": major,
        "CARGO_PKG_VERSION_MINOR": minor,
        "CARGO_PKG_VERSION_PATCH": patch,
        "CARGO_PKG_VERSION_PRE": "",
    }, ["--env-set=CARGO_MANIFEST_DIR=\\$(abspath {})".format(manifest_dir)]
