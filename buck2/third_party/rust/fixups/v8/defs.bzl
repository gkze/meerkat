# The `v8` crate's version, as Cargo.lock locks it: ./BUCK downloads that
# release's prebuilt library, and //Tools/Notices lists V8 for it. Notices
# fails while the shipped `v8` crate is another version (PREBUILT's
# `tracks`), so a crate bump that leaves this behind cannot link the previous
# release's library unnoticed.
V8_VERSION = "150.4.0"
