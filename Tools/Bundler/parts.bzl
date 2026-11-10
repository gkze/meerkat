# What Meerkat.app is assembled from: each part, by the `bundle_command`
# attribute that takes it (buck2/rules/bundle.bzl), and the target the full
# bundle takes it from (//Tools/Bundler). //Tools/Notices lists the
# third-party code these reach, so a part added here is covered by
# THIRD_PARTY_NOTICES.
PARTS = {
    "app": "//Sources/MeerkatApp:MeerkatApp",
    "cli": "//Sources/meerkat:meerkat",
    "daemon": "//Sources/meerkatd:meerkatd",
    "lint_toolchain": "//Tools/Bundler:lint-toolchain",
    "runtime_types": "//Sources/meerkat-rules:deno.d.ts",
    "typescript": "//buck2/third_party/js:tsrs",
}
