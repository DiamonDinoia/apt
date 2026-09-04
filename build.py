#!/usr/bin/env python3
"""Build a flat, signed apt repository of installer packages.

No wrapper package carries an upstream payload. Each one is a few kilobytes of
maintainer script whose postinst downloads the file from the publisher and
checks it against a SHA-256 pinned when the package was built. The published
repository therefore stays tiny, and the bytes a user installs always come from
the publisher, so no licence has to permit redistribution. The passthrough
shape is the exception: it serves debs this project forks and builds itself,
where there is nothing to license around.

Four install shapes exist, chosen by `install` in packages.toml:

  deb         download a .deb and unpack it into /
  member      download an archive and place one executable in /usr/bin
  tree        download an archive and place the whole application in /opt
  passthrough serve a .deb from the fork it was built in, bit-identical

The wrapper shapes drop a payload's own maintainer scripts. A package whose
scripts matter (juno-drivers, modified in a fork of this project) is built and
container-tested by that fork's CI and served here unchanged, still pinned to
the digest the publisher reported for the asset.

The hash comes from GitHub's release asset digest, or from a checksum file the
publisher publishes beside the payload. Only when neither exists is the payload
downloaded, hashed and discarded.

One further package, diamondinoia-apt, carries the signing key, the source entry
and the pin, so adding this repository is a single install. It also carries the
third-party sources listed under [repos] in packages.toml, each with its vendor
key pinned by SHA-256; the ones marked `separate` become a
diamondinoia-repo-<name> package instead, for repositories only the machine
with the matching hardware wants.

Compiler bundles
----------------

Beside the packages.toml wrappers above, build.py emits one "bundle" deb per
catalog.json compiler entry whose payload the mirror covers, merging four
inputs (the full list is also `meta.inputs` in --dump-spec):

  packages.toml        hand-written wrappers + [repos] (verbatim)
  catalog.json         the Compiler Explorer classification (S1): name,
                       series, regime, pcr class, version parts per payload
  mirror-manifest.json S2's mirror rows: payload sha256/size + per-payload
                       analysis (bin/ files+links, NEEDED union, layout)
  exceptions.json      MAY NOT EXIST; reserved overrides, surfaced verbatim
                       in --dump-spec

A catalog entry emits a bundle iff a manifest row exists with analysis != null
(greatest dated trunk row per family; stables by asset name). The rest are
reported once ("N catalog payloads not yet mirrored - skipped"); zero bundles
emitting is the only fatal form. --dump-spec prints the full resolved spec as
canonical JSON (indent=2, sort_keys, trailing newline) — THE test interface:

  meta            {inputs, exceptions_present}
  exceptions      exceptions.json verbatim ({})
  repos           packages.toml [repos] verbatim
  pins            {"100": [stanzas], "500": [...], "600": [...]} as shipped
  wrappers        name -> packages.toml entry verbatim + pin ("100"/"500"/"600")
                  and "version": null (wrapper versions resolve from the
                  network at build time; dump-spec is an offline interface)
  bundles         name ->
    name, state ("emit" | "pending: not yet mirrored"), install ("bundle"),
    family, series, regime, triplet, upstream version, version (deb string),
    pin ("defer" for every catalog bundle; bootstrap stanza covers the globs),
    payload {url, sha256, asset, size_bytes} (emit only),
            links {debian name -> payload path}, launcher [candidates],
    link_exclusions {payload bin name: {class, reason}},
    links_absent {tool table name: reason} (era gaps: payload lacks the tool),
    depends (final Debian Depends list), unmatched_sonames,
    payload_internal_sonames, pcr {provides {name: constraint}, conflicts[],
    replaces[]} | "none", prefix, strip
    Pending entries carry name/state/pin and the static catalog fields only.

Bundle internals (settled; do not relitigate):

  Version   stables: <series>~ce<upstream>-R (R=BUNDLE_REVISION below) —
            `N~ce...` sorts below every Debian spelling of series N
            (~ sorts below everything, incl. snapshots `N-<date>-R`, true
            versions `N.M.P-R`, `.crossR`, epochs, +debNNuN, ~bpo). Trunks keep
            the `N~trunkYYYYMMDD` form of the dated asset name. Each emitted
            version is asserted at build time, with dpkg --compare-versions,
            to sort below every version the catalog recorded for that series
            in sid/trixie; when neither suite records the series, the fallback
            corpus is the constructive lower forms `<series>-0`,
            `<series>.0.0-1` and `<upstream>-1` (the least shapes Debian could
            spell that series/lineage). A violation fails the build naming it.
  Links     the payload's bin/ universe (FILE + hardlink + symlink members,
            from the manifest analysis) partitions into Debian-spelled links
            and excluded-with-reason names; see LINK RULES below. The tables
            are data, one home each; a bin/ name no rule covers fails the
            build, so extensions are deliberate, never regex-luck.
  Depends   NEEDED soname union mapped through SONAME_PACKAGES; libc6-dev
            always (a compiler without libc headers compiles nothing);
            libxml2 added when the payload ships gcobol (libgcobol objects
            link unversioned libxml2 — the gcc-17 incident); binutils (native)
            or binutils-<triplet> (cross) only when the payload carries no
            binutils itself. Unmapped sonames land in unmatched_sonames and
            are omitted from Depends (S4's ldd sweep classifies them);
            payload-internal sonames (libgo.so.N, libclang*/libLLVM*) land in
            payload_internal_sonames.
  P/C/R     per regime, shapes over the recorded Debian inventory (§8 of the
            plan): runtime-soname packages and *-base packages are denied —
            see DENY_RE; a computed set intersecting the deny shapes aborts
            the build (poison control, exercised by --selftest).
  Atomicity the tree postinst stages into a sibling of /opt/<name> and renames
            onto it; a truncated tarball cannot leave a half-written tree.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

# A rebuild of unchanged content must produce unchanged bytes: the publish step
# skips assets whose digest still matches, and dpkg-deb's ar/tar members carry
# build-time mtimes unless pinned. A republish that only moves mtimes would
# otherwise invalidate every cached index until its next apt update.
os.environ.setdefault("SOURCE_DATE_EPOCH", "0")

ROOT = Path(__file__).parent
DL = ROOT / "dl"       # payloads fetched only to be hashed, cached between runs
OUT = ROOT / "out"     # what is published: installer .debs and the signed index
ARCH = "amd64"
MAINTAINER = "Marco Barbone <mbarbone@flatironinstitute.org>"
API = "https://api.github.com"
BOOTSTRAP = "diamondinoia-apt"
SELF = "DiamonDinoia/apt"
# Two different pin files were both published as 1.0, so no machine that
# installed 1.0 can be told which one it holds. That serial is burnt.
FLOOR = 1
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


# One read per release, not per package: two packages pinned to the same
# release must not straddle a re-publish by resolving seconds apart.
_RELEASES: dict[str, dict] = {}


def resolve(name: str, spec: dict) -> dict:
    """Current version, payload URL and, where the publisher gives one, its hash."""
    if "repo" in spec:
        endpoint = (f"{API}/repos/{spec['repo']}/releases/tags/{spec['tag']}"
                    if "tag" in spec
                    else f"{API}/repos/{spec['repo']}/releases/latest")
        if endpoint not in _RELEASES:
            try:
                with urllib.request.urlopen(http(endpoint)) as r:
                    _RELEASES[endpoint] = json.load(r)
            except urllib.error.HTTPError as e:
                raise SystemExit(f"{name}: {endpoint} returned {e.code}"
                                 + (f"; run mirror.sh to populate the {spec['tag']!r} "
                                    "release" if "tag" in spec else "")) from None
        release = _RELEASES[endpoint]
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
                m = re.search(spec["version_re"], a["name"])
                if not m:
                    raise SystemExit(
                        f"{name}: version_re does not match asset {a['name']!r}")
                return "~".join(m.groups())
            # dpkg's own ordering, not lexicographic: on text compare "0.5.9"
            # sorts above "0.5.48", which is wrong.
            asset = matches[0]
            for candidate in matches[1:]:
                if subprocess.run(["dpkg", "--compare-versions",
                                   ver(candidate), "gt", ver(asset)],
                                  check=False).returncode == 0:
                    asset = candidate
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


def fetch(info: dict, *, expected: str | None = None) -> Path:
    DL.mkdir(exist_ok=True)
    path = DL / info["source"]
    if path.exists() and path.stat().st_size > 0:
        if expected is None or sha256_of(path) == expected:
            return path
        # A publisher that re-uploads under an unmoved name (the fork's CI
        # clobbers the asset whenever only the packaging changed) leaves the
        # cache holding yesterday's bytes, and --clobber over 30-day eviction
        # means the mismatch would fail every build for a month.
        print(f"  refetch {info['source']} (cached bytes no longer match)")
        path.unlink()
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
    # Staged: the archive is exploded into a sibling of the prefix and renamed
    # onto it. A truncated tarball (caught by the SHA-256) or a failed
    # extraction dies before the rename, leaving /opt/<name> absent or
    # untouched rather than a partial tree. The rename is atomic because
    # staging and prefix sit on the same filesystem. /opt may not exist yet on
    # a fresh install, so the sibling's parent is made first.
    "tree": PREAMBLE + """mkdir -p "$(dirname {prefix})"
staging=$(mktemp -d "{prefix}.new.XXXXXX")
trap 'rm -rf "$tmp" "$staging"' EXIT
{unpack}
launcher=
for candidate in {launchers}; do
    if [ -x "$staging/$candidate" ]; then
        launcher=$candidate
        break
    fi
done
# An upstream that moves its launcher would otherwise leave a tree nothing can
# start, which no later check would notice. Checked before the rename, so the
# failure leaves the old tree (or nothing) at the prefix.
if [ -z "$launcher" ]; then
    echo "no launcher among: {launchers}" >&2; exit 1
fi
{link_checks}
rm -rf {prefix}
mv "$staging" {prefix}
trap 'rm -rf "$tmp"' EXIT
ln -sfn "{prefix}/$launcher" /usr/bin/{name}
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


def unpack_command(spec: dict, source: str, dest: str) -> str:
    """Shell writing one member to stdout, or exploding an archive into dest."""
    zipped = source.endswith(".zip")
    if spec["install"] == "member":
        return (f'unzip -p "$tmp/payload" {spec["member"]}' if zipped
                else f'tar -xaOf "$tmp/payload" {spec["member"]}')
    # Most archives wrap the application in one directory, which is stripped so
    # the tree lands directly in dest. `strip = 0` is for the ones that do not.
    strip = spec.get("strip", 1)
    return (f'unzip -q "$tmp/payload" -d {dest}' if zipped
            else f'tar -xaf "$tmp/payload" -C {dest} --strip-components={strip}')


def unpacker_dep(source: str, install: str) -> str:
    """The package providing the extraction tool the postinst runs."""
    return ("dpkg" if install == "deb" else
            "unzip" if source.endswith(".zip") else
            "tar, xz-utils" if source.endswith((".xz", ".txz")) else
            "tar")


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
        payload = fetch(info, expected=sha)
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
    links = spec.get("links", {})
    fields = {
        "url": info["url"],
        "sha": sha,
        "name": name,
        # Upstream's executable does not always share the package name.
        "bin": spec.get("binary", name),
        "prefix": prefix,
        "manifest": f"/var/lib/{name}.files",
        "launchers": " ".join(spec.get("launcher", [])),
        "unpack": unpack_command(spec, info["source"], '"$staging"'),
        # A tree that ships a toolchain needs more than one command in PATH.
        # Each target is checked in the staging tree before the rename, so a
        # tool upstream dropped fails the install with the old tree untouched
        # instead of leaving a dangling symlink.
        "link_checks": "".join(
            f'[ -x "$staging"/{target} ] || {{ echo "missing: {target}" >&2; exit 1; }}\n'
            for target in links.values()),
        "links": "".join(
            f'ln -sfn {prefix}/{target} /usr/bin/{link}\n'
            for link, target in links.items()),
        "link_names": " ".join(f"/usr/bin/{link}" for link in links),
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

    unpacker = unpacker_dep(info["source"], spec["install"])

    def wrap(field: str, values: list[str]) -> str:
        # deb822 continuation lines fold a long list onto space-prefixed
        # lines. Only the LAST line drops the trailing comma: the comma is
        # the separator and dpkg's control parser accepts a newline only
        # after it (measured: breaking after `)' fails the parse).
        out, line = [], f"{field}: "
        for v in values:
            piece = f"{v}, "
            if len(line) + len(piece) > 72:
                out.append(line.rstrip())
                line = f" {piece}"
            else:
                line += piece
        out.append(line.rstrip(", "))
        return "\n".join(out) + "\n"

    extra = ""
    pcr = spec.get("_pcr")
    if pcr:
        if pcr.get("provides"):
            extra += wrap("Provides",
                          [f"{n} ({c})" for n, c in pcr["provides"].items()])
        if pcr.get("conflicts"):
            extra += wrap("Conflicts", pcr["conflicts"])
        if pcr.get("replaces"):
            extra += wrap("Replaces", pcr["replaces"])

    body = spec.get("_body",
                    " Downloads the official build from the publisher on install and checks\n"
                    " it against a pinned SHA-256. Nothing is redistributed.\n")
    (control / "control").write_text(
        f"Package: {name}\n"
        f"Version: {info['version']}\n"
        f"Architecture: {ARCH}\n"
        f"Maintainer: {MAINTAINER}\n"
        f"Depends: {depends}, curl, ca-certificates, coreutils, {unpacker}\n"
        f"{extra}"
        f"Section: {spec.get('section', 'utils')}\n"
        "Priority: optional\n"
        f"Homepage: {spec['homepage']}\n"
        f"Description: {spec['description']}\n"
        f"{body}"
        f" License: {spec['license']}.\n"
    )
    run(["dpkg-deb", "--root-owner-group", "--build", str(tree), str(deb)])
    shutil.rmtree(tree)


def passthrough(name: str, info: dict) -> None:
    """Serve a .deb built and tested by the fork that publishes it.

    The wrapper shapes lose the payload's own maintainer scripts, which a
    package running real install logic (juno-drivers) needs, so here the
    payload is the package. The build stops unless the bytes hash to the
    digest the publisher reported and the deb's own control data names the
    package and version packages.toml resolved.
    """
    payload = fetch(info, expected=info["sha256"])
    measured = sha256_of(payload)
    if info["sha256"] is not None and info["sha256"] != measured:
        raise SystemExit(
            f"{name}: publisher's checksum {info['sha256']} does not match the "
            f"payload ({measured})")

    def field(f: str) -> str:
        return subprocess.run(["dpkg-deb", "-f", str(payload), f],
                              capture_output=True, text=True,
                              check=True).stdout.strip()
    if field("Package") != name or field("Version") != info["version"]:
        raise SystemExit(
            f"{name}: the deb says {field('Package')} {field('Version')}, but "
            f"packages.toml resolved {name} {info['version']}")
    if not re.fullmatch(r"[A-Za-z0-9._+-]+", info["source"]):
        raise SystemExit(f"{name}: {info['source']!r} has characters a release "
                         "host may rewrite")
    shutil.copy(payload, OUT / info["source"])


def content_version(pkg: str, tree: Path, suffix: str, floor: int = 0) -> str:
    """The version of a configuration package, bumped when its files change.

    Apt offers no upgrade at a version it already holds, so a pin file edited
    without a bump reaches nobody who installed earlier. Comparing against the
    published package is what decides, because nothing else in the build knows
    whether this rebuild changed anything. The serial leads the version: a
    rotated key sorts below the key it replaces as often as above it.
    """
    def payload(data: Path, debian: Path) -> dict[str, bytes]:
        # Control data must count as content: a Depends edit or a conffile
        # membership change has to reach installed machines, which is exactly
        # the shape of change /etc cannot see. The Version line is excluded so
        # an unchanged rebuild does not bump itself.
        out = {str(p.relative_to(data)): p.read_bytes() for p in data.rglob("*")
               if p.is_file()}
        for p in debian.rglob("*"):
            if not p.is_file():
                continue
            # dpkg generates md5sums when a deb is built, so it exists only on
            # the published side of the comparison and would read as a change
            # on every single build — a serial that ratchets nightly.
            if p.name == "md5sums":
                continue
            content = p.read_bytes()
            if p.name == "control":
                content = b"".join(l for l in content.splitlines(keepends=True)
                                   if not l.startswith(b"Version:"))
            out[f"DEBIAN/{p.name}"] = content
        return out

    rx = re.compile(rf"{pkg}_1\.(\d+)\+[0-9a-f]+_all\.deb")
    try:
        with urllib.request.urlopen(http(f"{API}/repos/{SELF}/releases/tags/repo")) as r:
            assets = [a for a in json.load(r)["assets"] if rx.fullmatch(a["name"])]
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise              # a 503 read as "nothing published" resets the serial
        assets = []            # no release yet, so this is the first version
    if not assets:
        return f"1.{floor}+{suffix}"

    old = max(assets, key=lambda a: int(rx.fullmatch(a["name"])[1]))
    with tempfile.TemporaryDirectory() as d:
        with urllib.request.urlopen(http(old["browser_download_url"])) as r:
            Path(d, "old.deb").write_bytes(r.read())
        run(["dpkg-deb", "-x", f"{d}/old.deb", f"{d}/x"])
        run(["dpkg-deb", "-e", f"{d}/old.deb", f"{d}/e"])
        changed = payload(Path(d, "x"), Path(d, "e")) != payload(tree, tree / "DEBIAN")
    serial = int(rx.fullmatch(old["name"])[1]) + changed
    return f"1.{max(serial, floor)}+{suffix}"


def add_repo(tree: Path, name: str, spec: dict) -> None:
    """Write one third-party apt source and its key into a package tree.

    The key is pinned by hash like every payload, so the day a vendor rotates
    one the build stops with the served hash in the error rather than shipping
    a key nobody checked. Armoured and binary keys both work as Signed-By, so
    whatever the vendor serves is stored unchanged under the matching suffix.
    """
    # Not through http(): that attaches GITHUB_TOKEN to any github.com host,
    # and cli.github.com is one. A vendor key needs no credential of ours.
    req = urllib.request.Request(spec["key"],
                                 headers={"User-Agent": "diamondinoia-apt"})
    blob = urllib.request.urlopen(req).read()
    got = hashlib.sha256(blob).hexdigest()
    if got != spec["key_sha256"]:
        raise SystemExit(f"{name}: key at {spec['key']} hashes {got}, "
                         f"not the pinned {spec['key_sha256']}")
    suffix = "asc" if blob.startswith(b"-----BEGIN") else "gpg"
    (tree / f"etc/apt/keyrings/{name}.{suffix}").write_bytes(blob)

    fields = {"Types": "deb", "URIs": spec["uris"], "Suites": spec["suites"]}
    for f in ("components", "architectures"):
        if spec.get(f):
            fields[f.capitalize()] = spec[f]
    fields["Signed-By"] = f"/etc/apt/keyrings/{name}.{suffix}"
    (tree / f"etc/apt/sources.list.d/{name}.sources").write_text(
        "".join(f"{k}: {v}\n" for k, v in fields.items()))


def conffiles(tree: Path) -> None:
    """Declare everything under /etc a configuration file, as policy requires.

    Without this dpkg overwrites a source the user edited on every upgrade, and
    `apt remove` on the bootstrap deletes the third-party sources and keys it
    carries. Conffiles survive removal and go only on purge.

    The pin file is the exception: it is centrally versioned, so an upgrade
    must replace it. As a conffile, every pin change prompts every user, and
    answering "keep mine", which is the default, silently shadows the pin the
    repository intends to ship — the repo would then add a package no pinned
    machine can ever install.
    """
    paths = sorted(
        f"/{p.relative_to(tree)}" for p in (tree / "etc").rglob("*")
        if p.is_file()
        and p.relative_to(tree) != Path("etc/apt/preferences.d") / LABEL)
    (tree / "DEBIAN/conffiles").write_text("".join(f"{p}\n" for p in paths))


def repo_package(name: str, spec: dict) -> None:
    """Build diamondinoia-repo-<name>: one third-party source, nothing else.

    A repository wanted only by the machine that has the matching hardware does
    not belong in the bootstrap, where everyone who adds this repository would
    get it.
    """
    pkg = f"diamondinoia-repo-{name}"
    tree = OUT / f"{pkg}-tree"
    shutil.rmtree(tree, ignore_errors=True)
    for d in ("DEBIAN", "etc/apt/keyrings", "etc/apt/sources.list.d"):
        (tree / d).mkdir(parents=True)
    add_repo(tree, name, spec)

    conffiles(tree)
    # control has to exist before content_version reads the tree: missing on
    # one side and present on the other would read as a change on every build.
    # The Version line is where the computed version lands at the end, and is
    # stripped from both sides of the comparison.
    def control(version: str) -> str:
        return (
            f"Package: {pkg}\n"
            f"Version: {version}\n"
            "Architecture: all\n"
            f"Maintainer: {MAINTAINER}\n"
            "Depends: apt, ca-certificates\n"
            "Section: admin\n"
            "Priority: optional\n"
            "Homepage: https://github.com/DiamonDinoia/apt\n"
            f"Description: {spec['description']}\n"
            f" Installs {spec['key']} and the matching source entry. The key is\n"
            " pinned by SHA-256 at build time, so a rotated key fails the build\n"
            " rather than reaching a machine unchecked.\n"
        )
    (tree / "DEBIAN/control").write_text(control("0"))
    version = content_version(pkg, tree, spec["key_sha256"][:8])
    (tree / "DEBIAN/control").write_text(control(version))
    run(["dpkg-deb", "--root-owner-group", "--build", str(tree),
         str(OUT / f"{pkg}_{version}_all.deb")])
    shutil.rmtree(tree)
    print(f"{pkg}: {version}")


# ---------------------------------------------------- merged catalog spec
#
# The tables here are the single home of the link/depend/pcr rules. Every rule
# is data plus a stated reason; an input that matches no rule fails the build,
# so table growth is a reviewed edit, never a silent regex widening.

CATALOG = ROOT / "catalog.json"
MANIFEST = ROOT / "mirror-manifest.json"
EXCEPTIONS = ROOT / "exceptions.json"   # reserved; tolerated absent
BUNDLE_REVISION = "1"
HOST_TRIPLET = "x86_64-linux-gnu"
# Runtime the postinst download-verify machinery needs; appended to every
# deb's Depends in the control writer the same way for wrappers and bundles.
DEPENDS_RUNTIME = ["curl", "ca-certificates", "coreutils"]

# SONAME -> Debian package. Era-aware where sonames drifted (libmpfr.so.4 vs
# .6, libisl across five ABI bumps). Only host-side sonames land here: the
# NEEDED union comes from the payload's own host executables, which run on
# x86-64 (CE hosts), so the loader is always ld-linux-x86-64.so.2.
SONAME_PACKAGES = {
    "ld-linux-x86-64.so.2": "libc6",
    "ld-linux.so.2": "libc6",
    "libc.so.6": "libc6",
    "libm.so.6": "libc6",
    "libdl.so.2": "libc6",
    "librt.so.1": "libc6",
    "libutil.so.1": "libc6",
    "libnsl.so.1": "libc6",
    "libpthread.so.0": "libc6",
    "libresolv.so.2": "libc6",
    "libgcc_s.so.1": "libgcc-s1",
    "libstdc++.so.6": "libstdc++6",
    "libz.so.1": "zlib1g",
    "libzstd.so.1": "libzstd1",
    "liblzma.so.5": "liblzma5",
    "libbz2.so.1.0": "libbz2-1.0",
    "libxml2.so.2": "libxml2",
    "libexpat.so.1": "libexpat1",
    "libgmp.so.10": "libgmp10",
    "libgmp.so.3": "libgmp3",
    "libgmpxx.so.4": "libgmpxx4ldbl",
    "libmpfr.so.1": "libmpfr1ldbl",
    "libmpfr.so.4": "libmpfr4",
    "libmpfr.so.6": "libmpfr6",
    "libmpc.so.2": "libmpc2",
    "libmpc.so.3": "libmpc3",
    "libisl.so.10": "libisl10",
    "libisl.so.15": "libisl15",
    "libisl.so.19": "libisl19",
    "libisl.so.22": "libisl22",
    "libisl.so.23": "libisl23",
    "libcloog-isl.so.4": "libcloog-isl4",
    "libfl.so.2": "libfl2",
}
# Sonames the payload ships for its own tools; they resolve from the payload
# lib dir (or not at all: the go helpers have no rpath, see the README). They
# get their own dump-spec column rather than conflating with unmatched ones.
PAYLOAD_INTERNAL_SONAME_RE = re.compile(
    r"^(libgo\.so\.\d+|libclang[^/]*\.so.*|libLLVM[^/]*\.so.*|liblldb[^/]*\.so.*)$")

# GNU triplet -> Debian arch, needed for the arch-spelled cross dev libs
# (libgcc-14-dev-arm64-cross). Covers every triplet the catalog's cross
# families carry; anything else fails loudly instead of producing a wrong name.
DEBIAN_ARCH = {
    "aarch64-linux-gnu": "arm64",
    "arm-linux-gnueabi": "armel",
    "arm-linux-gnueabihf": "armhf",
    "hppa-linux-gnu": "hppa",
    "i686-linux-gnu": "i386",
    "loongarch64-linux-gnu": "loong64",
    "m68k-linux-gnu": "m68k",
    "mips-linux-gnu": "mips",
    "mips64-linux-gnuabi64": "mips64",
    "mips64el-linux-gnuabi64": "mips64el",
    "mipsel-linux-gnu": "mipsel",
    "powerpc-linux-gnu": "powerpc",
    "powerpc64-linux-gnu": "ppc64",
    "powerpc64le-linux-gnu": "ppc64el",
    "riscv64-linux-gnu": "riscv64",
    "s390x-linux-gnu": "s390x",
    "sh4-linux-gnu": "sh4",
    "sparc64-linux-gnu": "sparc64",
    "x86_64-linux-gnu": "amd64",
    "x86_64-linux-gnux32": "x32",
}

# Runtime soname packages and *-base packages are never claimable: the payload
# is a compiler tree, not a runtime replacement, and -base packages carry the
# shared version machinery. A computed P/C/R set touching any of these is a
# table bug; the guard below aborts the build naming it (selftest trips it).
DENY_RE = re.compile(
    r"^(?:libgcc-s\d|libstdc\+\+\d|libgomp\d|libatomic\d|libgfortran\d|"
    r"libobjc\d|libgccjit\d|libgnat-\d|libc\+\+1-\d|libc\+\+-\d|libclang1-\d|"
    r"libclang-cpp\d|libomp\d*-\d|libunwind-\d)"
    r"|-base$"
    r"|^gcc-\d+(?:\.\d+)?-cross-base$")

# The gcc-suite entry points, in PATH order. The first is the package's
# launcher (it always exists, or the build fails); the rest become
# <tool>-<series> links (native) or <triplet>-<tool>-<series> links
# (cross/nodebian). Era gaps are expected (gcc-4.1 has no gcc-ar): an absent
# tool emits nothing and is recorded under links_absent.
GCC_TOOLS = [
    "gcc", "g++", "cpp", "gfortran", "gccgo", "gccrs", "gdc", "gm2",
    "gcobol", "gcobc", "ga68",
    "gnat", "gnatbind", "gnatchop", "gnatclean", "gnatkr", "gnatlink",
    "gnatls", "gnatmake", "gnatname", "gnatprep",
    "gcc-ar", "gcc-nm", "gcc-ranlib",
    "gcov", "gcov-dump", "gcov-tool", "lto-dump",
]
# clang: the Debian clang-N package ships clang-N, clang++-N, clang-cpp-N and
# clang-cl-N; the suite's other binaries live in their own splits
# (clang-tools-N, clang-tidy-N, clang-format-N, llvm-N, lld-N) and are
# excluded below, one class each.
CLANG_TOOLS = ["clang", "clang++", "clang-cpp", "clang-cl"]

# Exclusion classes: name -> reason. Classed by the first matching rule in
# classify_bin(). Membership is exact-set or explicitly documented prefix; the
# class strings land in dump-spec verbatim.
BINUTILS = {
    "addr2line", "ar", "as", "c++filt", "dwp", "elfedit", "gprof", "gprofng",
    "ld", "ld.bfd", "ld.gold", "nm", "objcopy", "objdump", "ranlib", "readelf",
    "size", "strings", "strip",
}
# go, gofmt and the four cgo helpers gccgo runs are Go programs linked against
# the payload's libgo with no rpath to it; they exit 127 from PATH. The cgo
# helpers live in libexec and are listed for completeness.
GO_LIBGO = {"go", "gofmt", "buildid", "cgo", "test2json", "vet"}
NO_SERIES_SPELLING = {"c++", "cc"}        # Debian gives these no -NN spelling
GCCBUG = {"gccbug"}                       # era script, mails bug reports
# clang-family plumbing: build-time generators, driver wrappers and test rigs
# that are not user entry points of the clang-N namespace.
CLANG_INTERNAL = {
    "c-index-test", "clang-tblgen", "diagtool", "hmaptool",
    "clang-linker-wrapper", "clang-nvlink-wrapper", "clang-offload-bundler",
    "clang-offload-wrapper", "clang-sycl-linker",
}
LLVM_EXACT = {  # llvm-N / lld-N namespace, shippable but not ours to spell
    "opt", "llc", "lli", "llubi", "lld", "ld.lld", "ld64.lld", "wasm-ld",
    "dsymutil", "sancov", "sanstats", "bugpoint", "macho-dump",
    "verify-uselistorder", "reduce-chunk-list", "offload-arch",
    "amdgpu-arch", "nvptx-arch", "lld-link",
}
# Payload-native plumbing for cross and exotic trees: crosstool helpers and
# NetBSD host build tools (vax). Not compiler entry points.
PAYLOAD_INTERNAL = {
    "ct-ng.config", "populate", "ldd",
    "dbsym", "fdisk", "install", "mdsetimage",
}

EXCLUSION_REASONS = {
    "bundled-binutils":
        "bundled in the payload; the driver finds them itself and Debian's "
        "gcc-NN packages put none of them on PATH",
    "triplet-alias":
        "target-triplet or version-suffixed spelling of a driver already "
        "linked; Debian's current gcc-NN packages ship no such alias",
    "no-series-spelling":
        "Debian gives this driver no -NN spelling",
    "go-libgo":
        "Go program linked against the payload's own libgo with no rpath; "
        "exits 127 unless the loader is pointed at the payload, which the "
        "package deliberately does not do",
    "gccbug":
        "era bug-report script, not a compiler",
    "llvm-suite":
        "belongs to the llvm-N/lld-N namespace; out of the clang-N "
        "namespace this bundle claims",
    "other-debian-split":
        "shipped by its own Debian split (clang-tools-N, clang-tidy-N, "
        "clang-format-N, clangd-N); this bundle links the clang-N driver set",
    "payload-internal":
        "payload build plumbing (build tool, driver wrapper, test rig or "
        "host-side helper), not a user entry point",
}

_TOOL_DUP_RE = re.compile(
    r"^(?:gcc|g\+\+|cpp|gfortran|gccgo|gccrs|gdc|gm2|gcobol|gcobc|ga68|"
    r"gnat[a-z]*|gcov(?:-dump|-tool)?|gcc-(?:ar|nm|ranlib)|lto-dump|clang|"
    r"clang\+\+|clang-cpp|clang-cl)-\d+(?:\.\d+)*$")


def classify_bin(name: str, *, kind: str, triplets: list[str]) -> str | None:
    """The exclusion class of a payload bin/ name, or None when the name is a
    linkable tool (the caller's tool table owns it) / unknown (fatal).

    Cross and nodebian payloads spell every tool triplet-prefixed, so the
    prefix is stripped first and the base classified; native payloads use the
    prefix for aliases of drivers already linked under their plain name.
    Crosstool occasionally double-prefixes a driver
    (aarch64-unknown-linux-gnu-aarch64-unknown-linux-gnu-ga68): a deeper
    nesting of a linkable driver is an alias spelling."""
    base = name
    stripped = 0
    for t in triplets:
        while base.startswith(t + "-"):
            if kind == "native":
                return "triplet-alias"
            base = base[len(t) + 1:]
            stripped += 1
    if stripped > 1 and (base in GCC_TOOLS or base in CLANG_TOOLS):
        return "triplet-alias"
    if _TOOL_DUP_RE.fullmatch(base):
        return "triplet-alias"
    if base in GCC_TOOLS or base in CLANG_TOOLS:
        return None                      # the tool table links this
    if base in GO_LIBGO:
        return "go-libgo"
    if base in NO_SERIES_SPELLING:
        return "no-series-spelling"
    if base in GCCBUG:
        return "gccbug"
    if base in BINUTILS or base.startswith(("gprofng-", "gp-")):
        return "bundled-binutils"
    if kind == "clang":
        if base.startswith("llvm-") or base in LLVM_EXACT:
            return "llvm-suite"
        if base in CLANG_INTERNAL or base.startswith("clang-ssaf-"):
            return "payload-internal"
        if base == "clangd" or base.startswith((
                "clang-", "analyze-build", "intercept-build",
                "scan-build", "scan-build-py", "scan-view",
                "run-clang-tidy", "git-clang-format",
                "find-all-symbols", "modularize", "pp-trace")):
            return "other-debian-split"
        return None                      # unknown clang name: caller fails
    if base in PAYLOAD_INTERNAL or base.startswith("nb"):
        return "payload-internal"
    return None                          # unknown gcc name: caller fails


# P/C/R shapes, per regime. Sets are computed by filtering the Debian
# inventory the catalog recorded (sid+trixie) — never by inventing names —
# then passed through the deny guard. What the inventory does not record
# (cpp-N, gfortran-N, gnat-N, libstdc++-N-dev) cannot be claimed from this
# evidence; the shapes below match exactly what the catalog carries (see
# catalog.py's debian_inventory filter: gcc|clang|libgcc|g++ prefixes).

GCC_PCR_RE = rf"(?:gcc|g\+\+|gccgo|gccrs|gfortran|gnat|gdc|gm2|gcobol)-%(S)s(?:-multilib)?"
CLANG_PCR_RE = rf"(?:clang|clang-tools|clang-tidy|clang-format|clangd)-%(S)s"


def pcr_guard(name: str, claim: list[str]) -> None:
    """Refuse to emit a P/C/R set intersecting the runtime/-base denylist.
    Sits at the chokepoint every computed claim passes through, so a table
    edit that widens onto a denied name fails the build naming the package."""
    denied = [n for n in claim if DENY_RE.search(n)]
    if denied:
        raise SystemExit(f"{name}: P/C/R claim intersects the runtime/-base "
                         f"denylist: {denied}")


def pcr_sets(name: str, *, series: str, regime: str, triplet: str | None,
             cross: bool, upstream: str, inventory: dict[str, str]) -> dict | None:
    """The Provides/Conflicts/Replaces sets for one bundle, or None (nodebian).

    provides   {name: "= <upstream>-0~ceR"} — upstream-spelling so >= N.M
               reverse deps resolve; the ~ce package version sorts below
               Debian's, which a versioned Provides must not inherit.
    conflicts/replaces  the same names, unversioned (Replaces is advisory for
               apt's resolver; the links are postinst-made, dpkg owns none).
    The bundle's own package name is filtered out of all three: a same-named
    Debian package is the upgrade path, not a conflict partner, and a package
    may not declare Conflicts on itself.
    """
    if regime == "nodebian":
        return None
    if regime == "unversioned":
        # gcc-14-avr conflicts the unversioned analog; provides it. Same-name
        # mutual exclusion between our versions of one family falls out: ours-13
        # Provides gcc-avr, ours-14 Conflicts gcc-avr.
        analog = re.sub(rf"^(gcc|clang)-{re.escape(series)}-", r"\1-", name)
        if analog == name:
            raise SystemExit(f"{name}: unversioned analog derivation no-op")
        claim = [analog]
    elif cross:
        arch = DEBIAN_ARCH.get(triplet)
        if arch is None:
            raise SystemExit(f"{name}: no Debian arch recorded for {triplet}")
        claim = [n for n in inventory
                 if re.fullmatch(GCC_PCR_RE % {"S": re.escape(series)} + "-" +
                                 re.escape(triplet), n)
                 or re.fullmatch(rf"gcc-{re.escape(series)}-(?:multilib-{re.escape(triplet)}"
                                 rf"|plugin-dev-{re.escape(triplet)})", n)
                 or n == f"libgcc-{series}-dev-{arch}-cross"]
    else:
        if name.startswith("clang"):
            claim = [n for n in inventory
                     if re.fullmatch(CLANG_PCR_RE % {"S": re.escape(series)}, n)]
        else:
            claim = [n for n in inventory
                     if re.fullmatch(GCC_PCR_RE % {"S": re.escape(series)}, n)
                     or re.fullmatch(rf"gcc-{re.escape(series)}-plugin-dev", n)
                     or n == f"libgcc-{series}-dev"]
    claim = sorted(set(claim) - {name})
    pcr_guard(name, claim)
    constraint = f"= {upstream}-0~ce{BUNDLE_REVISION}"
    return {"provides": {n: constraint for n in claim},
            "conflicts": claim, "replaces": claim}


def inventory_names(catalog: dict) -> dict[str, str]:
    """Every recorded Debian package name -> version, both suites."""
    out: dict[str, str] = {}
    for suite in catalog["debian"].values():
        for section in suite.values():
            out.update(section)
    return out


def dpkg_lt(a: str, b: str) -> bool:
    return subprocess.run(["dpkg", "--compare-versions", a, "lt", b],
                          check=False).returncode == 0


def version_order_violations(version: str, corpus: list[str]) -> list[str]:
    return [v for v in corpus if not dpkg_lt(version, v)]


# The versions a bundle must sort below: everything the catalog recorded for
# the same series shapes in sid/trixie, covering epochs (1:, 15:), +debNNuN,
# ~bpo, N-<date>-R snapshots, .crossN and vendor suffixes (+Atmel), plus the
# constructive fallback when the series is absent from both suites.
def version_corpus(series: str, upstream: str,
                   inventory: dict[str, str]) -> list[str]:
    shape = re.compile(rf"^(?:gcc|clang|libgcc|g\+\+)\S*-{re.escape(series)}"
                       rf"(?:$|-)")
    corpus = sorted({v for n, v in inventory.items() if shape.match(n)})
    corpus += [f"{series}-0", f"{series}.0.0-1", f"{upstream}-1"]
    return corpus


def bundle_depends(analysis: dict, *, gcobol: bool, cross_triplet: str | None
                   ) -> tuple[list[str], list[str], list[str]]:
    """(depends, unmatched_sonames, payload_internal_sonames)."""
    deps: set[str] = set()
    unmatched, internal = [], []
    for soname in analysis["needed"]:
        if soname in SONAME_PACKAGES:
            deps.add(SONAME_PACKAGES[soname])
        elif PAYLOAD_INTERNAL_SONAME_RE.match(soname):
            internal.append(soname)
        else:
            unmatched.append(soname)
    # A compiler without the C library headers cannot compile anything, and
    # Debian's own gcc-NN depends on libc6-dev for the same reason.
    deps.add("libc6-dev")
    # The libgcobol objects link unversioned libxml2; nothing but a COBOL link
    # would ever notice it missing (the gcc-17 incident), so presence gates it.
    if gcobol:
        deps.add("libxml2")
    if not analysis["has_binutils"]:
        deps.add(f"binutils-{cross_triplet}" if cross_triplet else "binutils")
    return sorted(deps), sorted(unmatched), sorted(internal)


def bin_universe(analysis: dict) -> set[str]:
    return set(analysis.get("bin", [])) | set(analysis.get("bin_links", {}))


def link_rule(tool: str, *, kind: str, series: str, catalog_triplet: str | None,
              payload_triplet: str | None) -> str:
    """The Debian-spelled link name one tool gets in this bundle's family."""
    if kind == "native":
        return f"{tool}-{series}"
    if kind == "cross":
        return f"{catalog_triplet}-{tool}-{series}"
    return f"{payload_triplet}-{tool}-{series}"


def plan_links(name: str, *, kind: str, family_kind: str, series: str,
               catalog_triplet: str | None, analysis: dict) -> dict:
    """Drive the link partition for one bundle.

    Returns links, launcher, link_exclusions, links_absent. Every bin/ name
    lands in links, launcher (both recorded as consumed) or an exclusion
    class; an unknown name fails the build naming itself.
    """
    universe = bin_universe(analysis)
    triplets = analysis.get("gcc_targets", [])
    pt = triplets[0] if len(triplets) == 1 else None
    upstream = analysis.get("gcc_version") or analysis.get("clang_version") or ""
    tools = CLANG_TOOLS if family_kind == "clang" else GCC_TOOLS
    driver = "clang" if family_kind == "clang" else "gcc"

    def candidates(tool: str) -> list[str]:
        if kind == "native":
            return [f"bin/{tool}", f"bin/{tool}-{upstream}",
                    f"bin/{HOST_TRIPLET}-{tool}"]
        return [f"bin/{pt}-{tool}", f"bin/{pt}-{tool}-{upstream}",
                f"bin/{tool}"]

    links: dict[str, str] = {}
    absent: dict[str, str] = {}
    consumed: set[str] = set()
    launcher: str | None = None
    for tool in tools:
        target = next((c for c in candidates(tool)
                       if c.removeprefix("bin/") in universe), None)
        if target is None:
            absent[tool] = "not shipped by this payload (era gap)"
            continue
        consumed.add(target.removeprefix("bin/"))
        if tool == driver:
            launcher = target
            if kind == "native":
                # The package name IS the driver's Debian spelling
                # (/usr/bin/gcc-16 points at bin/gcc); links carry the rest.
                continue
        links[link_rule(tool, kind=kind, series=series,
                        catalog_triplet=catalog_triplet,
                        payload_triplet=pt)] = target
    if launcher is None:
        raise SystemExit(f"{name}: no driver among the candidates of {driver!r} "
                         f"in the payload bin/ universe — cannot spell a launcher")
    # Cross and nodebian bundles alias /usr/bin/<pkgname> to the driver
    # through the launcher: their primary link is <triplet>-gcc-<series>,
    # and Debian's cross package does not own the short name.

    exclusions: dict[str, dict] = {}
    classifier_kind = "clang" if family_kind == "clang" else kind
    for n in sorted(universe - consumed):
        cls = classify_bin(n, kind=classifier_kind, triplets=triplets)
        if cls is None:
            raise SystemExit(
                f"{name}: payload bin/ name {n!r} has no link and no exclusion "
                "class — extend the rule tables deliberately (build.py)")
        exclusions[n] = {"class": cls, "reason": EXCLUSION_REASONS[cls]}
    return {"links": links, "launcher": launcher,
            "link_exclusions": exclusions, "links_absent": absent}


def load_bundle_inputs() -> tuple[dict, dict, dict]:
    catalog = json.loads(CATALOG.read_text())
    manifest = json.loads(MANIFEST.read_text())
    exceptions = (json.loads(EXCEPTIONS.read_text())
                  if EXCEPTIONS.exists() else {})
    return catalog, manifest, exceptions


def trunk_bundle_identity(fam: str, rec: dict, row: dict) -> tuple[str, str | None]:
    """deb name and triplet of a trunk family row. Names come off the family's
    own rename scheme; an unknown scheme shape fails loudly."""
    major = row["major"]
    scheme = rec["rename"]
    if scheme == "gcc-{major}-trunk{date}":
        return f"gcc-{major}", rec.get("triplet")
    if scheme == "clang-{major}-trunk{date}":
        return f"clang-{major}", rec.get("triplet")
    if scheme.startswith("gcc-{major}-trunk{date}-"):
        return f"gcc-{major}-{scheme[len('gcc-{major}-trunk{date}-'):]}", \
            rec.get("triplet")
    if fam == "riscv64-gcc-trunk":
        # The catalog records the host triplet here while the family names the
        # target; the rename scheme is the prefixed exception
        # (riscv64-gcc-{major}-trunk{date}).
        return f"gcc-{major}-riscv64-linux-gnu", "riscv64-linux-gnu"
    raise SystemExit(f"{fam}: no naming rule for rename scheme {scheme!r}")


def bundle_plans(catalog: dict, manifest: dict) -> tuple[dict[str, dict], int]:
    """(plans, pending_count). Every catalog compiler entry maps to exactly
    one bundle plan (emitted iff the mirror carries an analyzed row for it)."""
    rows = manifest["rows"]
    inventory = inventory_names(catalog)
    plans: dict[str, dict] = {}
    pending = 0

    def plan(name, *, family, series, regime, triplet, version, upstream,
             analysis, asset, sha, size, smoke) -> dict:
        cross = regime == "debian" and triplet is not None \
            and triplet != HOST_TRIPLET and not name.startswith("clang")
        family_kind = "clang" if name.startswith("clang") \
            or family.startswith("clang") else "gcc"
        kind = "native" if not cross and regime == "debian" else \
            "cross" if cross else "nodebian"
        lp = plan_links(name, kind=kind, family_kind=family_kind,
                        series=series, catalog_triplet=triplet,
                        analysis=analysis)
        deps, unmatched, internal = bundle_depends(
            analysis, gcobol=any("gcobol" in n for n in bin_universe(analysis)),
            cross_triplet=triplet if cross else None)
        pcr = pcr_sets(name, series=series, regime=regime, triplet=triplet,
                       cross=cross, upstream=upstream, inventory=inventory)
        corpus = version_corpus(series, upstream, inventory)
        bad = version_order_violations(version, corpus)
        if bad:
            raise SystemExit(f"{name}: version {version} does not sort below "
                             f"the recorded Debian corpus elements: {bad}")
        sibling = {"gcc": ("GNU Compiler Collection", "https://gcc.gnu.org",
                           "GPL-3.0-or-later with GCC Runtime Library Exception"),
                   "clang": ("Clang/LLVM compiler", "https://clang.llvm.org",
                             "Apache-2.0 with LLVM-exception")}[family_kind]
        return {
            "name": name, "state": "emit", "install": "bundle",
            "family": family, "series": series, "regime": regime,
            "triplet": triplet, "smoke": smoke,
            "version": version, "upstream_version": upstream,
            "pin": "defer",
            "payload": {
                "url": f"https://github.com/{manifest['meta']['repo']}/releases/"
                       f"download/{manifest['meta']['release']}/{asset}",
                "sha256": sha, "asset": asset, "size_bytes": size,
            },
            "launcher": lp["launcher"],
            "links": lp["links"],
            "link_exclusions": lp["link_exclusions"],
            "links_absent": lp["links_absent"],
            # Core payload-derived Depends only; the control writer appends
            # DEPENDS_RUNTIME plus the unpacker for every package alike.
            "depends": deps,
            "unmatched_sonames": unmatched,
            "payload_internal_sonames": internal,
            "pcr": pcr if pcr is not None else "none",
            "prefix": f"/opt/{name}",
            # tar counts RAW members; the analysis strip is over normalized
            # names, so a ./-prefixed payload needs one more component cut.
            "strip": analysis["root"]["strip"]
                     + (1 if analysis["root"].get("dot_prefix") else 0),
            "description": f"{sibling[0]} {upstream} ({asset}), built by "
                           "Compiler Explorer, mirrored by this repository",
            "homepage": sibling[1],
            "license": sibling[2],
        }

    for e in catalog["packaged"]:
        row = rows.get(e["asset"])
        if row is None or row.get("analysis") is None:
            pending += 1
            plans[e["name"]] = {
                "name": e["name"], "state": "pending: not yet mirrored",
                "install": "bundle", "family": e["family"],
                "series": e["series"], "regime": e["regime"],
                "triplet": e["triplet"], "version": None, "pin": "defer",
                "smoke": e["smoke"], "served": e["served"],
            }
            continue
        analysis = row["analysis"]
        upstream = e["version"] or analysis.get("gcc_version") \
            or analysis.get("clang_version")
        if not upstream:
            raise SystemExit(f"{e['name']}: no version from name or payload")
        probed = analysis.get("gcc_version") or analysis.get("clang_version")
        if e["version"] and probed and e["version"] != probed:
            raise SystemExit(f"{e['name']}: name carries {e['version']} but the "
                             f"payload probes {probed} — catalog/payload drift")
        version = f"{e['series']}~ce{upstream}-{BUNDLE_REVISION}"
        plans[e["name"]] = plan(
            e["name"], family=e["family"], series=e["series"],
            regime=e["regime"], triplet=e["triplet"], version=version,
            upstream=upstream, analysis=analysis, asset=row["asset"],
            sha=row["sha256"], size=row["size"], smoke=e["smoke"])

    for fam, rec in sorted(catalog["trunk_families"].items()):
        candidates = [r for r in rows.values()
                      if r.get("family") == fam and r.get("analysis")]
        if not candidates:
            pending += 1
            # The name needs a major; probe the catalog-recorded scheme with a
            # placeholder only for the pending record.
            plans[fam + " (trunk family)"] = {
                "name": fam, "state": "pending: not yet mirrored",
                "install": "bundle", "family": fam, "regime": rec["regime"],
                "triplet": rec.get("triplet"), "version": None, "pin": "defer",
                "smoke": rec["smoke"],
            }
            continue
        row = max(candidates, key=lambda r: r["date"])
        name, triplet = trunk_bundle_identity(fam, rec, row)
        analysis = row["analysis"]
        upstream = analysis.get("gcc_version") or analysis.get("clang_version")
        plans[name] = plan(
            name, family=fam, series=str(row["major"]), regime=rec["regime"],
            triplet=triplet, version=f"{row['major']}~trunk{row['date']}",
            upstream=upstream, analysis=analysis, asset=row["asset"],
            sha=row["sha256"], size=row["size"], smoke=rec["smoke"])
    return plans, pending


def wrapper_pin(spec: dict) -> str:
    if spec.get("defer_to_debian"):
        return "100"
    if spec.get("install") == "passthrough":
        return "500"
    return "600"


def pin_stanzas(specs: dict, repos: dict, plans: dict[str, dict]
                ) -> dict[str, list[str]]:
    """The three preference stanzas the bootstrap ships. The 100 stanza is the
    glob form covering the compiler namespace plus any enumerated name that
    escapes the globs; the 600 stanza keeps the enumerated wrapper form."""
    defer_wrappers = [n for n, s in specs.items() if s.get("defer_to_debian")]
    passthrough = [n for n, s in specs.items()
                   if s.get("install") == "passthrough"]
    pinned = [BOOTSTRAP, *(f"diamondinoia-repo-{n}" for n, r in repos.items()
                           if r.get("separate")),
              *(n for n in specs
                if n not in defer_wrappers and n not in passthrough)]
    globs = ["gcc-*", "clang-*"]
    compiler_names = sorted(n for n, p in plans.items() if "state" in p
                            and not n.endswith(" (trunk family)"))
    stray = [n for n in compiler_names
             if not any(fnmatch.fnmatchcase(n, g) for g in globs)]
    hundred = globs + sorted(set(stray) | set(defer_wrappers))
    return {"100": hundred, "500": sorted(passthrough), "600": sorted(pinned)}


def resolved_spec(specs: dict, repos: dict) -> dict:
    catalog, manifest, exceptions = load_bundle_inputs()
    plans, pending = bundle_plans(catalog, manifest)
    bundles = {}
    for name, plan in plans.items():
        if plan["state"] == "emit":
            bundles[name] = {
                **plan,
                # dump-spec shows the Depends list the deb will carry:
                # payload-derived core + runtime machinery + unpacker.
                "depends": plan["depends"] + DEPENDS_RUNTIME
                + [unpacker_dep(plan["payload"]["asset"], "bundle")],
            }
        else:
            bundles[name] = plan
    return {
        "meta": {
            "inputs": ["packages.toml", "catalog.json", "mirror-manifest.json",
                       "exceptions.json"],
            "exceptions_present": bool(exceptions),
            "pending_bundles": pending,
        },
        "exceptions": exceptions,
        "repos": repos,
        "pins": pin_stanzas(specs, repos, plans),
        "wrappers": {n: {**s, "pin": wrapper_pin(s), "version": None}
                     for n, s in specs.items()},
        "bundles": bundles,
    }


# --------------------------------------------------------------- selftest

def selftest() -> int:
    """Offline controls for the bundle rules. Every control is a real trip:
    the denylist poison, the version-order gate, the soname table and the
    gcc-17 28-linked / 45-excluded partition oracle from the README."""
    rc = 0

    def expect(name: str, cond: bool, detail: str = ""):
        nonlocal rc
        print(f"{'pass' if cond else 'FAIL'}  {name}"
              + (f" ({detail})" if detail else ""))
        if not cond:
            rc = 1

    # --- denylist poison: a computed claim touching the runtime/-base
    # denylist aborts the build naming the package. Tripped at the guard
    # itself — the claim shapes must never produce these names, so the guard
    # is what makes a careless shape edit fatal instead of silently shipped.
    try:
        pcr_guard("gcc-99", ["libstdc++6", "g++-99"])
        expect("pcr poison control: libstdc++6 claim aborts", False)
    except SystemExit as e:
        expect("pcr poison control: libstdc++6 claim aborts",
               "libstdc++6" in str(e), str(e))
    try:
        pcr_guard("gcc-99", ["gcc-99-base"])
        expect("pcr poison control: -base claim aborts", False)
    except SystemExit as e:
        expect("pcr poison control: -base claim aborts",
               "gcc-99-base" in str(e), str(e))
    pcr_guard("gcc-99", ["g++-99", "libgcc-99-dev"])  # a clean set passes
    clean = pcr_sets("gcc-16", series="16", regime="debian", triplet=None,
                     cross=False, upstream="16.2.0",
                     inventory={"g++-16": "16.2.0-2",
                                "libgcc-16-dev": "16.2.0-2"})
    expect("pcr clean set passes, self-name filtered, upstream constraint",
           clean == {"provides": {"g++-16": "= 16.2.0-0~ce1",
                                  "libgcc-16-dev": "= 16.2.0-0~ce1"},
                     "conflicts": ["g++-16", "libgcc-16-dev"],
                     "replaces": ["g++-16", "libgcc-16-dev"]}, str(clean))
    inv16 = inventory_names(json.loads(CATALOG.read_text()))
    n16 = pcr_sets("gcc-16", series="16", regime="debian", triplet=None,
                   cross=False, upstream="16.2.0", inventory=inv16)
    expect("gcc-16 pcr from the recorded inventory is deny-clean and "
           "non-vacuous", n16 and "g++-16" in n16["conflicts"], str(n16))

    # --- soname table: standard libc sonames can never be unmatched, payload
    # libs are internal, genuinely unknown ones land in unmatched
    deps, unmatched, internal = bundle_depends(
        {"needed": ["libc.so.6", "libm.so.6", "ld-linux-x86-64.so.2"],
         "has_binutils": True}, gcobol=False, cross_triplet=None)
    expect("glibc sonames are never unmatched",
           unmatched == [] and deps == ["libc6", "libc6-dev"], str(deps))
    deps, unmatched, internal = bundle_depends(
        {"needed": ["libclang.so.24.0git", "libc.so.6", "libfoo.so.9"],
         "has_binutils": False}, gcobol=True, cross_triplet=None)
    expect("payload-internal / unmatched / era extras partition",
           internal == ["libclang.so.24.0git"] and unmatched == ["libfoo.so.9"]
           and deps == ["binutils", "libc6", "libc6-dev", "libxml2"], str(deps))

    # --- version assembly + ordering gate over the real inventory
    v = version_corpus("16", "16.2.0", inv16)
    expect("16~ce16.2.0-1 sorts below the whole series-16 corpus",
           version_order_violations("16~ce16.2.0-1", v) == [],
           str(v[:4]))
    expect("ordering gate rejects a version inside the corpus",
           version_order_violations("16.2.0-2", v) != [])
    expect("4.9 trap: 4.9~ce4.9.4-1 < 4.9.2-10",
           dpkg_lt("4.9~ce4.9.4-1", "4.9.2-10"))
    expect("trunk form sorts below snapshots and true versions",
           dpkg_lt("17~trunk20260904", "17-20261001-1")
           and dpkg_lt("17~trunk20260904", "17.1.0-1"))

    # --- gcc-17 partition oracle: 28 linked + 45 excluded (27/15/1/2),
    # exactly the README's accounting
    catalog, manifest, _ = load_bundle_inputs()
    plans, pending = bundle_plans(catalog, manifest)
    p17 = plans.get("gcc-17")
    want_links = {f"{t}-17" for t in GCC_TOOLS} - {"gcc-17"}
    if not p17 or p17["state"] != "emit":
        expect("gcc-17 bundle is emittable off the reanalyzed rows", False,
               p17 and p17["state"] or "absent")
    else:
        from collections import Counter
        classes = Counter(x["class"] for x in p17["link_exclusions"].values())
        expect("gcc-17: 27 + launcher = 28 linked, 45 excluded 27/15/1/2",
               set(p17["links"]) == want_links
               and p17["launcher"] == "bin/gcc"
               and classes == {"bundled-binutils": 27, "triplet-alias": 15,
                               "no-series-spelling": 1, "go-libgo": 2},
               f"{len(p17['links'])} links, {dict(classes)}")
        expect("gcc-17: 73 bin/ executables accounted for",
               len(p17["links"]) + 1 + len(p17["link_exclusions"]) == 73)
    expect("the mirror gate leaves the pending remainder loud",
           pending > 200, str(pending))

    print("selftest:", "clean" if rc == 0 else "FAILURES above")
    return rc


def bootstrap(specs: dict, repos: dict, pins: dict[str, list[str]],
              key: str) -> None:
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

    # A machine that wants this repository at all wants a current llvm and gh,
    # so the sources that are not hardware-specific ride here rather than in a
    # package of their own.
    for repo, rspec in repos.items():
        if not rspec.get("separate"):
            add_repo(tree, repo, rspec)

    # The stanzas come from pin_stanzas: 600 = wrappers and repo packages,
    # 500 = passthrough (version-competes with the original publisher),
    # 100 = the compiler namespace globs (defer-to-Debian bundles) plus any
    # enumerated defer names. Anything left out of every stanza falls to the
    # -1 catch-all and stops being installable.
    # Pinned on the Release label, not the host, so the pin holds whatever the
    # repository is served from and never claims every package on github.com.
    (tree / f"etc/apt/preferences.d/{LABEL}").write_text(
        "Package: *\n"
        f"Pin: release l={LABEL}\n"
        "Pin-Priority: -1\n\n"
        f"Package: {' '.join(pins['600'])}\n"
        f"Pin: release l={LABEL}\n"
        "Pin-Priority: 600\n"
        + (f"\nPackage: {' '.join(pins['500'])}\n"
           f"Pin: release l={LABEL}\n"
           "Pin-Priority: 500\n" if pins["500"] else "")
        + (f"\nPackage: {' '.join(pins['100'])}\n"
           f"Pin: release l={LABEL}\n"
           "Pin-Priority: 100\n" if pins["100"] else "")
    )

    # 1.6 was the last published build that shipped the pin as a conffile, so
    # the bound is that version, not today's: rm_conffile on preinst removes an
    # untouched pin and moves a touched one to .dpkg-bak on every upgrade from
    # anything older. Removing it from the list is not enough: a machine whose
    # pin drifted would keep the drift across the upgrade, quietly vetoing
    # every later pin change. A bound of the current version would also make
    # this file differ on every build and ratchet the serial nightly.
    preinst = tree / "DEBIAN/preinst"
    preinst.write_text(
        "#!/bin/sh\n"
        f'dpkg-maintscript-helper rm_conffile "/etc/apt/preferences.d/{LABEL}" '
        f'"1.6~" "{BOOTSTRAP}" -- "$@"\n')
    preinst.chmod(0o755)
    conffiles(tree)
    # control has to exist before content_version reads the tree: missing on
    # one side and present on the other would read as a change on every build.
    # The Version line is where the computed version lands at the end, and is
    # stripped from both sides of the comparison.
    def control(version: str) -> str:
        return (
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
            " this repository to the packages it is meant to provide, together\n"
            " with the third-party sources a workstation needs anyway.\n"
        )
    (tree / "DEBIAN/control").write_text(control("0"))
    version = content_version(BOOTSTRAP, tree, key[-8:].lower(), FLOOR)
    (tree / "DEBIAN/control").write_text(control(version))
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
    # -n: gzip would otherwise embed the source mtime, and a rebuilt Packages
    # is a fresh file even when its bytes are identical.
    run(["gzip", "-9nkf", "Packages"], cwd=OUT)

    # Generate the Release OUTSIDE the tree: apt-ftparchive scans "." and the
    # shell's open("wb") on out/Release would be a file it reads while writing
    # it, hashing a partial self into the index (racy, pre-existing).
    fd, rel_tmp = tempfile.mkstemp(dir=ROOT, prefix=".Release.")
    with os.fdopen(fd, "wb") as f:
        run(["apt-ftparchive",
             "-o", "APT::FTPArchive::Release::Origin=diamondinoia",
             "-o", "APT::FTPArchive::Release::Label=diamondinoia",
             "-o", f"APT::FTPArchive::Release::Architectures={ARCH}",
             "release", "."],
            cwd=OUT, stdout=f)
    # apt-ftparchive stamps the wall clock into Date: (apt 3.3 does not honour
    # SOURCE_DATE_EPOCH, measured). Rewrite it so a rebuild over unchanged
    # inputs yields unchanged bytes; the signature below covers the result.
    # The pinned instant is the signing key's creation time: fixed for the
    # life of the key, and gpg refuses to sign earlier than the key exists
    # (epoch-0 fails a freshly generated key).
    key = os.environ.get("GPG_KEY_ID")
    if key:
        out = subprocess.run(["gpg", "--batch", "--list-keys",
                              "--with-colons", key],
                             capture_output=True, text=True, check=True).stdout
        stamp_epoch = next(int(l.split(":")[5]) for l in out.splitlines()
                           if l.startswith("pub:"))
    else:
        stamp_epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
    stamp = time.strftime("%a, %d %b %Y %H:%M:%S +0000",
                          time.gmtime(stamp_epoch))
    release = OUT / "Release"
    text = Path(rel_tmp).read_text()
    release.write_text(re.sub(r"^Date: .*$", f"Date: {stamp}", text,
                              count=1, flags=re.M))
    os.unlink(rel_tmp)

    if not key:
        print("GPG_KEY_ID unset, leaving the index unsigned")
        return
    # Signatures carry a creation time; pin it the same way for byte-stability.
    faked = ["--faked-system-time", str(stamp_epoch)]
    run(["gpg", "--batch", "--yes", "--default-key", key, *faked,
         "--clearsign", "-o", "InRelease", "Release"], cwd=OUT)
    run(["gpg", "--batch", "--yes", "--default-key", key, *faked,
         "-abs", "-o", "Release.gpg", "Release"], cwd=OUT)
    with (OUT / "KEY.gpg").open("wb") as f:
        run(["gpg", "--armor", "--export", key], stdout=f)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", action="append", help="build just these packages")
    parser.add_argument("--dump-spec", action="store_true",
                        help="print the merged resolved spec as canonical JSON "
                             "and exit (offline; the single test interface)")
    parser.add_argument("--selftest", action="store_true",
                        help="run the offline bundle-rule controls and exit")
    args = parser.parse_args()

    specs = tomllib.loads((ROOT / "packages.toml").read_text())
    repos = specs.pop("repos", {})

    if args.selftest:
        return selftest()

    catalog, manifest, _exceptions = load_bundle_inputs()
    plans, pending = bundle_plans(catalog, manifest)

    if args.dump_spec:
        print(json.dumps(resolved_spec(specs, repos), indent=2, sort_keys=True))
        return 0

    pins = pin_stanzas(specs, repos, plans)

    emittable = {n: p for n, p in plans.items() if p["state"] == "emit"}
    if args.only:
        specs = {k: v for k, v in specs.items() if k in args.only}
        emittable = {k: v for k, v in emittable.items() if k in args.only}

    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir()

    for name, spec in specs.items():
        info = resolve(name, spec)
        print(f"{name}: {info['version']}")
        if spec.get("install") == "passthrough":
            passthrough(name, info)
            continue
        # GitHub rewrites characters it dislikes in a release asset name, and
        # `~` becomes `.`, which leaves the index pointing at a name that 404s.
        # The version keeps its `~`; only the file name is spelled safely.
        deb = f"{name}_{info['version'].replace('~', '.')}_{ARCH}.deb"
        if not re.fullmatch(r"[A-Za-z0-9._+-]+", deb):
            raise SystemExit(f"{name}: {deb!r} has characters a release host may rewrite")
        build(name, spec, info, OUT / deb)

    for name in sorted(emittable):
        plan = emittable[name]
        p = plan["payload"]
        bspec = {
            "install": "tree",
            "strip": plan["strip"],
            "launcher": [plan["launcher"]],
            "links": plan["links"],
            "depends": ", ".join(plan["depends"]),
            "section": "devel",
            "homepage": plan["homepage"],
            "description": plan["description"],
            "license": plan["license"],
            "_pcr": plan["pcr"] if plan["pcr"] != "none" else None,
            "_body": " Extracts the Compiler Explorer payload into "
                     f"/opt/{name} from a staging sibling and checks it\n"
                     " against a pinned SHA-256. GCC payloads are GPL and the "
                     "mirror redistributes them; nothing is fetched from a\n"
                     " third-party bucket at install time.\n",
            # redistributed bytes: the mirror release is the publisher.
        }
        info = {"version": plan["version"], "url": p["url"],
                "source": p["asset"], "sha256": p["sha256"]}
        print(f"{name}: {info['version']} (bundle, {p['size_bytes'] >> 20} MiB "
              f"payload, {len(plan['links']) + 1} links "
              f"+ {len(plan['link_exclusions'])} excluded)")
        deb = f"{name}_{info['version'].replace('~', '.')}_{ARCH}.deb"
        if not re.fullmatch(r"[A-Za-z0-9._+-]+", deb):
            raise SystemExit(f"{name}: {deb!r} has characters a release host may rewrite")
        build(name, bspec, info, OUT / deb)
    if pending:
        print(f"{pending} catalog payloads not yet mirrored - skipped")
    if plans and not emittable and not args.only:
        raise SystemExit("the manifest carries no analyzed catalog row; zero "
                         "compiler bundles emitted — refusing an empty repo")

    key = os.environ.get("GPG_KEY_ID")
    if key:
        bootstrap(specs, repos, pins, key)
    for name, spec in repos.items():
        if spec.get("separate"):
            repo_package(name, spec)
    index()
    for p in sorted(OUT.iterdir()):
        print(f"  {p.stat().st_size:>10,}  {p.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
