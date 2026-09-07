#!/bin/bash
# Failure-mode deltas (D6): the controls S1-S3 deliberately did not duplicate.
#
# Controls, one function each; every run also stamps the control's name and the
# final tally refuses a silent skip, so commenting a control out of main turns
# the suite red:
#
#   1. ctl_truncated      a served tarball cut mid-stream must fail the bundle
#                         postinst loudly (at the sha256 gate / at extraction;
#                         two arms), leave no partial /opt tree, no staging
#                         sibling, no links, and dpkg not-configured. Positive
#                         control: the same deb + the intact payload over the
#                         same file:// harness must install green.
#   2. ctl_mutated_listing drive build.py's resolve() (the release-asset
#                         picker every repo-tag wrapper goes through) with a
#                         mutated asset set via the _RELEASES cache shim it
#                         already has: when a trunk family's pinned major no
#                         longer matches because the newest dated asset bumped
#                         a major, the build must stop with the new asset name
#                         in the "no asset matches ...; have: ..." error. The
#                         listing-mutation class is owned upstream by
#                         catalog.py's check; this control is the build side.
#   3. ctl_ghost          mirror.py's ghost filter (release assets whose state
#                         is not "uploaded" count as absent and are deleted).
#                         Attempt-1 proved a real ghost cannot be manufactured
#                         (SIGKILL mid-upload leaves no record), so this is an
#                         outside-the-gate control: `mirror.py selftest` must
#                         run green AND print its ghost control, and
#                         split_assets() is asserted directly on synthetic
#                         JSON, so deleting the ghost branch in mirror.py
#                         turns THIS suite red.
#   4. ctl_version_corpus  build.py's E20 assert (every emitted version sorts
#                         below the per-suite corpus build.py and catalog.json
#                         record) driven through python -c against the real
#                         inventory: unbroken-scheme arm passes (incl. a fake
#                         Debian entry ABOVE ours), poisoned-below arm trips
#                         naming the entry, tilde-less broken scheme trips.
#   5. ctl_relr           measure, per (native gcc series, debian baseline),
#                         whether installing the bundle and compiling+running
#                         a hello world works (E3's RELR question: CE's gcc 5-11
#                         payloads bundle binutils ld <= 2.36; sid/trixie glibc
#                         emits SHT_RELR). Rows land in exceptions.json; a row
#                         with no mirrored payload is "pending-mirror".
#   6. ctl_exceptions     mechanical checks on exceptions.json (canonical form,
#                         schema, matrix completeness, works/reason invariants)
#                         plus mutation positive controls proving the checks
#                         themselves fire. S4 builds its cutoff section on this
#                         shape.
#
# exceptions.json schema (curated + measured; canonical JSON written with
# json.dumps(indent=2, sort_keys=True) + trailing newline, same as
# catalog.json / mirror-manifest.json per E19; THIS file is edited only by
# test_failure_modes.sh for the "relr" section and by S4's harness for the
# future "cutoff" section — each section has exactly one writer):
#
#   schema   (string)  this text, shortened: section ownership + row shape.
#   relr     (object)  "<series>/<baseline>" -> row, where series is the
#                      Debian gcc major series ("5".."11" = the RELR era from
#                      E3; "16", "17" = control rows outside the era: the
#                      mirrored stable gcc-16.2.0 and the gcc-trunk nightly
#                      bundle gcc-17, which PROVE the measurement can pass)
#                      and baseline is "sid" or "trixie". Row fields, exactly:
#                        series    string, the key's series
#                        baseline  "sid" | "trixie"
#                        works     true | false | null
#                        measured  "YYYY-MM-DD" of the measurement, or
#                                  "pending-mirror"
#                        reason    human evidence: works:true rows start with
#                                  "ok:" and record gcc/ld/glibc versions;
#                                  works:false rows carry the failing error
#                                  fragment; pending rows name the unmirrored
#                                  series and asset explicitly.
#                      Invariant: works is null iff measured is
#                      "pending-mirror"; works is false only with a non-empty
#                      reason.
#   cutoff   (object)  RESERVED for S4 (clang <= 3.x C++ cutoff trials); S6
#                      creates it empty and never writes rows into it.
#
# Container usage follows test_install.sh: podman-or-docker detection, debs
# and payloads bind-mounted (read-only), results out on a scratch mount. The
# bundle debs come from build.py's EXISTING interfaces only
# (--dump-spec / --only); the fixtures that serve payloads locally are the
# REAL debs with exactly one postinst line rewritten (the fetch URL pointed
# at file:///payloads/<asset>) — the sha256 gate is untouched, so the bytes
# that land are still verified to be the mirrored ones. The truncation arms
# additionally rewrite the gate to pass (arm B), which exercises the
# extract+rename path rather than the hash gate.
#
# Re-runs skip rows already measured (the measurement is a recorded fact, not
# a recomputation); --remeasure re-runs every measurable row. A full measuring
# run downloads the two big payloads once; a pending-only run needs only the
# 47 MB k1-gcc payload for the truncation control. Everything scratch lives
# under one mktemp dir, removed on exit.
#
# Usage: ./test_failure_modes.sh [--remeasure]
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
EXC=$root/exceptions.json
remeasure=0
[ "${1:-}" = "--remeasure" ] && remeasure=1

engine=$(command -v podman || command -v docker) || {
  echo "FAIL  no podman or docker; this check cannot run"; exit 1; }

for tool in dpkg-deb curl python3; do
  command -v "$tool" >/dev/null || { echo "FAIL  $tool missing"; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"/payloads "$tmp"/fixtures "$tmp"/results
: > "$tmp/stamps"
stamp() { echo "$1" >> "$tmp/stamps"; }

# The three bundles the controls need: gcc-7-k1 (47 MB payload, smallest
# mirrored native-ish bundle — owns the truncation control) and the two RELR
# control rows (gcc-16 stable, gcc-17 = gcc-trunk nightly).
# build.py's repo packages re-read the published release during every build;
# an anonymous github.com caller is rate-limited to 60 req/hr, which repeated
# suite runs exhaust. Reuse gh's credential when none is exported.
export GITHUB_TOKEN="${GITHUB_TOKEN:-$(command -v gh >/dev/null && gh auth token 2>/dev/null)}"

spec=$tmp/spec.json
python3 "$root/build.py" --dump-spec > "$spec"
export EXC SPEC=$spec CATALOG="$root/catalog.json" REMEASURE=$remeasure

# ------------------------------------------------------------- helper lib

# Fetch one mirrored payload into the run cache, verified against the
# manifest's recorded sha256. $1: asset name.
payload() {
  local asset=$1 out=$tmp/payloads/$1 want url
  want=$(python3 -c "
import json
rows = json.load(open('$root/mirror-manifest.json'))['rows']
print(next(r['sha256'] for r in rows.values() if r['asset'] == '$asset'))")
  if [ -s "$out" ] && echo "$want  $out" | sha256sum -c --status -; then
    return
  fi
  url=$(python3 -c "
import json
meta = json.load(open('$root/mirror-manifest.json'))['meta']
print(f\"https://github.com/{meta['repo']}/releases/download/{meta['release']}/$asset\")")
  echo "==> fetch $asset"
  curl -fsSL -o "$out.part" "$url"
  echo "$want  $out.part" | sha256sum -c --status - || {
    echo "FAIL  $asset: mirrored bytes no longer match the manifest sha256"
    exit 1; }
  mv "$out.part" "$out"
}

# Rebuild one deb from out/ with its postinst fetch URL pointed at the local
# payload mount; optionally with the pinned sha256 replaced. The hash-gate
# line is the only thing this ever touches.
# $1: deb glob under out/   $2: output name   $3: served payload name
# $4: replacement sha256 (empty = keep the pinned one)
mkfixture() {
  local deb=$1 out=$2 served=$3 newsha=${4:-} d
  d=$(mktemp -d -p "$tmp")
  dpkg-deb -R "$root/out/"$deb "$d/x" >/dev/null 2>&1
  sed -i "s#^curl -fsSL '[^']*'#curl -fsSL 'file:///payloads/$served'#" "$d/x/DEBIAN/postinst"
  if [ -n "$newsha" ]; then
    sed -i "s/^echo '[0-9a-f]\{64\}  '/echo '$newsha  '/" "$d/x/DEBIAN/postinst"
  fi
  dpkg-deb --root-owner-group --build "$d/x" "$tmp/fixtures/$out" >/dev/null
  rm -rf "$d"
}

# One measured fact per RELR row, recorded into exceptions.json via exc.py.
record_relr_row() {  # series baseline works(0|1) reason-file
  python3 "$tmp/exc.py" record "$1" "$2" "$3" "$4" "$(date +%F)"
}

# The exceptions.json writer/checker (single home of the file's schema rules).
cat > "$tmp/exc.py" <<'PYEOF'
"""Writer + checker for exceptions.json's relr section. Row-shape rules live
here exactly once; test_failure_modes.sh drives the subcommands."""
import copy
import json
import os
import re
import sys

EXC = os.environ["EXC"]
SPEC = os.environ["SPEC"]
ZONE = ["5", "6", "7", "8", "9", "10", "11"]       # the RELR era, per E3
EXTRAS = ["16", "17"]       # control rows outside the era (can-pass proofs)
BASELINES = ["sid", "trixie"]

SCHEMA = (
    "exceptions.json: curated+measured bundle exceptions, canonical JSON "
    "(json.dumps(indent=2, sort_keys=True) + newline), one writer per "
    "section: test_failure_modes.sh owns 'relr' (rows keyed "
    "'<gcc series>/<baseline>': series 5-11 = the RELR era per E3, 16/17 = "
    "control rows outside it; row = {series, baseline, works "
    "(true|false|null), measured ('YYYY-MM-DD'|'pending-mirror'), reason}; "
    "works is null iff pending-mirror; works:false requires a non-empty "
    "evidence reason; pending rows name the unmirrored series and asset). "
    "'cutoff' is reserved for S4 (clang <= 3.x C++ trials); S6 creates it "
    "empty and never writes it."
)


def load_doc():
    if os.path.exists(EXC):
        with open(EXC) as f:
            return json.load(f)
    return {"schema": SCHEMA, "cutoff": {}, "relr": {}}


def canonical(doc):
    return json.dumps(doc, indent=2, sort_keys=True) + "\n"


def write_doc(doc):
    doc.setdefault("schema", SCHEMA)
    with open(EXC, "w") as f:
        f.write(canonical(doc))


def catalog_asset(series):
    """The catalog's native-gcc stable asset name for a series, or ''."""
    with open(os.environ["CATALOG"]) as f:
        cat = json.load(f)
    for e in cat["packaged"]:
        if (e["family"] == "gcc" and e["series"] == series
                and e["regime"] == "debian" and e["triplet"] == "x86_64-linux-gnu"):
            return e["asset"]
    return ""


def measurable(spec):
    """series -> bundle dict for series with a mirrored native gcc bundle.
    The bundle NAME is the test (gcc-17 covers the gcc-trunk nightly; native
    only — cross spellings get their own names)."""
    out = {}
    for s in ZONE + EXTRAS:
        b = spec["bundles"].get(f"gcc-{s}")
        if (b and b.get("state") == "emit" and b.get("regime") == "debian"
                and b.get("triplet") == "x86_64-linux-gnu"):
            out[s] = b
    return out


def pending_reason(series, baseline):
    asset = catalog_asset(series) or "?"
    if series in ZONE:
        return (f"native gcc (asset {asset}, series {series}) has no mirrored "
                f"payload; whether its CE-bundled ld (era binutils <= 2.36) "
                f"mis-links against the SHT_RELR-emitting glibc of "
                f"debian:{baseline} is unmeasured")
    return (f"control row outside the RELR era: native gcc (asset {asset}, "
            f"series {series}) has no mirrored payload; unmeasured")


def cmd_plan():
    with open(SPEC) as f:
        spec = json.load(f)
    doc = load_doc()
    remeasure = os.environ.get("REMEASURE") == "1"
    for s, b in sorted(measurable(spec).items()):
        for base in BASELINES:
            row = doc.get("relr", {}).get(f"{s}/{base}")
            have = bool(row) and row.get("measured") != "pending-mirror" \
                and row.get("works") is not None
            if have and not remeasure:
                continue
            print(s, base, b["name"], b["payload"]["asset"], b["launcher"])


def cmd_record(series, baseline, works, reason_file, today):
    with open(reason_file) as f:
        reason = f.read().strip()
    if not reason:
        raise SystemExit(f"refusing to record an empty reason for "
                         f"{series}/{baseline}")
    doc = load_doc()
    doc.setdefault("relr", {})[f"{series}/{baseline}"] = {
        "series": series, "baseline": baseline,
        "works": works == "1", "measured": today, "reason": reason,
    }
    write_doc(doc)
    print(f"  recorded relr {series}/{baseline}: works={works == '1'}")


def cmd_pending():
    with open(SPEC) as f:
        spec = json.load(f)
    doc = load_doc()
    relr = doc.setdefault("relr", {})
    avail = measurable(spec)
    for s in ZONE + EXTRAS:
        for base in BASELINES:
            key = f"{s}/{base}"
            row = relr.get(key)
            if row and row.get("measured") != "pending-mirror":
                continue                     # a recorded fact; never reworded
            if s in avail:
                continue                     # measurable; record step owns it
            relr[key] = {"series": s, "baseline": base, "works": None,
                         "measured": "pending-mirror",
                         "reason": pending_reason(s, base)}
    write_doc(doc)


def violations_of(doc, raw, spec):
    """Structural + canonical violations. raw=None skips the byte check."""
    out = []
    if raw is not None and raw != canonical(doc).encode():
        out.append("file is not canonical json.dumps(indent=2, sort_keys)")
    if set(doc) != {"schema", "cutoff", "relr"}:
        out.append(f"top-level keys {sorted(doc)} != [cutoff, relr, schema]")
    if not isinstance(doc.get("schema"), str):
        out.append("schema must be a string")
    relr = doc.get("relr")
    if not isinstance(relr, dict):
        return out + ["relr must be an object"]
    avail = measurable(spec)
    for s in ZONE + EXTRAS:
        for base in BASELINES:
            key = f"{s}/{base}"
            row = relr.get(key)
            if row is None:
                out.append(f"missing matrix row {key}")
                continue
            if set(row) != {"series", "baseline", "works", "measured", "reason"}:
                out.append(f"{key}: fields {sorted(row)}")
                continue
            if key != f"{row['series']}/{row['baseline']}":
                out.append(f"{key}: key/field mismatch")
            if row["baseline"] not in BASELINES:
                out.append(f"{key}: unknown baseline {row['baseline']!r}")
            pending = row["measured"] == "pending-mirror"
            if pending != (row["works"] is None):
                out.append(f"{key}: works null iff pending-mirror violated")
            if not pending and not re.fullmatch(r"\d{4}-\d{2}-\d{2}",
                                                str(row["measured"])):
                out.append(f"{key}: bad measured {row['measured']!r}")
            if row["works"] is not None and not isinstance(row["works"], bool):
                out.append(f"{key}: works must be true|false|null")
            if row["works"] is False and not str(row["reason"]).strip():
                out.append(f"{key}: works:false without a reason")
            if row["works"] is None and f"series {s}" not in str(row["reason"]):
                out.append(f"{key}: pending row does not name series {s}")
            pending_now = s not in avail
            if pending_now != pending:
                out.append(f"{key}: pending-mirror {pending} but bundle is "
                           f"{'not ' if pending_now else ''}mirrored today")
    return out


def cmd_check():
    with open(SPEC) as f:
        spec = json.load(f)
    if not os.path.exists(EXC):
        raise SystemExit(f"{EXC} does not exist")
    with open(EXC, "rb") as f:
        raw = f.read()
    doc = json.loads(raw)
    vs = violations_of(doc, raw, spec)

    # Positive controls for the checker itself: each mutated copy below must
    # be refused, or the checks above prove nothing.
    def mutant_fires(label, mutate):
        m = copy.deepcopy(doc)
        mutate(m)
        if not violations_of(m, None, spec):
            vs.append(f"checker positive control blind: {label}")

    probe = f"{ZONE[0]}/{BASELINES[0]}"
    mutant_fires("works:false with empty reason",
                 lambda m: m["relr"][probe].update(works=False, reason=" ",
                                                   measured="2026-09-04"))
    mutant_fires("works:null but measured a date",
                 lambda m: m["relr"][probe].update(works=None,
                                                   measured="2026-09-04"))
    mutant_fires("missing matrix row", lambda m: m["relr"].pop(probe))
    mutant_fires("unknown top section",
                 lambda m: m.update(frobnicate={}))
    if not violations_of(doc, canonical(doc).encode()[:-1] + b" ", spec):
        vs.append("checker positive control blind: non-canonical bytes")

    if vs:
        for v in vs:
            print(f"FAIL  exceptions.json: {v}")
        return 1
    print("ok    exceptions.json canonical, matrix complete, invariants held "
          "(positive controls: 5 mutations refused)")
    return 0


cmd = sys.argv[1]
if cmd == "plan":
    cmd_plan()
elif cmd == "record":
    cmd_record(*sys.argv[2:])
elif cmd == "pending":
    cmd_pending()
else:  # check
    sys.exit(cmd_check())
PYEOF

build_bundles() {  # $@: bundle deb names that must exist in out/ afterwards
  python3 "$root/build.py" $(printf -- '--only %s ' "$@") >/dev/null
  for name in "$@"; do
    compgen -G "$root/out/${name}_*_amd64.deb" >/dev/null ||
      { echo "FAIL  build.py --only $name produced no deb"; exit 1; }
  done
}

# ------------------------------------------------------------ control 1
# TRUNCATED-TARBALL: three arms in one container. A and B must fail without
# residue; C (same deb, intact bytes) must install green.
ctl_truncated() {
  echo "==> control 1: truncated tarball"
  payload k1-gcc-7.5.0.tar.xz
  build_bundles gcc-7-k1
  # Cut at 2/3 of the real bytes: xz errors out mid-stream, after tar has
  # already landed a partial tree in the staging sibling.
  head -c 31665669 "$tmp/payloads/k1-gcc-7.5.0.tar.xz" \
    > "$tmp/payloads/k1-truncated.tar.xz"
  local trunc_sha
  trunc_sha=$(sha256sum "$tmp/payloads/k1-truncated.tar.xz" | cut -d' ' -f1)
  mkfixture 'gcc-7-k1_*_amd64.deb' k1-intact.deb k1-gcc-7.5.0.tar.xz
  mkfixture 'gcc-7-k1_*_amd64.deb' k1-badsha.deb k1-truncated.tar.xz
  mkfixture 'gcc-7-k1_*_amd64.deb' k1-badtar.deb k1-truncated.tar.xz "$trunc_sha"
  local links
  links=$(python3 -c "
import json
b = json.load(open('$spec'))['bundles']['gcc-7-k1']
print(' '.join(b['links']))")

  "$engine" run --rm -i \
    -v "$tmp/fixtures:/fixtures:ro" -v "$tmp/payloads:/payloads:ro" \
    -e "LINKS=$links" debian:sid bash -euo pipefail -s <<'SCRIPT'
pkg=gcc-7-k1
opt=/opt/$pkg
mkdir -p /t
apt-get update -qq

# After a REQUIRED failure arm: the mechanism error is visible, dpkg is not
# configured, and the atomic staging left nothing behind.
check_failed_install() {  # $1 log, $2 evidence regex, $3 arm name
  grep -Eiq "$2" "$1" || { echo "FAIL  $3: no evidence matching /$2/"; cat "$1"; exit 1; }
  st=$(dpkg-query -W -f '${Status}' "$pkg" 2>/dev/null || true)
  [ "$st" != "install ok installed" ] ||
    { echo "FAIL  $3: dpkg reports '$st'"; exit 1; }
  [ ! -e "$opt" ] || { echo "FAIL  $3: $opt tree exists"; exit 1; }
  if compgen -G "$opt.new.*" >/dev/null; then
    echo "FAIL  $3: staging sibling left: $(compgen -G "$opt.new.*")"; exit 1
  fi
  [ ! -L "/usr/bin/$pkg" ] && [ ! -e "/usr/bin/$pkg" ] ||
    { echo "FAIL  $3: /usr/bin/$pkg left"; exit 1; }
  for l in $LINKS; do
    [ ! -L "/usr/bin/$l" ] && [ ! -e "/usr/bin/$l" ] ||
      { echo "FAIL  $3: link /usr/bin/$l left"; exit 1; }
  done
  apt-get purge -y "$pkg" >/dev/null 2>&1
  echo "ok    $3"
}

log=/t/badsha.log
if apt-get install -y --no-install-recommends /fixtures/k1-badsha.deb >"$log" 2>&1; then
  echo "FAIL  arm A: truncated payload with the ORIGINAL hash installed anyway"
  exit 1
fi
check_failed_install "$log" 'did not match' 'arm A: truncated bytes refused at the hash gate'

log=/t/badtar.log
if apt-get install -y --no-install-recommends /fixtures/k1-badtar.deb >"$log" 2>&1; then
  echo "FAIL  arm B: truncated payload with a MATCHING hash installed anyway"
  exit 1
fi
check_failed_install "$log" 'xz:|tar:|unexpected|corrupt' \
  'arm B: truncated tarball dies in extraction, staging left no trace'

# Positive control: the SAME deb over the SAME file:// harness with intact
# bytes must go green — otherwise the two failures above say nothing about
# truncation.
apt-get install -y --no-install-recommends /fixtures/k1-intact.deb >/t/intact.log 2>&1
st=$(dpkg-query -W -f '${Status}' "$pkg" 2>/dev/null || true)
[ "$st" = "install ok installed" ] || { echo "FAIL  arm C: intact payload not configured"; exit 1; }
target=$(readlink -f "/usr/bin/$pkg")
case $target in "$opt"/*) ;; *) echo "FAIL  arm C: launcher -> $target"; exit 1;; esac
[ -x "$target" ] || { echo "FAIL  arm C: launcher not executable"; exit 1; }
"/usr/bin/$pkg" --version >/dev/null
n=0
for l in $LINKS; do
  [ -x "$(readlink -f "/usr/bin/$l")" ] || { echo "FAIL  arm C: link /usr/bin/$l dead"; exit 1; }
  n=$((n + 1))
done
echo "ok    arm C (positive control): intact payload installs, launcher + $n links run"
SCRIPT
  stamp ctl_truncated
}

# ------------------------------------------------------------ control 2
# MUTATED-LISTING: drive build.py's release-asset picker with a listing whose
# trunk family bumped a major. The pinned spec must stop the build naming the
# new asset.
ctl_mutated_listing() {
  echo "==> control 2: mutated listing (trunk major bump)"
  ROOT="$root" python3 - <<'PYEOF'
import os
import sys
sys.path.insert(0, os.environ["ROOT"])
import build

# The spec form a trunk family takes when something pins its major (the old
# gcc-17 packages.toml wrapper had exactly this shape); the point is build.py
# behaviour, which resolve() owns for every repo/tag spec.
spec = {"repo": build.SELF, "tag": "mirror",
        "asset": r"^gcc-17-trunk\d{8}\.tar\.xz$",
        "version_re": r"^gcc-17-trunk(\d{8})\.tar\.xz$"}
ep = f"{build.API}/repos/{build.SELF}/releases/tags/mirror"
new_name = "gcc-18-trunk20270101.tar.xz"

# Positive arm: a listing that still carries the pinned major resolves.
def asset(name):
    return {"name": name, "browser_download_url": f"https://example.invalid/{name}"}
build._RELEASES[ep] = {"tag_name": "mirror", "assets": [
    asset("gcc-17-trunk20270101.tar.xz")]}
info = build.resolve("ctl-trunk", spec)
assert info["version"] == "20270101", info

# Mutated arm: the family moved to major 18; the pinned spec must stop the
# build and the error must name the new asset.
build._RELEASES[ep] = {"tag_name": "mirror", "assets": [
    asset(new_name), asset("gcc-16.2.0.tar.xz")]}
try:
    build.resolve("ctl-trunk", spec)
except SystemExit as e:
    msg = str(e)
    assert "no asset matches" in msg and new_name in msg, msg
    print(f"ok    build stops on the new major, naming it: {msg}")
else:
    print("FAIL  mutated listing resolved anyway"); sys.exit(1)
PYEOF
  stamp ctl_mutated_listing
}

# ------------------------------------------------------------ control 3
# GHOST-ASSET: the outside-the-gate assertion, honestly indirect per the
# header note.
ctl_ghost() {
  echo "==> control 3: ghost-asset filter"
  local out
  out=$(cd "$root" && python3 mirror.py selftest 2>&1) ||
    { echo "FAIL  mirror.py selftest"; printf '%s\n' "$out"; exit 1; }
  grep -q '^pass  ghost filtered out of uploaded' <<<"$out" || {
    echo "FAIL  mirror.py selftest lost its ghost control (or renamed it)";
    exit 1; }
  echo "ok    mirror.py selftest green incl. its ghost control"

  # Thin wrapper: hit split_assets() directly so removing the ghost branch in
  # mirror.py — with or without its selftest — turns this suite red.
  ROOT="$root" python3 - <<'PYEOF'
import os
import sys
sys.path.insert(0, os.environ["ROOT"])
import mirror

rel = {"assets": [
    {"name": "good.tar.xz", "state": "uploaded", "size": 1},
    {"name": "ghost-uploading.tar.xz", "state": "uploading", "size": 2},
    {"name": "ghost-starter.tar.xz", "state": "starter", "size": 3},
]}
uploaded, ghosts = mirror.split_assets(rel)
assert list(uploaded) == ["good.tar.xz"], uploaded
assert sorted(g["name"] for g in ghosts) == \
    ["ghost-starter.tar.xz", "ghost-uploading.tar.xz"], ghosts
print("ok    split_assets treats state!=uploaded as absent for coverage, "
      "2 ghosts named")
PYEOF
  stamp ctl_ghost
}

# ------------------------------------------------------------ control 4
# VERSION-ORDERING: the E20 assert's corpus machinery, three arms.
ctl_version_corpus() {
  echo "==> control 4: version-ordering mutated corpus"
  ROOT="$root" python3 - <<'PYEOF'
import json
import os
import re
import sys
sys.path.insert(0, os.environ["ROOT"])
import build

# Anchors: the assert must EXIST and be called from the bundle plan path —
# deleting it from build.py fails here loudly, not silently.
src = open(os.path.join(os.environ["ROOT"], "build.py")).read()
assert re.search(r"bad = version_order_violations\(version, corpus\)", src), \
    "the version-order assert call site is gone from build.py"
catalog = json.load(open(os.path.join(os.environ["ROOT"], "catalog.json")))
inv = build.inventory_names(catalog)
our = "16~ce16.2.0-1"

# Arm A (unbroken scheme): ours sorts below the real series-16 corpus, and a
# fake Debian entry ABOVE us (16.0-1) changes nothing.
corpus = build.version_corpus("16", "16.2.0", inv) + ["16.0-1"]
assert build.version_order_violations(our, corpus) == [], corpus
# Same for a RELR-era series, exercising the constructive fallback when the
# suite inventory knows nothing of it.
c9 = build.version_corpus("9", "9.5.0", inv)
assert {"9-0", "9.0.0-1", "9.5.0-1"} <= set(c9), c9
assert build.version_order_violations("9~ce9.5.0-1", c9) == []
print("ok    unbroken-scheme corpora pass (series 16 with a higher fake entry, "
      "series 9 fallback)")

# Arm B (poisoned corpus): an entry BELOW our version must trip the gate,
# and the trip must name it.
bad = build.version_order_violations(our, corpus + ["16~ce16.2.0-0"])
assert bad == ["16~ce16.2.0-0"], bad
try:
    if bad:
        raise SystemExit(f"gcc-16: version {our} does not sort below the "
                         f"recorded Debian corpus elements: {bad}")
except SystemExit as e:
    assert "16~ce16.2.0-0" in str(e)
print("ok    poisoned corpus trips the gate, naming the injected entry")

# Arm C (broken scheme): dropping the tilde must flip the same check red —
# the corpus is precisely what makes a broken scheme visible.
assert build.version_order_violations("16.ce16.2.0-1", corpus) != []
print("ok    tilde-less scheme is unmasked by the same corpus")
PYEOF
  stamp ctl_version_corpus
}

# ------------------------------------------------------------ control 5
# RELR MEASUREMENT into exceptions.json (see header for the file schema).
ctl_relr() {
  echo "==> control 5: RELR measurement"
  local need=() names=() built=()
  local i s base pkg asset launcher line
  mapfile -t need < <(python3 "$tmp/exc.py" plan)
  for ((i = 0; i < ${#need[@]}; i++)); do
    read -r s base pkg asset launcher <<<"${need[i]}"
    names+=("$pkg":x)
  done
  if [ "${#names[@]}" -gt 0 ]; then
    mapfile -t names < <(printf '%s\n' "${names[@]}" | cut -d: -f1 | sort -u)
    build_bundles "${names[@]}"
  else
    echo "--> every measurable row already recorded; nothing to measure"
  fi
  for ((i = 0; i < ${#need[@]}; i++)); do
    line=${need[i]}
    read -r s base pkg asset launcher <<<"$line"
    if ! printf '%s\n' "${built[@]+"${built[@]}"}" | grep -Fxq "$pkg"; then
      payload "$asset"
      mkfixture "${pkg}_*_amd64.deb" "${pkg}.file.deb" "$asset"
      built+=("$pkg")
    fi
    echo "--> measure relr $s/$base ($pkg on debian:$base)"
    mkdir -p "$tmp/results/$s-$base"
    set +e
    "$engine" run --rm -i \
      -v "$tmp/fixtures:/fixtures:ro" -v "$tmp/payloads:/payloads:ro" \
      -v "$tmp/results/$s-$base:/results" \
      -e "RELR_PKG=$pkg" -e "RELR_DEB=${pkg}.file.deb" \
      -e "RELR_LAUNCHER=$launcher" -e "RELR_BASELINE=$base" \
      "debian:$base" bash -uo pipefail -s <<'SCRIPT'
works=0
reason="unknown harness outcome (container died before deciding)"
mkdir -p /t
cat > /t/hello.c <<'C'
#include <stdio.h>
int main(void) { printf("hello relr\n"); return 0; }
C
opt=/opt/$RELR_PKG
gcc=$opt/$RELR_LAUNCHER
lddesc=""
apt-get update -qq
if ! apt-get install -y --no-install-recommends "/fixtures/$RELR_DEB" >/t/inst.log 2>&1; then
  reason="bundle install failed: $(tail -n 2 /t/inst.log | head -n 1)"
else
  st=$(dpkg-query -W -f '${Status}' "$RELR_PKG" 2>/dev/null || true)
  if [ "$st" != "install ok installed" ]; then
    reason="installed but dpkg state is '$st'"
  elif [ ! -x "$gcc" ]; then
    reason="no executable launcher at $gcc"
  else
    # Harness positive control: an uncompilable unit MUST be detected,
    # or a works:true below cannot be believed.
    printf 'this is not C' > /t/bad.c
    if "$gcc" -fsyntax-only /t/bad.c >/dev/null 2>&1; then
      reason="HARNESS BROKEN: the driver accepted a non-C unit"
    else
      if [ -x "$opt/bin/ld" ]; then
        lddesc="payload ld: $("$opt/bin/ld" --version 2>/dev/null | head -n 1)"
      elif [ -x "$opt/bin/ld.bfd" ]; then
        lddesc="payload ld: $("$opt/bin/ld.bfd" --version 2>/dev/null | head -n 1)"
      else
        lddesc="no in-bin ld (driver links with the binutils Depends)"
      fi
      gccver=$("$gcc" -dumpfullversion 2>/dev/null)
      if ! "$gcc" /t/hello.c -o /t/hello 2>/t/cc.log; then
        reason="payload driver failed to compile+link hello.c: $(head -n 1 /t/cc.log)"
      elif ! out=$(/t/hello 2>/t/run.log); then
        reason="hello binary failed to run: $(head -n 1 /t/run.log)"
      elif [ "$out" != "hello relr" ]; then
        reason="hello ran but printed '$out'"
      else
        works=1
        glibc=$(dpkg-query -W -f '${Version}' libc6)
        reason="ok: hello world compiled, linked and ran ('$out'); gcc $gccver; $lddesc; libc6 $glibc"
      fi
    fi
  fi
fi
reason=$(printf '%s' "$reason" | tr '\n\t' '  ' | cut -c1-240)
printf '%s' "$works" > "/results/works"
printf '%s' "$reason" > "/results/reason"
[ "$works" = 1 ]
SCRIPT
    rc=$?
    set -e
    [ -s "$tmp/results/$s-$base/works" ] || {
      echo "FAIL  relr $s/$base: container left no result (rc=$rc)"; exit 1; }
    record_relr_row "$s" "$base" "$(cat "$tmp/results/$s-$base/works")" \
      "$tmp/results/$s-$base/reason"
  done
  # Whatever could not be measured is pending-mirror; never rewrites facts.
  python3 "$tmp/exc.py" pending

  # The control rows exist to prove the measurement CAN pass. A measured
  # works:false on a control row means the harness is suspect; stay red
  # until a human reads the recorded reason.
  python3 - <<PYEOF
import json
doc = json.load(open("$EXC"))
bad = [k for s in ("16", "17") for b in ("sid", "trixie")
       if (row := doc["relr"].get(k := f"{s}/{b}")) is not None
       and row["measured"] != "pending-mirror" and row["works"] is False]
if bad:
    raise SystemExit(f"FAIL  RELR control rows measured works:false (harness "
                     f"suspect; read the recorded reasons): {bad}")
print("ok    RELR control rows measured green" )
PYEOF
  stamp ctl_relr
}

# ------------------------------------------------------------ control 6
ctl_exceptions() {
  echo "==> control 6: exceptions.json shape"
  python3 "$tmp/exc.py" check
  stamp ctl_exceptions
}

# ---------------------------------------------------------------- main
ctl_mutated_listing
ctl_version_corpus
ctl_ghost
ctl_truncated
ctl_relr
ctl_exceptions

# Stub-out tripwire: a run that skipped a control cannot pass.
missing=$(comm -13 <(sort "$tmp/stamps") \
  <(printf '%s\n' ctl_truncated ctl_mutated_listing ctl_ghost \
     ctl_version_corpus ctl_relr ctl_exceptions | sort))
[ -z "$missing" ] || { echo "FAIL  controls did not run: $missing"; exit 1; }

echo "==> all failure-mode controls green ($(wc -l < "$tmp/stamps") controls)"
exit 0
