#!/bin/bash
# End-to-end check of the gcc-17 package in a clean container: it installs from
# the published repository, the compiler it installs actually compiles, and the
# pin hands the name over to the distribution the moment the distribution
# publishes it. The handover is the part CI cannot check, because it needs a
# second repository standing in for Debian's archive.
set -euo pipefail

engine=$(command -v podman || command -v docker) || {
    echo "FAIL  no podman or docker; this check cannot run"; exit 1; }
repo=${1:-DiamonDinoia/apt}

boot=$(gh release view repo --repo "$repo" --json assets \
       -q '.assets[] | select(.name|startswith("diamondinoia-apt_")) | .url')
[ -n "$boot" ] || { echo "FAIL  no bootstrap package in the repo release"; exit 1; }
echo "bootstrap: $boot"

"$engine" run --rm -i debian:sid bash -s "$boot" <<'INNER'
set -euo pipefail
boot=$1
fail() { echo "FAIL  $*"; exit 1; }
ok()   { echo "  ok   $*"; }

export DEBIAN_FRONTEND=noninteractive
apt-get -qq update
# --no-install-recommends on purpose: dpkg-dev recommends build-essential, and
# letting that in would install libc6-dev behind the package's back, so the
# compile below would pass whether or not gcc-17 declares what it needs.
apt-get -qq install -y --no-install-recommends \
    curl ca-certificates dpkg-dev python3-minimal >/dev/null

echo "== bootstrap package installs the key, the source and the pin"
curl -fsSL "$boot" -o /tmp/boot.deb
apt-get -qq install -y /tmp/boot.deb >/dev/null
# Every check below reads a captured string rather than piping into `grep -q`.
# Under `pipefail` a `grep -q` that exits on the first match sends SIGPIPE to
# the producer, and the pipeline then reports 141 even though the match was
# found, which turns a pass into a failure.
pin=$(cat /etc/apt/preferences.d/diamondinoia)
grep -A2 '^Package: gcc-17$' <<<"$pin" | grep 'Pin-Priority: 100' >/dev/null ||
    fail "gcc-17 is not pinned at 100:$(printf '\n%s' "$pin")"
ok "pinned at 100"
apt-get -qq update

echo "== gcc-17 resolves from this repository while Debian has no such package"
apt-cache policy gcc-17
cand=$(apt-cache policy gcc-17 | sed -n 's/^ *Candidate: //p')
[[ $cand =~ ^17~trunk[0-9]{8}$ ]] ||
    fail "candidate is '$cand', not a 17~trunkYYYYMMDD version"
ok "candidate is the nightly"

echo "== install, with signature verification left on"
apt-get install -y gcc-17
for c in gcc-17 g++-17 gfortran-17; do
    command -v "$c" >/dev/null || fail "$c is not on PATH"
done
ok "gcc-17, g++-17 and gfortran-17 are on PATH"

echo "== the compiler reports the major the package is named for"
gcc-17 --version | sed -n 1p
dv=$(gcc-17 -dumpversion)
[[ $dv == 17.* ]] || fail "gcc-17 -dumpversion is $dv, not 17.x"
ok "-dumpversion is $(gcc-17 -dumpversion)"

echo "== it compiles and the program produces the right answer"
cat > /tmp/t.cpp <<'CPP'
#include <cstdio>
#include <numeric>
#include <vector>
constexpr int sum(int n) { std::vector<int> v(n); std::iota(v.begin(), v.end(), 1);
                           return std::accumulate(v.begin(), v.end(), 0); }
static_assert(sum(100) == 5050, "constexpr vector is broken");
int main() { std::printf("%d\n", sum(100)); }
CPP
g++-17 -std=c++26 -O2 -o /tmp/t /tmp/t.cpp -static-libstdc++ || fail "g++-17 could not compile"
out=$(/tmp/t)
[ "$out" = 5050 ] || fail "program printed '$out', expected 5050"
ok "g++-17 -std=c++26 compiles and the binary prints 5050"

cat > /tmp/t.f90 <<'F90'
program p
  print '(I0)', sum([(i, i=1,100)])
end program p
F90
gfortran-17 -O2 -Wl,-rpath,/opt/gcc-17/lib64 -o /tmp/tf /tmp/t.f90 ||
    fail "gfortran-17 could not compile"
[ "$(/tmp/tf)" = 5050 ] || fail "fortran program printed '$(/tmp/tf)'"
ok "gfortran-17 with the documented -Wl,-rpath compiles and prints 5050"

echo "== control: a program that must not compile does not"
echo 'int main(){ return undefined_symbol_xyz(); }' > /tmp/bad.c
gcc-17 -Werror=implicit-function-declaration -o /tmp/bad /tmp/bad.c 2>/dev/null &&
    fail "the compiler accepted an undeclared function; earlier successes prove nothing"
ok "an invalid program is rejected, so the successes above are real"

echo
echo "== handover: a second repository stands in for Debian shipping gcc-17"
mkdir -p /srv/deb/pkg/DEBIAN
stub() {
    printf 'Package: gcc-17\nVersion: %s\nArchitecture: amd64\nMaintainer: d <d@invalid>\nDescription: stand-in for the distribution package\n' "$1" \
        > /srv/deb/pkg/DEBIAN/control
    rm -f /srv/deb/*.deb
    dpkg-deb --root-owner-group --build /srv/deb/pkg "/srv/deb/gcc-17_$1_amd64.deb" >/dev/null
    # A compressed index too, or apt logs six warnings per update for the
    # variants it cannot find, which buries the evidence this check produces.
    ( cd /srv/deb && dpkg-scanpackages --multiversion . /dev/null > Packages 2>/dev/null
      gzip -kf Packages )
    echo 'deb [trusted=yes] file:///srv/deb ./' > /etc/apt/sources.list.d/stand-in.list
    apt-get -qq update
}

mine=$(dpkg-query -W -f '${Version}' gcc-17)

echo "-- the distribution publishes a higher version"
stub 17.1.0-1
apt-cache policy gcc-17
[ "$(apt-cache policy gcc-17 | sed -n 's/^ *Candidate: //p')" = 17.1.0-1 ] ||
    fail "the distribution package did not become the candidate"
for cmd in upgrade dist-upgrade; do
  grep '^Inst gcc-17 .*17\.1\.0-1' <<<"$(apt-get -s $cmd)" >/dev/null ||
    fail "apt-get $cmd does not hand gcc-17 over"
done
ok "apt upgrade and dist-upgrade both replace $mine with 17.1.0-1"

echo "-- control: raise the pin to 600 and nothing else, ours must win again"
# Same two repositories, same two versions. Only the pin differs, so the pin is
# what causes the handover and the check above is not passing for some other
# reason. apt does not downgrade across priorities, which is why the version
# also has to sort below the distribution's; the pin alone is not enough.
cp /etc/apt/preferences.d/diamondinoia /tmp/pin.orig
python3 - <<'PIN'
import pathlib
f = pathlib.Path("/etc/apt/preferences.d/diamondinoia")
f.write_text(f.read_text().replace("Package: gcc-17\nPin: release l=diamondinoia\nPin-Priority: 100",
                                   "Package: gcc-17\nPin: release l=diamondinoia\nPin-Priority: 600"))
PIN
[ "$(grep -c 'Pin-Priority: 600' /etc/apt/preferences.d/diamondinoia)" = 2 ] ||
    fail "the pin rewrite did not take"

apt-get -qq update
[ "$(apt-cache policy gcc-17 | sed -n 's/^ *Candidate: //p')" = "$mine" ] ||
    fail "at 600 the nightly is still not the candidate; the pin is not the cause"
grep '^Inst gcc-17' <<<"$(apt-get -s upgrade)" >/dev/null &&
    fail "at 600 an upgrade to the stand-in is still offered"
ok "at 600 the candidate is $mine and no handover happens"
cp /tmp/pin.orig /etc/apt/preferences.d/diamondinoia

echo
echo "ALLPASS"
INNER
