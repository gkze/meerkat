load("@prelude//rust:cargo_buildscript.bzl", _buildscript_run = "buildscript_run")
load("//buck2/platforms:defs.bzl", "LOCAL_EXECUTION")

# Build scripts that run on the Mac running Buck even with remote execution
# on. Remote execution runs each action in a directory of its own, so an
# absolute path one action records is not there for the next; these record or
# read such paths, and neither declares what it reads.
LOCAL_BUILD_SCRIPTS = {
    # Records the absolute paths of the ISLE files it generates in Rust
    # (`generated_files()`), which cranelift-codegen-meta compiles in.
    "cranelift-assembler-x64": True,
    # Reads those files, by those paths, through cranelift-codegen-meta.
    "cranelift-codegen": True,
}

def buildscript_run(name: str, package_name: str, **kwargs):
    """The prelude's `buildscript_run`, run on this Mac for the build scripts
    LOCAL_BUILD_SCRIPTS names. Reindeer generates every build script's target
    with this (reindeer.toml, `buckfile_imports`)."""
    if package_name in LOCAL_BUILD_SCRIPTS:
        kwargs["exec_compatible_with"] = kwargs.get("exec_compatible_with", []) + LOCAL_EXECUTION
    _buildscript_run(name = name, package_name = package_name, **kwargs)
