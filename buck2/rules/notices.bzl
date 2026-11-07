# THIRD_PARTY_NOTICES as a build output (Tools/Notices). The rule sorts what
# `shipped` found by where it was fetched from and hands the tool each
# download's path; the tool reads names, versions and licenses from them.

def _notices_impl(ctx: AnalysisContext) -> list[Provider]:
    crates = []
    swift = {}
    unaccounted = dict(ctx.attrs.npm)
    for dep in ctx.attrs.shipped:
        package = dep.label.package
        name = dep.label.name
        output = dep[DefaultInfo].default_outputs[0]
        if package == "buck2/third_party/rust" and name.endswith(".crate"):
            crates.append(output)
        elif package == "buck2/third_party/swift":
            swift[name] = output
        elif package == "buck2/third_party/js" and name.endswith(".tgz"):
            pass # The unpacked package is `name` without the suffix.
        elif package == "buck2/third_party/js" and name in unaccounted:
            unaccounted.pop(name)
        elif "{}:{}".format(package, name) not in ctx.attrs.covered:
            fail("{} ships but nothing says what its license is (Tools/Notices/BUCK)".format(dep.label))
    if unaccounted:
        fail("`npm` names what no longer ships: {}".format(sorted(unaccounted.keys())))
    manifest = ctx.actions.write_json(
        "notices.json",
        {
            "bundled": {key: archive[DefaultInfo].default_outputs[0] for key, archive in ctx.attrs.bundled.items()},
            "crates": crates,
            "exceptions": ctx.attrs.exceptions,
            "grammars": [
                {"repository": grammar["repository"], "revision": grammar["revision"], "texts": texts}
                for grammar, texts in ctx.attrs.grammars
            ],
            "lockfiles": [
                {"path": path, "programs": programs, "tracks": tracks}
                for programs, tracks, path in ctx.attrs.lockfiles
            ],
            "npm": [
                {"note": note, "package": target[DefaultInfo].default_outputs[0]}
                for target, note in ctx.attrs.npm.values()
            ],
            "policy": ctx.attrs.policy,
            "prebuilt": [dict(component, texts = texts) for component, texts in ctx.attrs.prebuilt],
            "resolved": ctx.attrs.resolved,
            "standard": ctx.attrs.standard,
            "swift": swift,
        },
        with_inputs = True,
    )
    output = ctx.actions.declare_output("THIRD_PARTY_NOTICES")
    ctx.actions.run(
        cmd_args(ctx.attrs.tool[RunInfo], manifest, output.as_output()),
        category = "notices",
    )
    return [DefaultInfo(default_output = output)]

# `shipped` (a query) is every download the bundle's parts reach. Each is a
# crate or a Swift package, or `npm` (closure name -> (package holding its
# license, note)) or `covered` must account for it: a new download fails the
# build until someone says what its license is. `grammars` and `prebuilt` are
# (fields, license files by name upstream). `lockfiles` are (programs, the
# components it tracks, Cargo.lock) of the prebuilt Rust programs, and
# `bundled` the crates they lock (`name@version` -> archive). Every
# component's license must be one `policy` (cargo-deny's configuration)
# allows, or have its `name@version` in `exceptions`, with the reason.
third_party_notices = rule(
    impl = _notices_impl,
    attrs = {
        "bundled": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "covered": attrs.list(attrs.string(), default = []),
        "exceptions": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "grammars": attrs.list(attrs.tuple(attrs.dict(attrs.string(), attrs.string()), attrs.dict(attrs.string(), attrs.source()))),
        "lockfiles": attrs.list(attrs.tuple(attrs.string(), attrs.list(attrs.string()), attrs.source()), default = []),
        "npm": attrs.dict(attrs.string(), attrs.tuple(attrs.dep(), attrs.string())),
        "policy": attrs.source(),
        "prebuilt": attrs.list(attrs.tuple(attrs.dict(attrs.string(), attrs.string()), attrs.dict(attrs.string(), attrs.source()))),
        "resolved": attrs.source(),
        "shipped": attrs.query(),
        "standard": attrs.dict(attrs.string(), attrs.source()),
        "tool": attrs.exec_dep(providers = [RunInfo]),
    },
)
