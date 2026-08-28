#!/usr/bin/env python3
"""Build a flat, signed apt repository of installer packages.

No package here carries an upstream payload. Each one is a few kilobytes of
maintainer script whose postinst downloads the file from the publisher and
checks it against a SHA-256 pinned when the package was built. The published
repository therefore stays tiny, and the bytes a user installs always come from
the publisher, so no licence has to permit redistribution.

Three install shapes exist, chosen by `install` in packages.toml:

  deb     download a .deb and unpack it into /
  member  download an archive and place one executable in /usr/bin
  tree    download an archive and place the whole application in /opt

The hash comes from GitHub's release asset digest, or from a checksum file the
publisher publishes beside the payload. Only when neither exists is the payload
downloaded, hashed and discarded.

One further package, diamondinoia-apt, carries the signing key, the source entry
and the pin, so adding this repository is a single install.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).parent
DL = ROOT / "dl"       # payloads fetched only to be hashed, cached between runs
OUT = ROOT / "out"     # what is published: installer .debs and the signed index
ARCH = "amd64"
MAINTAINER = "Marco Barbone <mbarbone@flatironinstitute.org>"
API = "https://api.github.com"
BOOTSTRAP = "diamondinoia-apt"
BASE_URI = "https://github.com/DiamonDinoia/apt/releases/download/repo/"
LABEL = "diamondinoia"


def http(url: str, *, method: str = "GET") -> urllib.request.Request:
    req = urllib.request.Request(url, method=method)
    req.add_header("User-Agent", "diamondinoia-apt")
    token = os.environ.get("GITHUB_TOKEN")
    if token and "github.com" in url:
        req.add_header("Authorization", f"Bearer {token}")
    return req


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, **kw)


def resolve(name: str, spec: dict) -> dict:
    """Current version, payload URL and, where the publisher gives one, its hash."""
    if "repo" in spec:
        endpoint = (f"{API}/repos/{spec['repo']}/releases/tags/{spec['tag']}"
                    if "tag" in spec
                    else f"{API}/repos/{spec['repo']}/releases/latest")
        try:
            with urllib.request.urlopen(http(endpoint)) as r:
                release = json.load(r)
        except urllib.error.HTTPError as e:
            raise SystemExit(f"{name}: {endpoint} returned {e.code}"
                             + (f"; run mirror.sh to populate the {spec['tag']!r} "
                                "release" if "tag" in spec else "")) from None
        rx = re.compile(spec["asset"])
        matches = [a for a in release["assets"] if rx.match(a["name"])]
        if not matches:
            names = ", ".join(a["name"] for a in release["assets"])
            raise SystemExit(f"{name}: no asset matches {spec['asset']!r}; have: {names}")
        # A mirror release accumulates versions under one fixed tag, so there
        # the version lives in the asset name and the greatest one is current.
        if "version_re" in spec:
            def ver(a: dict) -> str:
                # Two capture groups join with `~`, which dpkg sorts below
                # everything, so a pre-release nightly of major N stays below
                # every version the distribution could ship as that major.
                return "~".join(re.search(spec["version_re"], a["name"]).groups())
            asset = max(matches, key=ver)
            version = ver(asset)
        else:
            asset = matches[0]
            version = release["tag_name"].lstrip("v")
        digest = asset.get("digest") or ""
        return {
            "version": version,
            "url": asset["browser_download_url"],
            "source": asset["name"],
            "sha256": digest.removeprefix("sha256:") or None,
        }

    if "json" in spec:
        with urllib.request.urlopen(http(spec["json"])) as r:
            node = json.load(r)
        for key in spec["json_path"].split("."):
            node = node[int(key)] if key.isdigit() else node[key]
        with urllib.request.urlopen(http(node["checksumLink"])) as r:
            sha = r.read().split()[0].decode()
        return {
            "version": re.search(spec["version_re"], node["link"]).group(1),
            "url": node["link"],
            "source": Path(node["link"]).name,
            "sha256": sha,
        }

    # A plain URL that redirects to a versioned path. HEAD is enough to learn
    # the version; the publisher offers no checksum, so one is computed below.
    with urllib.request.urlopen(http(spec["url"], method="HEAD")) as r:
        final = r.geturl()
    match = re.search(spec["version_re"], final)
    if not match:
        raise SystemExit(f"{name}: {spec['version_re']!r} does not match {final}")
    return {
        "version": match.group(1),
        "url": spec["url"],
        "source": f"{name}_{match.group(1)}{Path(final).suffix}",
        "sha256": None,
    }


def fetch(info: dict) -> Path:
    DL.mkdir(exist_ok=True)
    path = DL / info["source"]
    if path.exists() and path.stat().st_size > 0:
        return path
    print(f"  fetch   {info['url']}")
    tmp = path.with_suffix(path.suffix + ".part")
    with urllib.request.urlopen(http(info["url"])) as r, tmp.open("wb") as f:
        shutil.copyfileobj(r, f)
    tmp.rename(path)
    return path


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


PREAMBLE = """#!/bin/sh
# The payload is not redistributed. It is fetched from the publisher and checked
# against the hash pinned when this package was built.
set -e
[ "$1" = configure ] || exit 0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL '{url}' -o "$tmp/payload"
echo '{sha}  '"$tmp/payload" | sha256sum -c - >/dev/null
"""

# The manifest is read off the payload's own tar stream, one path per line, so
# a name containing a space survives; `dpkg-deb -c` puts the path in a column
# and any field-splitting truncates it. Directory entries are dropped, so
# removal never deletes a directory another package also owns.
POSTINST = {
    "deb": PREAMBLE + """dpkg-deb --fsys-tarfile "$tmp/payload" | tar -t | sed -e 's|^\\./|/|' -e '/\\/$/d' > {manifest}
dpkg-deb -x "$tmp/payload" /
""",
    "member": PREAMBLE + """{unpack} > /usr/bin/{bin}
chmod 0755 /usr/bin/{bin}
""",
    "tree": PREAMBLE + """rm -rf {prefix}
mkdir -p {prefix}
{unpack}
for candidate in {launchers}; do
    if [ -x "{prefix}/$candidate" ]; then
        ln -sfn "{prefix}/$candidate" /usr/bin/{name}
        break
    fi
done
# An upstream that moves its launcher would otherwise leave a tree nothing can
# start, which no later check would notice.
[ -L /usr/bin/{name} ] || {{ echo "no launcher among: {launchers}" >&2; exit 1; }}
{links}""",
}

PRERM = {
    "deb": """#!/bin/sh
set -e
[ -f {manifest} ] || exit 0
xargs -r -d '\\n' rm -f < {manifest}
rm -f {manifest}
""",
    "member": """#!/bin/sh
set -e
rm -f /usr/bin/{bin}
""",
    "tree": """#!/bin/sh
set -e
rm -rf {prefix} /usr/bin/{name} {link_names}
""",
}


def unpack_command(spec: dict, source: str, prefix: str) -> str:
    """Shell writing one member to stdout, or exploding an archive into prefix."""
    zipped = source.endswith(".zip")
    if spec["install"] == "member":
        return (f'unzip -p "$tmp/payload" {spec["member"]}' if zipped
                else f'tar -xaOf "$tmp/payload" {spec["member"]}')
    # Most archives wrap the application in one directory, which is stripped so
    # the tree lands directly in prefix. `strip = 0` is for the ones that do not.
    strip = spec.get("strip", 1)
    return (f'unzip -q "$tmp/payload" -d {prefix}' if zipped
            else f'tar -xaf "$tmp/payload" -C {prefix} --strip-components={strip}')


def write_desktop(tree: Path, name: str, spec: dict, icon: str) -> None:
    apps = tree / "usr/share/applications"
    apps.mkdir(parents=True, exist_ok=True)
    (apps / f"{name}.desktop").write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        f"Name={spec['desktop_name']}\n"
        f"Comment={spec['description']}\n"
        f"Exec=/usr/bin/{name} %f\n"
        f"Icon={icon}\n"
        "Terminal=false\n"
        f"Categories={spec['desktop_categories']}\n"
        + (f"StartupWMClass={spec['wm_class']}\n" if "wm_class" in spec else "")
    )


def build(name: str, spec: dict, info: dict, deb: Path) -> None:
    tree = OUT / f"{name}-tree"
    shutil.rmtree(tree, ignore_errors=True)
    control = tree / "DEBIAN"
    control.mkdir(parents=True)

    depends = spec.get("depends", "libc6")
    sha = info["sha256"]

    # A .deb payload is always fetched, because its own Depends is the only
    # correct one and it can be read no other way. Anything else is fetched only
    # when the publisher offers no checksum. Either way the payload stays in the
    # cache and nothing of it enters the package.
    if sha is None or spec["install"] == "deb":
        payload = fetch(info)
        measured = sha256_of(payload)
        if sha is not None and sha != measured:
            raise SystemExit(
                f"{name}: publisher's checksum {sha} does not match the payload "
                f"({measured})")
        sha = measured
        if spec["install"] == "deb":
            depends = subprocess.run(
                ["dpkg-deb", "-f", str(payload), "Depends"],
                capture_output=True, text=True, check=True,
            ).stdout.strip() or depends

    prefix = f"/opt/{name}"
    fields = {
        "url": info["url"],
        "sha": sha,
        "name": name,
        # Upstream's executable does not always share the package name.
        "bin": spec.get("binary", name),
        "prefix": prefix,
        "manifest": f"/var/lib/{name}.files",
        "launchers": " ".join(spec.get("launcher", [])),
        "unpack": unpack_command(spec, info["source"], prefix),
        # A tree that ships a toolchain needs more than one command in PATH.
        # Every link is checked, because a target upstream dropped would
        # otherwise become a dangling symlink no later check notices.
        "links": "".join(
            f'ln -sfn {prefix}/{target} /usr/bin/{link}\n'
            f'[ -x {prefix}/{target} ] || {{ echo "missing: {target}" >&2; exit 1; }}\n'
            for link, target in spec.get("links", {}).items()),
        "link_names": " ".join(f"/usr/bin/{link}" for link in spec.get("links", {})),
    }
    for script, table in (("postinst", POSTINST), ("prerm", PRERM)):
        path = control / script
        path.write_text(table[spec["install"]].format(**fields))
        path.chmod(0o755)

    if "desktop_name" in spec:
        # A tree install keeps the icon inside the payload under /opt. A member
        # install has nowhere to put one, so the spec names a stock icon.
        write_desktop(tree, name, spec,
                      f"{prefix}/{spec['icon']}" if spec["install"] == "tree"
                      else spec["icon"])

    unpacker = ("dpkg" if spec["install"] == "deb" else
                "unzip" if info["source"].endswith(".zip") else
                "tar, xz-utils" if info["source"].endswith((".xz", ".txz")) else
                "tar")
    (control / "control").write_text(
        f"Package: {name}\n"
        f"Version: {info['version']}\n"
        f"Architecture: {ARCH}\n"
        f"Maintainer: {MAINTAINER}\n"
        f"Depends: {depends}, curl, ca-certificates, coreutils, {unpacker}\n"
        f"Section: {spec.get('section', 'utils')}\n"
        "Priority: optional\n"
        f"Homepage: {spec['homepage']}\n"
        f"Description: {spec['description']}\n"
        " Downloads the official build from the publisher on install and checks\n"
        " it against a pinned SHA-256. Nothing is redistributed.\n"
        f" License: {spec['license']}.\n"
    )
    run(["dpkg-deb", "--root-owner-group", "--build", str(tree), str(deb)])
    shutil.rmtree(tree)


def bootstrap(specs: dict, key: str) -> None:
    """Package the keyring, the source and the pin, so adding this repository
    is one `dpkg -i` rather than three files a user has to get right by hand."""
    tree = OUT / "bootstrap-tree"
    shutil.rmtree(tree, ignore_errors=True)
    for d in ("DEBIAN", "etc/apt/keyrings", "etc/apt/sources.list.d",
              "etc/apt/preferences.d"):
        (tree / d).mkdir(parents=True)

    with (tree / f"etc/apt/keyrings/{LABEL}.gpg").open("wb") as f:
        run(["gpg", "--export", key], stdout=f)

    (tree / f"etc/apt/sources.list.d/{LABEL}.sources").write_text(
        "Types: deb\n"
        f"URIs: {BASE_URI}\n"
        "Suites: /\n"
        "Components:\n"
        f"Signed-By: /etc/apt/keyrings/{LABEL}.gpg\n"
    )

    # A package that only fills a gap until the distribution fills it sits
    # below the archive's own 500, so the archive wins by priority alone the
    # day it ships that name. Above zero, so it still installs until then.
    defer = [n for n, s in specs.items() if s.get("defer_to_debian")]
    pinned = [BOOTSTRAP, *(n for n in specs if n not in defer)]

    # Pinned on the Release label, not the host, so the pin holds whatever the
    # repository is served from and never claims every package on github.com.
    (tree / f"etc/apt/preferences.d/{LABEL}").write_text(
        "Package: *\n"
        f"Pin: release l={LABEL}\n"
        "Pin-Priority: -1\n\n"
        f"Package: {' '.join(pinned)}\n"
        f"Pin: release l={LABEL}\n"
        "Pin-Priority: 600\n"
        + (f"\nPackage: {' '.join(defer)}\n"
           f"Pin: release l={LABEL}\n"
           "Pin-Priority: 100\n" if defer else "")
    )

    # The version tracks the key, so rotating it offers users an upgrade that
    # replaces the keyring rather than leaving them unable to verify the index.
    version = f"1.0+{key[-8:].lower()}"
    (tree / "DEBIAN/control").write_text(
        f"Package: {BOOTSTRAP}\n"
        f"Version: {version}\n"
        "Architecture: all\n"
        f"Maintainer: {MAINTAINER}\n"
        "Depends: apt, ca-certificates\n"
        "Section: admin\n"
        "Priority: optional\n"
        "Homepage: https://github.com/DiamonDinoia/apt\n"
        "Description: apt source for the DiamonDinoia repository\n"
        " Installs the signing key, the source entry and a pin that confines\n"
        " this repository to the packages it is meant to provide.\n"
    )
    run(["dpkg-deb", "--root-owner-group", "--build", str(tree),
         str(OUT / f"{BOOTSTRAP}_{version}_all.deb")])
    shutil.rmtree(tree)


def index() -> None:
    packages = OUT / "Packages"
    with packages.open("wb") as f:
        run(["dpkg-scanpackages", "--multiversion", ".", "/dev/null"],
            cwd=OUT, stdout=f)
    # Assets sit directly at the flat base URI, so the leading "./" that
    # dpkg-scanpackages emits has to go.
    packages.write_bytes(packages.read_bytes().replace(b"Filename: ./", b"Filename: "))
    run(["gzip", "-9kf", "Packages"], cwd=OUT)

    with (OUT / "Release").open("wb") as f:
        run(["apt-ftparchive",
             "-o", "APT::FTPArchive::Release::Origin=diamondinoia",
             "-o", "APT::FTPArchive::Release::Label=diamondinoia",
             "-o", f"APT::FTPArchive::Release::Architectures={ARCH}",
             "release", "."],
            cwd=OUT, stdout=f)

    key = os.environ.get("GPG_KEY_ID")
    if not key:
        print("GPG_KEY_ID unset, leaving the index unsigned")
        return
    run(["gpg", "--batch", "--yes", "--default-key", key,
         "--clearsign", "-o", "InRelease", "Release"], cwd=OUT)
    run(["gpg", "--batch", "--yes", "--default-key", key,
         "-abs", "-o", "Release.gpg", "Release"], cwd=OUT)
    with (OUT / "KEY.gpg").open("wb") as f:
        run(["gpg", "--armor", "--export", key], stdout=f)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", action="append", help="build just these packages")
    args = parser.parse_args()

    specs = tomllib.loads((ROOT / "packages.toml").read_text())
    if args.only:
        specs = {k: v for k, v in specs.items() if k in args.only}

    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir()

    for name, spec in specs.items():
        info = resolve(name, spec)
        print(f"{name}: {info['version']}")
        build(name, spec, info, OUT / f"{name}_{info['version']}_{ARCH}.deb")

    key = os.environ.get("GPG_KEY_ID")
    if key:
        bootstrap(specs, key)
    index()
    for p in sorted(OUT.iterdir()):
        print(f"  {p.stat().st_size:>10,}  {p.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
