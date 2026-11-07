# First-party Swift: what Package.swift applies to every target
# (//:package_swift_test compares them). Warnings are errors, and the upcoming
# features that only add compile-time checks are on; features that change
# runtime behaviour or need source-wide annotation are left for a deliberate
# migration (see Package.swift).

load("//buck2/rules:check.bzl", "swift_format_test", "swiftlint_test")
load("//buck2/rules/swift:defs.bzl", "swift_binary", "swift_library", "swift_test")

_SETTINGS = {
    "package": "meerkat",
    "upcoming_features": ["ExistentialAny", "MemberImportVisibility", "ImmutableWeakCaptures"],
    "warnings": "error",
}

# Each target's sources default to the package's Swift files, and each gets
# a `<name>-format` test (swift-format) and a `<name>-lint` test (SwiftLint),
# so a module's checks run with it. Test modules lint with Tests/.swiftlint.yml,
# which allows what a failing test may do: trap.

def _srcs(srcs):
    return glob(["**/*.swift"]) if srcs == None else srcs

def _checks(name: str, srcs: list, lint_config: str = ".swiftlint.yml"):
    if srcs:
        swift_format_test(name = name + "-format", srcs = srcs)
        swiftlint_test(name = name + "-lint", srcs = srcs, config = lint_config)

def meerkat_swift_library(name: str, srcs = None, generated = False, **kwargs):
    """`generated` sources (checked in, written by a generator) are not
    formatted or linted."""
    swift_library(name = name, srcs = _srcs(srcs), visibility = ["PUBLIC"], **(_SETTINGS | kwargs))
    if not generated:
        _checks(name, _srcs(srcs))

def meerkat_swift_binary(name: str, srcs = None, **kwargs):
    swift_binary(name = name, srcs = _srcs(srcs), visibility = ["PUBLIC"], **(_SETTINGS | kwargs))
    _checks(name, _srcs(srcs))

def meerkat_swift_executable(name: str, **kwargs):
    """An executable tests can import, built as SwiftPM builds an executable
    target that tests depend on: `:module`, with its entry point renamed so a
    test runner can link it, and `name`, which aliases that back to `main`."""
    entry_point = name + "_main"
    meerkat_swift_library(name = "module", module_name = name, entry_point = entry_point, **kwargs)
    meerkat_swift_binary(
        name = name,
        srcs = [],
        linker_flags = ["-Xlinker", "-alias", "-Xlinker", "_" + entry_point, "-Xlinker", "_main"],
        deps = [":module"],
    )

def meerkat_swift_test(name: str, srcs = None, **kwargs):
    swift_test(name = name, srcs = _srcs(srcs), visibility = ["PUBLIC"], **(_SETTINGS | kwargs))
    _checks(name, _srcs(srcs), lint_config = "Tests/.swiftlint.yml")
