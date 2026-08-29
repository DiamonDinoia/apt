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

# The links come from packages.toml, so the test cannot drift from the package:
# a tool added there is a tool checked here. Names and targets are read
# separately because the checks below need both and must not assume the one can
# be derived from the other.
IFS=$'\t' read -r links targets < <(python3 -c "import tomllib
spec = tomllib.load(open('packages.toml', 'rb'))['gcc-17']['links']
print(' '.join(spec) + chr(9) + ' '.join(t.split('/')[-1] for t in spec.values()))")

"$engine" run --rm -i debian:sid bash -s "$boot" "$links" "$targets" <<'INNER'
set -euo pipefail
boot=$1
links=$2
targets=$3
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

# The route a user is on: an older bootstrap already installed, reached only by
# `apt upgrade`. Installing /tmp/boot.deb by path skips version comparison, so
# it cannot see a republished package that kept its version, which is exactly
# how a corrected pin once reached nobody. The stand-in for that older package
# is this one with the gcc-17 stanza taken out and the serial dropped to 0.
new_v=$(dpkg-deb -f /tmp/boot.deb Version)
dpkg-deb -R /tmp/boot.deb /tmp/stale
python3 - <<'STALE'
import re, pathlib
pin = pathlib.Path("/tmp/stale/etc/apt/preferences.d/diamondinoia")
pin.write_text(re.sub(r"\nPackage: gcc-17\n[^\n]*\nPin-Priority: 100\n", "", pin.read_text()))
ctl = pathlib.Path("/tmp/stale/DEBIAN/control")
ctl.write_text(re.sub(r"^Version: 1\.\d+", "Version: 1.0", ctl.read_text(), flags=re.M))
STALE
dpkg-deb --build /tmp/stale /tmp/stale.deb >/dev/null
apt-get -qq install -y /tmp/stale.deb >/dev/null
apt-get -qq update

# Reproduce the reported failure first, or the upgrade below proves nothing.
stale_cand=$(apt-cache policy gcc-17 | sed -n 's/^ *Candidate: //p')
[ "$stale_cand" = "(none)" ] ||
    fail "the stale pin should leave gcc-17 with no candidate, got '$stale_cand'"
ok "control: the stale pin leaves gcc-17 uninstallable"

apt-get -qq install -y --only-upgrade diamondinoia-apt >/dev/null
have=$(dpkg-query -W -f '${Version}' diamondinoia-apt)
[ "$have" = "$new_v" ] ||
    fail "apt upgrade left diamondinoia-apt at $have, not $new_v"
ok "apt upgrade moves the bootstrap 1.0 -> $new_v"
apt-get -qq update
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
# A symlink on PATH proves only that a name exists. Running each one proves
# the target behind it is present and can start, which is what catches a tool
# the payload dropped or one that cannot find its own runtime.
for c in gcc-17 $links; do
    command -v "$c" >/dev/null || fail "$c is not on PATH"
    "$c" --version >/dev/null 2>&1 || fail "$c is on PATH but exits non-zero"
done
ok "gcc-17 and all $(wc -w <<<"$links") linked tools run"

# Every executable the payload ships is either linked onto PATH or excluded for
# a stated reason, so a front end a future payload adds fails here instead of
# going unnoticed. Excluded: the bundled binutils and gprofng, which the driver
# finds itself and which Debian's gcc-13 through gcc-16 do not put on PATH
# either; the x86_64-linux-gnu-* aliases, which carry no version suffix in the
# payload, so linking them would invent a name no current Debian gcc-NN ships
# (gcc-12 shipped eight of them, gcc-13 onwards ship none); c++, which has no
# -NN spelling in Debian; and go and gofmt, which cannot start.
skip='^(x86_64-linux-gnu-.*|go|gofmt|c\+\+|addr2line|ar|as|c\+\+filt|elfedit'
skip+='|gp-.*|gprof|gprofng.*|ld|ld\.bfd|nm|objcopy|objdump|ranlib|readelf'
skip+='|size|strings|strip)$'
linked=$(printf '%s\n' gcc $targets | sort)
present=$(for b in /opt/gcc-17/bin/*; do n=${b##*/}
              [[ $n =~ $skip ]] || printf '%s\n' "$n"; done | sort)
extra=$(comm -13 <(printf '%s\n' "$linked") <(printf '%s\n' "$present"))
[ -z "$extra" ] || fail "the payload ships tools that are neither linked nor
    excluded, so packages.toml is behind it:$(printf '\n  %s' $extra)"
ok "all $(wc -l <<<"$present") tools in the payload are linked or excluded"

# Control: a name the payload does not ship must come out of the same
# comparison, or an empty result above means only that the comparison is broken.
[ "$(comm -13 <(printf '%s\n' "$linked") \
              <(printf '%s\n' "$present" ; echo zz-new-frontend))" = zz-new-frontend ] ||
    fail "control: an unlinked tool did not show up, so the check above is blind"
ok "control: an unlinked tool is reported"

# A tool that starts is not a tool that links. libgcobol.so needs libxml2, which
# no --version call touches, so gcobol-17 died at link time in a container
# holding only what this package declares. The sweep therefore covers the whole
# payload: libexec holds the binaries gccgo invokes for cgo, and nothing on
# PATH would have shown them.
unresolved() {          # libraries $1 needs that the container cannot supply
    local out
    # ldd answers non-zero for a script or a static object, which is a normal
    # answer over a tree of mixed files, so the verdict is the text it prints.
    out=$(ldd "$1" 2>/dev/null) || out=
    printf '%s\n' "$out" | awk -v f="${1#/opt/gcc-17/}" '/not found/{ print f, $1 }'
}
missing=$(find /opt/gcc-17 -type f \( -perm -u+x -o -name '*.so*' \) |
          while read -r f; do unresolved "$f"; done)

# One class is accepted: go, gofmt and the four binaries gccgo runs for cgo are
# built against the payload's own libgo with no rpath to it. None is linked onto
# PATH and cgo does not work. Everything else has to resolve against what this
# package declares.
other=$(grep -v ' libgo\.so\.25$' <<<"$missing") || other=
[ -z "$other" ] || fail "unresolved shared libraries:$(printf '\n  %s' $other)"
ok "every payload object resolves apart from the Go helpers"

# Control: those Go helpers are permanently unresolvable, so a sweep that stops
# reporting them has stopped working. It runs on the same find and the same
# loop as the check above, not on a separate call.
n=$(grep -c ' libgo\.so\.25$' <<<"$missing") || n=0
[ "$n" -eq 6 ] || fail "control: the sweep reported $n Go helpers, expected 6"
ok "control: the sweep still reports all $n unresolvable Go helpers"

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

# Every front end the payload ships that can compile a program today. gccrs
# refuses by design, "gccrs is not yet able to compile Rust code properly", and
# ga68 is left at the version check with it; both are still linked, so the loop
# above proves they start. Each language sums 1..100 so one expected string
# covers them all, and each links with the documented rpath because the runtime
# libraries live in the payload, not in Debian.
rp=-Wl,-rpath,/opt/gcc-17/lib64
mkdir -p /tmp/lang && cd /tmp/lang

cat > h.adb <<'ADA'
with Ada.Text_IO;
procedure H is
   S : Integer := 0;
begin
   for I in 1 .. 100 loop S := S + I; end loop;
   Ada.Text_IO.Put_Line (Integer'Image (S));
end H;
ADA
cat > h.d <<'D'
import std.stdio;
void main() { int s = 0; foreach (i; 1 .. 101) s += i; writeln(s); }
D
cat > h.mod <<'MOD'
MODULE h ;
FROM StrIO IMPORT WriteLn ;
FROM NumberIO IMPORT WriteCard ;
VAR s, i: CARDINAL ;
BEGIN
   s := 0 ;
   FOR i := 1 TO 100 DO s := s + i END ;
   WriteCard(s, 0) ; WriteLn
END h.
MOD
cat > h.go <<'GO'
package main
import "fmt"
func main() { s := 0; for i := 1; i <= 100; i++ { s += i }; fmt.Println(s) }
GO
cat > h.cob <<'COB'
       IDENTIFICATION DIVISION.
       PROGRAM-ID. H.
       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 S PIC 9(5) VALUE 0.
       01 I PIC 9(5).
       PROCEDURE DIVISION.
           PERFORM VARYING I FROM 1 BY 1 UNTIL I > 100
               COMPUTE S = S + I
           END-PERFORM
           DISPLAY S
           STOP RUN.
COB

# Ada is the odd one: gnatmake drives the whole chain, so the linker flag has
# to be passed through to it rather than given to a compiler driver.
gnatmake-17 -q h.adb -bargs -largs "$rp" || fail "gnatmake-17 could not build h.adb"
gdc-17    -o hd h.d   "$rp" || fail "gdc-17 could not compile h.d"
gm2-17    -o hm h.mod "$rp" || fail "gm2-17 could not compile h.mod"
gccgo-17  -o hg h.go  "$rp" || fail "gccgo-17 could not compile h.go"
gcobol-17 -o hc h.cob "$rp" || fail "gcobol-17 could not compile h.cob"

for pair in "./h Ada 5050" "./hd D 5050" "./hm Modula-2 5050" \
            "./hg Go 5050" "./hc COBOL 05050"; do
    set -- $pair
    out=$("$1" 2>&1 | tr -d ' ')
    [ "$out" = "$3" ] || fail "$2 printed '$out', expected '$3'"
done
ok "Ada, D, Modula-2, Go and COBOL each compile and print the sum"
cd /

# A symlink on PATH proves nothing about the tool behind it, so each one has
# to produce its own output from a real input.
cat > /tmp/cov.c <<'C'
#include <stdio.h>
int main(void) {
    int sum = 0;
    for (int i = 1; i <= 100; ++i)
        sum += i;
    printf("%d\n", sum);
    return 0;
}
C
cd /tmp
gcc-17 -O0 --coverage -o cov cov.c
[ "$(./cov)" = 5050 ] || fail "the instrumented program printed the wrong sum"
gcov-17 cov.gcno >/dev/null
cov=$(awk -F: '$2 + 0 == 5 { gsub(/ /, "", $1); print $1 }' /tmp/cov.c.gcov)
[ "$cov" = 100 ] ||
    fail "gcov-17 counted '$cov' executions of the loop body, expected 100"
ok "gcov-17 counts the loop body 100 times"

gcc-17 -O2 -flto -c -o /tmp/lto.o /tmp/cov.c
syms=$(lto-dump-17 -list /tmp/lto.o)
grep -w main <<<"$syms" >/dev/null ||
    fail "lto-dump-17 did not list main:$(printf '\n%s' "$syms")"
ok "lto-dump-17 lists main out of an LTO object"

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
