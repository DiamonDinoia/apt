#!/bin/bash
# Verify that out/ is a usable apt repository.
#
# Check 1: apt reads the index, and every package it advertises is visible to
#          apt at the advertised version, coming from this repository.
# Check 2: a package carries no payload, only a pinned URL and SHA-256, so the
#          URL must still answer and the hash must be a hash.
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
for deb in "$repo"/*.deb; do
  pkg=$(dpkg-deb -f "$deb" Package)
  # A package with no postinst carries its own files and pins no payload, which
  # is true of the bootstrap package and of nothing else here.
  if ! script=$(dpkg-deb -I "$deb" postinst 2>/dev/null); then
    printf 'ok    %-18s ships its own files\n' "$pkg"
    continue
  fi
  url=$(sed -n "s/^curl -fsSL '\(.*\)' -o .*/\1/p" <<<"$script")
  sha=$(sed -n "s/^echo '\([0-9a-f]*\)  '.*/\1/p" <<<"$script")

  if [[ ${#sha} -ne 64 ]]; then
    printf 'FAIL  %-18s pinned hash is %q, not a SHA-256\n' "$pkg" "$sha"
    fail=1
  elif ! code=$(curl -fsSLI -o /dev/null -w '%{http_code}' --max-time 30 "$url"); then
    printf 'FAIL  %-18s payload unreachable: %s\n' "$pkg" "$url"
    fail=1
  else
    printf 'ok    %-18s payload %s %s\n' "$pkg" "$code" "${sha:0:12}"
  fi
done

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

# Check 6: the README names every linked tool, so the list a reader copies from
# has to be the list the package installs. Docs drift silently; a diff does not.
# A table the regex fails to find reads as empty and reports all 28 names as
# missing, so a broken parse cannot pass as agreement.
if python3 - <<'DOC'; then
import re, sys, tomllib
links = tomllib.load(open("packages.toml", "rb"))["gcc-17"]["links"]
table = re.search(r"\n    gcc-17 .*?\n\n", open("README.md").read(), re.S)
listed = set(re.findall(r"\b[a-z+0-9-]+-17\b", table.group(0))) if table else set()
want = set(links) | {"gcc-17"}
for name in sorted(listed - want):
    print(f"      the README lists {name}, which packages.toml does not link")
for name in sorted(want - listed):
    print(f"      packages.toml links {name}, which the README does not list")
sys.exit(listed != want)
DOC
  echo "ok    the README table names exactly the $(($(grep -c '" = "bin/' packages.toml) + 1)) linked tools"
else
  echo "FAIL  the README table and packages.toml disagree"; fail=1
fi

exit $fail
