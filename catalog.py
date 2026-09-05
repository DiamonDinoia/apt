#!/usr/bin/env python3
"""Classify the Compiler Explorer tool bucket into Debian package candidates.

Reads the full listing of s3.amazonaws.com/compiler-explorer under opt/ and
splits every key into exactly one of: packaged stables (latest point release
per series), in-scope trunk families (dated nightlies, recorded per family),
named skips ({key, reason}), and skip families (date-stamped keys of rotating
families, recorded per family so a nightly date rotation does not flip check).
Keys under opt/.buildrevs/ are excluded from classification. The result is
written to catalog.json; later stages (S2 packager, S3 P/C/R corpora) consume
the recorded classes, so the classification rules here are the contract.

catalog.json sections:
  meta           inputs of the run: ce_yaml_ref (compiler-explorer/infra commit
                 the served-set came from), source URLs, listing_max_modified
                 (max Last-Modified of the listing; input-derived, so a re-run
                 over identical inputs is byte-identical: sorted everywhere,
                 no wall-clock fields)
  schema         this schema, for standalone readers
  listing        every live key -> {bytes, modified}
  listing_keys   sorted(listing); what check diffs against
  debian         per-suite inventory scraped from deb.debian.org, in six
                 buckets: compilers (per-series driver/frontend/tool splits),
                 cross_compilers (per-series tool-N-<triplet>), cross and
                 native dev libs, runtime_and_base_packages (the names
                 build.py's denylist governs, recorded so the denylist is
                 evidence-backed), and other_compiler_packages (the rest of
                 the gcc/clang family stems) — all with the exact version
                 strings Debian ships. The inventory is ground truth; what
                 may be claimed from it is build.py's decision, not made here.
  packaged       list of entries:
    key            bucket key (opt/...)
    asset          payload basename
    name           Debian package name this maps to
    regime         "debian" (native or versioned cross name), "unversioned"
                   (Debian ships the family without a series), "nodebian"
                   (no Debian analog; name is ours)
    series         package series (Debian spelling: two components iff the
                   major is <= 4, e.g. gcc-4.9 / clang-3.9; else gcc-16)
    version        payload version, "" when not in the name
    version_parts  version as list of ints
    version_source "name" or "payload" (payload = probe the tarball, S2 work)
    family         bucket family (gcc, clang, arm-gcc, vax, ...)
    triplet        Debian GNU triplet; null only when the target has no
                   Debian-style triplet at all (bare-metal families)
    expected_arch  string readelf -h prints in Machine: for the target's
                   e_machine, probed with crafted ELF headers against the
                   host readelf (binutils 2.47); expected_arch_alts lists
                   other spellings S2 must also accept
    smoke          provisional level: L0 = --version + ldd, L1 = + C,
                   L2 = + C++ (era defaults: gcc < 5 -> L1, >= 5 -> L2;
                   clang <= 3.9 -> L1 pending S4, 4+ -> L2; cross -> L1)
    format         xz | gz
    served         true iff the CE infra yaml (at ce_yaml_ref) installs this
                   artifact
    pcr            "debian" when a Debian package relation exists for S3's
                   Provides/Conflicts/Replaces corpus, "none" otherwise
    ce_targets     CE arch_prefix values the yaml records for this artifact
    size_bytes     payload size from the listing
    notes          optional rationale
  trunk_families per in-scope dated-nightly family: family, rename (scheme
                 for the deb version; {major} and {date} are probed from the
                 payload downstream), triplet, regime, expected_arch, smoke,
                 served, latest_key/latest_modified/latest_size_bytes,
                 dated_count, notes
  skips         [{key, reason}] for undated non-packaged keys
  skip_families [{family, reason}] for date-stamped families out of scope;
                 the date rotates (CE keeps the last 5 nightlies), so only
                 the family is pinned

Decisions baked in (do not relitigate here):
- Latest point release per series is packaged; older point releases are
  skips with reason "superseded by <latest>".
- gcc-1.27 is a named skip: 32-bit i386-only toolchain, this repo is
  amd64-only.
- The renovated trio gcc-renovated-{3.4.6,4.0.4,6.5.0}.tar.xz is packaged and
  verified served by CE. gcc-6.5.0-renovated is the series-6 latest, so
  native gcc-6.4.0 becomes the superseded skip of series 6.
- gcc-4.8.0 is packaged although CE never served it (E2): the bucket keeps
  it and the decision is to ship it. It gets the point-versioned name
  gcc-4.8.0 because gcc-4.8 is taken by the series latest 4.8.5.
- vax is one family; gcc-vax--netbsdelf-<ver>-<date> is the canonical
  spelling (it has the fresh builds); the vax-netbsd(elf)-gcc spellings are
  named skips.
- powerpc64{,le}-gcc-at12/at13 have no gcc version in the name:
  version_source "payload", series at12/at13.
- sparc-leon-gcc-12.2.0-1 carries an extra build tag, tolerated by the
  version parser.
- Only 9 trunk families are in scope: native gcc-trunk/clang-trunk and the
  cross arm/arm64/bpf/powerpc64/powerpc64le/riscv32/riscv64 -gcc-trunk.
  Undated frozen aliases (arm64-gcc-trunk.tar.xz) are named skips.
- clang-assertions-*/gcc-assertions-* are named skips (decision).
- gcc-ce-* is a mingw32ce (Windows CE) cross with no Debian analog: skip.

Commands:
  generate   fetch listing + CE infra yaml + Debian suites, write catalog.json
  check      re-list the bucket live; every live key must be covered by the
             recorded packaged/skip/trunk-family/skip-family classes and vice
             versa; exit 0 clean, 2 naming every gap, 1 operational error
  selftest   positive control: replay check's comparison over the recorded
             snapshot, clean and with the fixture mutations (fake key
             opt/gcc-99.1.0.tar.xz added, one skip removed); exits 0 only if
             the clean half passes and the mutated half fails naming both.

Requires python >= 3.11, stdlib only.
"""

from __future__ import annotations

import copy
import io
import json
import lzma
import re
import sys
import tarfile
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).parent
CATALOG = ROOT / "catalog.json"

BUCKET = "https://s3.amazonaws.com/compiler-explorer/"
PREFIX = "opt/"
S3_NS = "{http://s3.amazonaws.com/doc/2006-03-01/}"
INFRA_REPO = "https://api.github.com/repos/compiler-explorer/infra"
INFRA_ARCHIVE = "https://github.com/compiler-explorer/infra/archive/{}.tar.gz"
DEBIAN_INDEX = "https://deb.debian.org/debian/dists/{}/main/binary-amd64/Packages.xz"
DEBIAN_SUITES = ("sid", "trixie")
UA = {"User-Agent": "diamondinoia-apt catalog"}

TRUNK_FAMILIES = (
    "gcc-trunk",
    "clang-trunk",
    "arm-gcc-trunk",
    "arm64-gcc-trunk",
    "bpf-gcc-trunk",
    "powerpc64-gcc-trunk",
    "powerpc64le-gcc-trunk",
    "riscv32-gcc-trunk",
    "riscv64-gcc-trunk",
)

# expected_arch values are the Machine: strings of the host readelf
# (binutils 2.47), probed on crafted ELF headers carrying each e_machine.
# _alts lists spellings a payload binary may also legitimately print.
ARCH_X86 = "Advanced Micro Devices X86-64"
SPARC32 = {"arch": "Sparc v8+", "expected_arch_alts": ["Sparc"],
           "notes_arch": "sparc v8 toolchains usually emit EM_SPARC32PLUS; plain EM_SPARC accepted"}

# family -> naming/classification record. label is our name component for
# regime != debian. debian_analog names the unversioned Debian package.
FAMILIES = {
    "arm64-gcc":       {"triplet": "aarch64-linux-gnu",     "regime": "debian", "arch": "AArch64"},
    "arm-gcc":         {"triplet": "arm-linux-gnueabihf",   "regime": "debian", "arch": "ARM"},
    "mips-gcc":        {"triplet": "mips-linux-gnu",        "regime": "debian", "arch": "MIPS R3000"},
    "mips64-gcc":      {"triplet": "mips64-linux-gnuabi64", "regime": "debian", "arch": "MIPS R3000"},
    "mipsel-gcc":      {"triplet": "mipsel-linux-gnu",      "regime": "debian", "arch": "MIPS R3000"},
    "mips64el-gcc":    {"triplet": "mips64el-linux-gnuabi64", "regime": "debian",
                        "arch": "MIPS R3000"},
    "powerpc-gcc":     {"triplet": "powerpc-linux-gnu",     "regime": "debian", "arch": "PowerPC"},
    "powerpc64-gcc":   {"triplet": "powerpc64-linux-gnu",   "regime": "debian", "arch": "PowerPC64"},
    "powerpc64le-gcc": {"triplet": "powerpc64le-linux-gnu", "regime": "debian", "arch": "PowerPC64"},
    "s390x-gcc":       {"triplet": "s390x-linux-gnu",       "regime": "debian", "arch": "IBM S/390"},
    "sparc64-gcc":     {"triplet": "sparc64-linux-gnu",     "regime": "debian", "arch": "Sparc v9"},
    "m68k-gcc":        {"triplet": "m68k-linux-gnu",        "regime": "debian", "arch": "MC68000"},
    "loongarch64-gcc": {"triplet": "loongarch64-linux-gnu", "regime": "debian", "arch": "LoongArch"},
    "sh-gcc":          {"triplet": "sh4-linux-gnu",         "regime": "debian",
                        "arch": "Renesas / SuperH SH"},
    "hppa-gcc":        {"triplet": "hppa-linux-gnu",        "regime": "debian", "arch": "HPPA"},
    "avr-gcc":       {"triplet": None, "regime": "unversioned", "label": "avr",
                      "debian_analog": "gcc-avr", "arch": "Atmel AVR 8-bit microcontroller"},
    "arm-unknown-gcc": {"triplet": None, "regime": "unversioned", "label": "arm-none-eabi",
                        "debian_analog": "gcc-arm-none-eabi", "arch": "ARM"},
    "msp430-gcc":    {"triplet": None, "regime": "nodebian", "label": "msp430",
                      "arch": "Texas Instruments msp430 microcontroller"},
    "bpf-gcc":       {"triplet": None, "regime": "nodebian", "label": "bpf", "arch": "Linux BPF"},
    "c6x-gcc":       {"triplet": None, "regime": "nodebian", "label": "c6x",
                      "arch": "Texas Instruments TMS320C6000 DSP family"},
    "k1-gcc":        {"triplet": None, "regime": "nodebian", "label": "k1",
                      "arch": "KM211 KVARC processor",
                      "notes_arch": "assumes EM_KVARC (214); confirm against the payload in S2"},
    "tricore-gcc":   {"triplet": None, "regime": "nodebian", "label": "tricore", "arch": "Siemens Tricore"},
    "sparc-gcc":     {"triplet": None, "regime": "nodebian", "label": "sparc", **SPARC32},
    "sparc-leon-gcc": {"triplet": None, "regime": "nodebian", "label": "sparc-leon", **SPARC32},
    "riscv32-gcc":   {"triplet": None, "regime": "nodebian", "label": "riscv32", "arch": "RISC-V"},
    "vax":           {"triplet": None, "regime": "nodebian", "label": "vax", "arch": "Digital VAX"},
}

# Matching order matters: longest family names first (sparc-leon before
# sparc, powerpc64le before powerpc64, mips64el before mips64/mips, mips64
# before mips).
_CROSS_BY_LEN = sorted(
    (f for f in FAMILIES if f != "vax"), key=len, reverse=True)
CROSS_RE = re.compile(
    r"^(" + "|".join(map(re.escape, _CROSS_BY_LEN))
    + r")-(\d+(?:\.\d+){1,2})(?:-(\d+))?\.tar\.xz$")
NATIVE_GCC_RE = re.compile(r"^gcc-(\d+(?:\.\d+){0,2})\.tar\.(xz|gz)$")
RENOVATED_RE = re.compile(r"^gcc-renovated-(\d+\.\d+\.\d+)\.tar\.xz$")
NATIVE_CLANG_RE = re.compile(r"^clang-(\d+(?:\.\d+){0,2})\.tar\.(xz|gz)$")
VAX_RE = re.compile(
    r"^(gcc-vax--netbsdelf|vax-netbsdelf-gcc|vax-netbsd-gcc)-(\d+\.\d+\.\d+)"
    r"(?:-(\d{4}-\d{2}-\d{2}))?\.tar\.xz$")
AT_RE = re.compile(r"^(powerpc64|powerpc64le)-gcc-(at12|at13)\.tar\.xz$")
DATED_RE = re.compile(r"^(.+)-(\d{8})\.tar\.(?:xz|gz|bz2)$")

REASON_ASSERTIONS = "assertions build; excluded by decision"
REASON_EXOTIC = "experimental branch nightly; family out of scope"
REASON_TOOL = "not a gcc/clang compiler toolchain"
REASON_TI = "served from ti.com, not mirrorable"

# Bucket-only stables kept although CE does not serve them (E2). The name
# carries the full point version because <compiler>-<series> is the series
# latest's name.
EXTRA_PACKAGED = {
    "gcc-4.8.0.tar.xz": "not served by CE (absent from the infra yaml targets); "
                        "packaged by decision because the bucket keeps it",
}

NAMED_SKIP_KEYS = {
    "gcc-1.27.tar.xz": "i386-only 32-bit toolchain; this repo is amd64-only",
}


def fetch(url: str, timeout: int = 120) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def fetch_listing() -> dict[str, dict]:
    """Full opt/ listing: key -> {bytes, modified}."""
    out: dict[str, dict] = {}
    start_after: str | None = None
    while True:
        url = f"{BUCKET}?list-type=2&prefix={PREFIX}"
        if start_after is not None:
            url += "&start-after=" + urllib.parse.quote(start_after)
        root = ET.fromstring(fetch(url))
        for c in root.findall(S3_NS + "Contents"):
            key = c.find(S3_NS + "Key").text
            out[key] = {
                "bytes": int(c.find(S3_NS + "Size").text),
                "modified": c.find(S3_NS + "LastModified").text,
            }
        if root.find(S3_NS + "IsTruncated").text != "true":
            return out
        start_after = next(reversed(out))


# ---------------------------------------------------------------- mini yaml
#
# A strict parser for the YAML subset the CE infra bin/yaml/*.yaml files use:
# nested block maps by two-space indentation, block sequences of scalars or
# maps, quoted scalars, single-line flow maps/lists, comments, block scalars
# (content discarded, aliases resolved), anchors. Anything else is a hard
# error: guessing here would silently misread which compilers CE serves.

class YamlError(ValueError):
    pass


def _indent(line: str) -> int:
    if "\t" in line[: len(line) - len(line.lstrip())]:
        raise YamlError(f"tab indentation: {line!r}")
    return len(line) - len(line.lstrip(" "))


def _content_lines(text: str) -> list[tuple[int, str, int]]:
    lines = []
    for n, raw in enumerate(text.splitlines(), 1):
        stripped_chars = []
        quote = None
        for i, ch in enumerate(raw):
            if quote == "'":
                quote = None if ch == "'" else quote
            elif quote == '"':
                quote = None if ch == '"' else quote
            elif ch in "'\"":
                quote = ch
            elif ch == "#" and (i == 0 or raw[i - 1] in " \t"):
                raw = raw[:i]
                break
            stripped_chars.append(ch)
        raw = "".join(stripped_chars).rstrip()
        if raw.strip():
            lines.append((_indent(raw), raw.strip(), n))
    return lines


def _split_flow(body: str) -> list[str]:
    parts, depth, quote, start = [], 0, None, 0
    for i, ch in enumerate(body):
        if quote:
            quote = None if ch == quote else quote
        elif ch in "'\"":
            quote = ch
        elif ch in "{[":
            depth += 1
        elif ch in "]}":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(body[start:i])
            start = i + 1
    parts.append(body[start:])
    return [p.strip() for p in parts if p.strip()]


class _Parser:
    def __init__(self, text: str):
        self.lines = _content_lines(text)
        self.anchors: dict[str, object] = {}

    def parse(self):
        if not self.lines:
            return None
        obj, pos = self._block(0, self.lines[0][0])
        if pos != len(self.lines):
            raise YamlError(f"trailing content at line {self.lines[pos][2]}")
        return obj

    def _block(self, pos: int, indent: int):
        if self.lines[pos][1].startswith("- ") or self.lines[pos][1] == "-":
            return self._seq(pos, indent)
        return self._map(pos, indent)

    def _map(self, pos: int, indent: int):
        out = {}
        n = len(self.lines)
        while pos < n:
            ind, text, nline = self.lines[pos]
            if ind < indent:
                break
            if ind > indent:
                raise YamlError(f"over-indented line {nline}: {text!r}")
            if text.startswith("- ") or text == "-":
                break
            m = re.match(r"^([^:]+?)(?::(?:\s+(.*))?)?$", text)
            if not m or not m.group(1).strip():
                raise YamlError(f"not a key line {nline}: {text!r}")
            key, value = m.group(1).strip(), m.group(2)
            if value is not None and not value.strip():
                value = None
            pos += 1
            out[key], pos = self._value(pos, ind, value, nline)
        return out, pos

    def _seq(self, pos: int, indent: int):
        out = []
        n = len(self.lines)
        while pos < n:
            ind, text, nline = self.lines[pos]
            if ind < indent or not (text.startswith("- ") or text == "-"):
                break
            if ind > indent:
                raise YamlError(f"over-indented sequence item at line {nline}")
            rest = text[1:].strip()
            col = ind + 2
            if not rest:
                pos += 1
                nxt = pos
                while nxt < n and self.lines[nxt][0] > ind:
                    nxt += 1
                if nxt == pos:
                    out.append(None)
                    continue
                child_ind = self.lines[pos][0]
                if child_ind < col:
                    child_ind = ind + 1
                sub, pos = self._block(pos, child_ind)
                out.append(sub)
                continue
            if rest.startswith("{"):
                out.append(self._scalar(rest, nline))
                pos += 1
                continue
            km = re.match(r"^([^:{]+?):(?:\s+(.*))?$", rest)
            if km:
                key = km.group(1).strip()
                nxt = pos + 1
                while nxt < n and self.lines[nxt][0] >= col:
                    nxt += 1
                sub_lines = [(col, rest, nline)] + self.lines[pos + 1: nxt]
                sub = _Parser.__new__(_Parser)
                sub.lines, sub.anchors = sub_lines, self.anchors
                item, used = sub._map(0, col)
                if used != len(sub_lines):
                    raise YamlError(f"unconsumed map item near line {nline}")
                out.append(item)
                pos = nxt
                continue
            val = self._scalar(rest, nline)
            pos += 1
            # A plain scalar folds across following more-indented lines.
            while pos < n and self.lines[pos][0] >= col:
                if isinstance(val, (dict, list)) or val is None:
                    raise YamlError(f"unexpected continuation after line {nline}")
                val = val + " " + self.lines[pos][1]
                pos += 1
            out.append(val)
        return out, pos

    def _value(self, pos: int, indent: int, value: str | None, nline: int):
        anchor = None
        if value is not None:
            am = re.match(r"^&([\w.-]+)\s*(.*)$", value)
            if am:
                anchor = am.group(1)
                value = am.group(2) or None
        if (value is not None and value[:1] in ("'", '"')
                and not (len(value) > 1 and value.endswith(value[0]))):
            # Multi-line quoted scalar (used for scripts): opaque here, but
            # the closing quote must exist or the file is unsupported input.
            quote = value[0]
            start = nline
            while pos < len(self.lines):
                _, text, ln = self.lines[pos]
                pos += 1
                if text.endswith(quote) and not text.endswith(quote * 2):
                    break
            else:
                raise YamlError(f"unterminated quoted scalar starting at line {start}")
            return None, pos
        if value is not None and re.match(r"^[|>][+-]?[0-9]?$", value):
            n = len(self.lines)
            start = pos
            block_ind = None
            while pos < n:
                ind = self.lines[pos][0]
                if ind <= indent:
                    break
                if block_ind is None:
                    block_ind = ind
                pos += 1
            return (None, pos) if anchor is None else (self._store(anchor, None), pos)
        if value is None:
            n = len(self.lines)
            if pos < n and (self.lines[pos][0] > indent
                            or (self.lines[pos][0] == indent
                                and self.lines[pos][1].startswith(("- ", "-")))):
                child_ind = self.lines[pos][0]
                child, pos = self._block(pos, child_ind)
            else:
                child = None
        else:
            child = self._scalar(value, nline)
        if anchor is not None:
            self.anchors[anchor] = child
        return child, pos

    def _store(self, anchor: str, value):
        self.anchors[anchor] = value
        return value

    def _scalar(self, tok: str, nline: int):
        tok = tok.strip()
        if tok.startswith("*"):
            name = tok[1:]
            if name not in self.anchors:
                raise YamlError(f"unresolved alias *{name} at line {nline}")
            return self.anchors[name]
        if tok.startswith("{"):
            if not tok.endswith("}"):
                raise YamlError(f"multiline flow map at line {nline}: {tok!r}")
            out = {}
            for part in _split_flow(tok[1:-1]):
                km = re.match(r"^([^:]+?):(?:\s+(.*))?$", part)
                if not km:
                    raise YamlError(f"flow map entry without key at line {nline}")
                out[km.group(1).strip()] = self._scalar(km.group(2), nline)
            return out
        if tok.startswith("["):
            if not tok.endswith("]"):
                raise YamlError(f"multiline flow list at line {nline}: {tok!r}")
            return [self._scalar(p, nline) for p in _split_flow(tok[1:-1])]
        if tok.startswith("'"):
            if not tok.endswith("'") or len(tok) < 2:
                raise YamlError(f"unterminated quote at line {nline}: {tok!r}")
            return tok[1:-1].replace("''", "'")
        if tok.startswith('"'):
            if not tok.endswith('"') or len(tok) < 2:
                raise YamlError(f"unterminated quote at line {nline}: {tok!r}")
            return tok[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        if re.fullmatch(r"[0-9][0-9_]*", tok):
            # PyYAML (what CE runs) reads 4_01_00_00 as the int 4010000.
            return tok.replace("_", "")
        return tok


def parse_yaml(text: str):
    return _Parser(text).parse()


# ---------------------------------------------------------- CE served set
#
# Emulates _targets_from in infra's bin/lib/installation.py plus the
# S3TarballInstallable/NightlyInstallable naming rules: config folds down the
# tree, list items are walked with equal context, and per-target keys
# override the folded config (ChainMap semantics).

def _render(template: str, pool: dict[str, str], what: str) -> str:
    def sub(m: re.Match) -> str:
        key = m.group(1)
        if key not in pool:
            raise YamlError(f"{what}: template {template!r} needs {key!r}, not in config")
        return pool[key]
    return re.sub(r"\{\{(\w+)\}\}", sub, template)


def ce_served_set(archive: bytes) -> tuple[dict[str, list[str]], set[str]]:
    """s3 artifact basename -> sorted CE arch_prefixes, and nightly families."""
    served: dict[str, set[str]] = {}
    nightlies: set[str] = set()
    files = 0
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        for member in tar.getmembers():
            if not re.match(r"^[^/]+/bin/yaml/[^/]+\.yaml$", member.name):
                continue
            files += 1
            doc = parse_yaml(tar.extractfile(member).read().decode())

            def walk(node, ctx, cfg, fname=member.name):
                if isinstance(node, list):
                    for child in node:
                        walk(child, ctx, cfg)
                    return
                if not isinstance(node, dict):
                    return
                cfg = dict(cfg)
                for k, v in node.items():
                    if k != "targets" and isinstance(v, (str, int, float)) and not isinstance(v, bool):
                        cfg[k] = str(v)
                for k, v in node.items():
                    if isinstance(v, (dict, list)):
                        walk(v, ctx + [k], cfg)
                for target in node.get("targets") or []:
                    td = target if isinstance(target, dict) else {"name": target}
                    if not isinstance(td, dict):
                        raise YamlError(f"{fname}: strange target {target!r}")
                    eff = dict(cfg)
                    eff.update({k: str(v) for k, v in td.items()
                                if isinstance(v, (str, int, float)) and not isinstance(v, bool)})
                    typ = eff.get("type")
                    if typ not in ("s3tarballs", "nightly"):
                        continue
                    if "name" not in td or td["name"] is None:
                        raise YamlError(f"{fname}: {typ} target without name: {target!r}")
                    if typ == "s3tarballs":
                        name = eff["name"]
                        subdir = eff.get("subdir", "")
                        prefix = eff.get("s3_path_prefix") or (
                            f"{subdir}-{ctx[-1]}-{name}" if subdir else f"{ctx[-1]}-{name}")
                        comp = eff.get("compression", "xz")
                        art = _render(prefix, eff, fname) + ".tar." + comp
                        served.setdefault(art, set())
                        if eff.get("arch_prefix"):
                            served[art].add(_render(eff["arch_prefix"], eff, fname))
                    elif typ == "nightly":
                        cname = eff.get("compiler_name") or f"{ctx[-1]}-{eff['name']}"
                        nightlies.add(_render(cname, eff, fname))

            walk(doc, [], {})
    if files == 0:
        raise OSError("infra archive contains no bin/yaml/*.yaml files")
    # Postconditions: a misparse that loses the C++ compilers must not pass.
    must = {"gcc-4.8.5.tar.xz", "gcc-renovated-3.4.6.tar.xz",
            "gcc-renovated-4.0.4.tar.xz", "gcc-renovated-6.5.0.tar.xz",
            "clang-3.2.tar.gz", "clang-3.3.tar.gz", "clang-16.0.0.tar.xz",
            "arm-gcc-12.5.0.tar.xz", "arm64-gcc-16.1.0.tar.xz",
            "gcc-ce-8.2.0.tar.xz", "arm-unknown-gcc-13.2.0.tar.xz",
            "gcc-vax--netbsdelf-12.4.0-2025-04-16.tar.xz",
            "k1-gcc-7.5.0.tar.xz", "tricore-gcc-11.3.0.tar.xz"}
    missing = sorted(must - set(served))
    if missing:
        raise ValueError(f"CE served-set lost expected artifacts: {missing}")
    if "gcc-4.8.0.tar.xz" in served:
        raise ValueError("gcc-4.8.0 must stay unserved by CE yaml (E2 assumption broke)")
    return {k: sorted(v) for k, v in served.items()}, nightlies


def ce_yaml_ref() -> str:
    data = json.loads(fetch(f"{INFRA_REPO}/commits/main"))
    return data["sha"]


# ---------------------------------------------------------- debian scrape
#
# Debian splits one compiler series across many packages. The inventory
# records every gcc/clang-family name in six buckets, matched in listed
# order with the stem catch-all last:
#   compilers                  per-series driver/frontend/tool splits
#                              (gcc-N, g++-N, cpp-N, gfortran-N, ..., clang-N,
#                              clang-tools-N, clang-tidy-N, clang-format-N,
#                              clangd-N, lld-N, lldb-N)
#   cross_compilers            per-series tool-N-<triplet> cross compilers
#   cross_dev_libs             arch-spelled cross dev libs
#                              (libgcc-N-dev-arm64-cross class)
#   native_dev_libs            per-series native dev libs
#                              (libstdc++-N-dev, libclang-18-dev, libomp-N-dev)
#   runtime_and_base_packages  runtime soname packages (libgcc-s1,
#                              libstdc++6, libgnat-14, libc++1-18, ...) and
#                              -base/-cross-base packages — recorded so
#                              build.py's P/C/R denylist is evidence-backed
#   other_compiler_packages    everything else under the family stems
# The stems carry boundary anchors so look-alikes stay out: lldpad/lldpd are
# LLDP daemons (not lld-N), cppcheck/cppman are not cpp-N, and libobjcryst,
# libompl*, libomp-jonathonl and libclang-perl are not the compiler libs.

_DEB_TRIPLET = r"[a-z0-9][a-z0-9+]*-linux-gnu[a-z0-9+]*"
_DEB_FRONTENDS = (r"gcc|g\+\+|cpp|gfortran|gccgo|gdc|gm2|gcobol|gccrs|gnat|"
                  r"gobjc|gobjc\+\+")
_DEB_CLANG_TOOLS = r"clang(?:-tools|-tidy|-format)?|clangd|lld|lldb"

_DEBIAN_RULES = (
    ("compilers", re.compile(
        rf"^(?:{_DEB_FRONTENDS}|{_DEB_CLANG_TOOLS})-\d+(?:\.\d+)?$")),
    ("cross_compilers", re.compile(
        rf"^(?:{_DEB_FRONTENDS})-\d+-{_DEB_TRIPLET}$")),
    ("cross_dev_libs", re.compile(
        r"^(?:libgcc|libstdc\+\+|libgfortran|libobjc)-\d+-dev-[a-z0-9]+-cross$")),
    ("native_dev_libs", re.compile(
        r"^(?:libgcc|libstdc\+\+|libgccjit)-\d+-dev$"
        r"|^libclang(?:-common|-rt)?-\d+-dev$|^libclang-cpp\d+-dev$"
        r"|^libc\+\+(?:abi)?-\d+-dev$"
        r"|^libomp-\d+-dev$|^libunwind-\d+-dev$")),
    ("runtime_and_base_packages", re.compile(
        r"^(?:libgcc-s\d+|libstdc\+\+\d+|libgomp\d+|libatomic\d+|"
        r"libgfortran\d+|libobjc\d+|libgnat-\d+)(?:-[a-z0-9]+-cross)?$"
        r"|^libgccjit\d+$"
        r"|^libc\+\+1?-\d+$|^libclang1-\d+$|^libclang-cpp\d+$"
        r"|^libomp\d+-\d+$|^libunwind-\d+$"
        r"|^gcc-\d+(?:\.\d+)?-base$"
        r"|^gcc-\d+(?:\.\d+)?-cross-base(?:-[a-z]+)?$"
        rf"|^gcc-\d+(?:\.\d+)?-{_DEB_TRIPLET}-base$")),
)
_DEBIAN_STEMS_RE = re.compile(
    r"^(?:gcc|g\+\+|gobjc|gfortran|gdc(?:-|$)|gm2(?:-|$)|gnat(?:-|$)|"
    r"cpp(?:-|$)|clang|lld(?:-\d|$)|lldb(?:-\d|$)|libgcc|libstdc\+\+|"
    r"libgfortran|libobjc(?:\d|-)|libgomp|libatomic|libclang(?:\d|-(?!perl)|$)|"
    r"libc\+\+|libomp(?:\d|-(?!jonathonl))|libunwind-\d)")

# Probe names the generate guard requires in each suite's recorded inventory;
# all verified live 2026-09-04 (fetch DEBIAN_INDEX, match "^Package: <name>$").
# trixie is frozen: its default series (gcc 14, LLVM 19) cannot rot away. sid
# pins the resident default series, gcc 15 (default since 2025-08), and
# gcc-12 as the long tail — sid carries each series for years (gcc-11..16
# are all resident today), so a probe fails only after a real series
# removal, which is the event this guard exists for.
DEBIAN_SERIES_PROBES = {
    "sid": (
        "gcc-15", "gcc-12", "g++-15", "cpp-15", "gfortran-15", "gccgo-15",
        "gdc-15", "gm2-15", "gccrs-15", "gcobol-15", "gnat-15", "gobjc-15",
        "gobjc++-15", "libgcc-15-dev", "libstdc++-15-dev", "libgccjit-15-dev",
        "libgcc-15-dev-arm64-cross", "libstdc++-15-dev-arm64-cross",
        "cpp-15-aarch64-linux-gnu", "gfortran-15-aarch64-linux-gnu",
        "gcc-15-base", "gcc-15-cross-base", "gcc-15-aarch64-linux-gnu-base",
        "clang-19", "clang-tools-19", "clang-tidy-19", "clang-format-19",
        "lld-19", "libomp-19-dev", "libc++-19-dev", "libc++1-18",
    ),
    "trixie": (
        "gcc-14", "gcc-12", "g++-14", "cpp-14", "gfortran-14", "gccgo-14",
        "gdc-14", "gm2-14", "gccrs-14", "gnat-14", "gobjc-14", "gobjc++-14",
        "libgcc-14-dev", "libstdc++-14-dev", "libgccjit-14-dev",
        "libgcc-14-dev-arm64-cross", "libstdc++-14-dev-arm64-cross",
        "cpp-14-aarch64-linux-gnu", "gfortran-14-aarch64-linux-gnu",
        "gcc-14-base", "gcc-14-cross-base", "gcc-14-aarch64-linux-gnu-base",
        "clang-19", "clang-tools-19", "clang-tidy-19", "clang-format-19",
        "lld-19", "libomp-19-dev", "libc++-19-dev", "libc++1-19",
    ),
}
# Runtime/-base names build.py's denylist governs; soname-stable in both
# suites (libstdc++6 since gcc 3.4). Verified live 2026-09-04.
DEBIAN_RUNTIME_PROBES = (
    "libgcc-s1", "libstdc++6", "libgomp1", "libatomic1", "libgfortran5",
    "libobjc4", "libgccjit0", "libgnat-14", "libgcc-s1-arm64-cross",
    "libstdc++6-arm64-cross", "libomp5-18", "libclang1-18", "libclang-cpp18",
    "libunwind-18",
)


def debian_inventory(text: str) -> dict:
    """name -> version for every gcc/clang-family package, bucketed."""
    out: dict[str, dict[str, str]] = {s: {} for s, _ in _DEBIAN_RULES}
    other: dict[str, str] = {}
    for stanza in text.split("\n\n"):
        pm = re.search(r"^Package: (\S+)$", stanza, re.M)
        vm = re.search(r"^Version: (\S+)$", stanza, re.M)
        if not pm or not vm:
            continue
        name, version = pm.group(1), vm.group(1)
        for section, rule in _DEBIAN_RULES:
            if rule.match(name):
                out[section][name] = version
                break
        else:
            if _DEBIAN_STEMS_RE.match(name):
                other[name] = version
    out["other_compiler_packages"] = other
    return out


# ---------------------------------------------------------- classification

def _series(version: str) -> str:
    parts = [int(p) for p in version.split(".")]
    return ".".join(map(str, parts[:2])) if parts[0] <= 4 else str(parts[0])


def _version_parts(version: str) -> list[int]:
    return [int(p) for p in version.split(".")]


def _smoke_native(compiler: str, version: str) -> str:
    major = _version_parts(version)[0]
    if compiler == "gcc":
        return "L2" if major >= 5 else "L1"
    return "L1" if major < 4 else "L2"


def classify_base(b: str):
    """One bucket basename -> (kind, detail).

    kind: candidate | trunk | skip-key | skip-family
    detail for candidate: (family, version, spelling_note or None)
    detail for trunk: family
    detail for skip-*: (reason, family or None)
    """
    if not b or b == "/":
        return "skip-key", ("bucket prefix placeholder; not a payload", None)
    for fam in TRUNK_FAMILIES:
        if re.fullmatch(re.escape(fam) + r"-\d{8}\.tar\.xz", b):
            return "trunk", fam
        if b == fam + ".tar.xz":
            return "skip-key", (f"frozen undated alias of {fam}", None)
    for pat, fam in ((NATIVE_GCC_RE, "gcc"), (RENOVATED_RE, "gcc"), (NATIVE_CLANG_RE, "clang")):
        m = pat.match(b)
        if m:
            return "candidate", (fam, m.group(1), "renovated" if "renovated" in b else None)
    m = VAX_RE.match(b)
    if m:
        spelling, version, date = m.groups()
        canonical = spelling == "gcc-vax--netbsdelf"
        return "candidate", ("vax", version, "canonical" if canonical else "alt-spelling")
    m = AT_RE.match(b)
    if m:
        return "candidate", (m.group(1) + "-gcc", m.group(2), "at")
    m = CROSS_RE.match(b)
    if m:
        spelling = f"build-tag-{m.group(3)}" if m.group(3) else None
        return "candidate", (m.group(1), m.group(2), spelling)
    if b in NAMED_SKIP_KEYS:
        return "skip-key", (NAMED_SKIP_KEYS[b], None)
    if re.match(r"^(gcc|clang)-assertions-", b):
        fam = DATED_RE.match(b)
        if fam:
            return "skip-family", (REASON_ASSERTIONS, fam.group(1))
        return "skip-key", (REASON_ASSERTIONS, None)
    if b.startswith("gcc-ce-"):
        return "skip-key", ("mingw32ce (Windows CE) cross; no Debian analog", None)
    if b.startswith("OracleDeveloperStudio"):
        return "skip-key", ("Oracle Developer Studio is proprietary; redistribution terms unknown", None)
    if b.startswith(("test-mgodbolt", "aburi-")):
        fam = DATED_RE.match(b)
        if fam:
            return "skip-family", ("CE test fixture", fam.group(1))
        return "skip-key", ("CE test fixture", None)
    if b.startswith("clang-rocm"):
        return "skip-key", ("AMD ROCm clang fork; not a vanilla clang release", None)
    if re.match(r"^msp430-gcc-ti-", b):
        return "skip-key", (REASON_TI, None)
    fam = DATED_RE.match(b)
    if fam:
        reason = REASON_EXOTIC if re.search(r"gcc|clang", b, re.I) else REASON_TOOL
        return "skip-family", (reason, fam.group(1))
    return "skip-key", (REASON_TOOL, None)


def _entry(key: str, b: str, fam: str, series: str, version: str,
           served: dict[str, list[str]], listing: dict[str, dict], **extra) -> dict:
    ce_targets = sorted(t for t in served.get(b, []) if t)
    entry = {
        "asset": b,
        "ce_targets": ce_targets,
        "expected_arch": extra.pop("expected_arch"),
        "family": fam,
        "format": "gz" if b.endswith(".gz") else "xz",
        "key": key,
        "name": extra.pop("name"),
        "pcr": "none" if extra["regime"] == "nodebian" else "debian",
        "regime": extra.pop("regime"),
        "series": series,
        "served": b in served,
        "size_bytes": listing[key]["bytes"],
        "smoke": extra.pop("smoke"),
        "triplet": extra.pop("triplet"),
        "version": version,
        "version_parts": _version_parts(version) if version else [],
        "version_source": extra.pop("version_source"),
    }
    for opt in ("expected_arch_alts", "debian_analog", "notes"):
        v = extra.pop(opt, None)
        if v:
            entry[opt] = v
    if extra:
        raise ValueError(f"_entry got unexpected fields {sorted(extra)}")
    return entry


def build_catalog(listing: dict[str, dict], yaml_ref: str,
                  served: dict[str, list[str]], nightlies: set[str],
                  debian: dict[str, dict]) -> dict:
    candidates: dict[tuple[str, str], list[tuple[tuple, str, str, str | None]]] = {}
    skips, skip_fams = {}, {}
    trunk_members: dict[str, list[str]] = {f: [] for f in TRUNK_FAMILIES}

    for key in sorted(listing):
        b = key[len(PREFIX):]
        if b.startswith(".buildrevs"):
            continue
        kind, detail = classify_base(b)
        if kind == "candidate":
            fam, version, spelling = detail
            if fam in ("gcc", "clang") and version in ("1.27",) or b in NAMED_SKIP_KEYS:
                skips[key] = {"key": key, "reason": NAMED_SKIP_KEYS[b]}
                continue
            try:
                series = _series(version)
            except ValueError:  # series label such as at12
                series = version
            if spelling == "at":
                sort_key = (999,)
            else:
                sort_key = (tuple(_version_parts(version)),
                            2 if spelling in ("renovated", "canonical") else
                            0 if spelling == "alt-spelling" else 1)
            candidates.setdefault((fam, series), []).append((sort_key, key, version, spelling))
        elif kind == "trunk":
            trunk_members[detail].append(key)
        elif kind == "skip-key":
            skips[key] = {"key": key, "reason": detail[0]}
        else:
            skip_fams[detail[1]] = {"family": detail[1], "reason": detail[0]}

    packaged = []
    for (fam, series), cands in sorted(candidates.items()):
        _, winner, version, spelling = max(cands, key=lambda c: c[0])
        if re.fullmatch(r"at\d+", version):
            version = ""
        if fam in ("gcc", "clang"):
            record = {"triplet": "x86_64-linux-gnu", "regime": "debian",
                      "expected_arch": ARCH_X86, "name": f"{fam}-{series}",
                      "smoke": _smoke_native(fam, version), "version_source": "name"}
        else:
            frec = FAMILIES[fam]
            record = {"triplet": frec["triplet"], "regime": frec["regime"],
                      "expected_arch": frec["arch"], "smoke": "L1",
                      "version_source": "payload" if spelling == "at" else "name"}
            if frec["regime"] == "debian":
                record["name"] = f"gcc-{series}-{frec['triplet']}"
            else:
                record["name"] = f"gcc-{series}-{frec['label']}"
            if spelling == "at":
                record["name"] = f"gcc-{series}-{fam[:-4]}"
                record["regime"] = "nodebian"
                record["notes"] = ("IBM Advance Toolchain build; no gcc version in the "
                                   "name, S2 probes the payload for it")
            if frec.get("expected_arch_alts"):
                record["expected_arch_alts"] = frec["expected_arch_alts"]
            if frec.get("notes_arch"):
                record["notes"] = frec["notes_arch"]
            if frec.get("debian_analog"):
                record["debian_analog"] = frec["debian_analog"]
            if frec["regime"] == "unversioned":
                note = f"Debian ships this family unversioned as {frec['debian_analog']}"
                record["notes"] = (record.get("notes", "") + " " + note).strip()
        b = winner[len(PREFIX):]
        entry = _entry(winner, b, fam, series, version, served, listing, **record)
        if spelling == "renovated":
            entry["notes"] = (entry.get("notes", "") + " " if entry.get("notes") else "") + \
                f"CE 'renovated' rebuild of {fam} {version}"
        packaged.append(entry)
        for _, loser, _lver, lspell in cands:
            if loser == winner:
                continue
            if fam == "vax" and lspell == "alt-spelling":
                reason = (f"alternate spelling of the vax family; superseded by the canonical "
                          f"{b}")
            else:
                reason = f"superseded by {version} (latest of series {series})"
            if fam == "gcc" and series == "6" and lspell != "renovated":
                reason = ("superseded by 6.5.0 (gcc-renovated-6.5.0, the served rebuild "
                          "of the series' latest point release)")
            skips[loser] = {"key": loser, "reason": reason}

    # E2 extra: gcc-4.8.0 although superseded and unserved.
    for b, reason in EXTRA_PACKAGED.items():
        key = PREFIX + b
        if key not in listing:
            raise ValueError(f"EXTRA_PACKAGED key {key} vanished from the bucket")
        if key in skips:
            del skips[key]
        fam, version = ("gcc", b[len("gcc-"):-len(".tar.xz")])
        entry = _entry(key, b, fam, _series(version), version, served, listing,
                       name=b[:-len(".tar.xz")], regime="debian", smoke="L1",
                       triplet="x86_64-linux-gnu", version_source="name",
                       expected_arch=ARCH_X86, notes=reason)
        packaged.append(entry)

    # Series 6 note: the winner is the renovated 6.5.0.
    # Soft-float arm ancestors: the Debian name maps the family to
    # arm-linux-gnueabihf, but these builds are CE's gnueabi targets.
    for entry in packaged:
        if entry["triplet"] == "arm-linux-gnueabihf" and entry["ce_targets"] and all(
                t.endswith("-gnueabi") for t in entry["ce_targets"]):
            entry["notes"] = (entry.get("notes", "") + " " if entry.get("notes") else "") + \
                ("CE target is soft-float arm-unknown-linux-gnueabi; the name follows "
                 "the family's Debian hard-float mapping")

    for entry in packaged:
        if entry["name"] == "gcc-6" and "renovated" in entry["asset"]:
            entry["notes"] = (entry.get("notes", "") + "; chosen over native 6.4.0 as "
                              "series-6 latest: 6.5.0 > 6.4.0, and CE serves this build").strip("; ")

    packaged.sort(key=lambda e: e["key"])

    trunk = {}
    for fam, keys in sorted(trunk_members.items()):
        frec = FAMILIES.get(fam.removesuffix("-trunk"))
        if frec:
            triplet, regime, arch = frec["triplet"], frec["regime"], frec["arch"]
            alts = frec.get("expected_arch_alts")
            if regime == "debian":
                rename = "gcc-{major}-trunk{date}-" + triplet
            else:
                rename = "gcc-{major}-trunk{date}-" + frec["label"]
            smoke = "L1"
        else:
            triplet, regime, arch, alts = "x86_64-linux-gnu", "debian", ARCH_X86, None
            rename = fam.replace("-trunk", "-{major}-trunk{date}")
            smoke = "L2"
        latest = max(keys, key=lambda k: listing[k]["modified"])
        series = {
            "dated_count": len(keys),
            "expected_arch": arch,
            "family": fam,
            "latest_key": latest,
            "latest_modified": listing[latest]["modified"],
            "latest_size_bytes": listing[latest]["bytes"],
            "regime": regime,
            "rename": rename,
            "served": fam in nightlies,
            "smoke": smoke,
            "triplet": triplet,
        }
        if alts:
            series["expected_arch_alts"] = alts
        trunk[fam] = series

    catalog = {
        "debian": debian,
        "listing": listing,
        "listing_keys": sorted(listing),
        "meta": {
            "byte_stability": ("no wall-clock fields; a re-run over identical inputs "
                               "(bucket listing, CE yaml at ce_yaml_ref, Debian indices) "
                               "is byte-identical"),
            "ce_yaml_ref": yaml_ref,
            "ce_yaml_url": INFRA_ARCHIVE.format(yaml_ref),
            "debian_sources": [DEBIAN_INDEX.format(s) for s in DEBIAN_SUITES],
            "expected_arch_source": ("readelf -h on the host binutils (2.47 at "
                                     "generation), fed crafted ELF headers per e_machine"),
            "listing_max_modified": max(m["modified"] for m in listing.values()),
            "listing_url": f"{BUCKET}?list-type=2&prefix={PREFIX}",
            "rotation_policy": ("date-stamped out-of-scope families are recorded per "
                                "family under skip_families: CE keeps only the last 5 "
                                "nightly dates, so pinning keys would fail check daily"),
        },
        "packaged": packaged,
        "schema": __doc__,
        "skip_families": [skip_fams[k] for k in sorted(skip_fams)],
        "skips": [skips[k] for k in sorted(skips)],
        "trunk_families": trunk,
    }

    problems = diff_listing(catalog, catalog["listing_keys"])
    if problems:
        raise ValueError("internal coverage hole:\n" + "\n".join(problems[:50]))
    invariants(catalog)
    return catalog


def invariants(catalog: dict) -> None:
    seen = set()
    for entry in catalog["packaged"]:
        if entry["name"] in seen:
            raise ValueError(f"duplicate package name {entry['name']}")
        seen.add(entry["name"])
    missing = [f for f in TRUNK_FAMILIES if f not in catalog["trunk_families"]]
    if missing:
        raise ValueError(f"trunk families vanished from bucket: {missing}")
    for fam, rec in catalog["trunk_families"].items():
        if rec["dated_count"] < 1:
            raise ValueError(f"trunk family {fam} has no dated keys")


# ---------------------------------------------------------- check machinery

def diff_listing(catalog: dict, live_keys: list[str]) -> list[str]:
    """The comparison check runs and selftest replays. Every live non-
    .buildrevs key must be covered: a packaged key, a skip key, or a dated
    member of a trunk family or skip family. Every recorded key must still
    be live, and every recorded family must still have a live member."""
    problems = []
    packaged = {e["key"] for e in catalog["packaged"]}
    skips = {s["key"] for s in catalog["skips"]}
    trunk_fams = set(catalog["trunk_families"])
    skip_fams = {s["family"] for s in catalog["skip_families"]}
    live = [k for k in live_keys if not k[len(PREFIX):].startswith(".buildrevs")]

    seen_members: set[str] = set()
    for key in live:
        if key in packaged or key in skips:
            continue
        b = key[len(PREFIX):]
        m = DATED_RE.match(b)
        if m and (m.group(1) in trunk_fams or m.group(1) in skip_fams):
            seen_members.add(m.group(1))
            continue
        problems.append(f"UNCOVERED live key not in any catalog class: {key}")
    for key in sorted((packaged | skips) - set(live)):
        problems.append(f"STALE catalog key not in the live listing: {key}")
    for fam in sorted((trunk_fams | skip_fams) - seen_members):
        problems.append(f"VANISHED family with no live dated member: {fam}")
    return problems


def summary(catalog: dict, listing: dict[str, dict]) -> list[str]:
    lines = []
    groups: dict[str, int] = {}
    for e in catalog["packaged"]:
        if e["family"] in ("gcc", "clang"):
            group = f"native {e['family']}"
        else:
            group = f"cross:{e['regime']}"
        groups[group] = groups.get(group, 0) + 1
    lines.append("packaged: " + ", ".join(f"{k}={v}" for k, v in sorted(groups.items()))
                 + f" (total {len(catalog['packaged'])})")
    lines.append(f"trunk families: {len(catalog['trunk_families'])}")
    reasons: dict[str, int] = {}
    for s in catalog["skips"]:
        reasons[s["reason"]] = reasons.get(s["reason"], 0) + 1
    for s in catalog["skip_families"]:
        reasons[s["reason"] + " (families)"] = reasons.get(s["reason"] + " (families)", 0) + 1
    lines.append("skips: " + ", ".join(f"{v}x {k}" for k, v in sorted(reasons.items())))
    bytes_total = sum(e["size_bytes"] for e in catalog["packaged"]) + \
        sum(t["latest_size_bytes"] for t in catalog["trunk_families"].values())
    count = len(catalog["packaged"]) + len(catalog["trunk_families"])
    lines.append(f"payload estimate: {count} payloads, {bytes_total / 2**30:.2f} GiB")
    return lines


# ---------------------------------------------------------- commands

def cmd_generate() -> int:
    listing = fetch_listing()
    if not listing:
        print("GUARD: empty bucket listing", file=sys.stderr)
        return 1
    yaml_ref = ce_yaml_ref()
    served, nightlies = ce_served_set(fetch(INFRA_ARCHIVE.format(yaml_ref)))
    debian = {suite: debian_inventory(lzma.decompress(fetch(DEBIAN_INDEX.format(suite))).decode())
              for suite in DEBIAN_SUITES}
    for suite, inv in debian.items():
        empty = sorted(s for s, d in inv.items() if not d)
        merged = set().union(*(set(d) for d in inv.values()))
        probes = list(DEBIAN_SERIES_PROBES[suite]) + list(DEBIAN_RUNTIME_PROBES)
        missing = [p for p in probes if p not in merged]
        if empty or missing:
            print(f"GUARD: debian {suite} inventory degraded: empty sections "
                  f"{empty}, missing probes {missing}", file=sys.stderr)
            return 1
    catalog = build_catalog(listing, yaml_ref, served, nightlies, debian)
    CATALOG.write_text(json.dumps(catalog, indent=2, sort_keys=True) + "\n")
    for line in summary(catalog, listing):
        print(line)
    print(f"meta: ce_yaml_ref={yaml_ref} listing_max_modified={catalog['meta']['listing_max_modified']}")
    return 0


def cmd_check() -> int:
    catalog = json.loads(CATALOG.read_text())
    listing = fetch_listing()
    if not listing:
        print("GUARD: empty bucket listing", file=sys.stderr)
        return 2
    if not catalog.get("packaged"):
        print("GUARD: catalog has an empty packaged set", file=sys.stderr)
        return 2
    live_keys = sorted(listing)
    problems = diff_listing(catalog, live_keys)
    missing = [f for f in TRUNK_FAMILIES if f not in catalog["trunk_families"]]
    for fam in missing:
        problems.append(f"GUARD: in-scope trunk family missing from catalog: {fam}")
    for fam in TRUNK_FAMILIES:
        if fam in catalog["trunk_families"] and not any(
                re.fullmatch(re.escape(fam) + r"-\d{8}\.tar\.xz", k[len(PREFIX):])
                for k in live_keys):
            problems.append(f"GUARD: in-scope trunk family has no live dated keys: {fam}")
    # Refresh ephemeral bytes for the summary from the live listing.
    live_lookup = listing
    for e in catalog["packaged"]:
        if e["key"] in live_lookup:
            e["size_bytes"] = live_lookup[e["key"]]["bytes"]
    for t in catalog["trunk_families"].values():
        dated = [k for k in live_keys
                 if re.fullmatch(re.escape(t["family"]) + r"-\d{8}\.tar\.xz", k[len(PREFIX):])]
        if dated:
            latest = max(dated, key=lambda k: live_lookup[k]["modified"])
            t["latest_size_bytes"] = live_lookup[latest]["bytes"]
    for line in summary(catalog, live_lookup):
        print(line)
    if problems:
        for p in problems:
            print(p)
        return 2
    print("check: clean")
    return 0


def cmd_selftest() -> int:
    catalog = json.loads(CATALOG.read_text())
    snapshot = catalog["listing_keys"]
    if not catalog["skips"]:
        print("selftest: catalog has no skips to mutate; fixture impossible", file=sys.stderr)
        return 1
    rc = 0
    problems = diff_listing(catalog, snapshot)
    if problems:
        print("selftest FAIL: unmutated snapshot is not clean:")
        for p in problems:
            print("  ", p)
        rc = 1
    else:
        print("selftest: unmutated snapshot is clean")

    fake = "opt/gcc-99.1.0.tar.xz"
    removed = catalog["skips"][0]["key"]
    broken = copy.deepcopy(catalog)
    broken["skips"] = broken["skips"][1:]
    mutated = sorted(snapshot + [fake])
    problems = diff_listing(broken, mutated)
    names_fake = any(fake in p for p in problems)
    names_removed = any(removed in p for p in problems)
    if problems and names_fake and names_removed:
        print(f"selftest: mutated snapshot fails as required, naming {fake} and {removed}")
    else:
        print("selftest FAIL: mutated snapshot outcome wrong:")
        for p in problems:
            print("  ", p)
        print(f"  names_fake={names_fake} names_removed={names_removed}")
        rc = 1

    # Scrape routing control: a synthetic index fragment must bucket as
    # expected, and the look-alike packages the stems guard against must
    # stay unrecorded. Fails if a rule regression drops or misroutes a class.
    routed = ["gcc-15", "gfortran-15-aarch64-linux-gnu",
              "libgcc-15-dev-arm64-cross", "libstdc++-15-dev",
              "libclang-rt-18-dev", "libomp-19-dev", "libgcc-s1", "libgnat-14",
              "gcc-15-base", "gcc-15-cross-base", "gcc-15-sh4-linux-gnu-base",
              "libc++1-19", "libomp5-18", "clang-tools-19", "lld-19",
              "gfortran-15-doc"]
    excluded = ["lldpd", "lldpad", "cppcheck", "cppman", "libobjcryst0",
                "libompl17", "libomp-jonathonl-dev", "libclang-perl",
                "libgnatcoll-dev", "libunwind8"]
    fixture = "\n\n".join(f"Package: {n}\nVersion: 15.2.0-2\n"
                          for n in routed + excluded)
    inv = debian_inventory(fixture)
    expect = {
        "compilers": {"gcc-15", "clang-tools-19", "lld-19"},
        "cross_compilers": {"gfortran-15-aarch64-linux-gnu"},
        "cross_dev_libs": {"libgcc-15-dev-arm64-cross"},
        "native_dev_libs": {"libstdc++-15-dev", "libclang-rt-18-dev",
                            "libomp-19-dev"},
        "runtime_and_base_packages": {
            "libgcc-s1", "libgnat-14", "gcc-15-base", "gcc-15-cross-base",
            "gcc-15-sh4-linux-gnu-base", "libc++1-19", "libomp5-18"},
        "other_compiler_packages": {"gfortran-15-doc"},
    }
    wrong = ([f"{s}={sorted(inv[s])}" for s, want in expect.items()
              if set(inv[s]) != want]
             + [f"recorded excluded name: {n}" for n in excluded
                if any(n in d for d in inv.values())])
    if wrong:
        print("selftest FAIL: debian inventory routing wrong:")
        for w in wrong:
            print("  ", w)
        rc = 1
    else:
        print("selftest: debian inventory routes the fixture into the right buckets")
    return rc


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "generate":
        sys.exit(cmd_generate())
    if cmd == "check":
        sys.exit(cmd_check())
    if cmd == "selftest":
        sys.exit(cmd_selftest())
    print(__doc__)
    sys.exit(1)
