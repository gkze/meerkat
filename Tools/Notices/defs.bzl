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
