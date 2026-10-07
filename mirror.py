#!/usr/bin/env python3
"""Mirror the Compiler Explorer catalog payloads onto the `mirror` release.

Moves payloads recorded in catalog.json (S1) from
s3.amazonaws.com/compiler-explorer/opt/ to this repository's `mirror` GitHub
release, once each, and records everything build.py (S3) later needs in
mirror-manifest.json. GCC is GPL and may be redistributed; Compiler Explorer
pays for its own S3 egress, which is the whole reason this file exists.

Modes and exit codes (S8's workflows map onto this contract):

  sync [--max N] [--dry-run] [payload ...]
      Mutating. Per trunk family: ghost cleanup, legacy adoption,
      reconciliation, rotation, pruning; then the same for stables.
      --dry-run prints the pruning plan and deletes nothing.
      Rotations to unseen dates and selector-named first pulls are the
      "new payloads" and --max N caps their CE downloads per run
      (default: unlimited). Reconciliation re-downloads of assets the
      release ALREADY serves are exempt from --max: they verify bytes
      already mirrored, and starving them would strand the
      release/manifest pair inconsistent (check would exit 1).
      Positional selectors (stable asset basenames and/or trunk family
      names) additionally restrict new-payload pulls to the named ones;
      housekeeping always runs. Exit 0 on success, 1 on operational
      error (failed upload, probe failure, missing upstream payload,
      release/manifest inconsistency, digest mismatch on an
      already-named asset).
  check [--complete]
      Verifies every mirrored row against the live release (asset
      present, state uploaded, size and GitHub sha256 digest match) and
      every mirrored STABLE against upstream S3 (size/ETag drift on an
      immutable stable = alarm). An uploaded release asset with no
      manifest row is unverifiable = alarm. Exit 0 when every mirrored
      row verifies (pending entries are printed and tolerated), 1 on
      any drift or unverifiable asset, 2 with --complete when a pending
      remainder exists (1 still beats 2).
  reanalyze-legacy [--include-stale]
      Read-only backfill: for each legacy row with analysis:null
      (--include-stale additionally: rows whose analysis predates the
      current analysis fields bin_links, target_bin, root.dot_prefix),
      its sha256 against the recorded digest (mismatch exits 1 naming
      the row), run the same analysis pipeline as first sync, and write
      the analysis with "analysis_source": "release". The legacy flag
      stays set: provenance is that these rows were adopted from
      release metadata, and now proved against the release bytes. Makes
      no mutating GitHub calls, so no pacing applies. With
      MIRROR_PAYLOAD_DIR set, a payload already on disk there replaces
      the download after the same digest gate (test/iteration hook).
  selftest
      Offline. Synthetic fixtures plus the committed catalog.json; no
      network, no release access. Positive controls: every mutated
      fixture must make the corresponding check FAIL. Exit 0 iff all
      pass.

Pacing (hard rule): at least 7.5 s between any two mutating GitHub calls
(upload AND delete), and HTTP 429/403 are retried honouring the server
backoff, because `gh` treats them as permanent and does not retry.
Exactly one release listing per run (a single `gh api repos/{repo}/
releases/tags/{tag}` GET), held in memory thereafter; never a re-list
per asset. Post-upload digest verification comes from the upload POST's
own JSON response, which GitHub populates with the asset's sha256 digest
(first attempt of this file proved all 110/110 assets embed inline on
the single-release GET, so no pagination path exists here).

Stables are immutable upstream: sha256+size+ETag are recorded at first
sync; later size/ETag drift is an exit-1 alarm, never an auto re-mirror.
Trunks rotate per family, asset renamed per
catalog.trunk_families[f].rename with the major probed from
the payload: gcc via lib/gcc/<target>/<ver>/, clang via
lib/clang/<major>/ (measured: lib/clang/24/ in the clang-trunk
payload). Matching of family members and extraction of {date}/{major}
goes through the family's OWN rename regex (named groups) — never a
positional or end-anchored date guess: 6 of the 9 rename schemes put
the triplet/arch after the date, where a date-anchored-at-end match
finds nothing and crashes (attempt 1, defect A). A new date
re-records the row without alarm; a dated payload is deleted only when
the published Packages index was fetched and verified against the
Release file's size and SHA256 for it, no package names it, it is
older than 14 days, and it is not the newest of its class in its
family; any doubt deletes nothing (fail safe). Raw dated leftovers
(mirror.sh-era `<family>-<8digits>.tar.xz`) follow this same rule as
renamed payloads; the renamed class and the raw class each protect
their own newest independently (the current build pins the newest
renamed payload before publication can name it).
Rows naming assets an external pass already pruned (the
mirror.sh-era nightly keeps its own window on main) are reaped at the
family pass — rotation never alarms, stables never reap. Retention
spans the whole renamed namespace of a family:
every asset matching the family's rename regex counts, whatever major
it carries. Release assets whose state is not "uploaded" are corrupt
leftovers (treated as absent for coverage, deleted during sync — they
422 on re-upload otherwise). Non-catalog assets are reported loudly.

RECONCILIATION (first run over the pre-existing release): the release
holds bytes this file never recorded. A manifest is rebuilt as follows.
Every asset matching a catalog stable name or a trunk family's rename
regex with no manifest row is re-downloaded from CE once and hashed;
if the hash equals the digest GitHub recorded for the asset, the full
first-sync row is written (analysis computed from those bytes, so every
row's analysis is proven against live bytes); a mismatch exits 1 naming
the asset. The only exceptions are the two mirror.sh-era nightlies
gcc-17-trunk20260903.tar.xz and gcc-17-trunk20260904.tar.xz: they are
ADOPTED with "legacy": true from release metadata only (name, size,
GitHub-reported sha256; size cross-checked against the catalog's
recorded bucket bytes), analysis: null until `reanalyze-legacy` proves
them against the digest-verified release bytes. Only those two names
auto-adopt.

Analysis runs at first sync, stream-only: the tarball is decompressed
in one pass with per-member reads via tarfile; peak disk = the one
downloaded tarball. The `analysis` field of each row records: root
layout (strip count, top dir, whether two-level <top>/<triplet>/
nesting applies), bin/ inventory (basenames of FILE members), bin/ LINK
inventory `bin_links` (basename -> {type: hardlink|symlink, target:
normalized target basename}; GNU tar stores the second occurrence of an
inode as a hardlink, so bin/gcc, bin/g++ and the binutils links hide
here — S3's link rules need the union of bin and bin_links keys, which
has_binutils/binutils_in_bin already count: a driver does not care how
a bin/ entry materialized), host ELF e_machine of a bin/ member (stdlib
struct parse; CE hosts are all x86-64), the union of DT_NEEDED sonames
across bin/ executables (ELF section-header walk, no external deps; the
machine has no pyelftools), has_binutils (ld/as/ar in the bin/
universe), multilib dirs (lib32/lib64/libx32 under root), the libgo
soname if present, the gcc/clang version probed from lib paths
(required for catalog version_source:"payload" keys: the at12/at13
families), and the target-side e_machine read from the payload's own
crt/libc bytes (k1's EM_KVARC assumption resolved to 4919/0x1337 and
vax to 75, both from payload bytes). `bin_links` is absent on rows
analyzed before the field existed; reanalyze-legacy --include-stale
backfills them from digest-verified release bytes and asserts the old
fields reproduce exactly.

mirror-manifest.json schema (canonical JSON: indent=2, sort_keys,
trailing newline; this file is the sole writer; byte-stable when
nothing changed):

  meta     {bucket, release, repo, schema} — constants of the writer
  rows     dict keyed by upstream payload basename (catalog `asset`
           for stables, the dated bucket basename for trunks). Row:
             kind      stable | trunk | legacy
             asset     release asset name (== row key for stables)
             key       upstream bucket key (null for legacy rows whose
                       dated key left the bucket window)
             size      payload bytes
             sha256    payload sha256; equals the digest GitHub reports
             etag      upstream ETag at first sync (stables/trunks only)
             family/date/major   trunk rows (major parsed from the
                                 name for legacy rows)
             legacy    true on adopted rows
             analysis  as above; null on legacy rows

Env overrides (test hooks): MIRROR_REPO (default GITHUB_REPOSITORY or
DiamonDinoia/apt), MIRROR_RELEASE (default mirror), MIRROR_MANIFEST,
MIRROR_CATALOG. gh must be authenticated. Requires python >= 3.11,
stdlib only. Supersedes mirror.sh.
"""

from __future__ import annotations

import datetime
import hashlib
import io
import json
import os
import re
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).parent
CATALOG = Path(os.environ.get("MIRROR_CATALOG", ROOT / "catalog.json"))
MANIFEST = Path(os.environ.get("MIRROR_MANIFEST", ROOT / "mirror-manifest.json"))
REPO = os.environ.get("MIRROR_REPO") or os.environ.get("GITHUB_REPOSITORY") or "DiamonDinoia/apt"
RELEASE = os.environ.get("MIRROR_RELEASE", "mirror")

BUCKET = "https://s3.amazonaws.com/compiler-explorer/"
PREFIX = "opt/"
S3_NS = "{http://s3.amazonaws.com/doc/2006-03-01/}"
UA = {"User-Agent": "diamondinoia-apt mirror"}

PACE_SECONDS = 7.5   # between any two mutating GitHub calls
KEEP_DAYS = 14      # dated assets younger than this are never pruned
TIMEOUT = 300

INDEX_URL = (f"https://github.com/{REPO}/releases/download/repo/")
# build.py's index() writes the `repo` release: Packages plus a Release
# file whose SHA256 stanza carries the Packages size and hash — the
# integrity metadata the prune's index fetch is verified against.

# The only auto-adopted names: mirror.sh uploaded these two with no
# committed ground truth. Everything else with no manifest row is
# re-download-verified against CE bytes.
LEGACY_ADOPT = ("gcc-17-trunk20260903.tar.xz", "gcc-17-trunk20260904.tar.xz")

# e_machine values relevant to the catalog's families; the number is the
# record, this table is only the human-readable gloss.
EM_NAMES = {3: "i386", 4: "m68k", 8: "mips", 15: "parisc", 18: "sparc32plus",
            20: "powerpc", 21: "powerpc64", 22: "s390", 40: "arm", 42: "sh",
            43: "sparc64", 44: "tricore", 62: "x86-64", 75: "vax", 83: "avr",
            105: "msp430", 140: "tic6x", 183: "aarch64", 214: "kvarc",
            243: "riscv", 247: "bpf", 258: "loongarch", 4919: "kvarc"}


# ------------------------------------------------------------ small IO

def fetch(url: str, timeout: int = TIMEOUT) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def http_head(url: str) -> dict | None:
    """size+etag of a payload, None when the key is gone."""
    req = urllib.request.Request(url, method="HEAD", headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return {"size": int(r.headers["Content-Length"]),
                    "etag": r.headers.get("ETag", "")}
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def s3_prefix_listing(prefix: str) -> dict[str, dict]:
    """All keys under one bucket prefix: key -> {bytes, modified}."""
    out: dict[str, dict] = {}
    start_after: str | None = None
    while True:
        url = f"{BUCKET}?list-type=2&prefix=" + urllib.parse.quote(prefix)
        if start_after is not None:
            url += "&start-after=" + urllib.parse.quote(start_after)
        root = ET.fromstring(fetch(url, timeout=60))
        for c in root.findall(S3_NS + "Contents"):
            key = c.find(S3_NS + "Key").text
            out[key] = {"bytes": int(c.find(S3_NS + "Size").text),
                        "modified": c.find(S3_NS + "LastModified").text}
        if root.find(S3_NS + "IsTruncated").text != "true":
            return out
        start_after = next(reversed(out))


_last_mutation = [0.0]


def pace() -> None:
    wait = PACE_SECONDS - (time.monotonic() - _last_mutation[0])
    if wait > 0:
        print(f"  pace: {wait:.1f}s between mutating GitHub calls")
        time.sleep(wait)
    _last_mutation[0] = time.monotonic()


def gh(args: list[str], mutating: bool = False, stdin: str | None = None,
       retries: int = 3) -> str:
    """Run gh, pacing mutations and honouring 429/403 backoff ourselves:
    gh treats them as permanent and does not retry."""
    for attempt in range(retries + 1):
        if mutating:
            pace()
        p = subprocess.run(["gh"] + args, input=stdin, capture_output=True, text=True)
        if p.returncode == 0:
            return p.stdout
        wait = None
        m = re.search(r"HTTP (429|403)\b", p.stderr + p.stdout)
        if m:
            r = re.search(r"(?i)retry[- ]after\D*(\d+)", p.stderr + p.stdout)
            wait = max(60, int(r.group(1))) if r else 60
        if wait is None or attempt == retries:
            raise RuntimeError(f"gh {' '.join(args)} failed:\n{p.stderr.strip()}")
        print(f"  gh got HTTP {m.group(1)}; backing off {wait}s "
              f"(attempt {attempt + 1}/{retries})", file=sys.stderr)
        time.sleep(wait)
    raise AssertionError("unreachable")


# ------------------------------------------------------- release access
#
# Exactly one listing per run: the single-release GET embeds the full
# assets array (proven uncapped past 100 on the mirror-scratch release
# by the first attempt of this file: 110/110 inline) and the release id
# that upload/delete URLs are built from.

def get_release(repo: str, tag: str) -> dict | None:
    p = subprocess.run(["gh", "api", f"repos/{repo}/releases/tags/{tag}"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        if "404" in p.stderr or "Not Found" in p.stderr:
            return None
        raise RuntimeError(f"gh api release lookup failed:\n{p.stderr.strip()}")
    return json.loads(p.stdout)


def release_create(repo: str, tag: str) -> dict:
    body = json.dumps({
        "tag_name": tag, "name": "payload mirror",
        "body": "Upstream payloads re-hosted under a licence that permits it, "
                "so the publisher is downloaded from once per version. "
                "Do not delete."})
    return json.loads(gh(["api", f"repos/{repo}/releases", "-X", "POST",
                          "--input", "-"], mutating=True, stdin=body))


def split_assets(release: dict | None) -> tuple[dict[str, dict], list[dict]]:
    """(uploaded assets by name, ghost assets). state != uploaded = ghost:
    a corrupt leftover, absent for coverage, deleted during sync."""
    assets = (release or {}).get("assets", [])
    uploaded = {a["name"]: a for a in assets if a.get("state") == "uploaded"}
    ghosts = [a for a in assets if a.get("state") != "uploaded"]
    return uploaded, ghosts


def upload_asset(release_id: int, path: Path, name: str) -> dict:
    """POST the file as raw octet-stream; the response JSON carries the
    sha256 digest GitHub computed, which is the post-upload verification
    (no re-listing needed). Asset uploads live on uploads.github.com, not
    api.github.com (the latter 404s)."""
    out = gh(["api", f"https://uploads.github.com/repos/{REPO}/releases/"
              f"{release_id}/assets?name=" + urllib.parse.quote(name), "-X", "POST",
              "-H", "Content-Type: application/octet-stream",
              "--input", str(path)], mutating=True)
    return json.loads(out)


def delete_asset(asset_id: int, name: str) -> None:
    try:
        gh(["api", f"repos/{REPO}/releases/assets/{asset_id}", "-X", "DELETE"],
           mutating=True)
    except RuntimeError as e:
        if "404" in str(e):
            print(f"  delete {name}: already gone (404 tolerated)")
            return
        raise


# -------------------------------------------------------------- ELF I/O

def parse_elf(data: bytes) -> dict | None:
    """e_machine + DT_NEEDED sonames from ELF bytes, stdlib only.

    Section headers locate .dynamic and its string table (sh_link), so no
    virtual-address translation is needed. None for non-ELF input."""
    if len(data) < 64 or data[:4] != b"\x7fELF":
        return None
    klass, enc = data[4], data[5]
    if klass not in (1, 2) or enc not in (1, 2):
        return None
    e = "<" if enc == 1 else ">"
    if klass == 2:
        f = struct.unpack_from(e + "HHIQQQIHHHHHH", data, 16)
        sfmt, ssize, dfmt, dsize = e + "IIQQQQIIQQ", 64, e + "qQ", 16
    else:
        f = struct.unpack_from(e + "HHIIIIIHHHHHH", data, 16)
        sfmt, ssize, dfmt, dsize = e + "IIIIIIIIII", 40, e + "iI", 8
    emachine, shoff, shentsize, shnum = f[1], f[5], f[10], f[11]
    needed: list[str] = []

    def section(i: int):
        off = shoff + i * shentsize
        if off < 0 or off + ssize > len(data):
            return None
        v = struct.unpack_from(sfmt, data, off)
        return {"type": v[1], "offset": v[4], "size": v[5], "link": v[6]}

    if shoff and shentsize >= ssize:
        if shnum == 0xFFFF:  # extended numbering: real count in sh_size of #0
            s0 = section(0)
            shnum = s0["size"] if s0 else 0
        for i in range(min(shnum, 65536)):
            s = section(i)
            if not s or s["type"] != 6:  # SHT_DYNAMIC
                continue
            strs = section(s["link"]) if 0 <= s["link"] < shnum else None
            if not strs or strs["offset"] + strs["size"] > len(data):
                continue
            base, limit = strs["offset"], strs["offset"] + strs["size"]
            for j in range(min(s["size"] // dsize, 4096)):
                tag, val = struct.unpack_from(dfmt, data, s["offset"] + j * dsize)
                if tag == 0:  # DT_NULL
                    break
                if tag == 1 and base + val < limit:  # DT_NEEDED
                    end = data.find(b"\0", base + val, limit)
                    if end != -1:
                        needed.append(data[base + val:end].decode("ascii", "replace"))
            break
    return {"emachine": emachine, "klass": klass, "needed": needed}


# --------------------------------------------------- tarball analysis

GCC_VER_RE = re.compile(r"(?:^|/)lib/gcc/([^/]+)/([0-9][^/]*)/")
CLANG_VER_RE = re.compile(r"(?:^|/)lib/clang/([0-9][^/]*)/")
# A target-side ELF to read the toolchain's target e_machine from: the
# payload bytes are the ground truth (k1's assumed EM_KVARC=214 resolved
# to 4919/0x1337 and vax's to 75, both read off the payloads).
TARGET_ELF_RE = re.compile(r"/(crt[^/]*\.o|lib(c|stdc\+\+|go|gcc_s)\.so[^/]*)$")
MULTILIB_DIRS = ("lib32", "lib64", "libx32")
BINUTILS = ("ar", "as", "ld")


def analyze_tarball(path: Path) -> dict:
    """One decompression pass; per-member reads. Peak disk = the tarball."""
    names: dict[str, dict] = {}
    links: dict[str, dict] = {}
    host_elf: dict | None = None
    needed: set[str] = set()
    target_emachine: int | None = None
    dot_prefix = False
    with tarfile.open(path, "r|*") as tar:
        for m in tar:
            name = m.name
            if name.startswith("./"):
                dot_prefix = True
            while name.startswith("./"):
                name = name[2:]
            if not name:
                continue
            if m.issym() or m.islnk():
                # Link members carry no bytes, but they are half of the
                # bin/ namespace a user sees: GNU tar stores the second
                # occurrence of an inode as a hardlink, so bin/gcc, bin/g++
                # and the binutils aliases only ever appear here.
                links[name] = {"type": "symlink" if m.issym() else "hardlink",
                               "target": (m.linkname or "").removeprefix("./")
                                       .rstrip("/").rsplit("/", 1)[-1]}
                names.setdefault(name, {"file": False})
                continue
            if not m.isfile():
                # Real tarballs carry DIRECTORY members besides. They restate
                # prefixes the file paths already give; only FILE entries
                # drive the root walk, the bin/ file inventory and the ELF
                # reads.
                names.setdefault(name, {"file": False})
                continue
            names[name] = {"file": True, "exec": bool(m.mode & 0o111)}
            if ("/bin/" in name or name.startswith("bin/")) and m.mode & 0o111:
                elf = parse_elf(tar.extractfile(m).read())
                if elf is not None:
                    needed.update(elf["needed"])
                    if host_elf is None:
                        host_elf = elf
            elif target_emachine is None and TARGET_ELF_RE.search(name):
                elf = parse_elf(tar.extractfile(m).read(64))
                if elf is not None:
                    target_emachine = elf["emachine"]

    if not names:
        raise ValueError(f"{path.name}: empty tarball")
    parts = {n: n.split("/") for n in names}
    # The payload root is the longest run of leading directory components
    # shared by every FILE entry.
    seqs = [p[:-1] for n, p in parts.items() if names[n]["file"]]
    strip = 0
    if seqs:
        while True:
            if strip >= min(len(s) for s in seqs):
                break
            comp = seqs[0][strip]
            if all(s[strip] == comp for s in seqs):
                strip += 1
            else:
                break
    bins = sorted({p[-1] for n, p in parts.items()
                   if len(p) == strip + 2 and p[strip] == "bin" and names[n]["file"]})
    bin_links = {p[-1]: links[n] for n, p in parts.items()
                 if len(p) == strip + 2 and p[strip] == "bin" and n in links}
    # A gcc-style payload also bundles its target binutils one level deeper:
    # <prefix>/<target>/bin/{as,ld,...}, on the driver's own search path. crosstool
    # cross payloads are the extreme case: bin/ holds only triplet-prefixed
    # drivers and every real binutils entry lives down here.
    target_bin = sorted({p[-1] for n, p in parts.items()
                         if len(p) == strip + 3 and p[strip + 1] == "bin"
                         and (names[n]["file"] or n in links)})
    # The bin/ universe a user sees = file entries + link entries. binutils
    # presence is judged over the universe and the target bin: a hardlinked ld
    # assembles as well as a stored one.
    universe = set(bins) | set(bin_links)
    has_binutils = all(b in universe for b in BINUTILS) or (
        {"ar", "as"} <= set(target_bin)
        and bool({"ld", "ld.bfd"} & set(target_bin)))
    multilib = sorted({p[strip] for n, p in parts.items()
                       if len(p) > strip + 1 and p[strip] in MULTILIB_DIRS})
    libgo = sorted({p[-1] for p in parts.values()
                    if re.fullmatch(r"libgo\.so\.\d+", p[-1])})
    gcc_vers = sorted({(m.group(2), m.group(1)) for n in names
                       if (m := GCC_VER_RE.search(n))})
    gcc_versions = sorted({v for v, _t in gcc_vers})
    clang_vers = sorted({m.group(1) for n in names if (m := CLANG_VER_RE.search(n))})
    if len(gcc_versions) > 1 or len(clang_vers) > 1:
        raise ValueError(f"{path.name}: no single gcc/clang version under lib/ "
                         f"(gcc {gcc_versions}, clang {clang_vers}); "
                         "refusing to guess the payload")
    return {
        "bin": bins,
        "bin_links": bin_links,
        "binutils_in_bin": [b for b in BINUTILS if b in universe],
        "target_bin": target_bin,
        "clang_version": clang_vers[0] if clang_vers else None,
        "gcc_targets": sorted({t for _v, t in gcc_vers}),
        "gcc_version": gcc_versions[0] if gcc_versions else None,
        "has_binutils": has_binutils,
        "host_arch": EM_NAMES.get(host_elf["emachine"], "unknown") if host_elf else None,
        "host_emachine": host_elf["emachine"] if host_elf else None,
        "libgo_soname": libgo[-1] if libgo else None,
        "multilib": multilib,
        "needed": sorted(needed),
        # dot_prefix: raw member names carry a leading ./ (GNU tar style).
        # strip counts NORMALIZED names, so a tar --strip-components=N for the
        # raw members needs strip + dot_prefix.
        "root": {"dot_prefix": dot_prefix,
                 "nested": (seqs[0][1] if seqs and strip >= 2 else None),
                 "strip": strip,
                 "top": (seqs[0][0] if seqs and strip >= 1 else "")},
        "target_arch": (EM_NAMES.get(target_emachine, "unknown")
                        if target_emachine is not None else None),
        "target_emachine": target_emachine,
    }


def probe_major(analysis: dict, family: str, payload: str) -> int:
    version = analysis["clang_version"] if family.startswith("clang") \
        else analysis["gcc_version"]
    if version is None or not version.split(".")[0].isdigit():
        raise ValueError(f"{payload}: no single {family} major probeable from "
                         "the payload (mirror.sh parity: fail loudly)")
    return int(version.split(".")[0])


def check_version_source(entry: dict, analysis: dict) -> str | None:
    """A version_source:"payload" catalog key is versionless by name; the
    payload must carry the gcc version under lib/gcc/ (at12/at13 class)."""
    if entry.get("version_source") == "payload" and not analysis["gcc_version"]:
        return (f"{entry['asset']}: version_source=payload but no lib/gcc "
                "version probed")
    return None


def sha256_path(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(key: str, dest: Path) -> None:
    req = urllib.request.Request(BUCKET + key, headers=UA)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r, open(dest, "wb") as f:
        while chunk := r.read(4 << 20):
            f.write(chunk)


def download_url(url: str, dest: Path) -> None:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r, open(dest, "wb") as f:
        while chunk := r.read(4 << 20):
            f.write(chunk)


# ------------------------------------------------- trunk family helpers

RAW_KEY_RE = r"-\d{8}\.tar\.xz"  # undated leftover shape: <family>-<8digits>


def rename_regex(scheme: str) -> re.Pattern:
    rx = re.escape(scheme).replace(r"\{major\}", r"(?P<major>\d+)") \
                           .replace(r"\{date\}", r"(?P<date>\d{8})")
    return re.compile("^" + rx + r"\.tar\.xz$")


def rename_render(scheme: str, major: int, date: str) -> str:
    return scheme.replace("{major}", str(major)).replace("{date}", date) + ".tar.xz"


def dated_prefix_listing(family: str) -> dict[str, str]:
    """date -> bucket key for one trunk family's live dated keys."""
    rx = re.compile("^" + PREFIX + re.escape(family) + r"-(\d{8})\.tar\.xz$")
    out = {}
    for key in s3_prefix_listing(PREFIX + family + "-"):
        m = rx.match(key)
        if m:
            out[m.group(1)] = key
    return out


def referenced_payloads(text: str) -> set[str]:
    """Payload asset names the published Packages index names. The deb
    stanzas carry the pinned payload asset in the Description field, so a
    scan for .tar.xz tokens is the full set prune must never delete. Call
    it only on an index fetch_referenced_payloads verified."""
    return set(re.findall(r"[A-Za-z0-9][A-Za-z0-9._+~-]*\.tar\.xz", text))


def fetch_referenced_payloads(base: str = INDEX_URL,
                              opener=urllib.request.urlopen) -> set[str] | None:
    """Live published index's referenced payloads; None on any failure
    (callers fail safe: prune nothing that run). The `repo` release's
    Release file carries the size and SHA256 of Packages: Packages is
    trusted only when its bytes match both, so a truncated, corrupt or
    swapped body can never arm a prune. One exception net covers both
    fetches (Exception covers URLError, HTTPError, IncompleteRead,
    ValueError, UnicodeDecodeError)."""
    def get(suffix: str) -> bytes:
        with opener(urllib.request.Request(base + suffix, headers=UA),
                    timeout=TIMEOUT) as r:
            return r.read()
    try:
        rel = get("Release").decode("utf-8")
        m = re.search(r"(?m)^SHA256:\n((?: .+\n)+)", rel)
        if m is None:
            raise ValueError("no SHA256 section in Release")
        m2 = re.search(r"(?m)^ ([0-9a-f]{64}) +(\d+) +Packages$", m.group(1))
        if m2 is None:
            raise ValueError("no SHA256 entry for Packages in Release")
        expected_sha, expected_size = m2.group(1), int(m2.group(2))
        raw = get("Packages")
        if len(raw) != expected_size:
            raise ValueError(f"Packages is {len(raw)} bytes, Release says "
                             f"{expected_size}")
        if hashlib.sha256(raw).hexdigest() != expected_sha:
            raise ValueError("Packages SHA256 does not match Release")
        return referenced_payloads(raw.decode("utf-8"))
    except Exception as e:
        print(f"prune: cannot fetch and verify the published index {base}: "
              f"{e}; deleting nothing this run", file=sys.stderr)
        return None


def prune_plan(dated_assets: list[str], rx: re.Pattern,
               referenced: set[str], today: str,
               keep_names: set[str] | None = None,
               keep_days: int = KEEP_DAYS) -> list[str]:
    """Release asset names of one family that may be deleted, oldest first.
    An asset is deleted only when the verified published Packages index
    does not name it, it is at least `keep_days` old, and it is not in
    `keep_names` (the family's newest asset: the current build pins it
    before publication can name it). Dates are yyyymmdd, so string
    arithmetic orders them. Each asset's date comes from the FAMILY's
    rename regex named group — never a positional/end-anchored guess: 6
    of the 9 schemes carry text after the date, where an anchored guess
    finds nothing. Every member must match rx: a foreign asset in the
    plan is a caller bug and must fail loudly."""
    keep = keep_names or set()
    def dateof(name: str) -> str:
        m = rx.match(name)
        if not m:
            raise ValueError(f"prune plan got {name!r}, not in scheme {rx.pattern!r}")
        return m["date"]
    # The family/scheme match runs before any keep short-circuit: a
    # foreign name is a caller bug and must fail loudly even when
    # referenced or keep_names would have protected it.
    for n in dated_assets:
        dateof(n)
    cutoff = (datetime.date(int(today[:4]), int(today[4:6]), int(today[6:8]))
              - datetime.timedelta(days=keep_days)).strftime("%Y%m%d")
    return sorted((n for n in dated_assets
                   if n not in referenced and n not in keep
                   and dateof(n) <= cutoff),
                  key=dateof)


def build_prune_plan(catalog: dict, uploaded: dict, referenced: set[str],
                     today: str,
                     live_dates: dict[str, dict]) -> dict[str, list[str]]:
    """Family -> asset names deletion may take, from one verified index
    read. The ONE plan `sync --dry-run` prints and normal sync executes,
    so the two can never disagree. The newest dated asset of each class of
    each family (the renamed class, which the build consumes, and the raw
    dated leftovers) is never planned away: the current build pins the
    newest renamed payload before publication can name it. Caller never
    passes referenced=None: an unread index deletes nothing. A family
    absent from live_dates (no dated keys upstream this run) is skipped:
    its sync pass errored and prunes nothing, so the plan must not name
    it either."""
    plan: dict[str, list[str]] = {}
    for fam in sorted(catalog["trunk_families"]):
        if fam not in live_dates:
            continue
        rec = catalog["trunk_families"][fam]
        rx = rename_regex(rec["rename"])
        raw_rx = re.compile("^" + re.escape(fam) + r"-(?P<date>\d{8})\.tar\.xz$")
        dated = [n for n in uploaded if rx.match(n)]
        raw = [n for n in uploaded if raw_rx.match(n)]
        # Every asset at its class's max date is protected, whatever its
        # age and whether the index names it. The renamed class (the one
        # the build consumes) and the raw class protect independently: a
        # newer raw leftover must not leave the newest RENAMED payload
        # deletable.
        keep = set()
        for names in (dated, raw):
            if names:
                newest = max((rx.match(m) or raw_rx.match(m))["date"]
                             for m in names)
                keep |= {n for n in names
                         if (rx.match(n) or raw_rx.match(n))["date"]
                         == newest}
        drops = prune_plan(dated, rx, referenced, today, keep_names=keep)
        # Raw dated leftovers (mirror.sh-era <family>-<yyyymmdd>) answer to
        # the same rule: index verified, unnamed, old, not its class newest.
        drops += prune_plan(raw, raw_rx, referenced, today, keep_names=keep)
        plan[fam] = sorted(drops)
    return plan


def reap_orphaned_trunk_rows(rows: dict, fam: str, uploaded: dict) -> list[str]:
    """Drop one nightly family's rows whose asset already left the release.

    Retention pruning deletes a dated asset and its rows only when no
    package in the live published index names it and it is older than
    14 days, and only when THIS process does the pruning. When another pass
    pruned first (the mirror.sh-era nightly on main still slides its own
    window, or an interrupted run died between the delete and its manifest
    commit), this copy's rows still name the gone assets and nothing else
    reaps them: check would alarm rc 1 on them forever. For the nightly
    class a vanished asset is expected rotation — re-record by dropping
    the row, without alarm. Stables are untouchable: a stable row carries
    no family, never reaps, and its vanished asset stays drift."""
    gone = sorted(rk for rk, r in rows.items()
                  if r.get("family") == fam and r["asset"] not in uploaded)
    for rk in gone:
        del rows[rk]
    return gone


# --------------------------------------------------------- verification

def verify_rows(rows: dict, uploaded: dict[str, dict], head=None) -> list[str]:
    """Every mirrored row against release state (+ upstream drift for
    stables when a head(key) fetcher is given)."""
    problems = []
    for b, row in sorted(rows.items()):
        a = uploaded.get(row["asset"])
        if a is None:
            problems.append(f"{b}: mirrored asset {row['asset']} absent from "
                            "the release or not in uploaded state")
            continue
        if a["size"] != row["size"]:
            problems.append(f"{b}: size drift: release {a['size']} != recorded "
                            f"{row['size']}")
        digest = (a.get("digest") or "").removeprefix("sha256:")
        if digest != row["sha256"]:
            problems.append(f"{b}: digest drift: release {a.get('digest')!r} != "
                            f"recorded sha256:{row['sha256']}")
        if row["kind"] == "stable" and head is not None and row.get("key"):
            live = head(row["key"])
            if live is None:
                problems.append(f"{b}: upstream key {row['key']} vanished "
                                "(stable payloads are immutable; catalog drift?)")
            elif live["size"] != row["size"]:
                problems.append(f"{b}: UPSTREAM size drift: S3 {live['size']} "
                                f"!= recorded {row['size']} (immutable stable)")
            elif row.get("etag") and live["etag"] != row["etag"]:
                problems.append(f"{b}: UPSTREAM ETag drift: S3 {live['etag']} "
                                f"!= recorded {row['etag']} (immutable stable)")
    return problems


def pending_payloads(catalog: dict, rows: dict,
                     trunk_latest: dict[str, str] | None = None) -> list[str]:
    """Catalog payloads without a manifest row. trunk_latest maps family ->
    latest live date; trunks are pending per family rotation, stables per
    asset basename."""
    pending = []
    for e in catalog["packaged"]:
        if e["asset"] not in rows:
            pending.append(e["asset"])
    for fam in sorted(catalog["trunk_families"]):
        if trunk_latest is not None and fam in trunk_latest:
            if f"{fam}-{trunk_latest[fam]}.tar.xz" not in rows:
                pending.append(f"{fam}-{trunk_latest[fam]}.tar.xz (trunk pending)")
        elif not any(r.get("family") == fam for r in rows.values()):
            pending.append(f"{fam} (trunk family, state unknown here)")
    return pending


def check_decision(problems: list[str], pending: list[str], complete: bool) -> int:
    if problems:
        return 1
    if complete and pending:
        return 2
    return 0


# ------------------------------------------------------------ manifest

def manifest_meta() -> dict:
    return {"bucket": BUCKET + PREFIX,
            "release": RELEASE,
            "repo": REPO,
            "schema": 1}


def load_manifest() -> dict:
    if MANIFEST.exists():
        m = json.loads(MANIFEST.read_text())
        if m.get("meta", {}).get("schema") != 1 or "rows" not in m:
            raise SystemExit(f"{MANIFEST}: not a schema-1 mirror manifest")
        return m
    return {"meta": manifest_meta(), "rows": {}}


def save_manifest(m: dict) -> None:
    data = json.dumps(m, indent=2, sort_keys=True) + "\n"
    if MANIFEST.exists() and MANIFEST.read_text() == data:
        return  # byte-stable: nothing changed
    tmp = MANIFEST.with_suffix(".tmp")
    tmp.write_text(data)
    os.replace(tmp, MANIFEST)


# ---------------------------------------------------------------- sync
#
# Non-catalog names on the release fall into exactly one of these classes
# (sync acts on each as marked; an asset classed "unknown" is only ever
# reported):
#   stable            catalog packaged asset basename (verbatim key)
#   trunk-renamed     matches a family's rename regex (dated, major-suffixed)
#   trunk-raw         undated <family>-<8digits>.tar.xz pre-rename leftover
#   legacy            the two names in LEGACY_ADOPT (a trunk-renamed subset)

def classify_asset(name: str, catalog: dict) -> tuple[str, dict | None]:
    """One release asset name -> (class, family record or None)."""
    for fam, rec in catalog["trunk_families"].items():
        rx = rename_regex(rec["rename"])
        if rx.match(name):
            if name in LEGACY_ADOPT:
                return "legacy", {"family": fam, "rename": rec["rename"], "rx": rx}
            return "trunk-renamed", {"family": fam, "rename": rec["rename"], "rx": rx}
    if any(re.fullmatch(re.escape(f) + RAW_KEY_RE, name)
           for f in catalog["trunk_families"]):
        return "trunk-raw", None
    return "unknown", None


def round_robin(entries: list[dict]) -> list[dict]:
    """Stables newest-first within each family, interleaved across families
    so any small --max chunk is representative."""
    by_family: dict[str, list[dict]] = {}
    for e in entries:
        by_family.setdefault(e["family"], []).append(e)
    for v in by_family.values():
        v.sort(key=lambda e: e["version_parts"], reverse=True)
    out = []
    while by_family:
        for fam in sorted(by_family):
            head = by_family[fam]
            if head:
                out.append(head.pop(0))
            if not head:
                del by_family[fam]
    return out


def head_and_check(key: str, size_hint: int | None) -> dict:
    live = http_head(BUCKET + key)
    if live is None:
        raise SystemExit(f"FAIL  upstream vanished: {key}")
    if size_hint is not None and live["size"] != size_hint:
        print(f"  note: live size {live['size']} differs from catalog "
              f"{size_hint}; the live payload is the truth", file=sys.stderr)
    return live


def fetch_payload(key: str) -> tuple[Path, str, "tempfile.TemporaryDirectory"]:
    """Download one bucket key to a scratch dir. Caller runs td.cleanup()."""
    td = tempfile.TemporaryDirectory(prefix="mirror-")
    dest = Path(td.name) / key[len(PREFIX):]
    print(f"  fetching {key}")
    download(key, dest)
    return dest, sha256_path(dest), td


def upload_and_record(release_id: int, dest: Path, asset_name: str, sha: str,
                      uploaded: dict) -> None:
    """Put sha-verified bytes on the release under asset_name. Identical
    bytes already there are reused without upload; the upload POST's own
    digest verifies the bytes that landed."""
    resp = upload_asset(release_id, dest, asset_name)
    digest = (resp.get("digest") or "").removeprefix("sha256:")
    if digest != sha:
        raise RuntimeError(f"GitHub reports sha256:{digest}, local bytes are "
                           f"sha256:{sha} — refusing to record the row")
    uploaded[asset_name] = resp
    print(f"  mirrored {asset_name} (sha256:{sha})")


def verify_release_bytes(name: str, uploaded_asset: dict, sha: str,
                         size: int) -> None:
    """Reconciliation gate: the payload pulled from CE must be the bytes
    the release already serves, or the release holds something nobody can
    vouch for — alarm, name the asset, never auto-heal."""
    digest = (uploaded_asset.get("digest") or "").removeprefix("sha256:")
    if digest != sha or uploaded_asset["size"] != size:
        raise SystemExit(
            f"FAIL  {name}: CE bytes sha256:{sha} ({size} B) do not match the "
            f"release asset (digest {uploaded_asset.get('digest')!r}, "
            f"{uploaded_asset['size']} B); the release holds unvouched bytes")


def cmd_sync(max_downloads: int | None, selectors: list[str],
             dry_run: bool = False) -> int:
    catalog = json.loads(CATALOG.read_text())
    manifest = load_manifest()
    rows = manifest["rows"]
    errors: list[str] = []
    budget = [max_downloads if max_downloads is not None else 1 << 30]
    downloaded = [0]

    known_selectors = {e["asset"] for e in catalog["packaged"]}
    for s in selectors:
        if s not in known_selectors and s not in catalog["trunk_families"]:
            print(f"FAIL  selector {s!r} is neither a catalog payload asset "
                  "nor a trunk family", file=sys.stderr)
            return 1

    release = get_release(REPO, RELEASE)
    if release is None and not dry_run:
        print(f"release {RELEASE!r} does not exist; creating it")
        release = release_create(REPO, RELEASE)
    uploaded, ghosts = split_assets(release)
    release_id = release["id"] if release else 0

    # Prune needs the live published index, fetched and verified against
    # the Release file once per run; any failure returns None and prunes
    # nothing (fail safe).
    referenced = fetch_referenced_payloads()
    # datetime is a module-global so the selftest can freeze today.
    today = datetime.date.today().strftime("%Y%m%d")
    # A family with no live dated keys upstream errors out of its sync
    # pass before pruning runs; its assets must not enter the plan
    # either, or dry-run would name a deletion live sync never makes. A
    # listing that fails marks the family not-live: doubt prunes nothing.
    listing_failed = [False]
    def safe_dated_prefix_listing(fam: str) -> dict[str, str]:
        try:
            keys = dated_prefix_listing(fam)
        except Exception as e:
            print(f"{fam}: cannot list upstream dated keys: {e}; "
                  "planning no deletions for it", file=sys.stderr)
            listing_failed[0] = True
            return {}
        if not keys:
            # Same condition live sync errors on ("no live dated keys
            # upstream"): an empty listing must fail dry-run too.
            print(f"{fam}: no live dated keys upstream", file=sys.stderr)
            listing_failed[0] = True
        return keys
    live_dates = {fam: keys
                  for fam in catalog["trunk_families"]
                  if (keys := safe_dated_prefix_listing(fam))}
    plan = build_prune_plan(catalog, uploaded, referenced, today,
                            live_dates) if referenced is not None else {}

    if dry_run:
        # Read-only: print the plan normal sync would execute and exit
        # before any mutating call (no ghosts, no reconciliation, no
        # rotation, no deletes, no release creation — the create is
        # guarded above). Same planning function, same gates: the two can
        # never disagree. referenced None (fetch failure) prints nothing:
        # that run would prune nothing. A listing failure is the error
        # live sync reports; dry-run exits with the same status for it.
        if release is None:
            print(f"release {RELEASE!r} does not exist; dry-run plans "
                  "against an empty release")
        for fam in sorted(plan):
            for n in plan[fam]:
                print(f"{fam}: would prune {n}")
        return 1 if listing_failed[0] else 0


    for g in ghosts:
        print(f"ghost asset {g['name']} (state {g.get('state')}): deleting, it "
              "is a corrupt leftover that would 422 a re-upload")
        delete_asset(g["id"], g["name"])

    def budgeted_pull(key: str) -> tuple[Path, str, object] | None:
        """Download a NEW payload, honouring selectors and --max. None =
        skipped, with the reason printed."""
        if budget[0] <= 0:
            print(f"  {key[len(PREFIX):]}: pull pending (--max exhausted)")
            return None
        dest, sha, td = fetch_payload(key)
        budget[0] -= 1
        downloaded[0] += 1
        return dest, sha, td

    def reconcile_verified(name: str, key: str, write_row) -> None:
        """The release already serves `name`; prove it against CE bytes once
        (exempt from --max: no new exposure) and write the first-sync row
        from those bytes. write_row(analysis, live, sha, size) returns the
        (row_key, row) pair to record."""
        live = head_and_check(key, None)
        dest, sha, td = fetch_payload(key)
        downloaded[0] += 1
        try:
            verify_release_bytes(name, uploaded[name], sha, dest.stat().st_size)
            analysis = analyze_tarball(dest)
            row_key, row = write_row(analysis, live, sha, dest.stat().st_size)
            rows[row_key] = row
            save_manifest(manifest)
            print(f"  reconciled {name}: CE bytes == release bytes "
                  f"(sha256:{sha}); full row written")
        finally:
            td.cleanup()

    # --- trunk families: adopt, reconcile, rotate, prune (per family) ---
    for fam in sorted(catalog["trunk_families"]):
        rec = catalog["trunk_families"][fam]
        rx = rename_regex(rec["rename"])
        latest = live_dates.get(fam) or {}
        if not latest:
            errors.append(f"{fam}: no live dated keys upstream")
            continue
        date = max(latest)
        key = latest[date]
        b = key[len(PREFIX):]

        fam_dated_assets = sorted(n for n in uploaded if rx.match(n))

        for rk in reap_orphaned_trunk_rows(rows, fam, uploaded):
            print(f"{fam}: reaped {rk}: its asset was already rotated off "
                  "the release (nightly class re-records without alarm)")
            save_manifest(manifest)

        # Rows for row-less assets already on the release: legacy adopt for
        # the two mirror.sh-era names, re-download-verify for anything else.
        for name in fam_dated_assets:
            m = rx.match(name)
            lb = f"{fam}-{m['date']}.tar.xz"
            if lb in rows:
                continue
            lkey = PREFIX + lb
            if name in LEGACY_ADOPT:
                row = {"analysis": None, "asset": name, "date": m["date"],
                       "family": fam, "kind": "legacy", "legacy": True,
                       "key": lkey if lkey in catalog["listing"] else None,
                       "major": int(m["major"]),
                       "sha256": (uploaded[name].get("digest") or "")
                       .removeprefix("sha256:"),
                       "size": uploaded[name]["size"]}
                listed = catalog["listing"].get(lkey)
                if listed and listed["bytes"] != row["size"]:
                    print(f"  WARNING {name}: release size {row['size']} != catalog "
                          f"bucket bytes {listed['bytes']}; the release bytes are "
                          "what is recorded", file=sys.stderr)
                rows[lb] = row
                save_manifest(manifest)
                print(f"{fam}: ADOPTED legacy {name} from release metadata "
                      f"(sha256:{row['sha256']}); CE not contacted")
                continue
            if m["date"] not in latest:
                raise SystemExit(
                    f"FAIL  {name}: no manifest row and upstream key {lkey} "
                    "left the nightly window; cannot re-verify it and it is "
                    "not one of the two legacy names")

            def make_row(analysis: dict, live: dict, sha: str, size: int,
                         name=name, m=m, lb=lb, lkey=lkey) -> tuple[str, dict]:
                if (probed := probe_major(analysis, fam, lb)) != int(m["major"]):
                    raise SystemExit(
                        f"FAIL  {name}: name claims major {m['major']} but the "
                        f"payload carries {probed}")
                return lb, {"analysis": analysis, "asset": name,
                            "date": m["date"], "etag": live["etag"], "family": fam,
                            "key": lkey, "kind": "trunk", "major": int(m["major"]),
                            "sha256": sha, "size": size}
            reconcile_verified(name, lkey, make_row)

        # Rotation to the live latest date: only for already-tracked
        # families or explicit selector pulls (a plain sync mirrors no new
        # payload, so a re-run downloads nothing and is byte-identical).
        tracked = any(r.get("family") == fam for r in rows.values())
        if b in rows:
            if rows[b]["asset"] not in uploaded:
                errors.append(f"{b}: manifest row but asset {rows[b]['asset']} "
                              "missing from release")
            else:
                print(f"{fam}: {date} already mirrored as {rows[b]['asset']}; "
                      "publisher not contacted")
        elif selectors and fam not in selectors:
            print(f"{fam}: rotation to {date} pending (not selected this run)")
        elif not tracked and not selectors:
            print(f"{fam}: latest {date} pending (family not yet mirrored; "
                  "select it to pull)")
        else:
            if (pull := budgeted_pull(key)) is not None:
                dest, sha, td = pull
                try:
                    analysis = analyze_tarball(dest)
                    major = probe_major(analysis, fam, b)
                    name = rename_render(rec["rename"], major, date)
                    if prev := uploaded.get(name):
                        verify_release_bytes(name, prev, sha, dest.stat().st_size)
                        print(f"  {name}: identical bytes already on the release; "
                              "recording without upload")
                    else:
                        upload_and_record(release_id, dest, name, sha, uploaded)
                    rows[b] = {"analysis": analysis, "asset": name, "date": date,
                               "etag": http_head(BUCKET + key)["etag"],
                               "family": fam, "key": key, "kind": "trunk",
                               "major": major, "sha256": sha,
                               "size": dest.stat().st_size}
                    save_manifest(manifest)
                finally:
                    td.cleanup()

        # Prune executes exactly the plan computed at the top of the run,
        # after rotation has uploaded and recorded any new payload. The
        # just-uploaded asset is absent from the plan: the plan was built
        # on the pre-rotation release state, and the newest-per-family
        # guard protected the previous newest. An unreadable index gave
        # an empty plan: nothing is deleted. A family with no live dated
        # keys upstream errored above and is absent from the plan; its
        # assets are untouched this run.
        for n in plan.get(fam, []):
            if n not in uploaded:
                continue
            print(f"{fam}: pruning {n}")
            delete_asset(uploaded[n]["id"], n)
            del uploaded[n]
            for rk in [rk for rk, r in rows.items() if r.get("asset") == n]:
                del rows[rk]
            save_manifest(manifest)

    # --- stables: verify mirrored, reconcile row-less release assets,
    #     pull selector-named pending ones ---
    entries = catalog["packaged"]
    if selectors:
        by_asset = {e["asset"]: e for e in entries}
        entries = [by_asset[s] for s in selectors if s in by_asset]
    else:
        entries = round_robin(entries)
    for e in entries:
        b = e["asset"]
        if b in rows:
            a = uploaded.get(b)
            if a is None:
                errors.append(f"{b}: manifest row but asset missing from release")
                continue
            digest = (a.get("digest") or "").removeprefix("sha256:")
            if digest != rows[b]["sha256"] or a["size"] != rows[b]["size"]:
                errors.append(f"{b}: drift against release (stable is immutable; "
                              "alarmed, never auto re-mirrored)")
            continue
        if b in uploaded:
            # Reconciliation: release serves it, the manifest does not.
            def make_stable_row(analysis: dict, live: dict, sha: str, size: int,
                                e=e, b=b) -> tuple[str, dict]:
                if err := check_version_source(e, analysis):
                    raise SystemExit(f"FAIL  {err}")
                return b, {"analysis": analysis, "asset": b,
                           "etag": live["etag"], "key": e["key"], "kind": "stable",
                           "sha256": sha, "size": size}
            reconcile_verified(b, e["key"], make_stable_row)
            continue
        if not selectors:
            continue  # backfill of never-mirrored stables is an explicit pull
        if (pull := budgeted_pull(e["key"])) is None:
            continue
        dest, sha, td = pull
        try:
            analysis = analyze_tarball(dest)
            if err := check_version_source(e, analysis):
                errors.append(err)
                continue
            upload_and_record(release_id, dest, b, sha, uploaded)
            rows[b] = {"analysis": analysis, "asset": b,
                       "etag": http_head(BUCKET + e["key"])["etag"], "key": e["key"],
                       "kind": "stable", "sha256": sha, "size": dest.stat().st_size}
            save_manifest(manifest)
        finally:
            td.cleanup()

    known = {e["asset"] for e in catalog["packaged"]}
    known |= {r["asset"] for r in rows.values()}
    for name in sorted(uploaded):
        if name in known:
            continue
        cls, _ = classify_asset(name, catalog)
        if cls == "trunk-raw":
            continue  # pruned above or pending the family's next pass
        print(f"WARNING non-catalog asset on the release: {name} "
              "(reported loudly; only the two legacy names auto-adopt)",
              file=sys.stderr)
    save_manifest(manifest)
    if errors:
        for e in errors:
            print(f"ERROR {e}", file=sys.stderr)
        return 1
    print(f"sync: clean ({downloaded[0]} CE downloads, "
          f"{budget[0] if budget[0] < 1 << 30 else 'unlimited'} budget left)")
    return 0


# ---------------------------------------------------------------- check

def cmd_check(complete: bool) -> int:
    catalog = json.loads(CATALOG.read_text())
    manifest = load_manifest()
    rows = manifest["rows"]
    release = get_release(REPO, RELEASE)
    if release is None:
        print(f"release {RELEASE!r} does not exist; every entry is pending")
    uploaded, ghosts = split_assets(release)
    for g in ghosts:
        print(f"ghost asset {g['name']} (state {g.get('state')}): counts as absent")

    problems = verify_rows(rows, uploaded,
                           head=lambda key: http_head(BUCKET + key))

    mirrored_assets = {r["asset"] for r in rows.values()}
    for name in sorted(uploaded):
        if name not in mirrored_assets:
            problems.append(f"{name}: uploaded release asset with no manifest "
                            "row is unverifiable")

    trunk_latest: dict[str, str] = {}
    for fam in sorted(catalog["trunk_families"]):
        latest = dated_prefix_listing(fam)
        if latest:
            trunk_latest[fam] = max(latest)
    pending = pending_payloads(catalog, rows, trunk_latest)

    print(f"mirrored: {len(rows)} rows verified against the release "
          "(stable rows also against upstream S3 size/ETag)")
    if pending:
        print(f"pending: {len(pending)} catalog payloads not yet mirrored "
              "(tolerated):")
        for p in pending:
            print(f"  PENDING {p}")
    rc = check_decision(problems, pending, complete)
    for p in problems:
        print(f"DRIFT {p}")
    if rc == 0:
        print("check: clean")
    elif rc == 2:
        print("check: pending remainder with --complete")
    return rc


# ------------------------------------------------------ reanalyze-legacy
#
# The legacy rows entered the manifest from release metadata only; their
# analysis is null, which gates every S3 consumer. The release bytes are
# vouched for by the recorded digest (they equalled CE bytes at adopt/reconcile
# time and GitHub hosts them since), so analysis is run against those bytes
# instead of spending CE egress. Digest mismatch = the release holds unvouched
# bytes: exit 1 naming the row, never analyze-and-proceed. Refreshing an
# already analyzed row (--include-stale, for a row predating the current
# analysis fields) must reproduce every recorded field; anything else is
# pipeline drift and is named.

def reanalyze_row(row: dict, payload: Path) -> None:
    """Digest-gated analysis of a row's recorded release bytes."""
    sha = sha256_path(payload)
    if sha != row["sha256"]:
        raise SystemExit(
            f"FAIL  {row['asset']}: payload hashes sha256:{sha}, recorded "
            f"{row['sha256']} — refusing to analyze unvouched bytes")
    analysis = analyze_tarball(payload)
    old = row.get("analysis")
    if old is not None:
        # Fields introduced after the row was recorded are expected, not
        # drift: compare the old dict's coverage only, and let the new fields
        # (bin_links, target_bin, root.dot_prefix) land freely.
        drift_keys = (set(old) | set(analysis)) - {"bin_links", "target_bin"}
        diff = {k for k in drift_keys if old.get(k) != analysis.get(k)}
        # root gains dot_prefix after the fact; older rows never recorded it.
        if diff == {"root"}:
            base = {k: v for k, v in analysis["root"].items() if k != "dot_prefix"}
            if all(old["root"].get(k) == v for k, v in base.items()):
                diff = set()
        # has_binutils/binutils_in_bin widen to the link-aware universe;
        # every other difference means the pipeline changed its answers.
        semantic = diff & {"has_binutils", "binutils_in_bin"}
        drift = diff - semantic
        if drift:
            raise SystemExit(
                f"FAIL  {row['asset']}: reanalysis changed {sorted(drift)}; the "
                "analysis pipeline drifted from what recorded the row")
        if semantic:
            print(f"  {row['asset']}: {sorted(semantic)} widen to the "
                  "link-aware bin/ universe (binutils ship as links there)")
    row["analysis"] = analysis
    row["analysis_source"] = "release"


def cmd_reanalyze_legacy(include_stale: bool) -> int:
    manifest = load_manifest()
    rows = manifest["rows"]
    stale = [b for b, r in sorted(rows.items())
             if r.get("analysis") is None
             or (include_stale
                 and ("bin_links" not in r["analysis"]
                      or "target_bin" not in r["analysis"]
                      or "dot_prefix" not in r["analysis"].get("root", {})))]
    if not stale:
        print("reanalyze-legacy: every row already carries current analysis")
        return 0
    payload_dir = os.environ.get("MIRROR_PAYLOAD_DIR")
    for b in stale:
        row = rows[b]
        asset = row["asset"]
        url = (f"https://github.com/{REPO}/releases/download/{RELEASE}/"
               f"{urllib.parse.quote(asset)}")
        td = tempfile.TemporaryDirectory(prefix="mirror-reanalyze-")
        try:
            cached = Path(payload_dir) / asset if payload_dir else None
            if cached is not None and cached.exists() \
                    and sha256_path(cached) == row["sha256"]:
                dest = cached
            else:
                dest = Path(td.name) / asset
                print(f"  fetching {url}")
                download_url(url, dest)
            reanalyze_row(row, dest)
            save_manifest(manifest)
            print(f"  analyzed {row['asset']} from release bytes "
                  f"({row['size'] >> 20} MiB, analysis_source=release)")
        finally:
            td.cleanup()
    print(f"reanalyze-legacy: {len(stale)} rows now carry release-proven "
          "analysis")
    return 0


# -------------------------------------------------------------- selftest

def _mk_elf(emachine: int = 62, needed: tuple[str, ...] = ("libc.so.6",),
            klass: int = 2, enc: int = 1) -> bytes:
    """Minimal ELF with a .dynamic section: fixture the parser must read,
    and whose mutation it must reject."""

    e = "<" if enc == 1 else ">"
    strs = b"\0" + b"\0".join(s.encode() for s in needed) + b"\0"
    offs, cur = [], 1
    for s in needed:
        offs.append(cur)
        cur += len(s) + 1
    dynent = "qQ" if klass == 2 else "iI"
    dyn = b"".join(struct.pack(e + dynent, 1, o) for o in offs) \
        + struct.pack(e + dynent, 0, 0)
    if klass == 2:
        hdr = struct.pack(e + "HHIQQQIHHHHHH", 2, emachine, 1, 0, 0, 64, 0,
                          64, 0, 0, 64, 3, 0)
        sh_null = b"\0" * 64
        sh_dyn = struct.pack(e + "IIQQQQIIQQ", 0, 6, 0, 0, 256, len(dyn), 2, 0, 8, 16)
        sh_str = struct.pack(e + "IIQQQQIIQQ", 0, 3, 0, 0, 384, len(strs), 0, 0, 1, 0)
    else:
        hdr = struct.pack(e + "HHIIIIIHHHHHH", 2, emachine, 1, 0, 0, 52, 0,
                          52, 0, 0, 40, 3, 0)
        sh_null = b"\0" * 40
        sh_dyn = struct.pack(e + "IIIIIIIIII", 0, 6, 0, 0, 256, len(dyn), 2, 0, 4, 8)
        sh_str = struct.pack(e + "IIIIIIIIII", 0, 3, 0, 0, 384, len(strs), 0, 0, 1, 0)
    out = b"\x7fELF" + bytes([klass, enc, 1, 0]) + b"\0" * 8 + hdr + sh_null + sh_dyn + sh_str
    out += b"\0" * (256 - len(out)) + dyn
    out += b"\0" * (384 - len(out)) + strs
    return out


def _mk_tar(members: list[tuple[str, bytes, int]], name: str = "fixture.tar.xz",
            mode: str = "w:xz") -> Path:
    """A tarball with the grammar REAL payloads have: directory members,
    file members, explicit modes. names trailing in / become dirs."""
    tmp = Path(tempfile.mkdtemp(prefix="mirror-selftest-"))
    p = tmp / name
    with tarfile.open(p, mode) as tar:
        for mname, data, mmode in members:
            ti = tarfile.TarInfo(mname)
            if mname.endswith("/"):
                ti.type = tarfile.DIRTYPE  # names trailing in / are dirs
                ti.size = 0
            else:
                ti.size = len(data)
            ti.mode = mmode
            tar.addfile(ti, io.BytesIO(data))
    return p


def _rm(p: Path) -> None:
    subprocess.run(["rm", "-rf", str(p.parent)], check=False)


def cmd_selftest() -> int:
    rc = 0
    catalog = json.loads(CATALOG.read_text())

    def expect(name: str, cond: bool, detail: str = ""):
        nonlocal rc
        print(f"{'pass' if cond else 'FAIL'}  {name}" + (f" ({detail})" if detail else ""))
        if not cond:
            rc = 1

    # ---------------- ghost filter: only state==uploaded counts
    rel = {"assets": [{"name": "a", "state": "uploaded", "size": 1,
                       "digest": "sha256:" + "0" * 64},
                      {"name": "g", "state": "uploading", "size": 2, "digest": None}]}
    uploaded, ghosts = split_assets(rel)
    expect("ghost filtered out of uploaded", list(uploaded) == ["a"] and
           [g["name"] for g in ghosts] == ["g"])

    # ---------------- tampered row must fail verification; pristine must pass
    rows = {"a": {"asset": "a", "kind": "stable", "key": "opt/a",
                  "size": 1, "sha256": "0" * 64, "etag": "E", "analysis": None}}
    head = lambda key: {"size": 1, "etag": "E"}
    expect("pristine row verifies", verify_rows(rows, uploaded, head) == [])
    bad = json.loads(json.dumps(rows))
    bad["a"]["sha256"] = "1" * 64
    expect("tampered digest is caught",
           any("digest drift" in p for p in verify_rows(bad, uploaded, head)))
    bad2 = json.loads(json.dumps(rows))
    bad2["a"]["asset"] = "missing"
    expect("missing asset is caught",
           any("absent" in p for p in verify_rows(bad2, uploaded, head)))
    head_size = lambda key: {"size": 2, "etag": "E"}
    expect("upstream size drift is caught",
           any("UPSTREAM size drift" in p
               for p in verify_rows(rows, uploaded, head_size)))
    head_etag = lambda key: {"size": 1, "etag": "F"}
    expect("upstream ETag drift is caught",
           any("UPSTREAM ETag drift" in p
               for p in verify_rows(rows, uploaded, head_etag)))

    # nightly class: a trunk row's upstream ETag is expected to rotate, so
    # verify_rows never heads trunk rows (rotation re-records without alarm)
    rel2 = {"assets": [{"name": "gcc-17-trunk20260904.tar.xz", "state": "uploaded",
                        "size": 1, "digest": "sha256:" + "0" * 64},
                       {"name": "gcc-17-trunk20260903.tar.xz", "state": "uploaded",
                        "size": 1, "digest": "sha256:" + "0" * 64}]}
    uploaded2, _ = split_assets(rel2)
    trow = {"t": {"asset": "gcc-17-trunk20260904.tar.xz", "kind": "trunk",
                  "key": "opt/gcc-trunk-20260904.tar.xz", "size": 1,
                  "sha256": "0" * 64, "etag": "OLD", "analysis": None}}
    head_boom = lambda key: (_ for _ in ()).throw(AssertionError("headed a trunk row"))
    expect("trunk rows skip upstream drift head (rotation re-records cleanly)",
           verify_rows(trow, uploaded2, head_boom) == [])
    # legacy rows likewise: ETag is not even recorded
    lrow = {"l": {"asset": "gcc-17-trunk20260903.tar.xz", "kind": "legacy",
                  "key": "opt/gcc-trunk-20260903.tar.xz", "size": 1,
                  "sha256": "0" * 64, "analysis": None, "legacy": True}}
    expect("legacy rows skip upstream drift head",
           verify_rows(lrow, uploaded2, head_boom) == [])

    # ---------------- exit-code contract mapping
    expect("pending tolerated -> 0", check_decision([], ["x"], False) == 0)
    expect("pending + --complete -> 2", check_decision([], ["x"], True) == 2)
    expect("problems -> 1", check_decision(["p"], [], False) == 1)
    expect("problems beat pending", check_decision(["p"], ["x"], True) == 1)

    # ---------------- reap of externally-rotated nightly rows
    # Live class observed 2026-09-07: the mirror.sh-era nightly on main
    # pruned gcc-17-trunk20260904/0905 off the release while the branch
    # manifest still recorded them — a permanent rc 1 until reaped here.
    up = {"gcc-17-trunk20260907.tar.xz": {}}
    rows_reap = {
        "gcc-trunk-20260904.tar.xz": {"asset": "gone-trunk",
                                      "family": "gcc-trunk", "kind": "trunk"},
        "gcc-trunk-20260907.tar.xz": {"asset": "gcc-17-trunk20260907.tar.xz",
                                      "family": "gcc-trunk", "kind": "trunk"},
        "clang-trunk-20260904.tar.xz": {"asset": "gone-legacy",
                                        "family": "clang-trunk",
                                        "kind": "legacy"},
        "gcc-16.2.0.tar.xz": {"asset": "gone-stable", "kind": "stable"},
    }
    got = reap_orphaned_trunk_rows(rows_reap, "gcc-trunk", up)
    expect("reap drops this family's gone rows only",
           got == ["gcc-trunk-20260904.tar.xz"]
           and sorted(rows_reap) == ["clang-trunk-20260904.tar.xz",
                                     "gcc-16.2.0.tar.xz",
                                     "gcc-trunk-20260907.tar.xz"], str(got))
    got2 = reap_orphaned_trunk_rows(rows_reap, "clang-trunk", up)
    expect("legacy rows reap too; the stable row is untouchable",
           got2 == ["clang-trunk-20260904.tar.xz"]
           and sorted(rows_reap) == ["gcc-16.2.0.tar.xz",
                                     "gcc-trunk-20260907.tar.xz"], str(got2))
    expect("nothing left to reap is a no-op",
           reap_orphaned_trunk_rows(rows_reap, "gcc-trunk", up) == []
           and "gcc-16.2.0.tar.xz" in rows_reap)

    # ---------------- prune: referenced + age rules over EVERY family's
    # rename scheme (defect A control: date and major always come out of
    # the family's own regex named groups; 6 of 9 schemes put text after
    # the date)
    families = catalog["trunk_families"]
    expect("catalog carries the nine trunk families", len(families) == 9,
           str(sorted(families)))
    ok_all = True
    for fam, frec in sorted(families.items()):
        rx = rename_regex(frec["rename"])
        assets = [rename_render(frec["rename"], 16, "20260820"),
                  rename_render(frec["rename"], 17, "20260822"),
                  rename_render(frec["rename"], 17, "20260903"),
                  rename_render(frec["rename"], 17, "20260904")]
        # today - 14 days = 20260822: the first two are old enough to
        # prune, but the oldest is named by the index, so it survives.
        plan = prune_plan(assets, rx, referenced={assets[0]},
                          today="20260905")
        keep = [a for a in assets if a not in plan]
        if not (plan == [assets[1]] and
                keep == [assets[0], assets[2], assets[3]]):
            ok_all = False
            print(f"  prune mismatch {fam}: plan={plan}")
    expect("referenced-payload and age prune correct over all 9 rename "
           "schemes", ok_all)

    # an old payload named by the index survives; an old unnamed one is
    # deleted; an unnamed one younger than 14 days survives
    gcc_rx = rename_regex(families["gcc-trunk"]["rename"])
    mixed = ["gcc-17-trunk20260801.tar.xz", "gcc-17-trunk20260802.tar.xz",
             "gcc-17-trunk20260904.tar.xz"]
    plan = prune_plan(mixed, gcc_rx,
                      referenced={"gcc-17-trunk20260801.tar.xz"},
                      today="20260905")
    expect("old referenced payload survives, old unnamed pruned, "
           "young unnamed survives",
           plan == ["gcc-17-trunk20260802.tar.xz"], str(plan))

    # the referenced set comes straight out of the verified Packages
    # text; related .tar.xz tokens in other fields come along harmlessly
    pkgs = ("Package: gcc-17\n"
            "Description: GNU Compiler Collection 17.0.0 "
            "(gcc-17-trunk20260801.tar.xz), built by Compiler Explorer\n"
            "Filename: gcc-17_17.trunk20260905_amd64.deb\n\n"
            "Package: clang-24\n"
            "Description: Clang 24.0.0 (clang-24-trunk20260901.tar.xz)\n")
    refs = referenced_payloads(pkgs)
    expect("Packages scan names the pinned payloads",
           refs == {"gcc-17-trunk20260801.tar.xz",
                    "clang-24-trunk20260901.tar.xz"}, str(refs))

    # ---------------- fetch_referenced_payloads through an injected
    # opener: every defect class returns None and a verified index parses.
    import http.client

    def mk_release(pkgs_bytes: bytes) -> bytes:
        sha = hashlib.sha256(pkgs_bytes).hexdigest()
        return ("Label: diamondinoia\nSHA256:\n"
                f" {sha} {len(pkgs_bytes):11d} Packages\n").encode()

    good_pkgs = pkgs.encode()
    good_rel = mk_release(good_pkgs)

    class FakeResp:
        def __init__(self, body: bytes):
            self.body = body
        def read(self, *a):
            return self.body
        def __enter__(self):
            return self
        def __exit__(self, *a):
            return False

    def fake_opener_factory(responses: dict, exc: Exception | None = None,
                            exc_on: tuple[str, ...] = ("Packages",)):
        def fake_opener(req, timeout=0):
            url = req.full_url if hasattr(req, "full_url") else req
            if exc is not None and any(url.endswith(s) for s in exc_on):
                raise exc
            return FakeResp(responses[url.rsplit("/", 1)[1]])
        return fake_opener

    cases = [
        ("corrupt Packages bytes decode-fail returns None",
         fake_opener_factory({"Release": mk_release(b"\xff\xfe" + good_pkgs),
                              "Packages": b"\xff\xfe" + good_pkgs})),
        ("SHA256 mismatch returns None",
         fake_opener_factory(
             {"Release": good_rel,
              # same length, one byte changed: the hash gate alone must
              # catch it (the size check cannot)
              "Packages": good_pkgs.replace(b"gcc-17", b"gce-17", 1)})),
        ("size mismatch returns None",
         fake_opener_factory(
             {"Release": ("Label: diamondinoia\nSHA256:\n "
                          + hashlib.sha256(good_pkgs).hexdigest()
                          + f" {len(good_pkgs) + 1:11d} Packages\n").encode(),
              "Packages": good_pkgs})),
        ("IncompleteRead returns None",
         fake_opener_factory({"Release": good_rel},
                             exc=http.client.IncompleteRead(b"half"))),
        ("an HTML error page the Release did NOT sign is rejected by the "
         "hash gate (its .tar.xz token never becomes a reference)",
         fake_opener_factory(
             {"Release": good_rel,
              "Packages": b"<html>404 gcc-17-trunk20260801.tar.xz</html>"})),
        ("Release without a Packages entry returns None",
         fake_opener_factory({"Release": b"Label: diamondinoia\nSHA256:\n",
                              "Packages": good_pkgs})),
        # the Packages checksum line sits under MD5Sum, not SHA256: the
        # parser must not take a line from another section
        ("Packages line under MD5Sum only returns None",
         fake_opener_factory(
             {"Release": (b"Label: diamondinoia\nMD5Sum:\n "
                          + hashlib.sha256(good_pkgs).hexdigest().encode()
                          + f" {len(good_pkgs):11d} Packages\n".encode()),
              "Packages": good_pkgs})),
        ("Release fetch itself failing returns None",
         fake_opener_factory({}, exc=urllib.error.URLError("offline"),
                             exc_on=("Release",))),
    ]
    for label, opener in cases:
        got = fetch_referenced_payloads(base="https://t.invalid/",
                                        opener=opener)
        expect(label, got is None)

    got = fetch_referenced_payloads(
        base="https://t.invalid/",
        opener=fake_opener_factory({"Release": good_rel,
                                    "Packages": good_pkgs}))
    expect("a size-and-hash-verified index yields its payloads",
           got == {"gcc-17-trunk20260801.tar.xz",
                   "clang-24-trunk20260901.tar.xz"}, str(got))

    # sync --dry-run over a missing release must reach no mutating call:
    # any POST/PATCH/DELETE or release_create means the dry-run lied. The
    # stubs go into cmd_sync's own globals (__main__ when run as a
    # script): patching a second `import mirror` module object would leave
    # the code under test on the real gh and release functions.
    g = cmd_sync.__globals__
    # K2: freeze today for every cmd_sync run below: patch the datetime
    # module global with a fake whose date subclass returns one fixed
    # calendar day from today(); every fixture date derives from it. The
    # real datetime module restores after each case, so the suite gives
    # the same result on any run date.
    FIXED_TODAY = datetime.date(2026, 9, 5)

    class _FrozenDate(datetime.date):
        @classmethod
        def today(cls):
            return cls(FIXED_TODAY.year, FIXED_TODAY.month, FIXED_TODAY.day)

    class FakeDateTime:
        date = _FrozenDate
        timedelta = datetime.timedelta

    def rel_date(days_ago: int) -> str:
        return (FIXED_TODAY
                - datetime.timedelta(days=days_ago)).strftime("%Y%m%d")

    def raw_name(fam: str, date: str) -> str:
        return f"{fam}-{date}.tar.xz"

    saved = {k: g[k] for k in
             ("gh", "release_create", "get_release",
              "fetch_referenced_payloads", "dated_prefix_listing",
              "datetime")}
    try:
        def no_mutation(args, **kw):
            if args[:1] != ["api"]:
                raise AssertionError(f"non-api gh call: {args}")
            if "-X" in args:
                raise AssertionError(f"mutating gh call: {args}")
            return json.dumps({"assets": []})
        def boom_create(*a, **kw):
            raise AssertionError("release_create called")
        g["gh"] = no_mutation
        g["release_create"] = boom_create
        g["get_release"] = lambda *a, **kw: None
        g["fetch_referenced_payloads"] = lambda: set()
        g["dated_prefix_listing"] = lambda fam: {}
        g["datetime"] = FakeDateTime
        try:
            cmd_sync(max_downloads=0, selectors=[], dry_run=True)
            mut = None
        except AssertionError as e:
            mut = e
        expect("sync --dry-run over a missing release makes no mutating call",
               mut is None, str(mut or ""))
    finally:
        g.update(saved)

    # raw dated assets obey the same rule as every dated payload, and
    # every family keeps its newest dated asset whatever its age. Drives
    # cmd_sync, not just prune_plan. Cases: an index-None run deletes
    # nothing; a referenced old raw survives; an old unnamed raw that is
    # the family's ONLY asset (hence its newest) survives; with a newer
    # family asset present the old unnamed raw drops; a young raw
    # survives the age gate even as non-newest.
    def one_release(*names):
        return {"id": 1, "assets": [
            {"name": n, "state": "uploaded", "size": 1,
             "digest": "sha256:" + "0" * 64, "id": i}
            for i, n in enumerate(names)]}
    # The date freeze (FIXED_TODAY, _FrozenDate, FakeDateTime, rel_date)
    # is defined above, before the first cmd_sync case: every fixture date
    # derives from the one fixed day.
    raw_rx_gcc = re.compile(r"^gcc-trunk-(?P<date>\d{8})\.tar\.xz$")

    raw = raw_name("gcc-trunk", rel_date(35))     # older than 14 days
    raw_new = raw_name("gcc-trunk", rel_date(1))  # newest raw of the family
    raw_young = raw_name("gcc-trunk", rel_date(3))
    ren_new = rename_render(families["gcc-trunk"]["rename"], 17, rel_date(0))
    # a live dated key: with none the family errors and prunes nothing,
    # which would look like "index None" passing for every case
    live = {rel_date(0): PREFIX + raw_name("gcc-trunk", rel_date(0))}
    cases = [
        ("index None: no raw asset is dropped", [raw, raw_new], None, set()),
        ("a raw asset named by the index is kept", [raw, raw_new],
         {raw}, set()),
        ("an old raw asset that is the family's newest is kept",
         [raw], set(), set()),
        ("an old raw asset the index does not name is dropped once the "
         "family has a newer asset", [raw, raw_new], set(), {raw}),
        ("a young non-newest raw asset survives the age gate",
         [raw_young, raw_new], set(), set()),
        # K1: the family's newest RENAMED payload is protected even when a
        # newer raw leftover exists; both are old and unnamed. The raw
        # leftover drops: it is not its class's newest (raw_new is).
        ("newest renamed payload survives a newer raw leftover",
         [rename_render(families["gcc-trunk"]["rename"], 17, rel_date(34)),
          raw_name("gcc-trunk", rel_date(33)), raw_new],
         set(), {raw_name("gcc-trunk", rel_date(33))}),
    ]
    for label, names, refs, want in cases:
        deleted: list[str] = []
        saved2 = {k: g[k] for k in
                  ("get_release", "fetch_referenced_payloads",
                   "delete_asset", "save_manifest", "dated_prefix_listing",
                   "gh", "datetime", "load_manifest", "http_head")}
        try:
            g["get_release"] = lambda *a, r=one_release(*names), **kw: r
            g["fetch_referenced_payloads"] = lambda refs=refs: refs
            g["delete_asset"] = lambda aid, n: deleted.append(n)
            g["save_manifest"] = lambda *a, **kw: None
            g["dated_prefix_listing"] = lambda fam, live=live: live
            g["gh"] = lambda args, **kw: json.dumps({"assets": []})
            g["datetime"] = FakeDateTime
            # Rows keyed by family-date for every fixture asset: the
            # reconciliation branch (which would head and download the
            # live key) skips any asset whose row exists.
            def stub_manifest(names=names):
                rows = {}
                for n in names:
                    m = (rename_regex(families["gcc-trunk"]["rename"])
                         .match(n) or raw_rx_gcc.match(n))
                    d = m["date"]
                    rows[f"gcc-trunk-{d}.tar.xz"] = {
                        "analysis": None, "asset": n, "date": d,
                        "etag": "E", "family": "gcc-trunk",
                        "key": f"opt/gcc-trunk-{d}.tar.xz", "kind": "trunk",
                        "major": 17, "sha256": "0" * 64, "size": 1}
                return {"meta": manifest_meta(), "rows": rows}
            g["load_manifest"] = stub_manifest
            g["http_head"] = lambda url: {"size": 1, "etag": "E"}
            cmd_sync(max_downloads=0, selectors=["gcc-trunk"])
            expect(label, set(deleted) == want, f"deleted={deleted}")
        finally:
            g.update(saved2)

    # a verified index keeps a named old payload and deletes an unnamed
    # old one (the named one being non-newest, or it would survive
    # regardless); and dry-run prints exactly the plan live executes on
    # the same fixture. The clock is frozen: these dates are relative to
    # the fixed today, so the case does not depend on the run date.
    old_named = rename_render(families["gcc-trunk"]["rename"], 17, rel_date(35))
    old_unnamed = rename_render(families["gcc-trunk"]["rename"], 17, rel_date(34))
    # old enough to drop, but the newest dated asset the release holds for
    # the family: the newest-per-family guard must keep it
    fam_newest = rename_render(families["gcc-trunk"]["rename"], 17, rel_date(33))
    # Manifest rows give each fixture asset a row (so the reconciliation
    # branch skips them) and point the live date's row at fam_newest (so
    # rotation pulls nothing and records no error).
    def fixture_manifest(*names_dates):
        return {"meta": manifest_meta(), "rows": {
            f"gcc-trunk-{d}.tar.xz": {
                "analysis": None, "asset": n, "date": d, "etag": "E",
                "family": "gcc-trunk", "key": f"opt/gcc-trunk-{d}.tar.xz",
                "kind": "trunk", "major": 17,
                "sha256": "0" * 64, "size": 1}
            for n, d in names_dates}}

    deleted = []
    saved3 = {k: g[k] for k in
              ("get_release", "fetch_referenced_payloads",
               "delete_asset", "save_manifest", "dated_prefix_listing",
               "gh", "load_manifest", "datetime")}
    try:
        rel = one_release(old_named, old_unnamed, fam_newest)
        fm = fixture_manifest((old_named, rel_date(35)),
                              (old_unnamed, rel_date(34)),
                              (fam_newest, rel_date(33)))
        g["get_release"] = lambda *a, r=rel, **kw: r
        g["fetch_referenced_payloads"] = lambda: {old_named}
        g["delete_asset"] = lambda aid, n: deleted.append(n)
        g["save_manifest"] = lambda *a, **kw: None
        g["dated_prefix_listing"] = lambda fam, live=live: live
        g["gh"] = lambda args, **kw: json.dumps({"assets": []})
        g["load_manifest"] = lambda fm=fm: json.loads(json.dumps(fm))
        g["datetime"] = FakeDateTime
        cmd_sync(max_downloads=0, selectors=["gcc-trunk"])
        expect("verified index: named old kept, unnamed old deleted, "
               "newest kept", set(deleted) == {old_unnamed},
               f"deleted={deleted}")
        # dry-run on the identical fixture names the same set
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            dry_rc = cmd_sync(max_downloads=0, selectors=["gcc-trunk"],
                              dry_run=True)
        would = {line.split("would prune ", 1)[1]
                 for line in buf.getvalue().splitlines()
                 if "would prune " in line}
        expect("dry-run prints the plan live executes",
               dry_rc == 0 and would == {old_unnamed},
               f"rc={dry_rc} would={would}")
    finally:
        g.update(saved3)

    # K8: the fam in live_dates gate must fail without it. An old unnamed
    # raw that is NOT its class's newest (raw_new is) sits on a family
    # whose upstream listing errors; the gate must still prune nothing.
    deleted = []
    saved3b = {k: g[k] for k in
               ("get_release", "fetch_referenced_payloads",
                "delete_asset", "save_manifest", "dated_prefix_listing",
                "gh", "load_manifest", "datetime", "http_head")}
    try:
        rel = one_release(raw, raw_new)
        fm = fixture_manifest((raw, rel_date(35)),
                              (raw_new, rel_date(1)))
        g["get_release"] = lambda *a, r=rel, **kw: r
        g["fetch_referenced_payloads"] = lambda: set()
        g["delete_asset"] = lambda aid, n: deleted.append(n)
        g["save_manifest"] = lambda *a, **kw: None
        def offline_listing(fam):
            raise urllib.error.URLError("offline")
        g["dated_prefix_listing"] = offline_listing
        g["gh"] = lambda args, **kw: json.dumps({"assets": []})
        g["load_manifest"] = lambda fm=fm: json.loads(json.dumps(fm))
        g["datetime"] = FakeDateTime
        g["http_head"] = lambda url: {"size": 1, "etag": "E"}
        cmd_sync(max_downloads=0, selectors=["gcc-trunk"])
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            dry_rc = cmd_sync(max_downloads=0, selectors=["gcc-trunk"],
                              dry_run=True)
        expect("live_dates gate: errored listing keeps non-newest old raw",
               deleted == [] and "would prune" not in buf.getvalue(),
               f"deleted={deleted} dry={buf.getvalue()!r}")
        expect("dry-run exits nonzero when a family listing errored",
               dry_rc != 0, f"rc={dry_rc}")
    finally:
        g.update(saved3b)

    # An empty listing that raises nothing is the same failure live sync
    # reports ("no live dated keys upstream"): dry-run must exit nonzero
    # on it through the one shared condition, not a second copy.
    saved3d = {k: g[k] for k in
               ("get_release", "fetch_referenced_payloads",
                "dated_prefix_listing", "gh", "load_manifest",
                "datetime", "http_head")}
    try:
        g["get_release"] = lambda *a, r=one_release(raw_new), **kw: r
        g["fetch_referenced_payloads"] = lambda: set()
        g["dated_prefix_listing"] = lambda fam: {}
        g["gh"] = lambda args, **kw: json.dumps({"assets": []})
        g["load_manifest"] = lambda fm=fixture_manifest(
            (raw_new, rel_date(1))): json.loads(json.dumps(fm))
        g["datetime"] = FakeDateTime
        g["http_head"] = lambda url: {"size": 1, "etag": "E"}
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            dry_rc = cmd_sync(max_downloads=0, selectors=["gcc-trunk"],
                              dry_run=True)
        expect("dry-run exits nonzero on an empty upstream listing",
               dry_rc != 0, f"rc={dry_rc}")
    finally:
        g.update(saved3d)

    # A misspelled selector must fail before any fetch or planning, in
    # dry-run too (the README promise). get_release and the index fetch
    # are stubbed to raise: reaching either means validation ran late.
    saved3c = {k: g[k] for k in
               ("get_release", "fetch_referenced_payloads",
                "dated_prefix_listing")}
    try:
        def touched(*a, **kw):
            raise AssertionError("fetch ran before selector validation")
        g["get_release"] = touched
        g["fetch_referenced_payloads"] = touched
        g["dated_prefix_listing"] = touched
        try:
            bad_rc = cmd_sync(max_downloads=0, selectors=["no-such-family"],
                              dry_run=True)
        except AssertionError:
            bad_rc = 0
        expect("bad selector fails before any fetch in dry-run",
               bad_rc != 0, f"rc={bad_rc}")
    finally:
        g.update(saved3c)

    # positive control: a foreign name in the plan must raise, never sort wrong
    try:
        prune_plan(["gcc-17-trunk20260904.tar.xz",
                    "clang-24-trunk20260904.tar.xz"], gcc_rx,
                   referenced=set(), today="20260905")
        expect("foreign asset in prune plan raises", False)
    except ValueError:
        expect("foreign asset in prune plan raises", True)

    # A foreign-family name that only sits in referenced or keep_names is
    # not this family's asset: the plan for this family must not change
    # and nothing may raise.
    fam_plan = prune_plan(["gcc-17-trunk20260802.tar.xz"], gcc_rx,
                          referenced={"clang-24-trunk20260801.tar.xz",
                                      "gcc-17-trunk20260802.tar.xz"},
                          today="20260905")
    expect("foreign name in referenced leaves the plan untouched",
           fam_plan == [], str(fam_plan))
    fam_plan = prune_plan(["gcc-17-trunk20260802.tar.xz"], gcc_rx,
                          referenced=set(), today="20260905",
                          keep_names={"clang-24-trunk20260801.tar.xz",
                                      "gcc-17-trunk20260802.tar.xz"})
    expect("foreign name in keep_names leaves the plan untouched",
           fam_plan == [], str(fam_plan))
    # But a foreign name that reaches the plan as one of the family's
    # assets must raise even when both protection sets would cover it:
    # the family/date match runs before any keep short-circuit.
    foreign = "clang-24-trunk20260801.tar.xz"
    for prot in ({"referenced": {foreign}},
                 {"referenced": set(), "keep_names": {foreign}},
                 {"referenced": {foreign}, "keep_names": {foreign}}):
        try:
            prune_plan([foreign], gcc_rx, today="20260905", **prot)
            expect("protected foreign asset still raises", False)
        except ValueError:
            expect("protected foreign asset still raises", True)

    # classify_asset: every rename scheme classed trunk-renamed; the legacy
    # two classed legacy; raw dated keys classed trunk-raw; junk unknown
    cls_ok = True
    for fam, frec in sorted(families.items()):
        cls, info = classify_asset(rename_render(frec["rename"], 17, "20260904"),
                                   catalog)
        if cls != ("legacy" if rename_render(frec["rename"], 17, "20260904")
                   in LEGACY_ADOPT else "trunk-renamed") \
                or info is None or info["family"] != fam \
                or info["rx"].match(rename_render(frec["rename"], 17, "20260904"))["date"] != "20260904":
            cls_ok = False
            print(f"  classify mismatch {fam}: {cls} {info}")
    expect("classify_asset across all 9 schemes (+legacy pair)", cls_ok)
    expect("legacy names classed legacy",
           all(classify_asset(n, catalog)[0] == "legacy" for n in LEGACY_ADOPT))
    expect("raw undated leftover classed trunk-raw",
           classify_asset("gcc-trunk-20260904.tar.xz", catalog)[0] == "trunk-raw")
    expect("junk classed unknown",
           classify_asset("totally-unrelated.tar.gz", catalog)[0] == "unknown")

    # ---------------- ELF parser on fixtures: both classes, both
    # endiannesses, mutation rejected
    elf = parse_elf(_mk_elf(62, ("libc.so.6", "libm.so.6"), enc=1))
    expect("elf64 LE parse", elf is not None and elf["emachine"] == 62 and
           elf["needed"] == ["libc.so.6", "libm.so.6"], str(elf))
    elf32 = parse_elf(_mk_elf(20, ("libdl.so.2",), klass=1, enc=2))
    expect("elf32 BE parse", elf32 is not None and elf32["emachine"] == 20 and
           elf32["needed"] == ["libdl.so.2"], str(elf32))
    expect("non-ELF rejected",
           parse_elf(b"not an elf at all, trailing pad" + b" " * 64) is None)
    truncated = _mk_elf(62, ("libc.so.6",), enc=1)[:48]
    expect("truncated ELF rejected", parse_elf(truncated) is None)

    # ---------------- rename regex roundtrip across every scheme,
    # incl. riscv64's prefix form; no cross-family collisions
    for fam, frec in sorted(families.items()):
        name = rename_render(frec["rename"], 17, "20260904")
        m = rename_regex(frec["rename"]).match(name)
        expect(f"rename roundtrip {fam}", bool(m) and m["major"] == "17"
               and m["date"] == "20260904")
    expect("riscv64 rename does not collide with native",
           rename_regex(families["gcc-trunk"]["rename"]).match(
               "riscv64-gcc-17-trunk20260904.tar.xz") is None)
    expect("arm64 asset does not match arm-gcc-trunk scheme",
           rename_regex(families["arm-gcc-trunk"]["rename"]).match(
               rename_render(families["arm64-gcc-trunk"]["rename"], 17, "20260904")) is None)

    # ---------------- full analysis over the tar grammar real payloads use
    # (defect B control): directory members, nested two-level cross root,
    # plain single root, and ./-prefixed members; gz variant too.
    gcc_bin = _mk_elf(62, ("libc.so.6", "libm.so.6"), enc=1)
    nested_members = [
        ("gcc-7.5.0/", b"", 0o755),                       # directory member
        ("gcc-7.5.0/k1-unknown-elf/", b"", 0o755),        # directory member
        ("gcc-7.5.0/k1-unknown-elf/bin/", b"", 0o755),    # directory member
        ("gcc-7.5.0/k1-unknown-elf/bin/gcc", gcc_bin, 0o755),
        ("gcc-7.5.0/k1-unknown-elf/bin/g++", b"\0" * 8, 0o777),
        ("gcc-7.5.0/k1-unknown-elf/bin/ld", b"\0" * 8, 0o755),
        ("gcc-7.5.0/k1-unknown-elf/bin/as", b"\0" * 8, 0o755),
        ("gcc-7.5.0/k1-unknown-elf/bin/ar", b"\0" * 8, 0o755),
        ("gcc-7.5.0/k1-unknown-elf/lib/libgo.so.21", b"\0" * 8, 0o644),
        ("gcc-7.5.0/k1-unknown-elf/lib32/.keep", b"", 0o644),
        ("gcc-7.5.0/k1-unknown-elf/lib/gcc/k1-unknown-elf/7.5.0/crtbegin.o",
         _mk_elf(4919, (), enc=1), 0o644),
    ]
    fx = _mk_tar(nested_members)
    try:
        a = analyze_tarball(fx)
        expect("analysis nested cross root",
               a["root"] == {"dot_prefix": False, "nested": "k1-unknown-elf",
                             "strip": 2, "top": "gcc-7.5.0"}, str(a["root"]))
        expect("analysis bin over nested root",
               a["bin"] == ["ar", "as", "g++", "gcc", "ld"], str(a["bin"]))
        expect("analysis binutils", a["has_binutils"] and
               a["binutils_in_bin"] == ["ar", "as", "ld"])
        expect("analysis host", a["host_emachine"] == 62 and a["host_arch"] == "x86-64")
        expect("analysis needed", a["needed"] == ["libc.so.6", "libm.so.6"],
               str(a["needed"]))
        expect("analysis multilib", a["multilib"] == ["lib32"], str(a["multilib"]))
        expect("analysis libgo", a["libgo_soname"] == "libgo.so.21")
        expect("analysis version", a["gcc_version"] == "7.5.0"
               and a["gcc_targets"] == ["k1-unknown-elf"])
        expect("analysis target e_machine from crt (k1 class)",
               a["target_emachine"] == 4919 and a["target_arch"] == "kvarc")
        expect("major probe", probe_major(a, "k1-gcc", "fixture") == 7)

        # the SAME file set without directory members must give the same
        # analysis (directory members carry no information)
        fx_nodirs = _mk_tar([m for m in nested_members if not m[0].endswith("/")])
        try:
            b = analyze_tarball(fx_nodirs)
            expect("directory members change nothing", b == a)
        finally:
            _rm(fx_nodirs)
    finally:
        _rm(fx)

    # plain single root (stable shape: gcc-16.2.0/...), gz-compressed
    plain_members = [
        ("gcc-16.2.0/", b"", 0o755),
        ("gcc-16.2.0/bin/", b"", 0o755),
        ("gcc-16.2.0/bin/gcc", gcc_bin, 0o755),
        ("gcc-16.2.0/bin/g++", b"\0" * 8, 0o755),
        ("gcc-16.2.0/lib64/.keep", b"", 0o644),
        ("./gcc-16.2.0/lib/gcc/x86_64-linux-gnu/16.2.0/crtbegin.o",
         _mk_elf(62, (), enc=1), 0o644),
    ]
    fx = _mk_tar(plain_members, name="fixture.tar.gz", mode="w:gz")
    try:
        a = analyze_tarball(fx)
        expect("plain root (gz, ./-prefixed member)",
               a["root"] == {"dot_prefix": True, "nested": None, "strip": 1,
                             "top": "gcc-16.2.0"}, str(a["root"]))
        expect("plain root bin", a["bin"] == ["g++", "gcc"], str(a["bin"]))
        expect("plain root multilib", a["multilib"] == ["lib64"])
        expect("plain root version", a["gcc_version"] == "16.2.0")
        expect("not has_binutils", a["has_binutils"] is False)
    finally:
        _rm(fx)

    # a payload whose gcc and clang majors disagree with themselves is
    # refused rather than guessed (mirror.sh parity)
    broken = _mk_tar(nested_members + [("gcc-7.5.0/k1-unknown-elf/lib/gcc/"
                                        "k1-unknown-elf/8.1.0/crtbegin.o",
                                        gcc_bin, 0o644)])
    try:
        analyze_tarball(broken)
        expect("two gcc majors are refused (mirror.sh parity)", False)
    except ValueError:
        expect("two gcc majors are refused (mirror.sh parity)", True)
    finally:
        _rm(broken)

    # ---------------- version_source:"payload" gate (at12/at13 class)
    entry_at = {"asset": "powerpc64-gcc-at13.tar.xz", "version_source": "payload"}
    entry_name = {"asset": "gcc-16.2.0.tar.xz", "version_source": "name"}
    expect("payload-version entry needs a probed gcc version",
           check_version_source(entry_at, {"gcc_version": None}) is not None and
           check_version_source(entry_at, {"gcc_version": "13.3.0"}) is None and
           check_version_source(entry_name, {"gcc_version": None}) is None)

    # ---------------- link-aware bin/ inventory (S3 link rules read it)
    # A payload whose bin/ entries are hardlinks/symlinks must surface in
    # bin_links and count toward the binutils universe.
    tmp = Path(tempfile.mkdtemp(prefix="mirror-selftest-"))
    p = tmp / "linked.tar.xz"
    with tarfile.open(p, "w:xz") as tar:
        def _d(name):
            ti = tarfile.TarInfo(name)
            ti.type = tarfile.DIRTYPE
            tar.addfile(ti)

        def _f(name, data=b"", mode=0o755):
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            ti.mode = mode
            tar.addfile(ti, io.BytesIO(data))

        def _l(name, target, sym=False):
            ti = tarfile.TarInfo(name)
            ti.type = tarfile.SYMTYPE if sym else tarfile.LNKTYPE
            ti.linkname = target
            ti.mode = 0o777 if sym else 0o755
            tar.addfile(ti)
        _d("t/")
        _d("t/bin/")
        _f("t/bin/as", gcc_bin, 0o755)
        _f("t/bin/ar", gcc_bin, 0o755)
        _l("t/bin/ld", "t/bin/as")                    # hardlink, like real CE bins
        _l("t/bin/gcc", "t/bin/as")                   # a driver carried as a link
        _l("t/bin/gp-x", "gprofng-archive", sym=True)  # relative symlink
        _d("t/lib/")
        _d("t/lib/gcc/")
        _d("t/lib/gcc/t/")
        _d("t/lib/gcc/t/1.2.3/")
        _f("t/lib/gcc/t/1.2.3/crtbegin.o", _mk_elf(62, (), enc=1), 0o644)
        _d("t/tgt/")
        _d("t/tgt/bin/")
        _f("t/tgt/bin/as", gcc_bin, 0o644)   # target-subdir binutils member
    try:
        a = analyze_tarball(p)
        expect("bin_links records hard+sym links, files stay files",
               a["bin"] == ["ar", "as"]
               and a["bin_links"] == {
                   "gcc": {"target": "as", "type": "hardlink"},
                   "gp-x": {"target": "gprofng-archive", "type": "symlink"},
                   "ld": {"target": "as", "type": "hardlink"}},
               str({k: a[k] for k in ("bin", "bin_links")}))
        expect("has_binutils counts the link universe",
               a["has_binutils"] and a["binutils_in_bin"] == ["ar", "as", "ld"],
               str(a["binutils_in_bin"]))
        expect("target_bin records the target-subdir bin",
               a["target_bin"] == ["as"], str(a["target_bin"]))

        # ---------------- reanalyze-legacy row gate: digest mismatch refuses,
        # release-proven bytes are recorded, pipeline drift is named
        bad_row = {"asset": "linked.tar.xz", "sha256": "0" * 64, "analysis": None}
        try:
            reanalyze_row(bad_row, p)
            expect("reanalyze refuses a wrong recorded digest", False)
        except SystemExit as e:
            expect("reanalyze refuses a wrong recorded digest",
                   "linked.tar.xz" in str(e), str(e))
        ok_row = {"asset": "linked.tar.xz", "sha256": sha256_path(p),
                  "analysis": None}
        reanalyze_row(ok_row, p)
        expect("reanalyze records release-proven analysis",
               ok_row["analysis"]["bin"] == ["ar", "as"]
               and ok_row["analysis_source"] == "release")
        # refresh of an old-schema row must pass and must catch pipeline drift
        stale_row = {"asset": "linked.tar.xz", "sha256": sha256_path(p),
                     "analysis": {k: v for k, v in ok_row["analysis"].items()
                                  if k != "bin_links"}}
        reanalyze_row(stale_row, p)
        expect("schema-stale refresh reproduces recorded fields",
               stale_row["analysis"]["bin_links"]["ld"]["target"] == "as")
        drift_row = json.loads(json.dumps(stale_row))
        drift_row["analysis"]["bin"] = ["as"]  # ar gone: a different past
        try:
            reanalyze_row(drift_row, p)
            expect("pipeline drift in a refreshed row is caught", False)
        except SystemExit as e:
            expect("pipeline drift in a refreshed row is caught",
                   "bin" in str(e), str(e))
    finally:
        _rm(p)

    # ---------------- manifest canonical form is byte-stable
    m = {"meta": manifest_meta(), "rows": {"a": {"b": [2, 3], "z": 1}}}
    data = json.dumps(m, indent=2, sort_keys=True) + "\n"
    again = json.dumps(json.loads(data), indent=2, sort_keys=True) + "\n"
    expect("manifest byte-stable canonical form",
           data == again and data.endswith("\n") and '"b": [\n' in data)

    # ---------------- pending arithmetic against the REAL catalog
    # Full coverage: one row per packaged asset and, per family, one row at
    # the family's live-latest date -> pending is exactly empty.
    rows_full = {e["asset"]: {"asset": e["asset"], "kind": "stable"}
                 for e in catalog["packaged"]}
    latest = {fam: rec["latest_key"].removesuffix(".tar.xz").rsplit("-", 1)[1]
              for fam, rec in catalog["trunk_families"].items()}
    for fam, d in latest.items():
        rows_full[f"{fam}-{d}.tar.xz"] = {"asset": "x", "kind": "trunk", "family": fam}
    pend = pending_payloads(catalog, rows_full, latest)
    expect("catalog fully covered -> pending empty", pend == [], str(pend[:5]))
    del rows_full[catalog["packaged"][0]["asset"]]
    missing = catalog["packaged"][0]["asset"]
    pend = pending_payloads(catalog, rows_full, latest)
    expect("one missing packaged asset is the one pending",
           pend == [missing], str(pend))
    fam0 = sorted(catalog["trunk_families"])[0]
    del rows_full[f"{fam0}-{latest[fam0]}.tar.xz"]
    pend = pending_payloads(catalog, rows_full, latest)
    expect("one missing trunk date is the one pending",
           pend == [missing, f"{fam0}-{latest[fam0]}.tar.xz (trunk pending)"],
           str(pend))
    expect("fixture decision: --complete gives 2",
           check_decision([], pend, True) == 2)

    print("selftest:", "clean" if rc == 0 else "FAILURES above")
    return rc


# ---------------------------------------------------------------- main

def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 1
    cmd, rest = argv[0], argv[1:]
    if cmd == "sync":
        max_downloads, selectors = None, []
        dry_run = False
        i = 0
        while i < len(rest):
            if rest[i] == "--max":
                max_downloads = int(rest[i + 1])
                i += 2
            elif rest[i] == "--dry-run":
                dry_run = True
                i += 1
            else:
                selectors.append(rest[i])
                i += 1
        return cmd_sync(max_downloads, selectors, dry_run)
    if cmd == "check":
        return cmd_check("--complete" in rest)
    if cmd == "reanalyze-legacy":
        return cmd_reanalyze_legacy("--include-stale" in rest)
    if cmd == "selftest":
        return cmd_selftest()
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
