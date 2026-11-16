load("//buck2/third_party/rust/overlays:defs.bzl", "PATCHED")

def http_archive(name: str, **kwargs):
    """The builtin `http_archive`, which Reindeer generates each crate's
    download with (reindeer.toml, `buckfile_imports`). The archive of a crate
    buck2/third_party/rust/overlays patches is visible to that package, under
    a name without its version (`<crate>.crate`), so the patches apply to the
    release Cargo.lock resolves and nothing there repeats it."""
    crate = name.removesuffix(".crate").rpartition("-")[0]
    if name.endswith(".crate") and crate in PATCHED:
        overlays = ["//buck2/third_party/rust/overlays:"]
        native.http_archive(name = name, **(kwargs | {"visibility": overlays}))
        native.alias(name = crate + ".crate", actual = ":" + name, visibility = overlays)
        return
    native.http_archive(name = name, **kwargs)
