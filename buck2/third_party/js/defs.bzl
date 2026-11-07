# An npm package from its registry tarball: `<name>.tgz` (the download,
# checked against `sha256`; //buck2/third_party/js:pins_test compares it with
# Sources/meerkat-rules/bun.lock) and `<name>`, its `package/` directory unpacked.

def _unpack_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output(ctx.label.name, dir = True)
    ctx.actions.run(
        cmd_args(
            "/bin/sh",
            "-c",
            'mkdir -p "$2" && /usr/bin/tar -xzf "$1" -C "$2" --strip-components 1',
            "--",
            ctx.attrs.tarball,
            out.as_output(),
        ),
        category = "npm_unpack",
    )
    return [DefaultInfo(default_output = out, sub_targets = {
        path: [DefaultInfo(default_output = out.project(path))]
        for path in ctx.attrs.paths
    })]

_unpack = rule(impl = _unpack_impl, attrs = {"paths": attrs.list(attrs.string()), "tarball": attrs.source()})

# `paths` inside the package are exposed as subtargets (`:tsrslint[tsrslint]`).
def npm_package(name: str, package: str, version: str, sha256: str, paths: list[str] = []):
    native.http_file(
        name = name + ".tgz",
        urls = ["https://registry.npmjs.org/{}/-/{}-{}.tgz".format(package, package.split("/")[-1], version)],
        sha256 = sha256,
    )
    _unpack(name = name, tarball = ":{}.tgz".format(name), paths = paths, visibility = ["PUBLIC"])
