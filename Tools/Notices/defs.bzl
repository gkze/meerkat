# Pinned downloads of single license files, for THIRD_PARTY_NOTICES.

def fetched_texts(prefix: str, files: dict) -> dict:
    """Declares a download of each file in `files` (name upstream -> (URL,
    SHA-256)) and returns name upstream -> target. A Gitiles `?format=TEXT` URL
    serves the file as base64; its target is the decoded file."""
    targets = {}
    for file, (url, sha256) in files.items():
        name = "{}-{}".format(prefix, file).replace("/", "-").replace(" ", "-").replace("+", "x")
        native.http_file(name = name + ".fetched", urls = [url], sha256 = sha256)
        if "?format=TEXT" in url:
            native.genrule(
                name = name,
                srcs = [":{}.fetched".format(name)],
                out = "license",
                cmd = "/usr/bin/base64 -D -i $SRCS -o $OUT",
            )
            targets[file] = ":" + name
        else:
            targets[file] = ":{}.fetched".format(name)
    return targets

# A component of THIRD_PARTY_NOTICES pinned at a commit of a GitHub
# repository, or of one of Chromium's mirrors, whose license `files` (name to
# SHA-256) are at that commit; `fields` are the rest of it.
def github_component(repository: str, revision: str, files: dict[str, str], **fields) -> dict:
    return dict(
        version = revision[:12],
        source = "https://github.com/{}/tree/{}".format(repository, revision),
        files = {
            file: ("https://raw.githubusercontent.com/{}/{}/{}".format(repository, revision, file), sha256)
            for file, sha256 in files.items()
        },
        **fields
    )

def chromium_component(path: str, revision: str, files: dict[str, str], **fields) -> dict:
    source = "https://chromium.googlesource.com/{}/+/{}".format(path, revision)
    return dict(
        version = revision[:12],
        source = source,
        files = {file: ("{}/{}?format=TEXT".format(source, file), sha256) for file, sha256 in files.items()},
        **fields
    )
