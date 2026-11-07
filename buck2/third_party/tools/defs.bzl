# The linters and formatters the repository's checks run (//:BUCK and
# buck2/rules/meerkat.bzl), as upstream release executables for macOS on
# Apple silicon, pinned by version and SHA-256. Development tools only:
# nothing here ships in Meerkat.app, so none needs a notice (//Tools/Notices).
#
# TOOLS is the one table: buck2/third_party/tools/BUCK declares each download
# from it (`tools()`), and a check names an executable with `tool()`. An
# archive's executable is a subtarget (`:shellcheck[shellcheck]`), at
# `strip_prefix` inside it; a `bare` executable is the target itself.
TOOLS = {
    # Shell formatting.
    "shfmt": dict(
        url = "https://github.com/mvdan/sh/releases/download/v3.14.1/shfmt_v3.14.1_darwin_arm64",
        sha256 = "b7c872db63553ccffc7253aba3ed7d4885a27d83f1ba567b1138c6315a5847e5",
        bare = True,
    ),
    # Shell scripts, and (through actionlint) the workflow's `run:` steps.
    "shellcheck": dict(
        url = "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.gz",
        sha256 = "339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f",
        strip_prefix = "shellcheck-v0.11.0",
    ),
    # GitHub Actions workflows: expressions, contexts, job graph.
    "actionlint": dict(
        url = "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz",
        sha256 = "aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f",
    ),
    # GitHub Actions security: injection, credentials, permissions, pins.
    "zizmor": dict(
        url = "https://github.com/zizmorcore/zizmor/releases/download/v1.32.0/zizmor-aarch64-apple-darwin.tar.gz",
        sha256 = "6efed18c4539a663fd3c851a2be9533fd8456c4e646d9416206da059154a0d3c",
    ),
    # TOML formatting and linting.
    "tombi": dict(
        url = "https://github.com/tombi-toml/tombi/releases/download/v1.10.0/tombi-cli-1.10.0-aarch64-apple-darwin.tar.gz",
        sha256 = "b00ca00f24125c1fbb61c8a7940ebd56f78e390878f11cd43235e38d07426832",
        strip_prefix = "tombi-cli-1.10.0-aarch64-apple-darwin",
    ),
    # Markdown linting and formatting.
    "rumdl": dict(
        url = "https://github.com/rvben/rumdl/releases/download/v0.3.2/rumdl-v0.3.2-aarch64-apple-darwin.tar.gz",
        sha256 = "a1eefb1cd2e0cafa42f0ca98d3f8713d7e73f9eba77fc8ef0ed6836875197935",
    ),
    # Links between the repository's own files and headings (offline).
    "lychee": dict(
        url = "https://github.com/lycheeverse/lychee/releases/download/lychee-v0.24.2/lychee-aarch64-apple-darwin.tar.gz",
        sha256 = "c9d3740ea2d891854d37116c9fba840f37b6e7c89d330e7db84ac333631c4977",
        strip_prefix = "lychee-aarch64-apple-darwin",
    ),
    # Swift rules beyond swift-format's: force casts and unwraps, and
    # other likely bugs (.swiftlint.yml).
    "swiftlint": dict(
        url = "https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip",
        sha256 = "c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0",
    ),
    # The Rust dependencies' advisories, licenses and sources
    # (buck2/third_party/rust/check/deny.toml).
    "cargo-deny": dict(
        url = "https://github.com/EmbarkStudios/cargo-deny/releases/download/0.20.2/cargo-deny-0.20.2-aarch64-apple-darwin.tar.gz",
        sha256 = "fe67d82a10d8597a3549364cb733a3f9cc1bfff9031b7ae46384a9f2a72090c3",
        strip_prefix = "cargo-deny-0.20.2-aarch64-apple-darwin",
    ),
}

def tools():
    """Declares every tool in TOOLS, for buck2/third_party/tools/BUCK."""
    for name, pin in TOOLS.items():
        if pin.get("bare", False):
            native.http_file(
                name = name,
                urls = [pin["url"]],
                sha256 = pin["sha256"],
                executable = True,
                visibility = ["PUBLIC"],
            )
        else:
            native.http_archive(
                name = name,
                urls = [pin["url"]],
                sha256 = pin["sha256"],
                strip_prefix = pin.get("strip_prefix"),
                sub_targets = [name],
                visibility = ["PUBLIC"],
            )

def tool(name: str) -> str:
    """The `$(location …)` of tool `name`'s executable, for a command line."""
    if TOOLS[name].get("bare", False):
        return "$(location //buck2/third_party/tools:{})".format(name)
    return "$(location //buck2/third_party/tools:{0}[{0}])".format(name)
