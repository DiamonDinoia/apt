#!/bin/bash
# Distro-precedence suite (D5): prove on debian:sid AND debian:trixie that the
# compiler bundles defer to anything the distribution shape could offer, and
# that the defer pin alone is the deciding mechanism. Absorbs the stand-in
# handover harness that test_gcc17.sh used pre-publish, generalized over the
# emit catalog. test_gcc17.sh keeps the published-path half (released
# bootstrap, compile battery); this file never contacts the published release.
#
# The repository under test is built locally from the tree's real inputs
# (build.py + catalog.json + mirror-manifest.json + packages.toml) with an
# ephemeral signing key, so the pin under test is byte-wise what a user gets.
# The container drops the third-party sources the bootstrap carries (not under
# test) and repoints the diamondinoia source at the local build; the index is
# signed by the same ephemeral key, so the apt path is the production one
# (verified Release, Signed-By keyring), just file://. The oracle for what
# Debian "ships" is the live archive inside the container, never the catalog.
#
#   LEG A  distro resolution. Every emit name is classified by live probes:
#          archive-shipped names must resolve the distribution's candidate
#          (ours parked at pin 100); archive-absent names must resolve OURS at
#          100. The shipped 100 glob stanza must cover every emit name. A
#          gcc-16 stand-in then furnishes the overlap case uniformly on both
#          baselines: at 100 the stand-in resolves, at 600 ours, restored to
#          100 the stand-in again. Stub-only: needs no payload.
#   LEG B  same-name handover, over three representative regimes (default):
#          gcc-16 native with its real split chain (measured apt-cache show:
#          gcc-16 = {x86-64, base, cpp} strict; g++-16 through g++-16-x86-64-
#          linux-gnu at libstdc++-16-dev strict), a clangN with an
#          epoch-shaped stand-in (clang-19, 1:19.1.7 style; skipped with clear
#          output while the mirror lacks the payload — today it does), and the
#          gcc-16-aarch64-linux-gnu cross regime (16.2.0-2cross1 spelling).
#          Ours installs (payload served from the per-run host cache through
#          the curl shim; the deb's own SHA-256 check still gates the bytes);
#          the stand-in offers the same-named package one spelling above the
#          live candidate; `apt-get upgrade` (--with-new-pkgs where the chain
#          pulls intermediates — plain upgrade keeps such a package back,
#          measured) must replace ours in one transaction: /opt tree purged,
#          self link owned by the stand-in, --version answers the stub marker,
#          no dpkg overwrite diagnostics. The native leg then installs g++-16 +
#          libstdc++-16-dev through the strict chain against the stand-in gcc-16
#          just installed (the contracted "stub g++-16 Depends gcc-16 (= W)"
#          shape, resolved by apt for real) and asserts /usr/bin/g++-16
#          transfers to the stub. The pin-flip control rides the first fixture:
#          at 600 no upgrade is offered and a real upgrade leaves ours
#          untouched; restore re-opens the handover.
#   LEG C  command swaps with exact asserted Inst/Upg/Remv sets (E22).
#          Forward: only our gcc-16 installed, then `apt-get install g++-16
#          libstdc++-16-dev` against the stand-in family. Reverse: the full
#          stand-in stack installed, then `apt-get --allow-downgrades install
#          ./our-bundle.deb` (flag load-bearing: the flagless attempt must
#          refuse, asserted first). Expected sets are computed from the stub
#          index + dpkg prestate + live policy — never hardcoded — compared
#          exactly against the simulated ledger, which is then bound to the
#          real run (script(1) log + dpkg poststate; apt 3.x prints the ledger
#          only in simulations). Our versioned Provides (= upstream-0~ce1)
#          cannot satisfy the family's strict (= W) deps, so reverse
#          dependents of conflicted splits go with them; gcc-16-base
#          (denylisted) survives as an orphan; runtime packages (libgcc-s1,
#          libstdc++6) are never removed, asserted both ways. The pin-flip
#          control runs first in the forward leg: at 600 the swap is refused
#          with ours kept.
#
# Download floor (E23): a full run fetches the gcc-16 (359 MB) and cross
# (220 MB) payloads — that is the CI profile. Locally, stay cheap: LEG A is
# stub-only on both baselines, and the epoch'd-clang regime has a local stand-
# in in the clang-3.3 fixture (83 MB), the same epoch mechanism clang-19 needs
# (`--legs a`, `--legs b --b-set clang-3.3`). Today the floor's real arms are
# native gcc-16 + cross arm64; sweep mode (real clang-19) requires a mirrored
# clang-19 payload.
#
#   ./test_precedence.sh [--baseline sid|trixie]
#                        [--legs a,b,cfwd,crev]
#                        [--b-set gcc-16,gcc-16-aarch64-linux-gnu,clang-19]
#
# clangN fixtures missing from the build SKIP with clear output; gcc fixtures
# missing FAIL (the CI floor requires them). Fixtures run in the requested
# order; their stand-in family names never overlap across fixtures, so a later
# fixture's stub_ver never reads a prior stand-in's rows. Non-vacuity: every
# leg asserts rc semantics AND payload markers both sides (ours: /opt tree +
# payload --version substring; stand-in: its own STUB-DEBIAN marker); leg A
# fails below three archive-absent probes; control 0 runs the ledger parser
# against doctored apt logs on the host and every mutation must be rejected.
set -euo pipefail

engine=$(command -v podman || command -v docker) || {
    echo "FAIL  no podman or docker; this check cannot run"; exit 1; }

baselines="sid trixie"
legs="a b cfwd crev"
bset="gcc-16,gcc-16-aarch64-linux-gnu,clang-19"
while [ $# -gt 0 ]; do
    case $1 in
        --baseline) baselines=$2; shift 2 ;;
        --legs) legs=${2//,/ }; shift 2 ;;
        --b-set) bset=$2; shift 2 ;;
        *) echo "usage: $0 [--baseline sid|trixie] [--legs a,b,cfwd,crev] [--b-set n,..]"; exit 2 ;;
    esac
done
for bl in $baselines; do
    case $bl in sid|trixie) ;;
        *) echo "usage: bad --baseline '$bl'" >&2; exit 2 ;;
    esac
done
for l in $legs; do
    case $l in a|b|cfwd|crev) ;;
        *) echo "usage: bad leg '$l'" >&2; exit 2 ;;
    esac
done

tree=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"/{lib,payloads,logs,src}

fail() { echo "FAIL  $*"; }
pass() { echo "  ok  $*"; }

# The merged spec is the test interface: emits, versions, links, pcr.
spec=$work/spec.json
python3 "$tree/build.py" --dump-spec > "$spec"
mapfile -t emits < <(python3 - "$spec" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for n, b in sorted(s["bundles"].items()):
    if b.get("state") == "emit":
        print(n)
PY
)
[ "${#emits[@]}" -gt 0 ] || { fail "no emit bundles in --dump-spec"; exit 1; }

python3 - "$spec" > "$work/lib/spec-lite.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
lite = {"emits": {}}
for n, b in sorted(s["bundles"].items()):
    if b.get("state") != "emit":
        continue
    depends = [d for item in b["depends"] for d in item.split(", ")]
    lite["emits"][n] = {"version": b["version"], "prefix": f"/opt/{n}",
                        "series": b["series"], "links": b["links"],
                        "pcr": b["pcr"], "depends": depends}
json.dump(lite, sys.stdout, indent=1, sort_keys=True)
PY
{
for n in "${emits[@]}"; do
    v=$(python3 -c "import json;print(json.load(open('$work/lib/spec-lite.json'))['emits']['$n']['version'])")
    k=$(printf %s "$n" | tr -c 'A-Za-z0-9_' '_')
    echo "V_${k}=$v"
done
} > "$work/lib/versions.env"

# The leg-B fixture plan, rendered host-side so the container receives data,
# never argv construction: marker links, regime class, fallback stand-in
# spelling. A clangN fixture absent from the build SKIPs in-container with
# clear output; a gcc fixture absent FAILS here (the CI floor requires it).
python3 - "$spec" "$bset" > "$work/lib/bplan.json" <<'PY' || exit 1
import json, re, sys
s = json.load(open(sys.argv[1]))
requested = [x for x in sys.argv[2].split(",") if x]
plan, skipped = [], []
for n in requested:
    emit = s["bundles"].get(n, {}).get("state") == "emit"
    if not emit:
        if re.fullmatch(r"clang-\d+(\.\d+)?", n):
            skipped.append(n)
            continue
        print(f"FAIL  --b-set fixture '{n}' is not an emit bundle", file=sys.stderr)
        sys.exit(1)
    links = sorted(s["bundles"][n]["links"])
    if n.startswith("clang-"):
        klass, fb = "clang", ("1:3.3-16" if n == "clang-3.3" else "1:19.1.7-16")
        # clang-N stand-ins are faithful file-wise: the real packages ship the
        # named links, so markers cover the self name plus the linked drivers
        marks = [n, *links][:3]
    elif "-" in n.split("gcc-", 1)[1]:
        klass, fb = "cross", "16.2.0-2cross1"
        geo = [l for l in links if "-gcc-" in l] or links
        marks = [n, geo[0]]
    else:
        klass, fb = "native", "16.2.0-3"
        marks = [n]  # g++-16 ownership is asserted at the chain-install step
    plan.append({"name": n, "class": klass, "fallback": fb, "marks": marks})
print(json.dumps({"fixtures": plan, "skipped": skipped}))
PY

# --- control 0: the ledger parser, host side, doctored logs ----------------
cat > "$work/lib/ledger.py" <<'PY'
#!/usr/bin/env python3
"""apt simulation-ledger and real-log parser + exact-set comparer for S5.

apt 3.x prints Inst/Remv/Conf ledger lines only in simulation (-s) output;
real runs print Unpacking/Removing/Setting up lines instead. Every swap
therefore runs twice from the same prestate: simulated once (the exact
ledger) and for real once under script(1) (the rc + the dpkg poststate).

Ledger grammar (measured: apt 3.0.3 on trixie, 3.2.0 on sid):
  Inst name [old] (new origin [arch]) [dep-cascade ]   upgrade (old present)
  Inst name (new origin [arch])                        fresh install
  Remv name [old] [dep-cascade ]                       removal
  real: Unpacking name (new) [over (old)] ... / Removing name (old) ...
Origin spellings (measured): the distribution 'Debian:unstable'; the
stand-in's signed flat Release (Origin/Suite set) renders 'standin:standin';
the local build renders 'diamondinoia:now' (apt-ftparchive without a Suite
option). The comparer's set algebra keys on names only; the origin strings
are asserted in the leg bodies whose business is resolution order.
"""
import json, re, sys

INST = re.compile(r"^Inst (\S+?)(:\w+)?(?: \[([^\]]*)\])? \((\S+) ([^]]*?)\s+\[[^\]]*\]\)")
REMV = re.compile(r"^Remv (\S+?)(:\w+)? \[([^\]]*)\]")
UNPACK = re.compile(r"^Unpacking (\S+?)(:\w+)? \(([^)]*)\)(?: over \(([^)]*)\))? \.\.\.")
REMOVING = re.compile(r"^Removing (\S+?)(:\w+)? \(([^)]*)\)")


def parse_sim(text):
    """(inst {name: origin}, upg {name: (old, origin)}, remv {name: old})."""
    inst, upg, remv = {}, {}, {}
    for line in text.splitlines():
        m = INST.match(line)
        if m:
            name, old, origin = m.group(1), m.group(3), m.group(5)
            if old:
                upg[name] = (old, origin)
            else:
                inst[name] = origin
            continue
        m = REMV.match(line)
        if m:
            remv[m.group(1)] = m.group(3)
    return inst, upg, remv


def parse_real(text):
    """(unpacked-new {name: ver}, upgraded-over {name: (old, new)}, removed {name: ver})."""
    new, over, gone = {}, {}, {}
    for line in text.splitlines():
        m = UNPACK.match(line)
        if m:
            if m.group(4):
                over[m.group(1)] = (m.group(4), m.group(3))
            else:
                new[m.group(1)] = m.group(3)
            continue
        m = REMOVING.match(line)
        if m:
            gone[m.group(1)] = m.group(3)
    return new, over, gone


def _diff(tag, have, want):
    return [f"unexpected {tag}: {n}" for n in sorted(set(have) - set(want))] + \
           [f"missing {tag}: {n}" for n in sorted(set(want) - set(have))]


def compare(expect, sim, real, post):
    """Exact over the asserted universe; then sim bound to the real run and
    to the dpkg poststate. expect/sim/(real) are the parse tuples; post is a
    set of installed package names."""
    e_inst, e_upg, e_remv = (set(x) for x in expect)
    s_inst, s_upg, s_remv = (set(x) for x in sim)
    r_new, r_over, r_gone = (set(x) for x in real)
    bad = []
    bad += _diff("Inst", s_inst, e_inst)
    bad += _diff("Upg", s_upg, e_upg)
    bad += _diff("Remv", s_remv, e_remv)
    bad += [f"simulated Remv not removed in the real run: {n}"
            for n in sorted(s_remv - r_gone)]
    bad += [f"simulated Upg not upgraded in the real run: {n}"
            for n in sorted(s_upg - r_over)]
    bad += [f"simulated Inst not unpacked in the real run: {n}"
            for n in sorted(s_inst - r_new)]
    bad += [f"expected installed but absent from the poststate: {n}"
            for n in sorted((e_inst | e_upg) - post)]
    bad += [f"removed yet still installed in the poststate: {n}"
            for n in sorted(e_remv & post)]
    return bad


def selftest():
    """Positive controls: every doctored shape must be rejected."""
    sim_log = """Inst libgcc-16-dev (16.2.0-3 standin:standin [amd64])
Inst gcc-16 [16~ce16.2.0-1] (16.2.0-3 standin:standin [amd64]) []
Remv g++-16 [16.2.0-3]
"""
    real_log = """Unpacking libgcc-16-dev (16.2.0-3) ...
Unpacking gcc-16 (16.2.0-3) over (16~ce16.2.0-1) ...
Removing g++-16 (16.2.0-3) ...
"""
    expect = ({"libgcc-16-dev"}, {"gcc-16"}, {"g++-16"})
    post = {"libgcc-16-dev", "gcc-16"}
    if compare(expect, parse_sim(sim_log), parse_real(real_log), post) != []:
        print("FAIL  control 0: a clean log pair was rejected")
        return 1
    rc = 0
    cases = {"extra Remv": sim_log + "Remv libgcc-s1 [16.2.0-2]\n",
             "extra Inst": sim_log + "Inst cpp-16 (16.2.0-3 standin:standin [amd64])\n",
             "extra Upg": sim_log + "Inst libxml2 [1] (2 Debian:unstable [amd64])\n",
             "missing Remv": sim_log.replace("Remv g++-16 [16.2.0-3]\n", "")}
    for tag, slog in sorted(cases.items()):
        got = compare(expect, parse_sim(slog), parse_real(real_log), post)
        if got:
            print(f"pass  control 0: {tag} rejected ({got[0]})")
        else:
            print(f"FAIL  control 0: {tag} accepted")
            rc = 1
    # a Remv missing from the REAL run (sim claims it) must also be caught
    got = compare(expect, parse_sim(sim_log),
                  parse_real(real_log.replace("Removing g++-16 (16.2.0-3) ...\n", "")),
                  post)
    if got:
        print(f"pass  control 0: sim-real divergence rejected ({got[0]})")
    else:
        print("FAIL  control 0: sim-real divergence accepted")
        rc = 1
    # epochs, cascade annotations and old-brackets must parse
    inst, upg, remv = parse_sim(
        "Inst clang-3.3 [3.3~ce3.3-1] (1:3.3-16 standin:standin [amd64]) [x:amd64 ]\n"
        "Remv gcc-16-x86-64-linux-gnu [16.2.0-3] []\n")
    if inst or upg.get("clang-3.3") != ("3.3~ce3.3-1", "standin:standin") or \
       remv != {"gcc-16-x86-64-linux-gnu": "16.2.0-3"}:
        print("FAIL  control 0: epoch/cascade parse broken")
        rc = 1
    else:
        print("pass  control 0: epoch and cascade annotations parse")
    return rc


if __name__ == "__main__":
    if sys.argv[1] == "selftest":
        sys.exit(selftest())
    # compare-log EXPECT.json SIM.log REAL.log POSTSTATE
    expect = json.load(open(sys.argv[1]))
    exp = (expect["inst"], expect["upg"], expect["remv"])
    bad = compare(exp, parse_sim(open(sys.argv[2]).read()),
                  parse_real(open(sys.argv[3]).read()),
                  set(open(sys.argv[4]).read().split()))
    for b in bad:
        print(f"      {b}")
    sys.exit(1 if bad else 0)
PY
python3 "$work/lib/ledger.py" selftest || exit 1

# --- scratch build with an ephemeral signing key ---------------------------
# build.py's ROOT is its own directory, so building a copy of the inputs
# never touches the working tree's out/.
for f in build.py catalog.json mirror-manifest.json packages.toml exceptions.json; do
    [ -f "$tree/$f" ] && cp "$tree/$f" "$work/src/"
done
export GNUPGHOME=$work/gnupg
mkdir -p -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key 'S5 precedence test <s5@invalid>' rsa2048 sign 0 2>/dev/null
export GPG_KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')
( cd "$work/src" && python3 build.py $(printf -- '--only %s ' "${emits[@]}") ) \
    > "$work/logs/build.log" 2>&1 || {
        fail "the scratch build itself failed"; tail -20 "$work/logs/build.log"; exit 1; }
boot=$(cd "$work/src/out" && echo diamondinoia-apt_*_all.deb)
pass "scratch repo built and signed (${#emits[@]} bundles + bootstrap $boot)"

# Payloads are the only fat downloads: fetched ONCE per run on the host for
# the selected legs/fixtures, checked against the manifest-pinned SHA-256,
# then served to every container's postinst by the curl shim off a read-only
# mount. The deb's own sha256sum -c still gates the bytes in-container, so a
# wrong cache file cannot pass silently.
needed=()
for n in $(python3 -c "import json; print(' '.join(
        f['name'] for f in json.load(open('$work/lib/bplan.json'))['fixtures']))"); do
    [[ " $legs " == *" b "* ]] && needed+=("$n")
done
if [[ " $legs " == *" cfwd "* || " $legs " == *" crev "* ]]; then
    case " ${needed[*]-} " in *" gcc-16 "*) ;; *) needed+=(gcc-16) ;; esac
fi
if [ "${#needed[@]}" -gt 0 ]; then
    python3 - "$spec" "${needed[@]}" > "$work/payloads.map" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for n in sys.argv[2:]:
    p = s["bundles"][n]["payload"]
    print(n, p["url"], p["sha256"], p["asset"], sep="\t")
PY
    auth=()
    [ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GH_TOKEN")
    while IFS=$'\t' read -r name url sha asset; do
        echo "$sha  $work/payloads/$asset"
    done < "$work/payloads.map" > "$work/payloads.sums"
    while IFS=$'\t' read -r name url sha asset; do
        [ -f "$work/payloads/$asset" ] ||
            curl -fsSL "${auth[@]+"${auth[@]}"}" "$url" -o "$work/payloads/$asset" &
    done < "$work/payloads.map"
    wait
    sha256sum -c "$work/payloads.sums" > /dev/null || {
        fail "a prefetched payload failed its pinned SHA-256"; exit 1; }
    pass "selected payloads cached and hash-clean ($(cut -f4 "$work/payloads.map" | tr '\n' ' '))"
else
    pass "no selected leg needs a payload (stub-only run)"
fi

cat > "$work/lib/curl-shim" <<'SH'
#!/bin/sh
# S5 payload shim: the bundle postinst curls its mirrored payload; serve the
# asset from the per-run host-fetched /payloads mount instead of re-pulling
# hundreds of MiB per container. Anything uncached falls through to the real
# curl. The postinst's own SHA-256 check still runs on the bytes.
url=; out=
while [ $# -gt 0 ]; do
    case $1 in
        -o) out=$2; shift 2;;
        -*) shift;;
        *)  url=$1; shift;;
    esac
done
asset=${url##*/}
if [ -n "$asset" ] && [ -f "/payloads/$asset" ]; then
    cp "/payloads/$asset" "$out"
    exit 0
fi
exec /usr/bin/curl -fsSL "$url" -o "$out"
SH
chmod 755 "$work/lib/curl-shim"

# --- shared in-container library -------------------------------------------
cat > "$work/lib/s5lib.sh" <<'SH'
# Shared harness for every S5 container. /repo: the scratch-built repository,
# read-only. /payloads: the per-run payload cache, read-only. /tlib: this lib.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/bin:$PATH
ok()   { echo "  ok   $*"; }
fail() { echo "FAIL   $*"; exit 1; }

prep() {
    cp /tlib/curl-shim /usr/local/bin/curl; chmod 755 /usr/local/bin/curl
    apt-get -qq update
    apt-get -qq install -y --no-install-recommends \
        curl ca-certificates dpkg-dev python3-minimal >/dev/null
    apt-get -qq install -y /repo/diamondinoia-apt_*_all.deb >/dev/null
    # The bootstrap attaches third-party sources a workstation wants; this
    # suite tests the compiler-namespace pin, not those feeds. Keep the
    # baseline's own source plus ours, repointed at the local signed build.
    ( cd /etc/apt/sources.list.d && rm -f brave.sources github-cli.sources \
        google-cloud-cli.sources llvm.sources nvidia-container-toolkit.sources \
        onlyoffice.sources tailscale.sources vscode.sources yazi.sources )
    printf 'Types: deb\nURIs: file:///repo\nSuites: /\nSigned-By: /etc/apt/keyrings/diamondinoia.gpg\n' \
        > /etc/apt/sources.list.d/diamondinoia.sources
    apt-get -qq update
}

# The shipped pin as installed by the bootstrap: the glob stanza sits at 100
# and one sed flips it to 600 for the per-leg controls. The stanza counts are
# asserted before and after, so the sed is total by construction.
pin_file=/etc/apt/preferences.d/diamondinoia
pin_flip_to_600() {
    [ "$(grep -c 'Pin-Priority: 100' "$pin_file")" = 1 ] ||
        fail "the shipped pin does not hold exactly one 100 stanza"
    cp "$pin_file" /tmp/pin.orig
    sed -i 's/Pin-Priority: 100/Pin-Priority: 600/' "$pin_file"
    [ "$(grep -c 'Pin-Priority: 600' "$pin_file")" = 2 ] ||
        fail "the pin rewrite did not take"
    apt-get -qq update
}
pin_restore() {
    cp /tmp/pin.orig "$pin_file"
    apt-get -qq update
}

# Stand-in repo machinery: metadata-faithful, empty-payload debs. Every stub
# ships one /usr/share marker (real splits are never empty: an empty stub
# tripped dpkg's "completely replaced" disappearance sweep while the outgoing
# bundle's Replaces still named it mid-transaction) plus one marker script
# per /usr/bin name to own.
stub_db=/srv/deb
stub_reset() { rm -rf "$stub_db"; mkdir -p "$stub_db"; }
stub() { # name version depends binfiles...
    local name=$1 ver=$2 deps=$3; shift 3
    local d=$stub_db/stage
    rm -rf "$d"; mkdir -p "$d/DEBIAN" "$d/usr/bin" "$d/usr/share/$name"
    { printf 'Package: %s\nVersion: %s\nArchitecture: amd64\nMaintainer: d <d@invalid>\n' "$name" "$ver"
      [ -n "$deps" ] && printf 'Depends: %s\n' "$deps"
      printf 'Description: stand-in for the distribution package\n'
    } > "$d/DEBIAN/control"
    printf 'stand-in marker for %s %s\n' "$name" "$ver" > "$d/usr/share/$name/marker"
    local b
    for b in "$@"; do
        printf '#!/bin/sh\necho "STUB-DEBIAN %s %s"\n' "$name" "$ver" > "$d/usr/bin/$b"
        chmod 755 "$d/usr/bin/$b"
    done
    dpkg-deb --root-owner-group --build "$d" "$stub_db/${name}_${ver}_amd64.deb" >/dev/null
    rm -rf "$d"
}
stub_attach() {
    ( cd "$stub_db" && rm -f Packages Packages.gz Release \
        && dpkg-scanpackages --multiversion . /dev/null > Packages 2>/dev/null \
        && gzip -kf Packages && python3 - <<'EOF'
# A signed-checksum Release: without one apt probes every compression variant
# per update and logs three W: lines each time, which buries the evidence
# (test_gcc17.sh compressed for the same reason).
import hashlib, time
dig = []
for f in ("Packages", "Packages.gz"):
    b = open(f, "rb").read()
    dig.append((hashlib.md5(b).hexdigest(), hashlib.sha256(b).hexdigest(), len(b), f))
rel = ["Origin: standin", "Label: standin", "Suite: standin", "Codename: standin",
       time.strftime("Date: %a, %d %b %Y %H:%M:%S UTC", time.gmtime()),
       "Architectures: amd64", "Components: ./", "MD5Sum:"]
rel += [f" {m} {s:16d} {f}" for m, h, s, f in dig]
rel.append("SHA256:")
rel += [f" {h} {s:16d} {f}" for m, h, s, f in dig]
open("Release", "w").write("\n".join(rel) + "\n")
EOF
    )
    echo "deb [trusted=yes] file://$stub_db ./" > /etc/apt/sources.list.d/stand-in.list
    apt-get -qq update
}

# The stand-in's same-named handover version must sort above everything the
# live archive holds for the name (an equal spelling made apt pick the
# archive's file), which also puts it above ours (`~` sorts below every
# complete spelling). Computed in-container: fallback spelling, else the live
# candidate with its last numeric run bumped.
stub_ver() { # name fallback -> stdout
    local n=$1 fb=$2 c
    c=$(apt-cache policy "$n" 2>/dev/null | sed -n 's/^ *Candidate: //p')
    if [ -n "$c" ] && [ "$c" != "(none)" ] && ! dpkg --compare-versions "$fb" gt "$c"; then
        fb=$(python3 -c "
import re, sys
v = sys.argv[1]
m = re.search(r'[0-9]+(?!.*[0-9])', v)
print(v[:m.start()] + str(int(m.group(0)) + 1) + v[m.end():])" "$c")
        dpkg --compare-versions "$fb" gt "$c" ||
            { echo "stub_ver: cannot beat the live candidate $c for $n" >&2; exit 1; }
    fi
    printf '%s' "$fb"
}

candidate() { apt-cache policy "$1" | sed -n 's/^ *Candidate: //p'; }

inst_line() { # name args... -> the simulated Inst ledger line for that name
    local n=$1; shift
    apt-get -s "$@" | grep "^Inst $n " || true
}

# Ours-marker check for leg B's pre-state: --version must carry the payload
# version our own version names (the piece after ~ce, revision dropped), so a
# swap at the right name cannot pass invisibly.
our_marker() { # link our_version
    local out m=${2#*ce} ; m=${m%%-*}
    out=$("$1" --version 2>&1 | head -1) || fail "$1 does not answer --version"
    case $out in
        *STUB-DEBIAN*) fail "$1 answers the stand-in marker before the handover" ;;
        *"$m"*) : ;;
        *) fail "$1 --version is '$out', not carrying our payload version $m" ;;
    esac
}
stub_marker() { # link name version
    [ "$("$1" --version)" = "STUB-DEBIAN $2 $3" ] ||
        fail "$1 answers '$("$1" --version)', not the stand-in marker"
}
SH

# --- gcc-16 split-family stand-in (legs B native + C) -----------------------
cat > "$work/lib/gcc16_family.sh" <<'SH'
# gcc-16 split-family stand-in, modelled on the live archive's relation shape
# (apt-cache show, measured on both baselines: gcc-16 Depends its triplet
# intermediate, base and cpp strict; g++-16 through its triplet intermediate
# at libstdc++-16-dev strict), with three deliberate, documented departures:
#   - gcc-16-base is NOT bumped where the baseline's archive ships it: the
#     installed runtime (libgcc-s1/libstdc++6) strict-depends gcc-16-base (=
#     its own version), so any bump makes the stand-in uninstallable next to
#     the runtime this suite must never touch. The family then floors base at
#     the archive's candidate with (>= C) and the archive supplies it; on a
#     baseline without the family (trixie today) the stand-in ships base at
#     W strict.
#   - runtime soname packages are never modelled (the build's P/C/R denylist
#     keeps our splits from naming them; the legs assert them removed-never).
#   - outside-family third-party deps (binutils, libc6-dev on libstdc++-N-dev)
#     are dropped: resolvable at any archive version, so they add Inst noise
#     the exact-set legs would have to model hostside for zero mechanism.
#     libc6 itself stays (installed in every prestate).
gcc16_stubs() {
    stub_reset
    local C base
    W=$(stub_ver gcc-16 16.2.0-3)
    C=$(apt-cache policy gcc-16-base | sed -n 's/^ *Candidate: //p')
    [ "$C" = "(none)" ] && C=
    if [ -n "$C" ]; then
        base="gcc-16-base (>= $C)"
    else
        base="gcc-16-base (= $W)"
        stub gcc-16-base "$W" ""
    fi
    stub cpp-16 "$W" "$base" cpp-16
    stub cpp-16-x86-64-linux-gnu "$W" "$base"
    stub libgcc-16-dev "$W" "$base"
    stub gcc-16-x86-64-linux-gnu "$W" \
        "$base, cpp-16-x86-64-linux-gnu (= $W), libgcc-16-dev (= $W), libc6" \
        x86_64-linux-gnu-gcc-16
    stub gcc-16 "$W" \
        "$base, cpp-16 (= $W), gcc-16-x86-64-linux-gnu (= $W)" gcc-16
    stub libstdc++-16-dev "$W" "$base, libgcc-16-dev (= $W)"
    stub g++-16-x86-64-linux-gnu "$W" \
        "$base, gcc-16-x86-64-linux-gnu (= $W), libstdc++-16-dev (= $W)"
    stub g++-16 "$W" "$base, gcc-16 (= $W), g++-16-x86-64-linux-gnu (= $W)" g++-16
    stub_attach
    GCC16_STUB_W=$W
}
SH

# --- LEG A -------------------------------------------------------------------
cat > "$work/lib/leg_a.sh" <<'SH'
#!/bin/bash
set -euo pipefail
. /tlib/s5lib.sh
. /tlib/versions.env
prep

echo "== LEG A: distro resolution against the live archive"
shipped=0; ours_only=0
while IFS=$'\t' read -r name ver; do
    pol=$(apt-cache policy "$name")
    if grep -qE '^\s+[0-9]+\s+https?://' <<<"$pol"; then
        shipped=$((shipped + 1))
        # our offer must sit in the table at exactly 100
        awk -v v="$ver" '$1 == v && $2 == 100 {found=1} END {exit !found}' <<<"$pol" ||
            fail "leg-A: $name: no row for our $ver at priority 100"
        # decisive: the simulated install resolves the distribution build
        line=$(inst_line "$name" install "$name")
        case $line in
            "Inst $name ("*" Debian:"*)
                ok "leg-A: $name resolves the distribution's candidate, ours parked at 100" ;;
            *) fail "leg-A: $name Inst line is not the distribution's build: $line" ;;
        esac
    else
        ours_only=$((ours_only + 1))
        [ "$(candidate "$name")" = "$ver" ] ||
            fail "leg-A: $name candidate is '$(candidate "$name")', expected our $ver"
        case $(inst_line "$name" install "$name") in
            "Inst $name ($ver diamondinoia:"*)
                ok "leg-A: $name resolves OURS ($ver) at pin 100" ;;
            *) fail "leg-A: $name Inst line is not our offer: $(inst_line "$name" install "$name")" ;;
        esac
    fi
done < <(python3 - <<'PY'
import json
lite = json.load(open("/tlib/spec-lite.json"))
for n, b in sorted(lite["emits"].items()):
    print(n, b["version"], sep="\t")
PY
)
[ "$ours_only" -ge 3 ] ||
    fail "leg-A non-vacuity: only $ours_only archive-absent names (want >= 3)"
ok "leg-A non-vacuity: $ours_only archive-absent names, all resolve ours"
if [ "$shipped" -ge 1 ]; then
    ok "leg-A non-vacuity: $shipped archive-shipped overlap names, all resolve Debian's"
else
    # trixie ships none of the emit names today; the overlap mechanism stands
    # proven there by the stand-in flip block below.
    ok "leg-A: the live archive ships none of our names; overlap proven by the flip block"
fi

# The shipped 100 glob stanza must cover every emit name (the S3 multi-name
# stanza semantics migrated from test_gcc17.sh, now over the full emit set).
python3 - <<'PY' || fail "leg-A: the 100 glob stanza does not cover every emit name"
import fnmatch, json, re
m = re.search(r"Package: ([^\n]*)\nPin: release l=diamondinoia\nPin-Priority: 100",
              open("/etc/apt/preferences.d/diamondinoia").read())
assert m, "no 100 stanza"
names = m.group(1).split()
lite = json.load(open("/tlib/spec-lite.json"))
bad = [n for n in lite["emits"]
       if not any(fnmatch.fnmatchcase(n, t) for t in names)]
if bad:
    print("      uncovered:", bad)
raise SystemExit(bool(bad) or not names)
PY
nemits=$(wc -l < /tlib/versions.env)
ok "leg-A: the shipped 100 glob stanza covers all $nemits emit names"

echo "== LEG A flip: a stand-in furnishes the overlap; only the pin decides"
stub_reset
V=$(stub_ver gcc-16 16.2.0-3)
stub gcc-16 "$V" "" gcc-16 g++-16
stub_attach
[ "$(candidate gcc-16)" = "$V" ] ||
    fail "leg-A flip: at 100 the stand-in's $V is not the candidate"
line=$(inst_line gcc-16 install gcc-16)
case $line in
    "Inst gcc-16 ($V standin:"*)
        ok "leg-A: at pin 100 the stand-in's $V resolves over ours" ;;
    *) fail "leg-A flip: at 100 the stand-in did not win: $line" ;;
esac
pin_flip_to_600
[ "$(candidate gcc-16)" = "$V_gcc_16" ] ||
    fail "leg-A flip: at 600 ours is not the candidate ($(candidate gcc-16))"
line=$(inst_line gcc-16 install gcc-16)
case $line in
    "Inst gcc-16 ($V_gcc_16 diamondinoia:"*)
        ok "leg-A flip: at pin 600 resolution picks OURS ($V_gcc_16)" ;;
    *) fail "leg-A flip: at 600 ours did not win: $line" ;;
esac
pin_restore
[ "$(candidate gcc-16)" = "$V" ] || fail "leg-A flip: the pin restore did not restore"
ok "leg-A flip: restored to 100, the stand-in wins again"
echo "PASS leg-a"
SH
chmod 755 "$work/lib/leg_a.sh"

# --- LEG B -------------------------------------------------------------------
cat > "$work/lib/leg_b.sh" <<'SH'
#!/bin/bash
set -euo pipefail
. /tlib/s5lib.sh
. /tlib/versions.env
. /tlib/gcc16_family.sh
prep

python3 - <<'PY'
import json
p = json.load(open("/tlib/bplan.json"))
for n in p["skipped"]:
    print(f"SKIP   leg-b: {n} fixture unemitted (no mirrored payload today);"
          f" sweep mode runs it for real once mirrored")
PY

handover_leg() { # name class fallback flip? marks...
    local name=$1 class=$2 fb=$3 flip=$4; shift 4
    local ours_ver
    ours_ver=$(python3 -c "
import json; print(json.load(open('/tlib/spec-lite.json'))['emits']['$name']['version'])")
    apt-get -y install "$name=$ours_ver" >/dev/null
    [ -d "/opt/$name" ] || fail "leg-B: /opt/$name absent after our install"
    local m t
    for m in "$@"; do
        t=$(readlink -f "/usr/bin/$m") ||
            fail "leg-B: /usr/bin/$m is no symlink after our install"
        case $t in
            /opt/$name/*) : ;;
            *) fail "leg-B: /usr/bin/$m -> $t, not our tree" ;;
        esac
        our_marker "/usr/bin/$m" "$ours_ver"
    done
    ok "leg-B: $name: our $ours_ver in, $# link(s) point into /opt/$name, markers answer our payload"
    local V upg=upgrade
    case $class in
        native)
            # the real split chain rides the same-name upgrade transaction:
            # intermediates are NEW packages, so plain upgrade keeps the name
            # back (measured: apt 3.2.0 kept a foo gaining Depends back) —
            # --with-new-pkgs completes one transaction
            gcc16_stubs; V=$GCC16_STUB_W; upg="--with-new-pkgs upgrade" ;;
        *) stub_reset; V=$(stub_ver "$name" "$fb")
           stub "$name" "$V" "" "$@"; stub_attach ;;
    esac
    [ "$(candidate "$name")" = "$V" ] ||
        fail "leg-B: $name: the stand-in $V did not become the candidate"
    # The pin control rides the first fixture of the run (mechanism, one
    # instance per leg).
    if [ "$flip" = flip ]; then
        pin_flip_to_600
        line=$(apt-get -s upgrade | grep "^Inst $name " || true)
        [ -z "$line" ] ||
            fail "leg-B flip: at 600 an upgrade to the stand-in is still offered: $line"
        apt-get -y $upg >/dev/null 2>&1 || true
        [ "$(dpkg-query -W -f '${Version}' "$name")" = "$ours_ver" ] ||
            fail "leg-B flip: at 600 an upgrade moved $name anyway"
        [ -d "/opt/$name" ] || fail "leg-B flip: at 600 our tree vanished"
        for m in "$@"; do our_marker "/usr/bin/$m" "$ours_ver"; done
        ok "leg-B flip: at 600 no upgrade is offered and a real upgrade leaves ours in place"
        pin_restore
    fi
    before=$(dpkg-query -W -f '${Version}' "$name")
    script -qec "apt-get -y $upg" "/tmp/upgrade.$name.log" >/dev/null ||
        { tail -20 "/tmp/upgrade.$name.log"; fail "leg-B: the handover upgrade failed for $name"; }
    grep -iE 'trying to overwrite|dpkg: error processing' "/tmp/upgrade.$name.log" \
        && fail "leg-B: dpkg overwrite diagnostics in the handover of $name" || :
    [ "$(dpkg-query -W -f '${Version}' "$name")" = "$V" ] ||
        fail "leg-B: $name still at $before, not $V"
    [ ! -e "/opt/$name" ] ||
        fail "leg-B: /opt/$name survived the handover (prerm purge broken)"
    for m in "$@"; do
        owner=$(dpkg -S "/usr/bin/$m" 2>/dev/null) ||
            fail "leg-B: /usr/bin/$m owned by nothing after the handover"
        case $owner in
            "$name: /usr/bin/$m") : ;;
            *) fail "leg-B: /usr/bin/$m owned by $owner, not the stand-in" ;;
        esac
        stub_marker "/usr/bin/$m" "$name" "$V"
    done
    ok "leg-B: $name handed over: $before -> $V; self link stub-owned; /opt purged; no overwrite errors"
    if [ "$class" = native ]; then
        # the chain intermediates must have joined the handover transaction,
        # not resolved later: their Unpacking lines sit in the upgrade log
        for inter in cpp-16 gcc-16-x86-64-linux-gnu cpp-16-x86-64-linux-gnu; do
            grep -qE "^Unpacking $inter \(" "/tmp/upgrade.$name.log" ||
                fail "leg-B: the chain intermediate $inter was not in the handover transaction"
        done
        ok "leg-B: the split chain (cpp-16, *-x86-64-linux-gnu) rode the upgrade transaction"
        # /usr/bin/g++-16 transfers only when its own package is installed:
        # stub g++-16 Depends gcc-16 (= W) resolves only against the stand-in
        # gcc-16 just installed — the contracted split-shape proof
        apt-get -y install g++-16 libstdc++-16-dev >/dev/null ||
            fail "leg-B: the g++-16 chain install failed"
        owner=$(dpkg -S /usr/bin/g++-16 2>/dev/null) ||
            fail "leg-B: /usr/bin/g++-16 owned by nothing after the chain install"
        [ "$owner" = "g++-16: /usr/bin/g++-16" ] ||
            fail "leg-B: /usr/bin/g++-16 owned by '$owner', not the stub g++-16"
        stub_marker /usr/bin/g++-16 g++-16 "$V"
        stub_marker /usr/bin/cpp-16 cpp-16 "$V"
        dpkg-query -W -f '${Status}\n' g++-16-x86-64-linux-gnu 2>/dev/null |
            grep -q '^install ok installed' ||
                fail "leg-B: the g++-16-x86-64-linux-gnu intermediate did not resolve"
        ok "leg-B: g++-16 + libstdc++-16-dev resolved through the strict chain (g++-16 Depends gcc-16 (= $V))"
    fi
}

i=0
python3 - <<'PY' > /tmp/bplan.tsv
import json
for f in json.load(open("/tlib/bplan.json"))["fixtures"]:
    print(f["name"], f["class"], f["fallback"], " ".join(f["marks"]), sep="\t")
PY
[ -s /tmp/bplan.tsv ] || fail "leg-B non-vacuity: no fixtures selected"
while IFS=$'\t' read -r n c fb ms; do
    read -ra marks <<<"$ms"
    flip=noflip; [ "$i" = 0 ] && flip=flip
    handover_leg "$n" "$c" "$fb" "$flip" "${marks[@]}"
    i=$((i + 1))
done < /tmp/bplan.tsv
echo "PASS leg-b"
SH
chmod 755 "$work/lib/leg_b.sh"

# --- LEG C shared pieces ----------------------------------------------------
cat > "$work/lib/leg_c_common.sh" <<'SH'
# Expected Inst/Upg/Remv sets, computed from the stub index + dpkg prestate +
# live policy (never hardcoded). forward|reverse as $1; JSON on stdout.
expect_sets() {
    python3 - "$1" <<'PY'
import json, re, subprocess, sys

direction = sys.argv[1]
FAMILY = ["g++-16", "g++-16-x86-64-linux-gnu", "gcc-16", "gcc-16-base",
          "gcc-16-x86-64-linux-gnu", "cpp-16", "cpp-16-x86-64-linux-gnu",
          "libgcc-16-dev", "libstdc++-16-dev"]
LOCKSTEP = ["libgcc-s1", "libstdc++6"]  # + gcc-16-base; see forward rule

def cmp(a, op, b):
    return subprocess.run(["dpkg", "--compare-versions", a, op, b],
                          check=False).returncode == 0

# the stub index: name -> (version, [(dep, op, ver)])
idx = {}
for stanza in open("/srv/deb/Packages").read().split("\n\n"):
    name = ver = None; deps = []
    for line in stanza.splitlines():
        if line.startswith("Package: "): name = line[9:]
        elif line.startswith("Version: "): ver = line[9:]
        elif line.startswith("Depends: "):
            for d in line[9:].split(", "):
                m = re.fullmatch(r"(\S+)(?: \((=|>=|<=) (\S+)\))?", d)
                deps.append((m.group(1), m.group(2), m.group(3)))
    if name and name in FAMILY:
        idx[name] = (ver, deps)

installed = {}
out = subprocess.run(["dpkg-query", "-W", "-f", "${Package}\t${Version}\n"],
                     capture_output=True, text=True, check=True).stdout
for line in out.splitlines():
    p, v = line.split("\t")
    installed[p.split(":")[0]] = v

def live_candidate(name):
    out = subprocess.run(["apt-cache", "policy", name],
                         capture_output=True, text=True, check=True).stdout
    m = re.search(r"^ *Candidate: (\S+)$", out, re.M)
    c = m.group(1) if m else "(none)"
    return None if c == "(none)" else c

if direction == "forward":
    W = idx["g++-16"][0]
    closure = set()
    def visit(n):
        if n in closure or n not in idx: return
        closure.add(n)
        for dn, op, dv in idx[n][1]:
            if op == "=":
                visit(dn)
    visit("g++-16"); visit("libstdc++-16-dev")
    inst, upg = [], []
    for n in sorted(closure):
        if n in installed and installed[n] != W: upg.append(n)
        elif n not in installed: inst.append(n)
    # gcc-16-base: fresh install only where the archive has none (trixie);
    # else the stub relations floor it at the live candidate C and apt must
    # upgrade any older installed base, dragging the runtime with it via its
    # strict (= base) deps (the sid lockstep triple, measured).
    C = live_candidate("gcc-16-base")
    basev = installed.get("gcc-16-base")
    if C is None and basev is None:
        inst.append("gcc-16-base")
    elif C is not None and basev is not None and cmp(basev, "lt", C):
        upg.append("gcc-16-base")
        for m in LOCKSTEP:
            mv = installed.get(m)
            if mv is not None and mv != C:
                upg.append(m)
    print(json.dumps({"inst": sorted(set(inst)), "upg": sorted(set(upg)),
                      "remv": []}))
else:
    lite = json.load(open("/tlib/spec-lite.json"))
    ours = lite["emits"]["gcc-16"]
    pcr = ours["pcr"]
    conflicts = set(pcr["conflicts"])
    provides = pcr["provides"]          # name -> "= ver"
    fam = {n: v for n, v in installed.items() if n in FAMILY or n in idx}
    remv = set(n for n in fam if n in conflicts)
    changed = True
    while changed:
        changed = False
        for n in sorted(fam):
            if n in remv or n == "gcc-16" or n not in idx: continue
            for dn, op, dv in idx[n][1]:
                if dn not in FAMILY or op != "=": continue
                if dn in conflicts or dn == "gcc-16":
                    # the name is ours after the swap; only our versioned
                    # Provides, if any, can answer the strict requirement
                    prov = provides.get(dn)
                    available = prov.split(" ", 1)[1] if prov else None
                elif dn in remv:
                    available = None
                else:
                    available = fam.get(dn)
                if available is None or not cmp(available, "eq", dv):
                    remv.add(n); changed = True
                    break
    # ours lands as a downgrade (Inst-with-old ledger line); its Depends pull
    # only what the prestate lacks, from the distribution archive (measured:
    # libc6-dev and libxml2 on both baselines today)
    ext = sorted(n for n in ours["depends"] if n not in installed)
    print(json.dumps({"inst": sorted(ext), "upg": ["gcc-16"],
                      "remv": sorted(remv)}))
PY
}
SH

cat > "$work/lib/leg_cfwd.sh" <<'SH'
#!/bin/bash
set -euo pipefail
. /tlib/s5lib.sh
. /tlib/versions.env
. /tlib/gcc16_family.sh
. /tlib/leg_c_common.sh
prep

echo "== LEG C forward: ours installed, then g++-16 + libstdc++-16-dev requested"
apt-get -y install "gcc-16=$V_gcc_16" >/dev/null
[ -d /opt/gcc-16 ] && [ -L /usr/bin/gcc-16 ] ||
    fail "leg-C forward: our gcc-16 did not install as the pre-state"
gcc16_stubs
W=$GCC16_STUB_W

echo "-- flip first, while ours is intact: at 600 the swap must be refused"
pin_flip_to_600
set +e
apt-get -s install g++-16 libstdc++-16-dev > /tmp/sim6.log 2>&1
rc6=$?
set -e
[ "$rc6" -ne 0 ] ||
    { sed 's/^/      /' /tmp/sim6.log; fail "leg-C flip: at 600 the forward swap SIMULATES clean"; }
grep -q 'Unable to satisfy dependencies\|unmet dependencies' /tmp/sim6.log ||
    fail "leg-C flip: at 600 the refusal is not an unmet-dependencies report"
[ "$(dpkg-query -W -f '${Version}' gcc-16)" = "$V_gcc_16" ] && [ -d /opt/gcc-16 ] ||
    fail "leg-C flip: at 600 the simulated refusal still disturbed ours"
ok "leg-C flip: at 600 the forward swap is refused (rc=$rc6) with ours kept"
pin_restore
apt-get -s install g++-16 libstdc++-16-dev > /dev/null 2>&1 ||
    fail "leg-C flip: after the pin restore the forward swap no longer resolves"
ok "leg-C flip: restored to 100, the forward swap resolves again"

expect_sets forward > /tmp/expect.json
echo "-- expected ledger: $(cat /tmp/expect.json)"
apt-get -s install g++-16 libstdc++-16-dev > /tmp/sim.log
echo "-- simulated: $(grep -E '^(Inst|Remv) ' /tmp/sim.log | tr '\n' '|')"
set +e
script -qec "apt-get -y install g++-16 libstdc++-16-dev" /tmp/real.log >/dev/null
rc=$?
set -e
[ "$rc" = 0 ] || { tail -20 /tmp/real.log; fail "leg-C forward: the real swap rc=$rc"; }
dpkg-query -W -f '${Package}\n' | sed 's/:amd64$//' | sort -u > /tmp/post.txt
python3 /tlib/ledger.py /tmp/expect.json /tmp/sim.log /tmp/real.log /tmp/post.txt ||
    fail "leg-C forward: the ledger does not equal the stub-derived expectation"
# ownership, markers and runtime keeps
for name in gcc-16 cpp-16 gcc-16-x86-64-linux-gnu libgcc-16-dev g++-16 libstdc++-16-dev; do
    dpkg-query -W -f '${Status}\n' "$name" 2>/dev/null | grep -q '^install ok installed' ||
        fail "leg-C forward: $name missing after the swap"
done
[ ! -e /opt/gcc-16 ] || fail "leg-C forward: /opt/gcc-16 survived the swap"
owner=$(dpkg -S /usr/bin/g++-16 2>/dev/null) ||
    fail "leg-C forward: /usr/bin/g++-16 owned by nothing after the swap"
[ "$owner" = "g++-16: /usr/bin/g++-16" ] ||
    fail "leg-C forward: /usr/bin/g++-16 owned by '$owner', not the stub g++-16"
stub_marker /usr/bin/g++-16 g++-16 "$W"
for rt in libgcc-s1 libstdc++6; do
    dpkg-query -W -f '${Status}\n' "$rt" 2>/dev/null | grep -q '^install ok installed' ||
        fail "leg-C forward: runtime package $rt was removed by the swap"
    grep -q "^Remv $rt " /tmp/sim.log &&
        fail "leg-C forward: runtime package $rt appears in the removal ledger" || :
done
ok "leg-C forward: exact sets match the stub-derived expectation; ours swapped out cleanly"
echo "PASS leg-cfwd"
SH
chmod 755 "$work/lib/leg_cfwd.sh"

cat > "$work/lib/leg_crev.sh" <<'SH'
#!/bin/bash
set -euo pipefail
. /tlib/s5lib.sh
. /tlib/versions.env
. /tlib/gcc16_family.sh
. /tlib/leg_c_common.sh
prep

echo "== LEG C reverse: full stand-in stack, then our bundle by path"
gcc16_stubs
apt-get -y install gcc-16 g++-16 libstdc++-16-dev >/dev/null
for n in gcc-16 g++-16 libstdc++-16-dev; do
    dpkg-query -W -f '${Status}\n' "$n" 2>/dev/null | grep -q '^install ok installed' ||
        fail "leg-C reverse: the stand-in stack did not install $n"
done
deb=/repo/gcc-16_${V_gcc_16//\~/.}_amd64.deb
[ -f "$deb" ] || fail "leg-C reverse: the built bundle $deb is missing"

# the flag is load-bearing: our version is a downgrade, and a flagless real
# attempt must refuse at the confirmation stage (the simulation leg accepts
# it — apt does not gate downgrades there), which is what proves the flag
# admitted ours at all. The refusal leaves the dpkg state untouched.
set +e
script -qec "apt-get -y install '$deb'" /tmp/nodown.log >/dev/null
rc=$?
set -e
[ "$rc" -ne 0 ] ||
    fail "leg-C reverse: the real downgrade proceeds without --allow-downgrades"
grep -qi downgrad /tmp/nodown.log ||
    fail "leg-C reverse: the flagless refusal is not a downgrade complaint"
dpkg-query -W -f '${Version}' gcc-16 | grep -q '16\.' ||
    fail "leg-C reverse: the refused attempt still touched the dpkg state"
ok "leg-C reverse: without --allow-downgrades the attempt refuses (rc=$rc), state untouched"

expect_sets reverse > /tmp/expect.json
echo "-- expected ledger: $(cat /tmp/expect.json)"
apt-get -s --allow-downgrades install "$deb" > /tmp/sim.log
echo "-- simulated: $(grep -E '^(Inst|Remv) ' /tmp/sim.log | tr '\n' '|')"
set +e
script -qec "apt-get -y --allow-downgrades install '$deb'" /tmp/real.log >/dev/null
rc=$?
set -e
[ "$rc" = 0 ] || { tail -20 /tmp/real.log; fail "leg-C reverse: the real downgrade rc=$rc"; }
dpkg-query -W -f '${Package}\n' | sed 's/:amd64$//' | sort -u > /tmp/post.txt
python3 /tlib/ledger.py /tmp/expect.json /tmp/sim.log /tmp/real.log /tmp/post.txt ||
    fail "leg-C reverse: the ledger does not equal the stub-derived expectation"
# contract-named keeps: denylisted base survives (as an orphan), the
# non-conflicted split cpp-16 survives, runtime is untouched
dpkg-query -W -f '${Status}\n' gcc-16-base 2>/dev/null | grep -q '^install ok installed' ||
    fail "leg-C reverse: gcc-16-base was removed though the denylist keeps it"
apt-mark showauto | grep -qx 'gcc-16-base' ||
    fail "leg-C reverse: gcc-16-base did not survive as an auto (orphan)"
dpkg-query -W -f '${Status}\n' cpp-16 2>/dev/null | grep -q '^install ok installed' ||
    fail "leg-C reverse: cpp-16 was removed though ours never conflicts it"
for rt in libgcc-s1 libstdc++6; do
    dpkg-query -W -f '${Status}\n' "$rt" 2>/dev/null | grep -q '^install ok installed' ||
        fail "leg-C reverse: runtime package $rt was removed"
    grep -q "^Remv $rt " /tmp/sim.log &&
        fail "leg-C reverse: runtime package $rt appears in the removal ledger" || :
done
# ours is in: payload tree + symlink ownership + version marker
[ -d /opt/gcc-16 ] || fail "leg-C reverse: /opt/gcc-16 absent after the downgrade"
[ "$(readlink -f /usr/bin/gcc-16)" = /opt/gcc-16/bin/gcc ] ||
    fail "leg-C reverse: /usr/bin/gcc-16 is not our symlink"
gcc-16 --version 2>/dev/null | grep -q '16\.2\.0' ||
    fail "leg-C reverse: gcc-16 --version is not our payload"
ok "leg-C reverse: conflicted splits and their revision-bearing dependents removed exactly"
echo "PASS leg-crev"
SH
chmod 755 "$work/lib/leg_crev.sh"

# --- drive the matrix --------------------------------------------------------
rc=0
for bl in $baselines; do
    mkdir -p "$work/cache-$bl"
    for leg in $legs; do
        log=$work/logs/$leg.$bl.log
        if "$engine" run --rm -i \
            -v "$work/src/out:/repo:ro" \
            -v "$work/payloads:/payloads:ro" \
            -v "$work/lib:/tlib:ro" \
            -v "$work/cache-$bl:/var/cache/apt/archives" \
            "debian:$bl" bash "/tlib/leg_${leg}.sh" > "$log" 2>&1; then
            grep -qx 'PASS leg.*' "$log" || {
                fail "leg $leg on $bl: rc 0 but no PASS marker"; rc=1; continue; }
            grep '^  ok  \|^SKIP' "$log" | sed 's/^/ /'
        else
            fail "leg $leg on $bl (log tail follows)"
            sed 's/^/      | /' "$log" | tail -40
            rc=1
        fi
    done
done

[ "$rc" != 0 ] || echo "ALLPASS"
exit $rc
