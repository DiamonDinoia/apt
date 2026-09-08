#!/bin/bash
# S4: the compiler container matrix over the catalog floor.
#
# Verifies, for every catalog compiler entry the mirror currently covers (the
# dev floor), in clean debian:sid AND debian:trixie containers: install by
# name=version, launcher + links land and answer, an ldd sweep of the whole
# payload, the per-entry smoke level, and on sid the cross arch leg and the
# apt-get -s install-UX legs. Bundles under test fetch the REAL mirror release
# URL in their postinst (the production path; S6 proved file:// fixtures
# byte-equivalent and this matrix deliberately does not use them).
#
# PROTOCOL (settled in .claude/team.md D4)
#
#   Shard space   every catalog compiler ENTRY name (packaged[].name plus the
#                 trunk_families keys), sorted once; shard i/N takes
#                 index%N == i-1 (round-robin). Entry names are date-free, so
#                 a family's dated-asset rotation never re-shuffles shards
#                 between nights, and mirror state (emit vs pending) does not
#                 move an entry between shards. i outside 1..N exits 1; a
#                 shard resolving ZERO emit bundles exits 1 (non-vacuity).
#   Smoke levels  from the catalog per entry:
#                 L0  the launcher and every spelled link answer --version
#                 L1  L0 + C compile+run (native). Cross/nodebian entries
#                     compile C to an OBJECT instead: there is no executor
#                     for the foreign target, so "and run" is undefined there.
#                 L2  L1 + C++ compile+run (gcc against its own payload
#                     libstdc++, clang against the baseline's).
#                 Both baselines; the cross object+arch check and the UX legs
#                 are sid-only.
#   Exceptions    asserted BOTH directions: a recorded/excluded set must
#                 match reality exactly. An ldd exception that unexpectedly
#                 RESOLVES fails as hard as a surprise not-found; an
#                 L1-limited entry unexpectedly compiling C++ fails the run
#                 (the recorded policy row is stale — re-trial with
#                 --remeasure).
#   ldd model     the expected-unresolved (basename, soname) set is derived
#                 from the dump-spec: payload-internal sonames cross the
#                 payload's Go-helper basenames (build.py's GO_LIBGO class
#                 table is the home of the go-libgo class), plus the measured
#                 clang-trunk runtime rows recorded under exceptions.json
#                 cutoff.ldd. Equality is exact; relpaths are reduced to
#                 basenames in the comparator.
#   Cutoff        exceptions.json's top-level keys stay {cutoff, relr,
#                 schema} (S6's ctl_exceptions enforces exactly those);
#                 "cutoff" is this harness's write area, "relr" is S6's and
#                 is asserted byte-identical across every write here. The file
#                 stays canonical json.dumps(indent=2, sort_keys=True) plus a
#                 trailing newline. cutoff keys:
#                 "clang_cutoff": {measured, result, policy} — one real
#                 trial (clang-3.3 bundle, sid, C AND C++ attempted),
#                 recorded once; re-runs read the row, --remeasure re-trials.
#                 Entries under the policy bound run at the policy level with
#                 the both-directions probes above.
#                 "ldd": bundle -> {files: [[basename, soname]...], measured,
#                 reason} = measured payload-runtime sonames that no Depends
#                 can resolve (clang-trunk's rpath-less libc++/libc++abi/
#                 libunwind chain; the payload's ompd gdb plugin needs
#                 libpython3.10, which no baseline ships). This is build.py's
#                 documented handover: "S4's ldd sweep classifies them".
#                 "install_refusals": bundle -> {baselines, measured, reason,
#                 signature, version} = the Breaks-window class: sid/trixie's
#                 libstdc++6 Breaks gcc-4.3/4.4/4.5 below fixed revisions, the
#                 defer spelling (E9) always sorts inside the window, and
#                 libstdc++6 cannot be removed (apt Depends it), so these
#                 bundles REFUSE to install by design. Asserted both
#                 directions: the design row pins our version + the exact
#                 Breaks clause in the apt output; an unexpected install or a
#                 drifted refusal text both fail.
#                 "era_smoke": bundle -> {c_flags, cxx_flags, extras, version,
#                 measured, reason} = flag sets the smoke needs on today's
#                 baselines (multiarch header/startfile injection for the
#                 3.4-4.1/4.9 payloads; baseline-ld -B/usr/bin for the 5/7/8
#                 payloads whose bundled ld pre-dates .relr.dyn; -std=c++11
#                 dialect for era C++). extras (binutils) are installed by the
#                 runner, loudly, never declared by the bundle. Asserted both
#                 directions: plain must still FAIL (the row is necessary)
#                 and flagged must compile+run (sufficient).
#                 "cxx_policy": bundle -> {baselines {sid, trixie -> bool},
#                 measured, reason} = per-series C++ verdict; every L2 clang
#                 stable must have a row. False legs assert the exact failing
#                 evidence; an unexpected pass fails as a stale row.
#                 "link_version_rc": bundle -> {links {link -> {rc, stderr}},
#                 measured, reason} = links that answer --version only with a
#                 measured non-zero rc + error text (era gcc-ar/nm/ranlib
#                 plugin-less wrappers, clang-cl driver-mode, gcobc-15's
#                 dangling /usr/bin/gcobol exec). rc 0 on a listed link is a
#                 stale row and fails.
#   Install-UX    one sid container with the built repo + real Debian
#                 sources: per-name `apt-get -s install` legs for every
#                 emitted regime debian name in the shard (rc 0; the candidate
#                 is DEBIAN's whenever the live archive ships the name, ours
#                 otherwise), a bare `apt-get -s install gcc-16` proving
#                 DEBIAN's package wins the 100-pin (ours never shadows), and
#                 the regime-3 abort of E21/E27 on the mirrored floor itself:
#                 a pattern over one unversioned-analog family's series aborts
#                 with apt's exact text "Reached two conflicting assignments",
#                 every family member named in the block carries our ~ce
#                 version, and each name alone resolves cleanly. The
#                 classifier control detaches OUR repo: no baseline ships the
#                 family's spelling, so the same glob must fail differently.
#   Class globs   'gcc-*' and 'clang-*' resolution with our repo attached,
#                 plus a no-repo baseline capture for evidence. Our bundles
#                 lawfully JOIN the glob solution set (gcc-17, clang-24,
#                 clang-3.3, the nodebian spellings resolve nowhere else),
#                 and which conflict apt reports first depends on the whole
#                 set — measured: sid's own gcc-* namespace aborts on a
#                 mingw pair today, so "text-equal to baseline" is not a
#                 stable property. The stable property is: no conflicting
#                 assignment carries a ~ce/~trunk version (apt prints them
#                 as name:arch=version), i.e. no bundle of ours is ever a
#                 conflict party under a class glob.
#   Digests       both image shas print once per run, so a future red/green
#                 flip can be blamed on (or cleared of) a base-image move.
#   Controls      host-side comparator selftests run first (synthetic
#                 surprise/resolve/rename ldd sets and zz-new-frontend must
#                 be refused) plus compilers_verdict.py --selftest (synthetic
#                 jobs dirs missing out/ artifacts must come back as FAIL
#                 rows with non-zero exit, no traceback, no forged E13
#                 verdicts on absent evidence); the UX leg proves its own
#                 abort classifier on the single-name and repo-detached
#                 arms; plan-reading loops carry an iterations==planned
#                 assert so a body command eating the plan's stdin can never
#                 silently skip rows (the S5 script(1) class); a stamps
#                 tripwire (same shape as test_failure_modes.sh) refuses a
#                 run that skipped a check class.
#   Floor         the mirror is COMPLETE: every catalog payload is mirrored
#                 (222 emit bundles, zero pending); --sweep asserts it.
#                 Concurrency 4; containers --rm; everything scratch under
#                 one mktemp dir.
#
# Usage: ./test_compilers.sh [--shard i/N] [--sweep] [--remeasure] [--baseline sid|trixie]
#   --sweep      the CI full gate: fail unless the mirror covers EVERY
#                catalog payload (today: well over a hundred pending -> rc 1).
#   --remeasure  re-run the clang <=3.x cutoff trial and rewrite its row.
#   --baseline   one baseline only (default: both); the CI matrix is
#                baseline x shard, one cell per job. The install-UX legs are
#                a sid-container class and run in every cell regardless.
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
shard_i=1; shard_n=1; sweep=0; remeasure=0; bases="sid trixie"
while [ $# -gt 0 ]; do
  case "$1" in
    --shard)   shard_i=${2%/*}; shard_n=${2#*/}; shift 2 ;;
    --shard=*) s=${1#--shard=}; shard_i=${s%/*}; shard_n=${s#*/}; shift ;;
    --sweep)     sweep=1; shift ;;
    --remeasure) remeasure=1; shift ;;
    --baseline)  bases=$2; shift 2 ;;
    --baseline=*) bases=${1#--baseline=}; shift ;;
    *) echo "FAIL  unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "$shard_i$shard_n" in ""|*[!0-9]*)
  echo "FAIL  bad --shard '$shard_i/$shard_n'"; exit 1 ;; esac
case " $bases " in *" sid "*|*" trixie "*) ;;
  *) echo "FAIL  --baseline takes sid, trixie or both"; exit 1 ;; esac

tmp=$(mktemp -d)
# A failed run keeps its artifacts: the FAIL lines in the log name the leg,
# but the /out evidence is what diagnoses it.
cleanup() {
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "==> run failed; evidence kept at $tmp" >&2
  else
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT
: > "$tmp/stamps"
stamp() { echo "$1" >> "$tmp/stamps"; }

engine=$(command -v podman || command -v docker) || {
  echo "FAIL  no podman or docker; this check cannot run"; exit 1; }
for tool in dpkg-deb dpkg-scanpackages python3 curl; do
  command -v "$tool" >/dev/null || { echo "FAIL  $tool missing"; exit 1; }
done

# build.py's wrapper resolution re-reads release metadata; an anonymous
# github.com caller is rate-limited to 60 req/hr, which repeated suite runs
# exhaust. Reuse gh's credential when none is exported (test_failure_modes.sh
# idiom).
export GITHUB_TOKEN="${GITHUB_TOKEN:-$(command -v gh >/dev/null && gh auth token 2>/dev/null)}"

mkdir -p "$tmp"/cfg "$tmp"/jobs "$tmp"/ux

# ------------------------------------------------------------ selection
#
# Resolve the shard to a concrete bundle list and render per-bundle JSON the
# render step turns into plain-text container config (no baseline image has
# python; containers eat KEY=value files and TSVs only).
python3 - "$root" "$tmp" "$shard_i" "$shard_n" "$sweep" "$remeasure" <<'PYSLICE'
import json
import os
import re
import subprocess
import sys

root, tmp = sys.argv[1], sys.argv[2]
shard_i, shard_n = int(sys.argv[3]), int(sys.argv[4])
sweep, remeasure = sys.argv[5] == "1", sys.argv[6] == "1"


def die(msg):
    print(f"FAIL  {msg}")
    sys.exit(1)


catalog = json.load(open(f"{root}/catalog.json"))
manifest = json.load(open(f"{root}/mirror-manifest.json"))
exceptions = json.load(open(f"{root}/exceptions.json"))
spec = json.loads(subprocess.run([sys.executable, f"{root}/build.py",
                                  "--dump-spec"], capture_output=True,
                                 text=True, check=True).stdout)
sys.path.insert(0, root)
import build

# The shard space: every catalog compiler entry name, sorted once. Unique by
# construction — assert it, the assignment arithmetic depends on it.
names = sorted([e["name"] for e in catalog["packaged"]]
               + list(catalog["trunk_families"]))
assert len(set(names)) == len(names), "catalog entry names are not unique"

if shard_n < 1:
    die(f"--shard denominator {shard_n} < 1")
if shard_i < 1 or shard_i > shard_n:
    die(f"--shard {shard_i}/{shard_n} names no slot (i runs 1..N)")
slot = [n for i, n in enumerate(names) if i % shard_n == shard_i - 1]

emit = {n: b for n, b in spec["bundles"].items() if b.get("state") == "emit"}
by_family = {b["family"]: n for n, b in emit.items()}
selected, pending_slot = [], []
for n in slot:
    if n in emit:
        selected.append(n)
    elif n in by_family:
        selected.append(by_family[n])
    else:
        pending_slot.append(n)

pending_total = spec["meta"]["pending_bundles"]
print(f"==> shard {shard_i}/{shard_n}: {len(slot)} catalog entries -> "
      f"{len(selected)} mirrored bundles, {len(pending_slot)} pending-mirror")
print(f"==> floor: {len(emit)} bundles emitted; {pending_total} catalog "
      "payloads pending-mirror")
if sweep and pending_total:
    die(f"--sweep: {pending_total} catalog payloads are pending-mirror; "
        "the full gate stays red until the mirror is --complete")
if not selected:
    die(f"shard {shard_i}/{shard_n} resolved ZERO packages (of {len(slot)} "
        "catalog entries) — a shard is not allowed to prove nothing")

cutoff = exceptions.get("cutoff", {})
refusals = cutoff.get("install_refusals", {})
bad = [n for n, r in refusals.items()
       if n in emit and r.get("version") != emit[n]["version"]]
if bad:
    die(f"install_refusals rows tied to stale versions: {bad} — re-measure")
policy = cutoff.get("clang_cutoff", {}).get("policy", "")
m = (re.search(r"≤\s*([0-9.]+)", policy)
     or re.search(r"<=\s*([0-9.]+)", policy))
bound = m.group(1) if m else None


def limited(b):
    if not b["family"].startswith("clang"):
        return False
    # Without a recorded row only the trial entry itself takes the cutoff
    # branch — that is what measures the row in the first place.
    if bound is None:
        return b["name"] == "clang-3.3"
    return float(b["series"]) <= float(bound)


clang_here = [n for n in selected if n.startswith("clang")]
if clang_here and bound is None and "clang-3.3" not in selected:
    die("clang bundles in the shard but no clang cutoff policy recorded and "
        "the trial bundle clang-3.3 is not in the shard — run a shard that "
        "contains it once, or --remeasure")

arch = {e["name"]: e["expected_arch"] for e in catalog["packaged"]}
arch.update({f: r["expected_arch"] for f, r in
             catalog["trunk_families"].items()})
arch_alts = {e["name"]: e.get("expected_arch_alts", [])
             for e in catalog["packaged"]}
arch_alts.update({f: r.get("expected_arch_alts", [])
                  for f, r in catalog["trunk_families"].items()})
emachine = {r["asset"]: (r.get("analysis") or {}).get("target_emachine")
            for r in manifest["rows"].values()}

json.dump(sorted(build.GO_LIBGO), open(f"{tmp}/go_libgo.json", "w"))
json.dump({"remeasure": remeasure,
           "have_cutoff_row": "clang_cutoff" in cutoff},
          open(f"{tmp}/flags.json", "w"))
json.dump({"pending_total": pending_total,
           "pending_slot": len(pending_slot),
           "emit_floor": sorted(emit)}, open(f"{tmp}/floor.json", "w"))

# Era policies, all in exceptions.json's cutoff section and all asserted
# BOTH directions: a recorded link --version allowance must fire exactly
# (rc + stderr substring), an era flag set must be BOTH necessary (the
# plain control compile still fails) and sufficient (flags compile+run),
# and a clang C++ policy row must match per baseline. A fix that lands
# upstream red-marks its stale row instead of passing silently.
era_smoke = cutoff.get("era_smoke", {})
cxx_policy = cutoff.get("cxx_policy", {})
link_rc = cutoff.get("link_version_rc", {})
for n in selected:
    b = emit[n]
    if b["family"].startswith("clang") and not b["family"].endswith("trunk"):
        if b["smoke"] == "L2" and n not in cxx_policy:
            die(f"{n}: no cxx_policy row — the policy table is "
                "non-vacuous per L2 clang bundle")
for n, r in cxx_policy.items():
    if n in emit and set(r.get("baselines", {})) != {"sid", "trixie"}:
        die(f"cxx_policy row {n} does not name both baselines")
for n, r in era_smoke.items():
    if n in emit and r.get("version") and r["version"] != emit[n]["version"]:
        die(f"era_smoke row for {n} tied to stale version {r['version']}")

names12 = []
for n in sorted(selected):
    b = emit[n]
    cfg = {"version": b["version"], "prefix": b["prefix"],
           "launcher": b["launcher"], "smoke": b["smoke"],
           "regime": b["regime"], "family": b["family"],
           "series": b["series"], "triplet": b.get("triplet") or "",
           "links": b["links"], "link_exclusions": b["link_exclusions"],
           "internal_sonames": b["payload_internal_sonames"],
           "expected_arch": arch.get(n) or arch.get(b["family"], ""),
           "expected_arch_alts": (arch_alts.get(n)
                                  or arch_alts.get(b["family"], [])),
           "target_emachine": emachine.get(b["payload"]["asset"]),
           "cutoff": limited(b),
           "refusal_signature": refusals.get(n, {}).get("signature"),
           "era_c": era_smoke.get(n, {}).get("c_flags", []),
           "era_cxx": era_smoke.get(n, {}).get("cxx_flags", []),
           "era_extra": era_smoke.get(n, {}).get("extras", []),
           "cxx_policy": cxx_policy.get(n, {}),
           "link_rc": link_rc.get(n, {}).get("links", {}),
           "ldd_recorded": cutoff.get("ldd", {}).get(n, {}).get("files", []),
           "asset": b["payload"]["asset"],
           "size_mib": b["payload"]["size_bytes"] >> 20}
    if b["regime"] == "debian" and not cfg["expected_arch"]:
        die(f"{n}: debian entry without a recorded expected_arch")
    d = f"{tmp}/cfg/{n}"
    os.makedirs(d, exist_ok=True)
    json.dump(cfg, open(f"{d}/cfg.json", "w"), indent=1)
    if b["regime"] == "debian":
        names12.append(n)

with open(f"{tmp}/shard.tsv", "w") as f:
    for n in sorted(selected):
        f.write(f"{n}\n")
open(f"{tmp}/ux/names.12", "w").write("\n".join(names12) + "\n")
with open(f"{tmp}/ux/refusals.tsv", "w") as f:
    for n in sorted(refusals):
        f.write(f"{n}\t{refusals[n]['signature']}\n")
if names12:
    print(f"==> install-UX names (regime debian, this shard): "
          f"{len(names12)}")
else:
    print("==> NOTE: no regime-debian names in this shard; the per-name "
          "UX legs are vacuous (glob legs still run)")
PYSLICE
stamp slice

repo=$root/out
if [[ -z ${GPG_KEY_ID:-} ]]; then
  echo "==> GPG_KEY_ID unset, building with a throwaway key"
  gnupg=$tmp/gnupg; mkdir -p "$gnupg"; chmod 700 "$gnupg"
  export GNUPGHOME=$gnupg
  gpg --batch --pinentry-mode loopback --passphrase '' \
      --quick-generate-key 'apt test <test@invalid>' rsa3072 sign never ||
    { echo "FAIL  key generation"; exit 1; }
  GPG_KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')
  export GPG_KEY_ID
  python3 "$root/build.py" >/dev/null || { echo "FAIL  build"; exit 1; }
fi
[[ -f $repo/InRelease ]] || { echo "FAIL  $repo is not signed"; exit 1; }

# Digest log: without it, a payload-identical run flipping red/green across
# nights cannot be told apart from a base-image move.
for base in $bases; do
  d=$("$engine" image inspect --format '{{index .RepoDigests 0}}' "debian:$base") || {
    echo "FAIL  no debian:$base image for $engine"; exit 1; }
  echo "==> image debian:$base = $d"
done
stamp digests

# ---------------------------------------------------------comparators fire
#
# The verdict step's comparators, proven wrong-set-refusing before any bundle
# result is believed. A comparator that can only say "equal" is not evidence.
python3 - <<'PYCTL'
def ldd_diff(actual, expected):
    return sorted(set(map(tuple, actual)) - set(map(tuple, expected))), \
           sorted(set(map(tuple, expected)) - set(map(tuple, actual)))


def bin_diff(present, launcher, links, exclusions):
    exp = {launcher.split("/", 1)[1]}
    exp.update(t.split("/", 1)[1] for t in links)
    exp.update(exclusions)
    return sorted(set(present) - exp), sorted(exp - set(present))


base = [("go", "libgo.so.25"), ("gofmt", "libgo.so.25"),
        ("buildid", "libgo.so.25"), ("cgo", "libgo.so.25"),
        ("test2json", "libgo.so.25"), ("vet", "libgo.so.25")]
assert ldd_diff(base, base) == ([], [])
s, m = ldd_diff(base + [("cc1", "libbogus.so.1")], base)
assert s == [("cc1", "libbogus.so.1")] and not m, "surprise not refused"
s, m = ldd_diff(base[:-1], base)
assert m == [("vet", "libgo.so.25")] and not s, "unexpected resolve kept"
s, m = ldd_diff([("go777" if a == "go" else a, sn) for a, sn in base], base)
assert s and m, "a relocated helper slipped both directions"

present = ["gcc", "gcc-ar", "g++", "ar", "go"]
assert bin_diff(present, "bin/gcc", ["bin/gcc-ar", "bin/g++"],
                ["ar", "go"]) == ([], [])
extra, missing = bin_diff(present + ["zz-new-frontend"], "bin/gcc",
                          ["bin/gcc-ar", "bin/g++"], ["ar", "go"])
assert extra == ["zz-new-frontend"] and not missing
extra, missing = bin_diff(present[:-1], "bin/gcc",
                          ["bin/gcc-ar", "bin/g++"], ["ar", "go"])
assert missing == ["go"] and not extra
print("ok    comparator controls: 3 ldd mutations refused; "
      "zz-new-frontend reported; a dropped tool reported")
PYCTL
stamp comparators

# The verdict collector (compilers_verdict.py) selftest: synthetic evidence
# trees missing out/ artifacts must come back as clean FAIL rows with a
# non-zero exit and no traceback; a complete tree must pass; E13 must still
# fire on evidence that exists. This class shipped red in run 34158756678 as
# a FileNotFoundError traceback plus forged E13 rows for payloadless jobs.
python3 "$root/compilers_verdict.py" --selftest ||
  { echo "FAIL  collector selftest"; exit 1; }
stamp collector_selftest

# Regime-3 leg inputs (E21/E27): the mirrored unversioned-analog families
# carry the designed shape directly — no fixture. Pick the family with the
# most emit members (deterministically), hand its name list and glob to the
# install-UX container; the abort assertion there runs against the SAME debs
# the production repo serves.
python3 - "$root" "$tmp" <<'PYFIX'
import json
import subprocess
import sys

root, tmp = sys.argv[1:3]
spec = json.loads(subprocess.run([sys.executable, f"{root}/build.py",
                                  "--dump-spec"], capture_output=True,
                                  text=True, check=True).stdout)
groups = {}
for n, b in spec["bundles"].items():
    if b.get("state") == "emit" and b.get("regime") == "unversioned":
        groups.setdefault(n.rsplit("-", 1)[1], []).append(n)
fams = sorted(groups, key=lambda f: (-len(groups[f]), f))
assert fams and len(groups[fams[0]]) >= 2, \
    "regime-3 leg needs a mirrored unversioned family with >=2 series"
fam = fams[0]
names = sorted(groups[fam])
assert all(n.startswith("gcc-") for n in names), \
    f"the '{fam}' unversioned family left the gcc- naming regime: {names}"
with open(f"{tmp}/ux/names.r3", "w") as f:
    for n in names:
        f.write(n + "\n")
with open(f"{tmp}/ux/r3.env", "w") as f:
    f.write(f"R3FAM={fam}\nR3GLOB=gcc-*-{fam}\n")
print(f"ok    regime-3 leg: {len(names)} mirrored {fam} bundles "
      f"({names[0]} .. {names[-1]}), glob 'gcc-*-{fam}'")
PYFIX
stamp regime3_leg

# ------------------------------------------------------ container scripts
#
# One job = one (bundle, baseline) pair. The runner collects failures into
# /out/report and always leaves an rc marker; an absent marker means the
# container died mid-check, which the verdict step reads as FAIL.
cat > "$tmp/job.sh" <<'JOBEOS'
cfg=/cfg
out=/out
. "$cfg/env"
rc=0
fail() { echo "FAIL  $*" >> "$out/report"; rc=1; }
note() { echo "$*" >> "$out/report"; }
: > "$out/report"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq ||
  { fail "apt update of the real sources"; echo "$rc" > "$out/rc"; exit 1; }
apt-get install -y --no-install-recommends /repo/diamondinoia-apt_*.deb \
    >/dev/null 2>&1 ||
  { fail "bootstrap deb refused"; echo "$rc" > "$out/rc"; exit 1; }
sed -i 's|^URIs: .*|URIs: file:///repo/|' /etc/apt/sources.list.d/diamondinoia.sources
apt-get update -qq -o APT::Update::Error-Mode=any ||
  { fail "strict update against the local repo"; echo "$rc" > "$out/rc"; exit 1; }

if apt-get install -y --no-install-recommends "$PKG=$VERSION" \
    >"$out/install.log" 2>&1; then
  if [ -f "$cfg/refusal" ]; then
    fail "install $PKG=$VERSION unexpectedly SUCCEEDED — the recorded Breaks-window refusal row is stale (re-measure exceptions.json cutoff.install_refusals)"
    echo "$rc" > "$out/rc"; exit 1
  fi
  note "ok    install $PKG=$VERSION from the built repo"
else
  if [ -f "$cfg/refusal" ]; then
    sig=$(cat "$cfg/refusal")
    if grep -qF "$sig" "$out/install.log" &&
       grep -qF "$VERSION" "$out/install.log"; then
      note "ok    designed refusal: $PKG=$VERSION refused with '$sig' (E13: both directions asserted)"
      echo "$rc" > "$out/rc"; exit 0
    fi
    fail "install $PKG=$VERSION refused WITHOUT the recorded signature '$sig' — the refusal text drifted (re-measure)"
  else
    fail "install $PKG=$VERSION: $(tail -n 2 "$out/install.log" | head -n 1)"
  fi
  echo "$rc" > "$out/rc"; exit 1
fi
st=$(dpkg-query -W -f '${Status}' "$PKG" 2>/dev/null || true)
[ "$st" = "install ok installed" ] || fail "dpkg state: '$st'"
v=$(dpkg-query -W -f '${Version}' "$PKG" 2>/dev/null || true)
[ "$v" = "$VERSION" ] ||
  fail "installed version '$v' != spec '$VERSION' (name=version did not pin)"
[ -d "$PREFIX" ] || fail "no payload tree at $PREFIX"

# The launcher and every spelled link resolve INTO the payload and run. A
# link that starts but 127s is exactly the go-libgo class the table excludes;
# everything the table links must answer.
lt=$(readlink -f "/usr/bin/$PKG" 2>/dev/null || true)
case $lt in
  "$PREFIX/"*) ;;
  *) fail "launcher /usr/bin/$PKG resolves to '$lt', not into $PREFIX" ;;
esac
[ -x "$lt" ] || fail "launcher $lt not executable"
"/usr/bin/$PKG" --version >"$out/launcher.version" 2>&1 ||
  fail "launcher --version rc=$?"
linked=0
# Payloads legitimately chain driver symlinks (bin/clang++ -> bin/clang-24),
# so readlink -f resolves past the dump-spec target: assert the resolution
# lands INSIDE the prefix, is executable, and runs — never the intermediate
# spelling (test_install.sh's "resolves to something runnable" semantics).
# The plan file rides fd 9 and every body command gets dead stdin: with the
# plan on fd 0 (the old shape), a payload binary that reads stdin eats the
# remaining rows and the loop silently skips every later link (S5's
# script(1) class). iter==planned is the assert that turns the skip loud.
planned=$(wc -l < "$cfg/links.tsv")
iter=0
while IFS=$'\t' read -r -u 9 link target; do
  iter=$((iter + 1))
  t=$(readlink -f "/usr/bin/$link" 2>/dev/null || true)
  case $t in
    "$PREFIX/"*) ;;
    *) fail "link /usr/bin/$link -> $t, not into $PREFIX"; continue ;;
  esac
  [ -x "$t" ] || { fail "link target $t not executable"; continue; }
  rc_row=$(grep "^$link	" "$cfg/linkrc.tsv" 2>/dev/null || true)
  lrc=0
  "$link" --version </dev/null >"$out/link.$link.version" 2>&1 || lrc=$?
  if [ "$lrc" -eq 0 ]; then
    [ -z "$rc_row" ] ||
      fail "link $link answers --version now — its allowance row is stale"
    linked=$((linked + 1)); continue
  fi
  if [ -n "$rc_row" ]; then
    want_rc=$(printf '%s' "$rc_row" | cut -f2)
    want_sub=$(printf '%s' "$rc_row" | cut -f3-)
    if [ "$lrc" = "$want_rc" ] &&
       grep -qF "$want_sub" "$out/link.$link.version"; then
      note "ok    link $link answers with its measured allowance (rc=$lrc, '$want_sub')"
      linked=$((linked + 1)); continue
    fi
  fi
  fail "link $link is on PATH but --version exits rc=$lrc"; continue
done 9< "$cfg/links.tsv"
[ "$iter" -eq "$planned" ] ||
  fail "link loop visited $iter of $planned rows — a body command ate the plan"
note "ok    launcher + $linked/$planned links resolve into $PREFIX and run"
du -sh "$PREFIX" | awk '{print "ok    payload on disk: " $1}' >> "$out/report"

# bin/ accounting and ldd sweep inputs; both are compared host-side, where
# the comparators sit next to their controls. The sweep's process-substitution
# input keeps the loop in THIS shell (a pipeline's subshell would swallow the
# seen counter); ldd gets dead stdin so it can never eat the find stream,
# and seen==total makes any such truncation loud instead of silent.
(cd "$PREFIX/bin" && find . -maxdepth 1 -mindepth 1 \( -type f -o -type l \) \
   -printf '%f\n') | sort > "$out/bin.present"
total=$(find "$PREFIX" -type f \( -perm -u+x -o -name '*.so*' \) -printf 'x' |
        wc -c)
seen=0
while IFS= read -r -d '' f; do
  seen=$((seen + 1))
  r=$(ldd "$f" </dev/null 2>/dev/null) || r=
  printf '%s\n' "$r" |
    awk -v f="${f#"$PREFIX"/}" '/not found/{ print f "\t" $1 }'
done < <(find "$PREFIX" -type f \( -perm -u+x -o -name '*.so*' \) -print0) \
  > "$out/.ldd.raw"
sort -o "$out/ldd.pairs" "$out/.ldd.raw"
rm -f "$out/.ldd.raw"
[ "$seen" -eq "$total" ] ||
  fail "ldd sweep covered $seen of $total payload paths — loop input eaten"

cat > /tmp/hello.c <<'C'
#include <stdio.h>
/* C89-safe on purpose: era gcc defaults to gnu89, so no C99 declarations. */
int main(void) { int s = 0; int i; for (i = 1; i <= 100; ++i) s += i;
                 printf("s4-c-%d\n", s); return 0; }
C
cat > /tmp/hello.cpp <<'CPP'
#include <cstdio>
#include <numeric>
#include <vector>
int main() { std::vector<int> v(100); std::iota(v.begin(), v.end(), 1);
             std::printf("s4-cpp-%d\n",
                         std::accumulate(v.begin(), v.end(), 0)); }
CPP
cat > /tmp/obj.c <<'C'
int s4arch(void) { return 42; }
C

CC=/usr/bin/$PKG
CXX=
[ -f "$cfg/cxx" ] && CXX=$(cat "$cfg/cxx")

# clang payloads carry neither a GCC runtime tree nor libstdc++ headers, and
# the bundle Depends declares neither (measured 2026-09-05: plain C dies with
# 'cannot find crtbeginS.o'; Debian's own clang-N declares both splits).
# Install the baseline's dev splits as harness EXTRAS, loudly, so the smoke
# measures the compiler rather than an absent runtime tree.
extras=
if [ "$FAMILYKIND" = clang ]; then
  gccdev=$(apt-cache pkgnames libgcc- | grep -E '^libgcc-[0-9]+-dev$' |
             sort -V | tail -n 1)
  cxxdev=$(apt-cache pkgnames libstdc++- | grep -E '^libstdc\+\+-[0-9]+-dev$' |
             sort -V | tail -n 1)
  extras="$gccdev $cxxdev"
  apt-get install -y --no-install-recommends $extras \
      >"$out/extras.log" 2>&1 ||
    { fail "baseline dev splits ($extras) not installable"
      echo "$rc" > "$out/rc"; exit 1; }
  note "note  HARNESS EXTRAS for $PKG: $extras (bundle Depends does not declare them; Debian's own clang-N does)"
fi
# Era rows can name their own harness extras (e.g. binutils: the baseline
# ld the -B flag routes to exists only when binutils is installed, and the
# bundle's Depends rightly do not declare it).
era_extra=$(cat "$cfg/era_extra" 2>/dev/null || true)
if [ -n "$era_extra" ]; then
  apt-get install -y --no-install-recommends $era_extra \
      >"$out/era_extra.log" 2>&1 ||
    { fail "era harness extras ($era_extra) not installable"
      echo "$rc" > "$out/rc"; exit 1; }
  note "note  HARNESS EXTRAS for $PKG: $era_extra (era_smoke row; not in the bundle Depends)"
fi

if [ "$NATIVE" = 1 ]; then
  if [ "$CUTOFF" = 1 ]; then
    # The policy row says L1 with C++ cut. All three arms assert the
    # recorded facts; a flip in either direction means the row is stale and
    # the run goes red until re-measured.
    crtd=$(dirname "$(find /usr/lib/gcc -name crtbegin.o | sort -V | tail -n 1)")
    [ -n "$crtd" ] ||
      { fail "cutoff probe: no crtbegin.o under /usr/lib/gcc (extras broken)"
        echo "$rc" > "$out/rc"; exit 1; }
    dver=${crtd##*/}
    hdr=; [ -d "/usr/include/c++/$dver" ] &&
      hdr="-I/usr/include/c++/$dver -I/usr/include/x86_64-linux-gnu/c++/$dver"
    if "$CC" -O2 -o /tmp/h /tmp/hello.c 2>/dev/null; then
      fail "cutoff probe: PLAIN C link unexpectedly succeeded — the recorded policy row is stale (--remeasure to update)"
    else
      note "ok    cutoff: plain C link fails as recorded (pre-multiversion driver)"
    fi
    if "$CC" -O2 -o /tmp/h /tmp/hello.c -B"$crtd" -L"$crtd" \
         2>"$out/cc.cutoff.log"; then
      got=$(/tmp/h) || got="rc=$?"
      [ "$got" = "s4-c-5050" ] ||
        fail "cutoff L1: injected C printed '$got'"
      note "ok    cutoff L1: C with -B/-L $crtd compiles, links, runs ($got)"
    else
      fail "cutoff L1: C with -B/-L $crtd did not link"
    fi
    if [ -n "$CXX" ]; then
      # shellcheck disable=SC2086 # hdr is a deliberate two-flag string
      if $CXX -O2 -o /tmp/hp /tmp/hello.cpp -B"$crtd" -L"$crtd" $hdr \
           2>"$out/cxx.probe"; then
        fail "cutoff probe: C++ unexpectedly compiled — the policy row is stale"
      else
        ev=$(grep -m1 'error' "$out/cxx.probe" | head -c 200)
        note "ok    cutoff: C++ fails as recorded ($ev)"
      fi
    fi
    if [ "$RECORD_TRIAL" = 1 ]; then
      {
        printf 'plain_c=fail\n'
        printf 'injected_c=%s\n' "$(/tmp/h)"
        printf 'cxx=fail\n'
        printf 'cxx_evidence=%s\n' \
          "$(grep -m1 'error' "$out/cxx.probe" | head -c 180)"
        printf 'crtd=%s\n' "$crtd"
        printf 'extras=%s\n' "$extras"
        printf 'baseline=%s\n' "$BASE"
      } > "$out/trial.facts"
    fi
  else
    cflags=$(cat "$cfg/flags.c" 2>/dev/null || true)
    if [ -n "$cflags" ]; then
      # Era row present: the flags must be BOTH necessary (plain still
      # fails) and sufficient (flags compile+run). shellcheck disable=SC2086
      if "$CC" -O2 -o /tmp/h0 /tmp/hello.c 2>"$out/cc.control.log"; then
        fail "era_smoke row stale: plain C unexpectedly links without $cflags"
      else
        note "ok    era control: plain C still fails without the era flags"
      fi
    fi
    # shellcheck disable=SC2086 # policy flags are a deliberate word-split
    if "$CC" -O2 $cflags -o /tmp/h /tmp/hello.c 2>"$out/cc.log"; then
      got=$(/tmp/h) || got="rc=$?"
      [ "$got" = "s4-c-5050" ] || fail "L1: C printed '$got'"
      note "ok    L1: C compiles, links, runs ($got)${cflags:+ [$cflags]}"
    else
      err=$(head -c 160 "$out/cc.log" | tr '\n' ' ')
      fail "L1: C compile+link rc=$? ($err)"
    fi
    if [ "$LEVEL" = L2 ]; then
      if [ -z "$CXX" ]; then
        fail "L2 entry has no C++ driver link in the dump-spec"
      else
        static=
        [ "$FAMILYKIND" = gcc ] && static=-static-libstdc++
        cxxflags=$(cat "$cfg/flags.cxx" 2>/dev/null || true)
        cxx_expected=$(cat "$cfg/cxx_expected" 2>/dev/null || true)
        # shellcheck disable=SC2086 # static/cxxflags: deliberate word-splits
        if $CXX -O2 $static $cxxflags -o /tmp/hp /tmp/hello.cpp 2>"$out/cxx.log"; then
          if [ "$cxx_expected" = fail ]; then
            fail "cxx_policy row stale: C++ unexpectedly passes on $BASE"
          else
            got=$(/tmp/hp) || got="rc=$?"
            [ "$got" = "s4-cpp-5050" ] ||
              fail "L2: C++ printed '$got'"
            note "ok    L2: C++ compiles, links, runs ($got)"
          fi
        else
          if [ "$cxx_expected" = fail ]; then
            ev=$(grep -m1 'error' "$out/cxx.log" | head -c 160)
            note "ok    L2: C++ fails as the cxx_policy row records ($ev)"
          else
            err=$(head -c 160 "$out/cxx.log" | tr '\n' ' ')
            fail "L2: C++ compile+link rc=$? ($err)"
          fi
        fi
      fi
    fi
  fi
else
  # Cross/nodebian, sid-only: C to an object, then the payload's OWN
  # binutils read it back (the baselines carry no external binutils).
  if [ "$BASE" = sid ]; then
    if "$CC" -c -o /tmp/o.o /tmp/obj.c 2>"$out/cross.log"; then
      note "ok    cross: C compiles to an object"
      reelf=$(cat "$cfg/payload_readelf")
      objd=$(cat "$cfg/payload_objdump")
      "$PREFIX/bin/$reelf" -h /tmp/o.o > "$out/arch.readelf" 2>&1 ||
        fail "payload readelf ($reelf) refused the object"
      # e_machine honors the object's OWN endianness (EI_DATA at offset 5):
      # a big-endian cross object (m68k, ppc, sparc64, hppa, s390x) decodes
      # byte-swapped -> 4 reads as 1024 and the numeric gate false-fires.
      if [ "$(od -An -j 5 -N 1 -tu1 /tmp/o.o | awk '{print $1}')" = 2 ]; then
        em=$(od -An -j 18 -N 2 -tu1 /tmp/o.o | awk '{print $1 * 256 + $2}')
      else
        em=$(od -An -j 18 -N 2 -tu1 /tmp/o.o | awk '{print $1 + 256 * $2}')
      fi
      echo "emachine=$em" >> "$out/arch.readelf"
      "$PREFIX/bin/$objd" -f /tmp/o.o > "$out/arch.objdump" 2>&1 ||
        fail "payload objdump ($objd) refused the object"
    else
      fail "cross: C does not compile to an object"
    fi
  else
    note "ok    cross arch leg is sid-only; $BASE runs install+links+ldd"
  fi
fi

echo "$rc" > "$out/rc"
exit "$rc"
JOBEOS

cat > "$tmp/ux.sh" <<'UXEOS'
# Install-UX legs, inside ONE sid container with the built repo, real Debian
# sources, and the regime-3 fixture repo. rc accumulates; every leg prints.
set -uo pipefail
out=/out
rc=0
fail() { echo "FAIL  $*" >> "$out/report"; rc=1; }
note() { echo "$*" >> "$out/report"; }
: > "$out/report"
export DEBIAN_FRONTEND=noninteractive

# The no-repo baseline captures are evidence for the class-glob comment in
# the header: the live archive's own namespace aborts 'gcc-*' today, and the
# assertion below is ours-specific, not text-equal.
apt-get update -qq
apt-get -s install 'gcc-*'   > "$out/glob.gcc.base"   2>&1 || true
apt-get -s install 'clang-*' > "$out/glob.clang.base" 2>&1 || true

apt-get install -y --no-install-recommends /repo/diamondinoia-apt_*.deb \
    >/dev/null || fail "bootstrap deb refused"
sed -i 's|^URIs: .*|URIs: file:///repo/|' /etc/apt/sources.list.d/diamondinoia.sources
apt-get update -qq || fail "update with our repo"

# Each emitted regime-debian name in the shard: clean resolution, and
# whenever a 500-priority source (the live sid archive, or apt.llvm.org which
# the bootstrap adds) ships the name, the candidate must be THEIRS (ours sit
# at 100 below 500; never shadowing is the defer contract, E4 included).
# fd 9 carries the plan; body commands get dead stdin (an apt-mode change
# that starts reading fd 0 must trip the count assert, never skip names).
planned=$(wc -l < /out/names.12)
iter=0
while IFS= read -r -u 9 n; do
  iter=$((iter + 1))
  [ -n "$n" ] || continue
  if ! apt-get -s install "$n" </dev/null > "$out/leg.$n" 2>&1; then
    sig=$(grep "^$n	" /out/refusals.tsv | cut -f2-)
    if [ -n "$sig" ]; then
      grep -qF "$sig" "$out/leg.$n" ||
        { fail "bare-name $n refused WITHOUT the recorded signature '$sig'"
          continue; }
      note "ok    designed refusal: bare-name $n refuses with '$sig'"
      continue
    fi
    # Not ours: the defer candidate is the archive's, and the archive's own
    # package may be uninstallable today (e.g. llvm.org's clang-21/22/24 on
    # trixie want a libstdc++-NN-dev trixie lacks). The assertable property:
    # OUR versions never appear as a failure party.
    grep -qE '~(ce|trunk)' "$out/leg.$n" &&
      { fail "bare-name $n unresolved and OUR version appears in the failure"
        continue; }
    note "ok    defer-under-broken-archive: $n fails inside the archive's own candidate"
    continue
  elif grep -q "^$n	" /out/refusals.tsv; then
    fail "bare-name $n unexpectedly RESOLVES — the recorded refusal row is stale"
    continue
  fi
  pol=$(apt-cache policy "$n" </dev/null)
  cand=$(sed -n 's/^ *Candidate: //p' <<<"$pol")
  if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then
    fail "$n: no candidate with our repo attached"; continue
  fi
  awk '$2 == "100" && NF == 2 {f=1} END {exit !f}' <<<"$pol" ||
    { fail "$n: no 100-pin row in apt-cache policy (repo not consulted?)"
      continue; }
  if awk '$2 == "500" && NF == 2 {f=1} END {exit !f}' <<<"$pol"; then
    case "$cand" in
      *~ce*|*~trunk*)
        fail "$n: candidate $cand is OURS though the archive ships the name" ;;
      *) note "ok    defer: $n -> the archive's $cand (ours at 100)" ;;
    esac
  else
    case "$cand" in
      *~ce*|*~trunk*) note "ok    surfaces: $n -> ours ($cand), archive has none" ;;
      *) fail "$n: candidate $cand is neither ours nor the archive's" ;;
    esac
  fi
done 9< /out/names.12
[ "$iter" -eq "$planned" ] ||
  fail "per-name UX legs visited $iter of $planned names — plan input eaten"

s=$(apt-get -s install gcc-16 2>&1) || fail "apt-get -s install gcc-16 rc=$?"
inst=$(sed -n 's/^Inst gcc-16 //p' <<<"$s")
case "$inst" in
  *~ce*|*~trunk*|"") fail "bare 'gcc-16' resolves '$inst'; ours must never shadow" ;;
  *) note "ok    bare apt-get -s install gcc-16 -> $inst" ;;
esac

# Class globs. Which pair apt's solver reports FIRST depends on the whole
# solution set, and our bundles lawfully JOIN that set (gcc-17, gcc-12-vax,
# clang-24, clang-3.3 resolve nowhere else), so the reported pair can differ
# with and without our repo. The property that survives: no conflicting
# assignment apt reports may involve OUR packages — every one either carries
# a ~ce/~trunk version or is a name only our repo offers. A glob that makes a
# bundle of ours conflict is the E21 defect class, and the regime-3 legs
# below prove the abort classifier on the mirrored unversioned family.
apt-get -s install 'gcc-*'   > "$out/glob.gcc.ours"   2>&1 || true
apt-get -s install 'clang-*' > "$out/glob.clang.ours" 2>&1 || true
# apt prints conflicting assignments as `name:amd64=version is selected for
# install`, so a bundle of ours in the block ALWAYS carries a ~ce/~trunk
# version; matching the version assignment directly is both precise and
# ours-specific (a bare name match would false-fire on Debian's own
# gcc-16-base et al.).
for g in gcc clang; do
  block=$(sed -n '/Reached two conflicting assignments/,$p' \
    "$out/glob.$g.ours")
  if [ -z "$block" ]; then
    note "ok    $g-* glob: no conflicting assignments with our repo"
    continue
  fi
  echo "$block" | grep -E '=[^ ]*~(ce|trunk)' >/dev/null &&
    fail "$g-* glob: a conflict-block assignment carries OUR version"
  note "ok    $g-* glob: conflict block is Debian's own; no ~ce/~trunk assignment in it"
done

# Regime-3 (E21/E27): the mirrored unversioned-analog family itself. Each
# name resolves alone; the class glob across the family's series aborts with
# apt's exact "Reached two conflicting assignments" text, and every family
# member named in the abort block must carry OUR ~ce version (the bundles
# ARE the conflict parties — the designed E21 outcome; only this targeted
# glob may show ~ce assignments, never the wide class globs above).
. /out/r3.env
r3planned=$(wc -l < /out/names.r3)
r3iter=0
while IFS= read -r -u 9 one; do
  r3iter=$((r3iter + 1))
  s=$(apt-get -s install "$one" </dev/null 2>&1) ||
    { fail "regime-3 control: single name $one does not resolve"; continue; }
  grep -q "^Inst $one " <<<"$s" ||
    fail "regime-3 control: $one not in the solution"
done 9< /out/names.r3
[ "$r3iter" -eq "$r3planned" ] ||
  fail "regime-3 single-name legs visited $r3iter of $r3planned names"
note "ok    regime-3: each of the $r3planned mirrored $R3FAM names resolves alone"
rc3=0
s=$(apt-get -s install "$R3GLOB" </dev/null 2>&1) || rc3=$?
echo "$s" > "$out/r3.glob"
block=$(sed -n '/Reached two conflicting assignments/,$p' <<<"$s")
if [ "$rc3" -ne 100 ] || [ -z "$block" ]; then
  fail "regime-3 glob '$R3GLOB': rc=$rc3, abort text missing"
else
  named=0
  while IFS= read -r -u 9 one; do
    grep -q "$one" <<<"$block" || continue
    grep -Eq "$one:amd64=[^ ]*~ce" <<<"$block" ||
      { fail "regime-3 block names $one without our ~ce version"; continue; }
    named=$((named + 1))
  done 9< /out/names.r3
  [ "$named" -ge 2 ] ||
    fail "regime-3 block names $named family members with ~ce versions (<2)"
  note "ok    regime-3 glob '$R3GLOB' aborts: $named family members in two conflicting assignments, all ~ce (E21/E27)"
fi
# Classifier control: with OUR repo detached the glob matches nothing (no
# baseline ships a gcc-*-<family> spelling), so the same glob must fail for
# a DIFFERENT reason — the conflict-abort text must be absent.
rm /etc/apt/sources.list.d/diamondinoia.sources
apt-get update -qq
rc4=0
s=$(apt-get -s install "$R3GLOB" </dev/null 2>&1) || rc4=$?
grep -q 'Reached two conflicting assignments' <<<"$s" &&
  fail "classifier control: the abort persists without our repo"
note "ok    classifier control: the glob without our bundles fails differently (rc=$rc4)"
echo "$rc" > "$out/rc"
exit "$rc"
UXEOS

# ------------------------------------------------------------ scheduling
render_job() { # $1 bundle $2 baseline
  local b=$1 base=$2 d=$tmp/jobs/$1.$2
  mkdir -p "$d/cfg" "$d/out"
  B="$b" BASE="$base" python3 - "$tmp" <<'PYREN'
import json
import os
import sys

tmp = sys.argv[1]
b, base = os.environ["B"], os.environ["BASE"]
cfg = json.load(open(f"{tmp}/cfg/{b}/cfg.json"))
flags = json.load(open(f"{tmp}/flags.json"))
d = f"{tmp}/jobs/{b}.{base}/cfg"

native = cfg["regime"] == "debian" and cfg["triplet"] in ("",
                                                          "x86_64-linux-gnu")
family_kind = "clang" if cfg["family"].startswith("clang") else "gcc"
level = cfg["smoke"]
if cfg["cutoff"] and level not in ("L0", "L1"):
    print(f"FAIL  {b}: the cutoff policy covers a {level} entry — nonsense",
          file=sys.stderr)
    sys.exit(1)

go = json.load(open(f"{tmp}/go_libgo.json"))
expect = ([[g, s] for g in sorted(go) for s in cfg["internal_sonames"]]
          if family_kind == "gcc" else [])
expect += cfg["ldd_recorded"]

cxx = ""
for link, target in cfg["links"].items():
    if target.split("/", 1)[1] in ("g++", "clang++"):
        cxx = link
if family_kind == "gcc" and level == "L2" and native and not cxx:
    print(f"FAIL  {b}: L2 without a g++ link in the dump-spec",
          file=sys.stderr)
    sys.exit(1)

with open(f"{d}/links.tsv", "w") as f:
    for link, target in sorted(cfg["links"].items()):
        f.write(f"{link}\t{target}\n")
env = {"PKG": b, "VERSION": cfg["version"], "PREFIX": cfg["prefix"],
       "LEVEL": level, "NATIVE": "1" if native else "0",
       "FAMILYKIND": family_kind, "BASE": base,
       "CUTOFF": "1" if cfg["cutoff"] else "0",
       # The trial re-measures only where it was measured: clang-3.3 on sid.
       "RECORD_TRIAL": "1" if (b == "clang-3.3" and base == "sid"
                               and (flags["remeasure"]
                                    or not flags["have_cutoff_row"]))
                       else "0"}
with open(f"{d}/env", "w") as f:
    for k, v in env.items():
        f.write(f"{k}={v}\n")
if cxx:
    open(f"{d}/cxx", "w").write(cxx)
if cfg["refusal_signature"]:
    open(f"{d}/refusal", "w").write(cfg["refusal_signature"])
open(f"{d}/era_extra", "w").write(" ".join(cfg["era_extra"]))
open(f"{d}/flags.c", "w").write(" ".join(cfg["era_c"]))
open(f"{d}/flags.cxx", "w").write(" ".join(cfg["era_cxx"]))
with open(f"{d}/linkrc.tsv", "w") as f:
    for link, row in sorted(cfg["link_rc"].items()):
        f.write(f"{link}\t{row['rc']}\t{row['stderr']}\n")
cd = cfg["cxx_policy"]
if cd and base not in cd.get("baselines", {}):
    print(f"FAIL  {b}: cxx_policy row lists no verdict for baseline {base}",
          file=sys.stderr)
    sys.exit(1)
open(f"{d}/cxx_expected", "w").write(
    "" if not cd else ("pass" if cd["baselines"][base] else "fail"))

if not native:
    def bt(tool):
        keys = [k for k, v in cfg["link_exclusions"].items()
                if (k == tool or k.endswith("-" + tool))
                and v["class"] == "bundled-binutils"]
        if keys:
            return sorted(keys)[0]
        print(f"FAIL  {b}: no payload {tool} among excluded bin names",
              file=sys.stderr)
        sys.exit(1)
    open(f"{d}/payload_readelf", "w").write(bt("readelf"))
    open(f"{d}/payload_objdump", "w").write(bt("objdump"))

meta = {"expect": expect,
        "bin": {"launcher": cfg["launcher"],
                "links": sorted(cfg["links"].values()),
                "exclusions": sorted(cfg["link_exclusions"])},
        "expected_arch": cfg["expected_arch"],
        "expected_arch_alts": cfg["expected_arch_alts"],
        "target_emachine": cfg["target_emachine"],
        "smoke": cfg["smoke"], "level": level, "cutoff": cfg["cutoff"],
        "regime": cfg["regime"], "native": native,
        "install_refusal": cfg["refusal_signature"],
        "version": cfg["version"], "size_mib": cfg["size_mib"]}
json.dump(meta, open(f"{tmp}/jobs/{b}.{base}/expect.json", "w"), indent=1)
PYREN
}

job() { # $1 bundle $2 baseline
  local b=$1 base=$2 d=$tmp/jobs/$1.$2
  # A render that aborts is a script defect; the job leaves no rc marker and
  # the verdict step marks the job DEAD, so it can never pass silently.
  render_job "$b" "$base" || return 0
  echo "==> job $b/$base"
  "$engine" run --rm -i \
    -v "$repo:/repo:ro" \
    -v "$d/cfg:/cfg:ro" -v "$d/out:/out" \
    "debian:$base" bash -o pipefail -s < "$tmp/job.sh" \
    > "$d/out/container.log" 2>&1
  return 0  # the verdict comes from /out files, not podman's rc
}

ux_job() {
  local d=$tmp/ux
  mkdir -p "$d"
  echo "==> job install-UX/sid"
  "$engine" run --rm -i \
    -v "$repo:/repo:ro" \
    -v "$d:/out" \
    debian:sid bash -o pipefail -s < "$tmp/ux.sh" \
    > "$d/container.log" 2>&1
  return 0
}
export -f render_job job ux_job
export root tmp repo engine

: > "$tmp/tasks"
while IFS= read -r n; do
  for base in $bases; do
    printf 'job %s %s\n' "$n" "$base" >> "$tmp/tasks"
  done
done < "$tmp/shard.tsv"
printf 'ux_job\n' >> "$tmp/tasks"

xargs -P4 -L1 bash -c '"$@"' _ < "$tmp/tasks"
stamp jobs_ran

printf '%s\n' $bases > "$tmp/bases"

# --------------------------------------------------------------- verdicts
python3 "$root/compilers_verdict.py" "$root" "$tmp"

# Tripwire: a run that silently skipped a check class must not pass.
missing=$(comm -13 <(sort "$tmp/stamps") \
  <(printf '%s\n' digests slice comparators collector_selftest regime3_leg jobs_ran | sort))
[ -z "$missing" ] || { echo "FAIL  check classes did not run: $missing"; exit 1; }

echo "==> all compiler-matrix classes green ($(wc -l < "$tmp/stamps") stamps)"
exit 0
