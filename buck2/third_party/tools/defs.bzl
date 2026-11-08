# The linters and formatters the repository's checks run (//:BUCK and
# buck2/rules/meerkat.bzl), as upstream release executables, pinned by version
# and SHA-256. Development tools only: nothing here ships in Meerkat.app, so
# none needs a notice (//Tools/Notices).
#
# TOOLS is the one table: buck2/third_party/tools/BUCK declares each download
# from it (`tools()`), and a check names an executable with `tool()`. An
# archive's executable is a subtarget (`:shellcheck[shellcheck]`), at
# `strip_prefix` inside it; a `bare` executable is the target itself.
#
# Each tool has one `version` and an asset per host it runs on: `macos-arm64`,
# where everything builds, and `linux-arm64`, for the checks CI also runs on
# Linux (the `portable` label, .github/workflows/ci.yml). `{version}` in an
# asset's `url` and `strip_prefix` is the tool's version, so the hosts cannot
# run different releases. A tool with no `linux-arm64` asset fails to
# configure on Linux, which only a check outside `portable` names.
TOOLS = {
    # Shell formatting.
    "shfmt": dict(
        version = "3.14.1",
        bare = True,
        assets = {
            "macos-arm64": dict(
                url = "https://github.com/mvdan/sh/releases/download/v{version}/shfmt_v{version}_darwin_arm64",
                sha256 = "b7c872db63553ccffc7253aba3ed7d4885a27d83f1ba567b1138c6315a5847e5",
            ),
            "linux-arm64": dict(
                url = "https://github.com/mvdan/sh/releases/download/v{version}/shfmt_v{version}_linux_arm64",
                sha256 = "5f2db09dae91fca848f7adbdd014632e921a383863a2ad7e0450ad3aba0c6489",
            ),
        },
    ),
    # Shell scripts, and (through actionlint) the workflow's `run:` steps.
    "shellcheck": dict(
        version = "0.11.0",
        assets = {
            "macos-arm64": dict(
                url = "https://github.com/koalaman/shellcheck/releases/download/v{version}/shellcheck-v{version}.darwin.aarch64.tar.gz",
                sha256 = "339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f",
                strip_prefix = "shellcheck-v{version}",
            ),
            "linux-arm64": dict(
                url = "https://github.com/koalaman/shellcheck/releases/download/v{version}/shellcheck-v{version}.linux.aarch64.tar.gz",
                sha256 = "68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc",
                strip_prefix = "shellcheck-v{version}",
            ),
        },
    ),
    # GitHub Actions workflows: expressions, contexts, job graph.
    "actionlint": dict(
        version = "1.7.12",
        assets = {
            "macos-arm64": dict(
                url = "https://github.com/rhysd/actionlint/releases/download/v{version}/actionlint_{version}_darwin_arm64.tar.gz",
                sha256 = "aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f",
            ),
            "linux-arm64": dict(
                url = "https://github.com/rhysd/actionlint/releases/download/v{version}/actionlint_{version}_linux_arm64.tar.gz",
                sha256 = "325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6",
            ),
        },
    ),
    # GitHub Actions security: injection, credentials, permissions, pins.
    "zizmor": dict(
        version = "1.32.0",
        assets = {
            "macos-arm64": dict(
                url = "https://github.com/zizmorcore/zizmor/releases/download/v{version}/zizmor-aarch64-apple-darwin.tar.gz",
                sha256 = "6efed18c4539a663fd3c851a2be9533fd8456c4e646d9416206da059154a0d3c",
            ),
            "linux-arm64": dict(
                url = "https://github.com/zizmorcore/zizmor/releases/download/v{version}/zizmor-aarch64-unknown-linux-gnu.tar.gz",
                sha256 = "cb152b207f815116d7fa1c1ee4614f61578803351395052908095e79adfd9fd0",
            ),
        },
    ),
    # Every `uses:` of the workflow and the actions pinned to a full commit
    # SHA with the version it is as a comment (//:pinact), and that comment
    # checked against the SHA (//:pinact-verify).
    "pinact": dict(
        version = "5.0.2",
        assets = {
            "macos-arm64": dict(
                url = "https://github.com/suzuki-shunsuke/pinact/releases/download/v{version}/pinact_darwin_arm64.tar.gz",
                sha256 = "9b9545d53376654005daaee5ab736d579887205ca3df99925c8fe8358c6e7fdb",
            ),
            "linux-arm64": dict(
                url = "https://github.com/suzuki-shunsuke/pinact/releases/download/v{version}/pinact_linux_arm64.tar.gz",
                sha256 = "326e27f5b3b5fca21e6a169b2785ba2023df3dd9ee82dd0f4e438cb1220b68d7",
            ),
        },
    ),
    # Secrets in the history (//:gitleaks) and in the staged changes
    # (//:gitleaks-staged, which the pre-commit hook runs).
    "gitleaks": dict(
        version = "8.30.1",
        assets = {
            "macos-arm64": dict(
                url = "https://github.com/gitleaks/gitleaks/releases/download/v{version}/gitleaks_{version}_darwin_arm64.tar.gz",
                sha256 = "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
            ),
            "linux-arm64": dict(
                url = "https://github.com/gitleaks/gitleaks/releases/download/v{version}/gitleaks_{version}_linux_arm64.tar.gz",
                sha256 = "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080",
            ),
        },
    ),
    # The Git hooks (prek.toml): when each check runs, not what it runs.
    "prek": dict(
        version = "0.5.10",
        assets = {
            "macos-arm64": dict(
                url = "https://github.com/j178/prek/releases/download/v{version}/prek-aarch64-apple-darwin.tar.gz",
                sha256 = "28186099374a3158e7b27e82fedb0bd20723658dc8ee24a841bdffe8a91b1ad9",
                strip_prefix = "prek-aarch64-apple-darwin",
            ),
            "linux-arm64": dict(
                url = "https://github.com/j178/prek/releases/download/v{version}/prek-aarch64-unknown-linux-gnu.tar.gz",
                sha256 = "6ee3e5696f0b76bb4c95708579a54714aabd9a20e89c998f69a1a5cc41dbbbee",
                strip_prefix = "prek-aarch64-unknown-linux-gnu",
            ),
        },
    ),
    # TOML formatting and linting.
    "tombi": dict(
        version = "1.10.0",
        assets = {
            "macos-arm64": dict(
                url = "https://github.com/tombi-toml/tombi/releases/download/v{version}/tombi-cli-{version}-aarch64-apple-darwin.tar.gz",
                sha256 = "b00ca00f24125c1fbb61c8a7940ebd56f78e390878f11cd43235e38d07426832",
                strip_prefix = "tombi-cli-{version}-aarch64-apple-darwin",
            ),
            "linux-arm64": dict(
                url = "https://github.com/tombi-toml/tombi/releases/download/v{version}/tombi-cli-{version}-aarch64-unknown-linux-musl.tar.gz",
                sha256 = "90950a01c67c061a0bc1d8180ef93bf9e741ba8d22a575c3efa0b943d4676516",
                strip_prefix = "tombi-cli-{version}-aarch64-unknown-linux-musl",
            ),
        },
    ),
    # Markdown linting and formatting.
    "rumdl": dict(
        version = "0.3.2",
        assets = {
            "macos-arm64": dict(
                url = "https://github.com/rvben/rumdl/releases/download/v{version}/rumdl-v{version}-aarch64-apple-darwin.tar.gz",
                sha256 = "a1eefb1cd2e0cafa42f0ca98d3f8713d7e73f9eba77fc8ef0ed6836875197935",
            ),
            "linux-arm64": dict(
                url = "https://github.com/rvben/rumdl/releases/download/v{version}/rumdl-v{version}-aarch64-unknown-linux-gnu.tar.gz",
                sha256 = "bdfca7a602f893fbe5d73d5e38f73b31f45a21d3bcf385b6ea819997d0449ec3",
            ),
        },
    ),
    # Links between the repository's own files and headings (offline).
    "lychee": dict(
        version = "0.24.2",
        assets = {
            "macos-arm64": dict(
                url = "https://github.com/lycheeverse/lychee/releases/download/lychee-v{version}/lychee-aarch64-apple-darwin.tar.gz",
                sha256 = "c9d3740ea2d891854d37116c9fba840f37b6e7c89d330e7db84ac333631c4977",
                strip_prefix = "lychee-aarch64-apple-darwin",
            ),
            "linux-arm64": dict(
                url = "https://github.com/lycheeverse/lychee/releases/download/lychee-v{version}/lychee-aarch64-unknown-linux-gnu.tar.gz",
                sha256 = "91a7bd65685da41b90ccb9bc867a3d649a7818042dae04ff405e55a25bddee4c",
                strip_prefix = "lychee-aarch64-unknown-linux-gnu",
            ),
        },
    ),
    # Swift rules beyond swift-format's: force casts and unwraps, and
    # other likely bugs (.swiftlint.yml). macOS only: it finds SourceKit
    # through Xcode.
    "swiftlint": dict(
        version = "0.65.1",
        assets = {
            "macos-arm64": dict(
                url = "https://github.com/realm/SwiftLint/releases/download/{version}/portable_swiftlint.zip",
                sha256 = "c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0",
            ),
        },
    ),
    # The Rust dependencies' advisories, licenses and sources
    # (buck2/third_party/rust/check/deny.toml).
    "cargo-deny": dict(
        version = "0.20.2",
        assets = {
            "macos-arm64": dict(
                url = "https://github.com/EmbarkStudios/cargo-deny/releases/download/{version}/cargo-deny-{version}-aarch64-apple-darwin.tar.gz",
                sha256 = "fe67d82a10d8597a3549364cb733a3f9cc1bfff9031b7ae46384a9f2a72090c3",
                strip_prefix = "cargo-deny-{version}-aarch64-apple-darwin",
            ),
            "linux-arm64": dict(
                url = "https://github.com/EmbarkStudios/cargo-deny/releases/download/{version}/cargo-deny-{version}-aarch64-unknown-linux-musl.tar.gz",
                sha256 = "995c82be0defc7a025cae49a2aa2644ce8245c9a3318fc4103907c6a285e8c7d",
                strip_prefix = "cargo-deny-{version}-aarch64-unknown-linux-musl",
            ),
        },
    ),
}

# The hosts an asset can be for, as //buck2/platforms config settings.
_HOSTS = {
    "macos-arm64": "//buck2/platforms:macos-arm64",
    "linux-arm64": "//buck2/platforms:linux-arm64",
}

def _by_host(pin: dict, field: str):
    """A select() of the asset `field` (with `{version}` filled in) by host,
    or None when no asset has it."""
    values = {}
    for host, asset in pin["assets"].items():
        value = asset.get(field)
        if value != None:
            values[_HOSTS[host]] = value.format(version = pin["version"])
    if not values:
        return None
    if len(values) != len(pin["assets"]):
        fail("a tool's assets must all have `{}` or none have it".format(field))
    return select(values)

def tools():
    """Declares every tool in TOOLS, for buck2/third_party/tools/BUCK."""
    for name, pin in TOOLS.items():
        urls = select({_HOSTS[host]: [asset["url"].format(version = pin["version"])] for host, asset in pin["assets"].items()})
        sha256 = _by_host(pin, "sha256")
        if pin.get("bare", False):
            native.http_file(
                name = name,
                urls = urls,
                sha256 = sha256,
                executable = True,
                visibility = ["PUBLIC"],
            )
        else:
            native.http_archive(
                name = name,
                urls = urls,
                sha256 = sha256,
                strip_prefix = _by_host(pin, "strip_prefix"),
                sub_targets = [name],
                visibility = ["PUBLIC"],
            )

def tool(name: str) -> str:
    """The `$(location …)` of tool `name`'s executable, for a command line."""
    if TOOLS[name].get("bare", False):
        return "$(location //buck2/third_party/tools:{})".format(name)
    return "$(location //buck2/third_party/tools:{0}[{0}])".format(name)
