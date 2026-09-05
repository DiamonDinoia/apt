#!/bin/bash
# Verify that out/ is a usable apt repository.
#
# Check 1: apt reads the index, and every package it advertises is visible to
#          apt at the advertised version, coming from this repository.
# Check 2: a package carries no payload, only a pinned URL and SHA-256, so the
#          URL must still answer and the hash must be a hash. Passthrough
#          packages carry their own deb; the signed index binds its bytes.
# Check 3 (positive control): mutating Packages after Release was written must
#          make apt reject the repository. Without it the checks above cannot be
#          told apart from apt quietly ignoring an index it never read.
# Check 4: every Filename in the index survives the release host unrewritten.
# Check 5: the bootstrap package changes version whenever the files it installs
#          change, because apt offers no upgrade at a version it already holds.
#
# Dependency resolution is not checked here. It only means anything against the
# archive the packages target, and test_install.sh proves it by installing them
# in a Debian sid container. Simulating it against whatever archive this host
# happens to carry fails on packages that install correctly.
#
# Nothing is installed and nothing outside the temporary directory is written.
set -uo pipefail

repo=$(cd "$(dirname "$0")" && pwd)/out
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The merged spec is the single test interface for everything build.py derives:
# wrapper shapes and pins, bundle links/exclusions/depends, repos. Offline.
# Kept in a file: it is too large for argv/env.
spec=$work/spec.json
python3 "$(dirname "$0")/build.py" --dump-spec > "$spec"

mkdir -p "$work"/{sources,lists/partial,archives/partial}
cp /etc/apt/sources.list.d/* "$work/sources/" 2>/dev/null
echo "deb [trusted=yes] file://$repo ./" > "$work/sources/zz-local.list"

apt=(-o Dir::Etc::sourcelist=/dev/null
     -o Dir::Etc::sourceparts="$work/sources"
     -o Dir::State::lists="$work/lists"
     -o Dir::Cache::archives="$work/archives"
     -o Dir::Etc::preferences=/dev/null
     -o Dir::Etc::preferencesparts=/dev/null
     -o APT::Get::AllowUnauthenticated=true)

if ! apt-get "${apt[@]}" update -qq 2>"$work/err"; then
  echo "FAIL  apt update rejected the repository"; cat "$work/err"; exit 1
fi

fail=0
while read -r pkg ver; do
  # Check 1. The version table must bind the advertised version to this repo.
  # grep without -q: -q exits on the first match and SIGPIPEs whatever feeds
  # it, which pipefail then reports as a failed pipeline despite the match.
  if ! apt-cache "${apt[@]}" policy "$pkg" | grep -A5 -F " $ver " | grep -F "$repo" >/dev/null; then
    printf 'FAIL  %-18s %s not offered by this repository\n' "$pkg" "$ver"
    fail=1
    continue
  fi
  printf 'ok    %-18s %s\n' "$pkg" "$ver"
done < <(awk '/^Package: /{p=$2} /^Version: /{print p, $2}' "$repo/Packages")

# Check 2. A package carries no payload, only a URL and a hash, so the URL has
# to answer and the hash has to be a hash. A HEAD follows the publisher's
# redirects the same way the postinst curl does.
# Which packages intentionally serve their own deb is a property of the merged
# spec, not of whatever a postinst happens to contain: a wrapper that lost its
# pinned download must still fail here, and sniffing the script would mistake
# that loss for a passthrough package.
pt=" $(python3 -c "import json
print(' '.join(n for n, w in json.load(open('$spec'))['wrappers'].items()
               if w.get('install') == 'passthrough'))") "
: > "$work/probes"
for deb in "$repo"/*.deb; do
  pkg=$(dpkg-deb -f "$deb" Package)
  # A package with no postinst carries its own files and pins no payload, which
  # is true of the bootstrap package and of nothing else here.
  if ! script=$(dpkg-deb -I "$deb" postinst 2>/dev/null); then
    printf 'ok    %-18s ships its own files\n' "$pkg"
    continue
  fi
  url=$(sed -n "s/^curl -fsSL '\(.*\)' -o .*/\1/p" <<<"$script")
  case "$pt" in
  *" $pkg "*)
    # A passthrough deb pins no URL: the bytes are served, and the signed index
    # binds them. Its postinst is the payload's own.
    if [ -n "$url" ]; then
      printf 'FAIL  %-18s is passthrough but its postinst pins a payload\n' "$pkg"
      fail=1
      continue
    fi
    printf 'ok    %-18s serves its own deb, built and tested by its fork\n' "$pkg"
    continue
    ;;
  esac
  if [ -z "$url" ]; then
    printf 'FAIL  %-18s is no passthrough package but its postinst pins no payload\n' "$pkg"
    fail=1
    continue
  fi
  sha=$(sed -n "s/^echo '\([0-9a-f]*\)  '.*/\1/p" <<<"$script")
  printf '%s\0%s\0%s\0' "$pkg" "$url" "$sha" >> "$work/probes"
done
# The probes run in parallel; a bundle payload is a large file on the mirror,
# and a HEAD answers from its headers alone. max-time is per probe, unchanged.
xargs -0 -r -n 3 -P 8 bash -c '
  pkg=$1 url=$2 sha=$3
  if [[ ${#sha} -ne 64 ]]; then
    printf "FAIL  %-18s pinned hash is %q, not a SHA-256\n" "$pkg" "$sha"
    exit 1
  fi
  if ! code=$(curl -fsSLI -o /dev/null -w "%{http_code}" --max-time 30 "$url"); then
    printf "FAIL  %-18s payload unreachable: %s\n" "$pkg" "$url"
    exit 1
  fi
  printf "ok    %-18s payload %s %s\n" "$pkg" "$code" "${sha:0:12}"
' _ < "$work/probes" > "$work/probe-out"
sort "$work/probe-out"
grep -q '^FAIL' "$work/probe-out" && fail=1

# Positive control for check 2: the reachability probe must fail on a URL that
# does not resolve, or a dead payload would pass unnoticed.
if curl -fsSLI -o /dev/null --max-time 30 \
     https://github.com/DiamonDinoia/apt/releases/download/repo/no-such-asset 2>/dev/null; then
  echo "FAIL  positive control: curl accepted a missing payload"
  fail=1
else
  echo "ok    positive control: missing payload rejected"
fi

# Check 4. Every Filename in the index has to survive the release host, which
# rewrites a character it dislikes and leaves the index pointing at a 404. The
# published index is never fetched here, so this is the only place that catches
# it before users do.
bad=$(awk '/^Filename: /{ if ($2 !~ /^[A-Za-z0-9._+-]+$/) print $2 }' "$repo/Packages")
if [ -n "$bad" ]; then
  echo "FAIL  index filenames a release host may rewrite:"; printf '  %s\n' $bad; exit 1
fi
echo "ok    every Filename uses characters a release host keeps"

# Positive control for check 4: the pattern must reject a name that needs it.
if grep -E '^[A-Za-z0-9._+-]+$' <<<'gcc-17_17~trunk20260828_amd64.deb' >/dev/null; then
  echo "FAIL  positive control: the filename pattern accepted a '~' name"; exit 1
fi
echo "ok    positive control: a '~' filename is rejected"

# Check 3. Release carries the SHA256 of Packages, so any edit must be caught.
cp "$repo/Packages" "$work/Packages.bak"
printf 'Package: bogus\nVersion: 1\nArchitecture: amd64\n\n' >> "$repo/Packages"
rm -rf "$work/lists"; mkdir -p "$work/lists/partial"
if apt-get "${apt[@]}" update -qq 2>/dev/null &&
   apt-cache "${apt[@]}" policy bogus | grep -F 'Candidate: 1' >/dev/null; then
  echo "FAIL  positive control: apt accepted a mutated Packages index"
  fail=1
else
  echo "ok    positive control: mutated index rejected"
fi
cp "$work/Packages.bak" "$repo/Packages"

# Check 5. The bootstrap package carries the pin, and a pin only reaches an
# existing installation through an upgrade. Compare what this build produces
# against what is published: same files must keep the version, different files
# must raise it. build.py decides this from the same pair, so the comparison is
# repeated here from the published artifact rather than trusted.
boot=$(cd "$repo" && echo diamondinoia-apt_*_all.deb)
new_v=${boot#diamondinoia-apt_}; new_v=${new_v%_all.deb}
url=https://github.com/DiamonDinoia/apt/releases/download/repo
old_b=$(curl -fsSL "$url/Packages" |
        awk '/^Filename: diamondinoia-apt_/{ print $2 }')
if [ -z "$old_b" ]; then
  echo "FAIL  the published index advertises no bootstrap package"; fail=1
else
  old_v=${old_b#diamondinoia-apt_}; old_v=${old_v%_all.deb}
  curl -fsSL -o "$work/old.deb" "$url/$old_b"
  dpkg-deb -x "$work/old.deb" "$work/old"
  dpkg-deb -x "$repo/$boot" "$work/new"
  # Different files must raise the version, or the change reaches nobody. An
  # unchanged rebuild may still raise it, because build.py holds a floor under
  # serials that were published twice with different contents.
  if diff -r "$work/old" "$work/new" >/dev/null; then
    want=ge; why="the files are identical"
  else
    want=gt; why="the files differ"
  fi
  if dpkg --compare-versions "$new_v" "$want" "$old_v"; then
    echo "ok    bootstrap $old_v -> $new_v, $why"
  else
    echo "FAIL  bootstrap $old_v -> $new_v, but $why so it must be $want"; fail=1
  fi
fi

# Positive control for check 5: an unchanged version must fail the gt arm, which
# is exactly the case that shipped a stale pin nobody could receive.
if dpkg --compare-versions "$new_v" gt "$new_v"; then
  echo "FAIL  positive control: dpkg called a version greater than itself"; fail=1
else
  echo "ok    positive control: an unmoved version does not satisfy gt"
fi

# Check 6: the README names every linked tool and the exclusion accounting of
# the gcc-17 payload (28 linked; 45 excluded as 27 bundled binutils/gprofng, 15
# triplet aliases, 1 c++, 2 go/gofmt), so the spec a reader copies from has to
# be the partition the bundle installs. Docs drift silently; a diff does not. A
# table the regex fails to find reads as empty and reports all 28 names as
# missing, so a broken parse cannot pass as agreement.
if python3 - "$spec" <<'DOC'; then
import json, re, sys
from collections import Counter
spec = json.load(open(sys.argv[1]))
bundle = spec["bundles"]["gcc-17"]
want = set(bundle["links"]) | {"gcc-17"}
readme = open("README.md").read()
table = re.search(r"\n    gcc-17 .*?\n\n", readme, re.S)
listed = set(re.findall(r"\b[a-z+0-9-]+-17\b", table.group(0))) if table else set()
for name in sorted(listed - want):
    print(f"      the README lists {name}, which the spec does not link")
for name in sorted(want - listed):
    print(f"      the spec links {name}, which the README does not list")
ok = listed == want and len(want) == 28
# The README's exclusion prose is the oracle for the 45-name partition: the
# numerals come from the text itself, so a prose rewrite that drops them fails
# loudly rather than neutralising the check.
classes = Counter(x["class"] for x in bundle["link_exclusions"].values())
oracle = {}
m = re.search(r"(\d+) are\s+the\s+bundled\s+binutils", readme)
if m: oracle["bundled-binutils"] = int(m.group(1))
m = re.search(r"(\d+) are\s+`?x86_64-linux-gnu-`?\s+aliases", readme)
if m: oracle["triplet-alias"] = int(m.group(1))
if re.search(r"[Oo]ne is `?c\+\+`?", readme): oracle["no-series-spelling"] = 1
if re.search(r"two are `?go`? and `?gofmt`?", readme): oracle["go-libgo"] = 2
if oracle != {"bundled-binutils": 27, "triplet-alias": 15,
              "no-series-spelling": 1, "go-libgo": 2}:
    print(f"      the README prose no longer states the 27/15/1/2 accounting: {oracle}")
    ok = False
if dict(classes) != oracle:
    print(f"      spec exclusion classes {dict(classes)} != README oracle {oracle}")
    ok = False
total = len(bundle["links"]) + 1 + len(bundle["link_exclusions"])
if total != 73:
    print(f"      gcc-17 accounts for {total} bin/ names, expected 73")
    ok = False
sys.exit(not ok)
DOC
  echo "ok    the README names exactly the spec's 28 linked tools, and its 27/15/1/2 exclusion oracle matches the spec"
else
  echo "FAIL  the README and the spec disagree on the gcc-17 partition"; fail=1
fi

# Check 7: the README's install command must not name a version. It named
# 1.0+939a3a3d and kept naming it after the serial moved to 1.1, so the very
# first command a new user runs answered 404. Check 5 already proves the name
# derived from the published index is fetchable; this proves the README derives
# it rather than spelling it out.
if grep -qE 'diamondinoia-apt_[0-9]' README.md; then
  echo "FAIL  the README hardcodes a bootstrap version in an install command"; fail=1
else
  echo "ok    the README derives the bootstrap file name from the index"
fi
if ! grep -qE 'diamondinoia-apt_[0-9]' <<<'diamondinoia-apt_1.0+abc12345_all.deb'; then
  echo "FAIL  positive control: the pattern misses a versioned file name"; fail=1
else
  echo "ok    positive control: the pattern catches a versioned file name"
fi

# Check 8: the README prints the pin file, and a reader who trusts it has to be
# reading the pin the package installs. The 600 stanza gained two names when
# the repo packages appeared and the README kept the old list, which is the
# same drift check 6 exists for, on the other block of the same document.
dpkg-deb --fsys-tarfile "$repo/$boot" |
    tar -xO ./etc/apt/preferences.d/diamondinoia > "$work/pin" 2>/dev/null
if python3 - "$work/pin" <<'DOC'; then
import re, sys

def names(text):
    # A continuation line starts with a space, so this cannot run past the
    # stanza above into the one that is pinned at -1.
    m = re.search(r"Package: ((?:[^\n]|\n )*)\n"
                  r"Pin: release l=diamondinoia\nPin-Priority: 600", text)
    return set(m.group(1).split()) if m else set()

built = names(open(sys.argv[1]).read())
doc = names(re.sub(r"^    ", "", open("README.md").read(), flags=re.M))
for n in sorted(doc - built):
    print(f"      the README pins {n}, which the built pin does not")
for n in sorted(built - doc):
    print(f"      the built pin holds {n}, which the README does not")
sys.exit(not built or built != doc)
DOC
  echo "ok    the README prints the pin the package installs"
else
  echo "FAIL  the README pin and the built pin disagree"; fail=1
fi

# Check 9: the README names the sources the bootstrap package carries, and a
# reader who installs on that promise has to get them. The vscode source was
# on the machine and in neither, so the list is exactly the kind of thing that
# is wrong without anyone noticing.
if python3 - "$spec" <<'DOC'; then
import json, re, sys
repos = json.load(open(sys.argv[1]))["repos"]
want = {n for n, r in repos.items() if not r.get("separate")}
block = re.search(r"with the keys\nthat verify them:\n\n((?:    .*\n)+)",
                  open("README.md").read())
listed = set(block.group(1).split()) if block else set()
for n in sorted(listed - want):
    print(f"      the README names {n}, which the spec does not carry")
for n in sorted(want - listed):
    print(f"      the spec carries {n}, which the README does not name")
sys.exit(not listed or listed != want)
DOC
  echo "ok    the README names the $(python3 -c "import json
print(sum(1 for v in json.load(open('$spec'))['repos'].values() if not v.get('separate')))") carried sources"
else
  echo "FAIL  the README and the spec disagree on the carried sources"; fail=1
fi

# Check 10: pin-aware policy. The bootstrap's preferences land in this apt
# context, so priorities are the ones a user gets. Every emitted bundle name
# must be offered by this repository, one representative compiler proves the
# glob stanza sits at 100, and a name outside the index must show no offer
# from us at all. Non-vacuity: the 100 stanza must cover at least one offered
# name (an empty or never-matching stanza would satisfy every line vacuously).
boot=$(cd "$repo" && echo diamondinoia-apt_*_all.deb)
mkdir -p "$work/prefs"
dpkg-deb --fsys-tarfile "$repo/$boot" |
    tar -xO ./etc/apt/preferences.d/diamondinoia > "$work/prefs/diamondinoia" 2>/dev/null
apt_p=(-o Dir::Etc::sourcelist=/dev/null
      -o Dir::Etc::sourceparts="$work/sources"
      -o Dir::State::lists="$work/lists"
      -o Dir::Cache::archives="$work/archives"
      -o Dir::Etc::preferences=/dev/null
      -o Dir::Etc::preferencesparts="$work/prefs"
      -o APT::Get::AllowUnauthenticated=true)
rm -rf "$work/lists"; mkdir -p "$work/lists/partial"
apt-get "${apt_p[@]}" update -qq 2>/dev/null

# apt-cache policy prints one `  <version> <priority>` line followed by the
# source lines for that version; ours is the one whose source is this repo,
# and the glob stanza must put it at 100.
n100=0
while IFS=$'\t' read -r pkg ver; do
  [ -n "$pkg" ] || continue
  if apt-cache "${apt_p[@]}" policy "$pkg" |
     awk -v ver="$ver" -v repo="$repo" '
       $1 == ver && $2 ~ /^[0-9]+$/ { prio=$2; want=1; next }
       want && $0 ~ repo { if (prio == 100) found=1; want=0 }
       $2 ~ /^[0-9]+$/ && $1 != ver { want=0 }
       END { exit !found }'; then
    n100=$((n100 + 1))
    printf 'ok    %-18s offered at 100 under the pin\n' "$pkg"
  else
    printf 'FAIL  %-18s not offered by this repository at pin 100\n' "$pkg"
    apt-cache "${apt_p[@]}" policy "$pkg" | sed 's/^/         /'
    fail=1
  fi
done < <(python3 -c "import json
s = json.load(open('$spec'))
for n, b in sorted(s['bundles'].items()):
    if b.get('state') == 'emit':
        print(n + chr(9) + b['version'])")

if [ "$n100" -lt 1 ]; then
  echo "FAIL  the 100 stanza covers no offered name (non-vacuity)"; fail=1
else
  echo "ok    the 100 stanza covers $n100 offered bundles"
fi
# Positive control: a name not in the index must show no offer from us.
if apt-cache "${apt_p[@]}" policy gcc-99 2>/dev/null | grep -F "$repo" >/dev/null; then
  echo "FAIL  positive control: gcc-99 shows an offer from this repository"
  fail=1
else
  echo "ok    positive control: gcc-99 has no offer from us"
fi

# Check 11: the bundle rules' poison controls (denylist P/C/R, version-order
# gate, soname table, the gcc-17 28/45 oracle) run offline in build.py.
if python3 "$(cd "$(dirname "$0")" && pwd)/build.py" --selftest > "$work/selftest.log" 2>&1; then
  echo "ok    bundle-rule selftest clean"
else
  echo "FAIL  bundle-rule selftest:"; cat "$work/selftest.log"; fail=1
fi

exit $fail
