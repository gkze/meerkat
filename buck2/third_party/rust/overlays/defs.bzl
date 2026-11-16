# The files of Deno's crates that this package patches, by crate: each
# <crate>/<file>.patch applies to the file at the crate's root, in the release
# Cargo.lock resolves (docs/design/remote-execution.md, "Remote execution, as
# built", says why). Reindeer's BUCK reads this too (buck2/rules/cargo.bzl),
# to let this package read those crates' archives.
PATCHED = {
    "deno_core": ["extension_set.rs", "extensions.rs"],
    "deno_runtime": ["shared.rs", "snapshot.rs"],
}
