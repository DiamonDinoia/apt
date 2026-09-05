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
#   Install-UX    one sid container with the built repo + real Debian
#                 sources: per-name `apt-get -s install` legs for every
#                 emitted regime debian name in the shard (rc 0; the candidate
#                 is DEBIAN's whenever the live archive ships the name, ours
#                 otherwise), a bare `apt-get -s install gcc-16` proving
#                 DEBIAN's package wins the 100-pin (ours never shadows), and
#                 the regime-3 abort of E21/E27: two same-family unversioned-
#                 analog bundles under one pattern abort with apt's exact
#                 text "Reached two conflicting assignments" while each name
#                 alone resolves cleanly. No avr payload is mirrored today,
#                 so the pair is SYNTHESIZED with the exact P/C/R shape
#                 pcr_sets computes for the pending catalog entries (derived
#                 from build.py, not paraphrased).
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
#                 be refused); the UX leg proves its own abort classifier on
#                 the single-name and fixture-removed arms; a stamps tripwire
#                 (same shape as test_failure_modes.sh) refuses a run that
#                 skipped a check class.
#   Floor         8 bundles today (9 mirrored payloads; the two dated
#                 gcc-trunk rows fold into one gcc-17 bundle). Concurrency 4;
#                 containers --rm; everything scratch under one mktemp dir.
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

mkdir -p "$tmp"/cfg "$tmp"/jobs "$tmp"/fixtures "$tmp"/ux

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
emachine = {r["asset"]: (r.get("analysis") or {}).get("target_emachine")
            for r in manifest["rows"].values()}

json.dump(sorted(build.GO_LIBGO), open(f"{tmp}/go_libgo.json", "w"))
json.dump({"remeasure": remeasure,
           "have_cutoff_row": "clang_cutoff" in cutoff},
          open(f"{tmp}/flags.json", "w"))
json.dump({"pending_total": pending_total,
           "pending_slot": len(pending_slot),
           "emit_floor": sorted(emit)}, open(f"{tmp}/floor.json", "w"))

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
           "target_emachine": emachine.get(b["payload"]["asset"]),
           "cutoff": limited(b),
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

# Regime-3 fixture (E21/E27): two pending unversioned-analog bundles
# synthesized with the exact P/C/R pcr_sets computes for them.
python3 - "$root" "$tmp" <<'PYFIX'
import json
import os
import shutil
import subprocess
import sys

root, tmp = sys.argv[1:3]
sys.path.insert(0, root)
import build

catalog = json.load(open(f"{root}/catalog.json"))
inv = build.inventory_names(catalog)
spec = json.loads(subprocess.run([sys.executable, f"{root}/build.py",
                                  "--dump-spec"], capture_output=True,
                                 text=True, check=True).stdout)
pend = sorted(n for n, b in spec["bundles"].items()
              if b.get("state") != "emit"
              and b.get("regime") == "unversioned"
              and " (trunk family)" not in n)
assert len(pend) >= 2, "regime-3 fixture needs two pending unversioned names"
fam = lambda n: n.rsplit("-", 1)[1]
one = pend[0]
pair = [one, next(n for n in pend[1:] if fam(n) == fam(one))]

fx = f"{tmp}/fixtures"
os.makedirs(f"{fx}/w", exist_ok=True)
for name in pair:
    e = next(e for e in catalog["packaged"] if e["name"] == name)
    pcr = build.pcr_sets(name, series=e["series"], regime=e["regime"],
                         triplet=e["triplet"], cross=False,
                         upstream=e["version"], inventory=inv)
    d = f"{fx}/w/{name}"
    os.makedirs(f"{d}/DEBIAN", exist_ok=True)
    ctl = (f"Package: {name}\nVersion: {e['series']}~fx1\n"
           "Architecture: amd64\nMaintainer: regime-3 probe <t@invalid>\n"
           f"Description: regime-3 unversioned-analog probe ({name})\n")
    for deb, ours in (("Provides", "provides"), ("Conflicts", "conflicts"),
                      ("Replaces", "replaces")):
        vals = pcr[ours]
        if ours == "provides":
            vals = [f"{n} ({c})" for n, c in vals.items()]
        if vals:
            ctl += f"{deb}: {', '.join(vals)}\n"
    open(f"{d}/DEBIAN/control", "w").write(ctl)
    subprocess.run(["dpkg-deb", "--root-owner-group", "--build", d,
                    f"{fx}/{name}_{e['series']}.fx1_amd64.deb"],
                   check=True, capture_output=True)
shutil.rmtree(f"{fx}/w")
subprocess.run("dpkg-scanpackages --multiversion . /dev/null > Packages"
               " 2>/dev/null && gzip -kf Packages",
               shell=True, cwd=fx, check=True)
glob = f"gcc-*-{fam(pair[0])}"
with open(f"{tmp}/ux/regime3.env", "w") as f:
    f.write(f"R3NAME1={pair[0]}\nR3NAME2={pair[1]}\nR3GLOB={glob}\n")
print(f"ok    regime-3 fixture: {pair[0]} + {pair[1]} (pcr_sets-derived), "
      f"glob '{glob}'")
PYFIX
stamp regime3_fixture

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
  note "ok    install $PKG=$VERSION from the built repo"
else
  fail "install $PKG=$VERSION: $(tail -n 2 "$out/install.log" | head -n 1)"
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
while IFS=$'\t' read -r link target; do
  t=$(readlink -f "/usr/bin/$link" 2>/dev/null || true)
  case $t in
    "$PREFIX/"*) ;;
    *) fail "link /usr/bin/$link -> $t, not into $PREFIX"; continue ;;
  esac
  [ -x "$t" ] || { fail "link target $t not executable"; continue; }
  "$link" --version >"$out/link.$link.version" 2>&1 ||
    { fail "link $link is on PATH but --version exits rc=$?"; continue; }
  linked=$((linked + 1))
done < "$cfg/links.tsv"
note "ok    launcher + $linked links resolve into $PREFIX and run"
du -sh "$PREFIX" | awk '{print "ok    payload on disk: " $1}' >> "$out/report"

# bin/ accounting and ldd sweep inputs; both are compared host-side, where
# the comparators sit next to their controls.
(cd "$PREFIX/bin" && find . -maxdepth 1 -mindepth 1 \( -type f -o -type l \) \
   -printf '%f\n') | sort > "$out/bin.present"
find "$PREFIX" -type f \( -perm -u+x -o -name '*.so*' \) -print0 |
while IFS= read -r -d '' f; do
  r=$(ldd "$f" 2>/dev/null) || r=
  printf '%s\n' "$r" |
    awk -v f="${f#"$PREFIX"/}" '/not found/{ print f "\t" $1 }'
done | sort > "$out/ldd.pairs"

cat > /tmp/hello.c <<'C'
#include <stdio.h>
int main(void) { int s = 0; for (int i = 1; i <= 100; ++i) s += i;
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
    if "$CC" -O2 -o /tmp/h /tmp/hello.c 2>"$out/cc.log"; then
      got=$(/tmp/h) || got="rc=$?"
      [ "$got" = "s4-c-5050" ] || fail "L1: C printed '$got'"
      note "ok    L1: C compiles, links, runs ($got)"
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
        if $CXX -O2 $static -o /tmp/hp /tmp/hello.cpp 2>"$out/cxx.log"; then
          got=$(/tmp/hp) || got="rc=$?"
          [ "$got" = "s4-cpp-5050" ] ||
            fail "L2: C++ printed '$got'"
          note "ok    L2: C++ compiles, links, runs ($got)"
        else
          err=$(head -c 160 "$out/cxx.log" | tr '\n' ' ')
          fail "L2: C++ compile+link rc=$? ($err)"
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
      em=$(od -An -j 18 -N 2 -tu1 /tmp/o.o | awk '{print $1 + 256 * $2}')
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
while IFS= read -r n; do
  [ -n "$n" ] || continue
  apt-get -s install "$n" > "$out/leg.$n" 2>&1 ||
    { fail "apt-get -s install $n: rc=$?"; continue; }
  pol=$(apt-cache policy "$n")
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
done < /out/names.12

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
# bundle of ours conflict is the E21 defect class, and the regime-3 fixture
# below proves the abort classifier on the controlled instance.
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

# Regime-3 (E21/E27): the synthesized unversioned-analog pair.
. /out/regime3.env
echo 'deb [trusted=yes] file:///fixtures ./' > /etc/apt/sources.list.d/r3.list
apt-get update -qq || fail "update with the fixture repo"
for one in "$R3NAME1" "$R3NAME2"; do
  s=$(apt-get -s install "$one" 2>&1) ||
    { fail "regime-3 control: single name $one does not resolve"; continue; }
  grep -q "^Inst $one " <<<"$s" ||
    fail "regime-3 control: $one not in the solution"
done
note "ok    regime-3 control: each fixture name resolves alone"
rc3=0
s=$(apt-get -s install "$R3GLOB" 2>&1) || rc3=$?
if [ "$rc3" -ne 100 ] ||
   ! grep -q 'Reached two conflicting assignments' <<<"$s" ||
   ! grep -q "$R3NAME1" <<<"$s" || ! grep -q "$R3NAME2" <<<"$s"; then
  fail "regime-3 glob '$R3GLOB': rc=$rc3, abort text or fixture names missing"
else
  note "ok    regime-3 glob '$R3GLOB' aborts: two conflicting assignments naming both bundles (E21/E27)"
fi
# Classifier control: without the fixture repo the same glob must fail for a
# DIFFERENT reason (nothing found), not with the conflict abort.
rm /etc/apt/sources.list.d/r3.list
apt-get update -qq
rc4=0
s=$(apt-get -s install "$R3GLOB" 2>&1) || rc4=$?
grep -q 'Reached two conflicting assignments' <<<"$s" &&
  fail "classifier control: the abort persists without the fixture repo"
note "ok    classifier control: the glob without the pair fails differently (rc=$rc4)"
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
        "target_emachine": cfg["target_emachine"],
        "smoke": cfg["smoke"], "level": level, "cutoff": cfg["cutoff"],
        "regime": cfg["regime"], "native": native,
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
  echo "==> job install-UX/sid"
  "$engine" run --rm -i \
    -v "$repo:/repo:ro" \
    -v "$tmp/fixtures:/fixtures:ro" \
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
python3 - "$root" "$tmp" <<'PYVERDICT'
import re
import sys
import datetime
import json
import os

root, tmp = sys.argv[1:3]
fails = []


def fail(msg):
    print(f"FAIL  {msg}")
    fails.append(msg)


def ldd_diff(actual, expected):
    return sorted(set(map(tuple, actual)) - set(map(tuple, expected))), \
           sorted(set(map(tuple, expected)) - set(map(tuple, actual)))


def bin_diff(present, launcher, links, exclusions):
    exp = {launcher.split("/", 1)[1]}
    exp.update(t.split("/", 1)[1] for t in links)
    exp.update(exclusions)
    return sorted(set(present) - exp), sorted(exp - set(present))


flags = json.load(open(f"{tmp}/flags.json"))
bases = open(f"{tmp}/bases").read().split()
slice_names = [l.strip() for l in open(f"{tmp}/shard.tsv") if l.strip()]
matrix = []

# The recorded payload-readelf spellings of target machines the stock
# spelling does not cover. Numeric e_machine (manifest-measured at mirror
# time) is the identity anchor; Kalray's binutils rebrands EM_KVARC, measured
# 2026-09-05 on k1-gcc-7.5.0's payload readelf.
ARCH_ALIASES = {"KM211 KVARC processor": {"Kalray-1 Processor"}}

for name in slice_names:
    for base in bases:
        d = f"{tmp}/jobs/{name}.{base}"
        meta = json.load(open(f"{d}/expect.json"))
        rp = f"{d}/out/report"
        report = open(rp).read().splitlines() if os.path.exists(rp) else []
        for line in report:
            print(f"     {name}/{base}: {line}")
        if not os.path.exists(f"{d}/out/rc"):
            fail(f"{name}/{base}: container left no rc marker "
                 "(died mid-check — see container.log)")
            matrix.append((name, base, "DEAD"))
            continue
        rcv = open(f"{d}/out/rc").read().strip()
        for line in report:
            if line.startswith("FAIL"):
                fails.append(f"{name}/{base}: {line}")

        pairs = []
        p = f"{d}/out/ldd.pairs"
        if os.path.exists(p):
            pairs = [l.split("\t", 1) for l in open(p) if "\t" in l]
        bp = [(os.path.basename(f), s.strip()) for f, s in pairs]
        if len(set(map(tuple, bp))) != len(bp):
            fail(f"{name}/{base}: ambiguous (basename, soname) duplicates "
                 f"in the sweep: {sorted(bp)}")
        surprise, missing = ldd_diff(bp, meta["expect"])
        if surprise:
            fail(f"{name}/{base}: ldd sweep surprise not-found: {surprise}")
        if missing:
            fail(f"{name}/{base}: recorded ldd exception unexpectedly "
                 f"resolved: {missing}")
        if not surprise and not missing and len(set(bp)) == len(bp):
            print(f"      {name}/{base}: ldd sweep exact "
                  f"({len(bp)} exception pair(s), 0 surprises)")

        present = [l.strip() for l in open(f"{d}/out/bin.present") if l.strip()]
        extra, gone = bin_diff(present, meta["bin"]["launcher"],
                               meta["bin"]["links"],
                               meta["bin"]["exclusions"])
        if extra:
            fail(f"{name}/{base}: bin/ names neither linked nor excluded: "
                 f"{extra}")
        if gone:
            fail(f"{name}/{base}: dump-spec bin/ names absent from the "
                 f"payload: {gone}")
        if not extra and not gone:
            print(f"      {name}/{base}: all {len(present)} bin/ names "
                  "linked or excluded")

        if not meta["native"] and base == "sid":
            rd = f"{d}/out/arch.readelf"
            if not os.path.exists(rd):
                fail(f"{name}/{base}: no payload-readelf evidence")
            else:
                txt = open(rd).read()
                m = re.search(r"Machine:\s*(.+)", txt)
                em = re.search(r"emachine=(\d+)", txt)
                machine = m.group(1).strip() if m else ""
                want = meta["expected_arch"]
                allowed = {want} | ARCH_ALIASES.get(want, set())
                if machine not in allowed and not re.fullmatch(
                        r"<unknown>: 0x[0-9a-f]+", machine):
                    fail(f"{name}/{base}: Machine '{machine}' not in "
                         f"{sorted(allowed)}")
                if not em or int(em.group(1)) != meta["target_emachine"]:
                    fail(f"{name}/{base}: e_machine "
                         f"{em and em.group(1)} != manifest "
                         f"{meta['target_emachine']}")
                if os.path.exists(f"{d}/out/arch.objdump"):
                    if "architecture:" not in open(f"{d}/out/arch.objdump") \
                            .read():
                        fail(f"{name}/{base}: payload objdump printed no "
                             "architecture line")
                if m and em and int(em.group(1)) == meta["target_emachine"]:
                    print(f"      {name}/{base}: arch '{machine}' "
                          f"(e_machine {em.group(1)}) vs catalog '{want}'")
        matrix.append((name, base,
                       "ok(%s%s)" % (meta["level"],
                                     "/cutoff" if meta["cutoff"] else "")
                       if rcv == "0" and not any(
                           f.startswith(f"{name}/{base}:") for f in fails)
                       else "FAIL"))

# The clang cutoff trial row: written ONCE (or under --remeasure), relr
# byte-preserved, whole file canonical.
EXC = f"{root}/exceptions.json"
raw_before = open(EXC, "rb").read()
doc = json.loads(raw_before)
relr_before = json.dumps(doc["relr"], indent=2, sort_keys=True)
need_row = flags["remeasure"] or "clang_cutoff" not in doc.get("cutoff", {})
trial = f"{tmp}/jobs/clang-3.3.sid/out/trial.facts"
if need_row:
    if os.path.exists(trial):
        facts = dict(l.rstrip("\n").split("=", 1) for l in open(trial)
                     if "=" in l)
        result = ("3.3: plain C link fails ('cannot find crtbegin.o': the "
                  "driver predates multiversion GCC discovery; "
                  "--gcc-toolchain is unrecognized); C with -B/-L "
                  f"{facts.get('crtd', '?')} compiles and runs "
                  f"({facts.get('injected_c', '?')}); C++ fails on "
                  f"{facts.get('extras', '?').split()[-1]} headers "
                  f"({facts.get('cxx_evidence', '?')})")
        today = datetime.date.today().isoformat()
        doc["cutoff"]["clang_cutoff"] = {
            "measured": today,
            "policy": "clang series ≤3.9 → L1",
            "result": result}
        canon = json.dumps(doc, indent=2, sort_keys=True) + "\n"
        open(EXC, "w").write(canon)
        after = json.loads(open(EXC).read())
        assert json.dumps(after["relr"], indent=2, sort_keys=True) == \
            relr_before, "the relr section moved on write"
        assert open(EXC, "rb").read() == canon.encode(), \
            "exceptions.json is not canonical after write"
        print(f"==> CUT: recorded clang_cutoff trial (measured {today}); "
              "relr section byte-identical")
    else:
        fail("the cutoff trial was required but clang-3.3/sid left no "
             "trial.facts (is clang-3.3 in this shard, and did the run "
             "include the sid baseline?)")
else:
    print("==> cutoff: recorded row read back; probes asserted against it")

ux = f"{tmp}/ux/report"
if os.path.exists(ux):
    for line in open(ux):
        line = line.rstrip("\n")
        print(f"     ux: {line}")
        if line.startswith("FAIL"):
            fails.append(f"ux: {line}")
else:
    fail("install-UX leg left no report")
rcx = f"{tmp}/ux/rc"
if not os.path.exists(rcx):
    fail("install-UX leg left no rc marker")
elif open(rcx).read().strip() != "0":
    fail("install-UX leg rc != 0")

print()
print("== matrix (bundle x baseline -> verdict) ==")
for name, base, res in matrix:
    print(f"  {name:34s} {base:7s} {res}")
floor = json.load(open(f"{tmp}/floor.json"))
print(f"== floor: {len(floor['emit_floor'])} bundles mirrored; "
      f"{floor['pending_total']} catalog payloads pending-mirror "
      f"({floor['pending_slot']} in this shard) — "
      "installed-only runs never go green on a pending entry")

if fails:
    print()
    for f in fails:
        print(f"FAIL  {f}")
    sys.exit(1)
print(f"ALLPASS ({len(matrix)} matrix jobs + install-UX legs)")
PYVERDICT

# Tripwire: a run that silently skipped a check class must not pass.
missing=$(comm -13 <(sort "$tmp/stamps") \
  <(printf '%s\n' digests slice comparators regime3_fixture jobs_ran | sort))
[ -z "$missing" ] || { echo "FAIL  check classes did not run: $missing"; exit 1; }

echo "==> all compiler-matrix classes green ($(wc -l < "$tmp/stamps") stamps)"
exit 0
