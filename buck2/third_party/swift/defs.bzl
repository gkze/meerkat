# Third-party Swift packages, built from source the way SwiftPM builds them
# as dependencies of this package. buck2/third_party/swift/BUCK holds the data:
# each package's pinned archive, and modules.bzl each target's manifest settings.
#
#   spm_packages  one archive per package, with each module's directory as a
#                 subtarget (`:grdb.swift[GRDB]`)
#   spm_modules   one target per module: a Swift library (with its
#                 resource bundle, if it has resources), a macro plugin
#                 (built for the host), a system library's module map, a C
#                 or Objective-C target with its module map, or a binary
#                 framework
#
# Warnings are suppressed, as SwiftPM does for remote packages, and each
# package's traits are compilation conditions of its targets.

load(
    "//buck2/rules/swift:defs.bzl",
    "clang_module",
    "prebuilt_framework",
    "swift_library",
    "swift_macro",
    "swift_resource_bundle",
)

def _include(module: dict) -> str:
    """A C target's public headers directory, relative to its package."""
    include = module.get("include", "include")
    return module["path"] if include == "." else module["path"] + "/" + include

def _subpaths(module: dict) -> list[str]:
    path = module["path"]
    if module["kind"] == "c":
        own = [_include(module)] + [path + "/" + src for src in module["srcs"]]
        own += [_include(module) + "/" + header for header in module.get("headers", [])]
        return own + [path + "/" + search for search in module.get("header_search_paths", [])]
    return [path] + [path + "/" + resource["path"] for resource in module.get("resources", [])]

def spm_packages(packages: dict, modules: dict):
    """The packages' archives at their pinned revisions."""
    for name, package in packages.items():
        native.http_archive(
            name = name,
            urls = ["https://github.com/{}/archive/{}.tar.gz".format(package["github"], package["revision"])],
            sha256 = package["sha256"],
            strip_prefix = "{}-{}".format(package.get("directory", package["github"].split("/")[1]), package["revision"]),
            sub_targets = sorted([path for module in modules.values() if module["package"] == name for path in _subpaths(module)]),
        )

def _c_source(name: str, module: dict, src: str):
    """A C target's source for `cxx_library`. The C++ toolchain has no
    Objective-C compiler, so an `.m` file is compiled by clang as `.c`
    with `-x objective-c`, and with ARC, as SwiftPM compiles it."""
    if not src.endswith(".m"):
        return _subtarget(module, src)
    copy = "{}-{}".format(name, src.replace("/", "_"))
    native.genrule(
        name = copy,
        srcs = [_subtarget(module, src)],
        out = src.split("/")[-1] + ".c",
        cmd = "cp $SRCS $OUT",
    )
    return (":" + copy, ["-x", "objective-c", "-fobjc-arc"])

def _subtarget(module: dict, path: str = "") -> str:
    """A file or directory of the module's package archive."""
    return ":{}[{}]".format(module["package"], module["path"] + ("/" + path if path else ""))

def spm_modules(modules: dict, traits: dict, minimum_macos: dict):
    for name, module in modules.items():
        package = module["package"]
        directory = _subtarget(module)
        kind = module["kind"]
        if kind == "system":
            clang_module(name = name, include_dir = directory, visibility = ["PUBLIC"])
        elif kind == "c":
            include = ":{}[{}]".format(package, _include(module))
            flags = ["-I$(location {})".format(include)]
            flags += ["-I$(location {})".format(_subtarget(module, search)) for search in module.get("header_search_paths", [])]
            flags += ["-D" + define for define in module.get("c_defines", [])]
            native.cxx_library(
                name = name + "-c",
                srcs = [_c_source(name, module, src) for src in module["srcs"]],
                preprocessor_flags = flags,
            )
            if "headers" in module:
                # No module map of the package's own: one over its headers,
                # as SwiftPM generates.
                clang_module(
                    name = name,
                    headers = [":{}[{}/{}]".format(package, _include(module), header) for header in module["headers"]],
                    deps = [":" + name + "-c"],
                    visibility = ["PUBLIC"],
                )
            else:
                clang_module(name = name, include_dir = include, deps = [":" + name + "-c"], visibility = ["PUBLIC"])
        elif kind == "binary":
            prebuilt_framework(
                name = name,
                archive = directory,
                framework = module["framework"],
                library = module["library"],
                visibility = ["PUBLIC"],
            )
        else:
            resources = module.get("resources", [])
            extra = {}
            if resources:
                swift_resource_bundle(
                    name = name + "-resources",
                    bundle_name = "{}_{}".format(package, name),
                    copy = [_subtarget(module, resource["path"]) for resource in resources if resource["rule"] == "copy"],
                    process = [_subtarget(module, resource["path"]) for resource in resources if resource["rule"] == "process"],
                    minimum_os = minimum_macos[package],
                )
                extra["resource_bundle"] = ":" + name + "-resources"
            if module.get("linked_libraries"):
                extra["linker_flags"] = ["-l" + library for library in module["linked_libraries"]]
            rule = swift_macro if kind == "macro" else swift_library
            rule(
                name = name,
                package = package,
                srcs_dir = directory,
                deps = [":" + dep for dep in module.get("deps", [])],
                macros = [":" + macro for macro in module.get("macros", [])],
                defines = module.get("defines", []) + traits.get(package, []),
                upcoming_features = module.get("upcoming_features", []),
                experimental_features = module.get("experimental_features", []),
                swift_flags = module.get("swift_flags", []),
                exclude = module.get("exclude", []),
                language_mode = module.get("language_mode", "6"),
                minimum_os = minimum_macos[package],
                warnings = "suppress",
                visibility = ["PUBLIC"],
                **extra
            )
